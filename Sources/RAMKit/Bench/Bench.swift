import Darwin
import Foundation

/// The control arm: identical timing to a real download, but the kernel is never touched. Whatever
/// a control arm "downloads" is natural drift, which is what relief has to beat.
public struct NullBackend: ReliefBackend {
    public let name = "control (no signal)"
    public init() {}
    public func relieve(level: PressureLevel, holdMs: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(holdMs) * 1_000_000)
    }
    public func restore() async throws {}
}

/// A rejected command-line value, with the message to show.
public struct InputError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Command-line inputs for downloads and benchmarks, validated before anything touches the kernel.
public enum InputLimits {
    public static func holdSeconds(_ text: String?) -> Result<Int, InputError> {
        guard let text else { return .success(10) }
        guard let v = Int(text), (1...30).contains(v) else { return .failure(InputError("--hold must be a whole number of seconds from 1 to 30")) }
        return .success(v)
    }
    public static func int(_ text: String?, default d: Int, range: ClosedRange<Int>, name: String) -> Result<Int, InputError> {
        guard let text else { return .success(d) }
        guard let v = Int(text), range.contains(v) else {
            return .failure(InputError("\(name) must be a whole number from \(range.lowerBound) to \(range.upperBound)"))
        }
        return .success(v)
    }
    /// Fixture/workload memory is capped at a quarter of the memory macOS can still hand out.
    public static func cappedMB(_ requested: Int, headroom: UInt64) -> Int {
        max(16, min(requested, Int(headroom / 4 / 1_048_576)))
    }
}

/// Refuses to start (or continue) a benchmark when the Mac is already short of memory.
public enum BenchGate {
    public static let startLevel = 15
    public static let abortLevel = 10

    public static func canStart(_ s: SystemSample) -> (ok: Bool, reason: String) {
        if s.pressureLevel == .critical { return (false, "memory pressure is critical") }
        if s.availablePercent < startLevel { return (false, "only \(s.availablePercent)% memory available (need \(startLevel)%)") }
        return (true, "")
    }

    public static func shouldAbort(_ s: SystemSample) -> Bool {
        s.pressureLevel == .critical || s.availablePercent < abortLevel
    }
}

public struct WorkloadResult: Codable, Sendable {
    public var sizeMB: Int
    public var seconds: Double
    public var gbPerSecond: Double
    public var swapins: UInt64
    public var swapouts: UInt64
    public var compressions: UInt64
    public var decompressions: UInt64
    public var pageins: UInt64
}

public struct ArmResult: Codable, Sendable {
    public var arm: String
    public var trial: Int
    public var startedAt: Date
    public var headlineBytes: Int64
    public var grossFreedBytes: Int64
    public var swapUsedBefore: UInt64
    public var swapUsedAfter: UInt64
    public var compressedBefore: UInt64
    public var compressedAfter: UInt64
    public var wallBefore: Double?
    public var wallAfter: Double?
    public var topApps: [AppDelta]
    public var excludedBusy: [String]
    public var fixtures: [FixtureDelta]
    public var workload: WorkloadResult?
}

public struct FixtureDelta: Codable, Sendable {
    public var kind: String
    public var pid: Int32
    public var before: UInt64
    public var after: UInt64
}

public struct ArmStats: Codable, Sendable {
    public var n: Int
    public var mean: Double
    public var sd: Double
}

public struct BenchSummary: Codable, Sendable {
    public var metric: String
    public var relief: ArmStats
    public var control: ArmStats
    public var welch: WelchResult?
}

public struct BenchResult: Codable, Sendable {
    public var scenario: String
    public var machine: MachineInfo
    public var startedAt: Date
    public var finishedAt: Date
    public var holdMs: Int
    public var settleMs: Int
    public var cooldownS: Double
    public var seed: UInt64
    public var arms: [ArmResult]
    public var summaries: [BenchSummary]
    public var notes: [String]
    /// Arms that were thrown away and run again, and why (another process sent the signal, or the
    /// helper asked to wait). Nil in results from before this rule existed.
    public var redone: [String]? = nil

