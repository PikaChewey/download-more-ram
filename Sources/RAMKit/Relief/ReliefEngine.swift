import Darwin
import Foundation

/// Where the engine gets its readings (injected so tests never touch the system).
public protocol Sampling: Sendable {
    func processSnapshot() -> ProcessSnapshot
    func systemSample() throws -> SystemSample
    func sleep(ms: Int) async throws
    func now() -> Date
}

public struct LiveSampling: Sampling {
    public init() {}
    public func processSnapshot() -> ProcessSnapshot {
        var s = ProcessSampler.snapshot(includePaths: true)
        // Never count our own sampling allocations.
        s.records.removeAll { $0.pid == getpid() }
        return s
    }
    public func systemSample() throws -> SystemSample { try SystemSampler.read() }
    public func sleep(ms: Int) async throws { try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
    public func now() -> Date { Date() }
}

/// Live state of a download, for the progress bar.
public struct ReliefProgress: Sendable {
    public enum Phase: String, Sendable { case baseline, holding, settling, done }
    public var phase: Phase
    public var elapsed: Double
    public var total: Double
    /// Net bytes returned so far by non-busy apps (the number that becomes the headline).
    public var reclaimedSoFar: Int64
    public var rateBytesPerSec: Double
    public var topApps: [AppDelta]
    /// Set while a lever after the signal is running (phase stays `.settling`), so UIs can say
    /// "Restarting Firefox's GPU process…". Results so far are in `leversDone`.
    public var lever: LeverKind? = nil
    public var leversDone: [LeverResult] = []