    public func save(to dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(Receipt.makeID(startedAt))-\(scenario).json")
        try Receipt.encoder.encode(self).write(to: url, options: .atomic)
        return url
    }

    public static func load(_ url: URL) throws -> BenchResult {
        try Receipt.decoder.decode(BenchResult.self, from: Data(contentsOf: url))
    }
}

public enum BenchError: Error, CustomStringConvertible {
    case gate(String)
    case aborted(String)
    case fixture(String)

    public var description: String {
        switch self {
        case .gate(let r): "Not starting the benchmark: \(r). Close something and try again."
        case .aborted(let r): "Benchmark stopped early to protect this Mac: \(r)."
        case .fixture(let r): "Fixture problem: \(r)"
        }
    }
}

/// Runs benchmark scenarios. Relief and control arms alternate in a seeded random order with a
/// cooldown between arms, so ordering and drift do not masquerade as an effect.
public struct BenchRunner: Sendable {
    public var backend: any ReliefBackend
    public var holdMs: Int
    public var settleMs: Int
    public var cooldownS: Double
    public var seed: UInt64
    public var fixtureBinary: String?
    /// Pids of other processes that sent the signal in a time window (from the helper's log).
    /// An arm whose window, including the cooldown before it, saw one is redone, not counted.
    public var foreignSignals: @Sendable (Date, Date) -> [Int32]
    /// Readings for the engine and the gate (injected so tests run on a virtual clock).
    public var sampling: any Sampling
    public static let maxRedos = 3

    public init(backend: any ReliefBackend, holdMs: Int = 10_000, settleMs: Int = 5_000, cooldownS: Double = 60,
                seed: UInt64 = 20_261_020, fixtureBinary: String? = nil,
                foreignSignals: @escaping @Sendable (Date, Date) -> [Int32] = { from, to in
                    HelperLog.reliefCallers(from: from, to: to, excluding: getpid()) ?? []
                }, sampling: any Sampling = LiveSampling()) {
        self.backend = backend
        self.holdMs = holdMs
        self.settleMs = settleMs
        self.cooldownS = cooldownS
        self.seed = seed
        self.fixtureBinary = fixtureBinary
        self.foreignSignals = foreignSignals
        self.sampling = sampling
    }

    /// Helper refusals that clear up by waiting (someone else's download is running or just ended).
    static func isTransient(_ why: String) -> Bool { why.contains("between downloads") || why.contains("already running") }

    /// Order of arms per trial: true = relief first.
    public static func order(trials: Int, seed: UInt64) -> [Bool] {
        var x = seed | 1
        return (0..<trials).map { _ in
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return x & 1 == 1
        }
    }

    // MARK: Scenarios

    /// Real apps: what this Mac's running apps give back, relief vs control.
    public func real(trials: Int, log: @Sendable (String) -> Void) async throws -> BenchResult {
        try await run(scenario: "real", trials: trials, log: log) { _ in ([], nil) }
    }

    /// Controlled fixtures: `hogs` pressure-aware caches and `hogs` processes that ignore pressure.
    public func synthetic(trials: Int, hogs: Int, mb: Int, log: @Sendable (String) -> Void) async throws -> BenchResult {
        guard let fixtureBinary else { throw BenchError.fixture("ram-fixture not found") }
        return try await run(scenario: "synthetic", trials: trials, log: log, notes: [
            "\(hogs) x cachehog (\(mb) MiB, frees on memory pressure) + \(hogs) x dumbhog (\(mb) MiB, ignores it), respawned per arm",
        ]) { _ in
            var procs: [(String, SpawnedFixture)] = []
            for _ in 0..<hogs {
                procs.append(("cachehog", try SpawnedFixture(binary: fixtureBinary, args: ["cachehog", "--mb", "\(mb)"])))
                procs.append(("dumbhog", try SpawnedFixture(binary: fixtureBinary, args: ["dumbhog", "--mb", "\(mb)"])))
            }
            return (procs, nil)
        }
    }

    /// Foreground performance: a workload that needs `sizeMB` of fresh memory, timed right after a
    /// download vs right after a control window.
    public func perf(trials: Int, sizeMB: Int, log: @Sendable (String) -> Void) async throws -> BenchResult {
        guard let fixtureBinary else { throw BenchError.fixture("ram-fixture not found") }
        return try await run(scenario: "perf", trials: trials, log: log, notes: [
            "workload: allocate and write \(sizeMB) MiB in a fresh process, then exit",
        ]) { _ in ([], { try Self.runWorkload(binary: fixtureBinary, sizeMB: sizeMB) }) }
    }

    // MARK: Engine

    typealias Setup = (Int) throws -> ([(String, SpawnedFixture)], (() throws -> WorkloadResult)?)

    func run(scenario: String, trials: Int, log: @Sendable (String) -> Void, notes: [String] = [],
             setup: Setup) async throws -> BenchResult {
        let start = Date()
        let first = try sampling.systemSample()
        let gate = BenchGate.canStart(first)
        guard gate.ok else { throw BenchError.gate(gate.reason) }
        var arms: [ArmResult] = []
        var redone: [String] = []
        let order = Self.order(trials: trials, seed: seed)
        // A foreign signal anywhere from the end of the previous arm to the end of this one
        // (cooldown included) would leak into this arm's numbers.
        var windowStart = Date()
        for trial in 0..<trials {
            for reliefArm in order[trial] ? [true, false] : [false, true] {
              var attempt = 0
              while true {
                if !arms.isEmpty || attempt > 0 {
                    log("cooling down \(Int(cooldownS))s")
                    try await Task.sleep(nanoseconds: UInt64(cooldownS * 1e9))
                }
                let now = try sampling.systemSample()
                if BenchGate.shouldAbort(now) {
                    throw BenchError.aborted("\(now.availablePercent)% available, pressure \(now.pressureLevel.word)")
                }
                let name = reliefArm ? "relief" : "control"
                log("trial \(trial + 1)/\(trials): \(name)")
                let (fixtures, workload) = try setup(trial)
                defer { fixtures.forEach { $0.1.stop() } }
                let before = fixtures.map { ($0.0, $0.1.pid, ProcessSampler.record(pid: $0.1.pid)?.footprint ?? 0) }
                let engine = ReliefEngine(backend: reliefArm ? backend : NullBackend(), holdMs: holdMs, settleMs: settleMs,
                                          sampling: sampling,
                                          wall: { s in var m = WallModel(); m.add(s); return m.status()?.percent ?? 0 })
                let receipt: Receipt
                do {
                    receipt = try await engine.run()
                } catch let ReliefError.refused(why) where Self.isTransient(why) && attempt < Self.maxRedos {
                    attempt += 1
                    redone.append("trial \(trial + 1) \(name): the helper said \"\(why)\"")
                    log("  the helper said \"\(why)\"; redoing this arm")
                    continue
                }
                let fixtureDeltas = before.map { kind, pid, fp in
                    FixtureDelta(kind: kind, pid: pid, before: fp, after: ProcessSampler.record(pid: pid)?.footprint ?? 0)
                }
                let work = try workload?()
                let foreign = foreignSignals(windowStart, Date())
                if !foreign.isEmpty {
                    let who = foreign.map { "pid \($0)" }.joined(separator: ", ")
                    guard attempt < Self.maxRedos else {
                        throw BenchError.aborted("other processes (\(who)) kept sending the memory-pressure signal")
                    }
                    attempt += 1
                    redone.append("trial \(trial + 1) \(name): \(who) sent the signal during it")
                    log("  \(who) sent the signal during this arm; redoing it")
                    windowStart = Date()
                    continue
                }
                windowStart = Date()
                arms.append(ArmResult(
                    arm: name, trial: trial + 1, startedAt: receipt.startedAt, headlineBytes: receipt.headlineBytes,
                    grossFreedBytes: receipt.grossFreedBytes, swapUsedBefore: receipt.systemBefore.swapUsed,
                    swapUsedAfter: receipt.systemAfter.swapUsed, compressedBefore: receipt.systemBefore.compressorOccupiedBytes,
                    compressedAfter: receipt.systemAfter.compressorOccupiedBytes, wallBefore: receipt.wallBefore,
                    wallAfter: receipt.wallAfter, topApps: Array(receipt.apps.prefix(8)),
                    excludedBusy: receipt.excludedBusy.map(\.name), fixtures: fixtureDeltas, workload: work))
                let last = arms[arms.count - 1]
                var line = "  \(name): \(Format.bytes(last.headlineBytes, signed: true)) net"
                if let w = work { line += String(format: ", workload %.2f s (%.2f GB/s, %llu swapouts)", w.seconds, w.gbPerSecond, w.swapouts) }
                log(line)
                break
              }
            }
        }
        return BenchResult(scenario: scenario, machine: .current(), startedAt: start, finishedAt: Date(), holdMs: holdMs,
                           settleMs: settleMs, cooldownS: cooldownS, seed: seed, arms: arms,
                           summaries: Self.summaries(arms), notes: notes, redone: redone)
    }