    /// Memberwise, public so UIs can replay a recording (the app's clip renderer rebuilds progress
    /// from the frames `ram download --record` wrote).
    public init(phase: Phase, elapsed: Double, total: Double, reclaimedSoFar: Int64, rateBytesPerSec: Double,
                topApps: [AppDelta], lever: LeverKind? = nil, leversDone: [LeverResult] = []) {
        self.phase = phase
        self.elapsed = elapsed
        self.total = total
        self.reclaimedSoFar = reclaimedSoFar
        self.rateBytesPerSec = rateBytesPerSec
        self.topApps = topApps
        self.lever = lever
        self.leversDone = leversDone
    }
}

/// Runs one "download": baseline, kernel pressure signal, live measurement, receipt.
public actor ReliefEngine {
    public let backend: any ReliefBackend
    public let level: PressureLevel
    public let holdMs: Int
    public let settleMs: Int
    let sampling: any Sampling
    let wall: (@Sendable (SystemSample) -> Double)?
    /// Levers to run after the signal (each needs the user's yes where `needsConsent`).
    public let levers: [LeverKind]
    /// The user named `resume` itself (not via `all`): resume paused apps even near the wall.
    public let forceResume: Bool
    let actions: any LeverActions
    let info: any ProcessInfoSource

    public static let baselineSamples = 3
    public static let baselineIntervalMs = 1000
    public static let tickMs = 500
    /// Rough time a lever takes (restart + settle), so the progress bar keeps moving while levers run.
    public static let leverEstimateS: Double = 7

    public init(backend: any ReliefBackend, level: PressureLevel = .critical, holdMs: Int = 10_000,
                settleMs: Int = 5_000, sampling: any Sampling = LiveSampling(),
                wall: (@Sendable (SystemSample) -> Double)? = nil, levers: [LeverKind] = [],
                actions: any LeverActions = LiveLeverActions(), info: any ProcessInfoSource = LiveProcessInfo(),
                forceResume: Bool = false) {
        self.backend = backend
        self.level = level
        self.holdMs = holdMs
        self.settleMs = settleMs
        self.sampling = sampling
        self.wall = wall
        self.levers = levers.filter { $0 != .kernelSignal }
        self.forceResume = forceResume
        self.actions = actions
        self.info = info
    }

    public func run(progress: @Sendable (ReliefProgress) -> Void = { _ in }) async throws -> Receipt {
        let started = sampling.now()
        let total = Double(Self.baselineSamples - 1) * Double(Self.baselineIntervalMs) / 1000
            + Double(holdMs + settleMs) / 1000 + Double(levers.count) * Self.leverEstimateS

        // 1. Baseline: drift and CPU decide which apps are too busy to judge.
        var baseline: [ProcessSnapshot] = []
        var cpu = CPUHistory()
        for i in 0..<Self.baselineSamples {
            if i > 0 { try await sampling.sleep(ms: Self.baselineIntervalMs) }
            baseline.append(sampling.processSnapshot())
            cpu.add(baseline[baseline.count - 1])
            progress(ReliefProgress(phase: .baseline, elapsed: sampling.now().timeIntervalSince(started),
                                    total: total, reclaimedSoFar: 0, rateBytesPerSec: 0, topApps: []))
        }
        let busy = Measurement.busyGroups(baseline: baseline)
        let before = baseline[baseline.count - 1]
        let systemBefore = try sampling.systemSample()

        // 2. Signal the kernel. The backend restores normal pressure on every path.
        let backend = self.backend
        let level = self.level
        let holdMs = self.holdMs
        let relief = Task { try await backend.relieve(level: level, holdMs: holdMs) }

        // 3. Watch apps respond through the hold and the settle window. On any error, end the hold
        // (cancelling restores normal pressure) before rethrowing, so a caller that exits right
        // away never leaves the kernel in simulated pressure.
        let reliefStart = sampling.now()
        var lastReclaimed: Int64 = 0
        var lastTime = reliefStart
        var rate = 0.0
        do {
            while sampling.now().timeIntervalSince(reliefStart) * 1000 < Double(holdMs + settleMs) {
                try await sampling.sleep(ms: Self.tickMs)
                let current = sampling.processSnapshot()
                cpu.add(current)
                let m = Measurement.deltas(before: before, after: current, busy: busy)
                let t = sampling.now()
                let dt = t.timeIntervalSince(lastTime)
                if dt > 0 { rate = max(0, Double(m.headline - lastReclaimed) / dt) }
                lastReclaimed = m.headline
                lastTime = t
                let inHold = t.timeIntervalSince(reliefStart) * 1000 < Double(holdMs)
                progress(ReliefProgress(phase: inHold ? .holding : .settling, elapsed: t.timeIntervalSince(started),
                                        total: total, reclaimedSoFar: m.headline, rateBytesPerSec: rate,
                                        topApps: Array(m.apps.prefix(5))))
            }
        } catch {
            relief.cancel()
            _ = try? await relief.value
            throw error
        }
        try await relief.value

        // 4. The signal's own result, measured over its window.
        let afterSignal = sampling.processSnapshot()
        cpu.add(afterSignal)
        let m = Measurement.deltas(before: before, after: afterSignal, busy: busy)
        let signalEnd = sampling.now()
        let gainers = m.apps.filter { $0.delta > 0 }.prefix(4).map { "\($0.name) \(Format.bytes($0.delta, signed: true))" }
        var leverResults = [LeverResult(kind: .kernelSignal, title: LeverKind.kernelSignal.title, bytes: m.headline,
                                        targets: m.apps.filter { $0.delta > 0 }.map(\.name),
                                        detail: gainers.isEmpty ? "no app gave memory back" : gainers.joined(separator: ", "),
                                        durationS: signalEnd.timeIntervalSince(reliefStart))]

        // 5. Allowed levers, one after another, each with its own before/after.
        let sessions = AgentClassifier.sessions(afterSignal, cpuHistory: cpu, info: info, now: signalEnd)
        let leftovers = AgentClassifier.leftovers(afterSignal, cpuHistory: cpu, info: info, now: signalEnd)
        var wallNow: WallStatus? = nil
        if let s = try? sampling.systemSample() { var wm = WallModel(); wm.add(s); wallNow = wm.status() }
        let runner = LeverRunner(sampling: sampling, actions: actions)
        for kind in levers {
            let soFar = leverResults.compactMap(\.bytes).reduce(0, +)
            progress(ReliefProgress(phase: .settling, elapsed: sampling.now().timeIntervalSince(started), total: total,
                                    reclaimedSoFar: soFar, rateBytesPerSec: 0, topApps: Array(m.apps.prefix(5)),
                                    lever: kind, leversDone: leverResults))
            leverResults += try await runner.run([kind], sessions: sessions, leftovers: leftovers, wall: wallNow, forceResume: forceResume)
        }
        let offers = LeverPlanner.offers(snapshot: afterSignal, sessions: sessions, leftovers: leftovers, wall: wallNow, now: signalEnd)
            .filter { !levers.contains($0.kind) }

        // 6. Final reading and receipt.
        let systemAfter = try sampling.systemSample()
        let finished = sampling.now()
        let headline = leverResults.compactMap(\.bytes).reduce(0, +)
        progress(ReliefProgress(phase: .done, elapsed: finished.timeIntervalSince(started), total: total,
                                reclaimedSoFar: headline, rateBytesPerSec: 0, topApps: Array(m.apps.prefix(5))))
        return Receipt(
            id: Receipt.makeID(started), startedAt: started, durationS: finished.timeIntervalSince(started),
            backend: backend.name, level: level, holdMs: holdMs, machine: .current(),
            headlineBytes: headline, grossFreedBytes: m.grossFreed, apps: m.apps, excludedBusy: m.excluded,
            newApps: m.new, goneApps: m.gone, systemBefore: systemBefore, systemAfter: systemAfter,
            wallBefore: wall?(systemBefore), wallAfter: wall?(systemAfter), levers: leverResults,
            offers: offers.isEmpty ? nil : offers)
    }
}