    static func summaries(_ arms: [ArmResult]) -> [BenchSummary] {
        func stats(_ xs: [Double]) -> ArmStats { let (m, s) = Stats.meanSD(xs); return ArmStats(n: xs.count, mean: m, sd: s) }
        let relief = arms.filter { $0.arm == "relief" }, control = arms.filter { $0.arm == "control" }
        var out: [BenchSummary] = []
        let r = relief.map { Double($0.headlineBytes) }, c = control.map { Double($0.headlineBytes) }
        out.append(BenchSummary(metric: "net bytes returned", relief: stats(r), control: stats(c), welch: Stats.welch(r, c)))
        let rw = relief.compactMap { $0.workload?.seconds }, cw = control.compactMap { $0.workload?.seconds }
        if !rw.isEmpty {
            out.append(BenchSummary(metric: "workload seconds", relief: stats(rw), control: stats(cw), welch: Stats.welch(rw, cw)))
            let rs = relief.compactMap { $0.workload.map { Double($0.swapouts) } }
            let cs = control.compactMap { $0.workload.map { Double($0.swapouts) } }
            out.append(BenchSummary(metric: "workload swapouts", relief: stats(rs), control: stats(cs), welch: Stats.welch(rs, cs)))
        }
        let rf = relief.flatMap(\.fixtures).filter { $0.kind == "cachehog" }.map { Double(Int64($0.before) - Int64($0.after)) }
        let cf = control.flatMap(\.fixtures).filter { $0.kind == "cachehog" }.map { Double(Int64($0.before) - Int64($0.after)) }
        if !rf.isEmpty {
            out.append(BenchSummary(metric: "cachehog bytes returned", relief: stats(rf), control: stats(cf), welch: Stats.welch(rf, cf)))
        }
        return out
    }

    /// Runs `ram-fixture workload --mb N` and measures it plus the system's VM counters around it.
    static func runWorkload(binary: String, sizeMB: Int) throws -> WorkloadResult {
        let before = try SystemSampler.read()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["workload", "--mb", "\(sizeMB)"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let after = try SystemSampler.read()
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("seconds ") }),
              let seconds = Double(line.dropFirst("seconds ".count)) else { throw BenchError.fixture("workload printed: \(text)") }
        return WorkloadResult(sizeMB: sizeMB, seconds: seconds, gbPerSecond: Double(sizeMB) / 1024 / max(seconds, 1e-9),
                              swapins: after.swapins &- before.swapins, swapouts: after.swapouts &- before.swapouts,
                              compressions: after.compressions &- before.compressions,
                              decompressions: after.decompressions &- before.decompressions,
                              pageins: after.pageins &- before.pageins)
    }
}

/// A fixture process started for one benchmark arm; waits until it reports ready.
public final class SpawnedFixture: @unchecked Sendable {
    let process = Process()
    public private(set) var pid: Int32 = 0

    public init(binary: String, args: [String], timeout: Double = 30) throws {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let line = String(decoding: buffer, as: UTF8.self).split(separator: "\n").first(where: { $0.hasPrefix("ready ") }),
               let p = Int32(line.dropFirst(6)) {
                pid = p
                return
            }
        }
        stop()
        throw BenchError.fixture("\(args.first ?? "fixture") never became ready")
    }

    public func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }

    deinit { stop() }
}
