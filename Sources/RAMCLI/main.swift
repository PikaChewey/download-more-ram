// ram: the Download More RAM command line.
import Darwin
import Foundation
import RAMKit

let version = "1.1.0"
setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered even when piped (watch, bench logs)
signal(SIGPIPE, SIG_IGN)          // `ram download | head` must never kill a hold: writes just fail with EPIPE
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "status"
let flags = Set(args.filter { $0.hasPrefix("--") })
let isTTY = isatty(STDOUT_FILENO) == 1
let style = Render.Style(color: isTTY && ProcessInfo.processInfo.environment["NO_COLOR"] == nil)

func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func printJSON<T: Encodable>(_ v: T) {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    print(String(decoding: (try? e.encode(v)) ?? Data(), as: UTF8.self))
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func warnInterruptedHold() {
    if ReliefAvailability.interruptedHoldDetected {
        FileHandle.standardError.write(Data(style.amber("! An interrupted download may have left simulated memory pressure on. Run  sudo ram restore\n").utf8))
    }
}

let usage = """
    ram — Download More RAM (\(version))

      ram                       memory, swap, distance to the wall, top apps
      ram apps [--all]          every app's memory, grouped like Force Quit
      ram agents [--quit-archived [--yes]]
                                AI agent sessions (titles, last activity, archived-but-running) and leftovers
      ram download [--hold S] [--levers firefox-gpu,leftovers,archived,resume|all] [--yes] [--dry-run] [--record FILE]
                                ask the kernel for its memory-pressure response, measure what came back
      ram quit <pid> [--force]  quit a leftover (SIGTERM; --force sends SIGKILL)
      ram doctor [--days N] [--fast]
                                when you hit the wall, what was paused, what to do (--fast skips the logs)
      ram firefox [unloader on|off] [gpu-restart]
                                Firefox's two real levers (tab unloader pref, GPU process restart)
      ram watch [--autopilot]   live wall readout; with --autopilot, download when the wall is near
      ram receipt [last|FILE]   print a saved download receipt
      ram bench real|synthetic|perf [--trials N] [--hold S] [--cooldown S]
                                relief vs control, Welch's t-test; JSON to bench/results/
      ram bench report          regenerate docs/BENCHMARKS.md from bench/results/
      ram resume                resume apps macOS paused at the memory wall (what its Resume button does)
      ram restore               force the kernel back to normal pressure (root)
      ram helper install|uninstall|status
                                the root helper that lets downloads run without sudo

    Every read command takes --json.
    """

/// Records the live progress of a download (for scripts/make-demo-svg.swift: the README demo is
/// rendered from a real run, never typed).
final class FrameRecorder: @unchecked Sendable {
    struct Frame: Codable { var t: Double; var phase: String; var reclaimed: Int64; var rate: Double; var elapsed: Double; var total: Double; var lever: String? }
    struct Recording: Codable { var command: String; var frames: [Frame]; var receipt: Receipt }
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var start = Date()
    /// Drops what was recorded so far (a refused start), so a retry records from zero.
    func reset() { lock.withLock { frames = []; start = Date() } }
    func add(_ p: ReliefProgress) {
        lock.withLock {
            frames.append(Frame(t: Date().timeIntervalSince(start), phase: p.phase.rawValue, reclaimed: p.reclaimedSoFar,
                                rate: p.rateBytesPerSec, elapsed: p.elapsed, total: p.total, lever: p.lever?.title))
        }
    }
    func write(to url: URL, receipt: Receipt) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        let command = "ram " + CommandLine.arguments.dropFirst().filter { $0 != "--record" && !$0.hasSuffix(".json") }.joined(separator: " ")
        try e.encode(Recording(command: command, frames: lock.withLock { frames }, receipt: receipt)).write(to: url, options: .atomic)
    }
}

struct StatusJSON: Encodable {
    var system: SystemSample
    var wall: WallStatus?
    var insights: WallInsights
    var apps: [AppSummary]
}

struct AppSummary: Encodable {
    var name: String
    var pid: Int32
    var footprint: UInt64
    var processes: Int
    var kind: AppKind
    init(_ g: AppGroup) { name = g.name; pid = g.id; footprint = g.footprint; processes = g.processCount; kind = g.kind }
}

switch command {
case "status", "--json":
    warnInterruptedHold()
    guard let system = try? SystemSampler.read() else { fail("Could not read memory statistics", code: 1) }
    var wall = WallModel()
    wall.add(system)
    let snap = ProcessSampler.snapshot()
    let groups = AppGrouper.group(snap)
    let insights = WallInsights.from(snap, system: system)
    if flags.contains("--json") {
        printJSON(StatusJSON(system: system, wall: wall.status(), insights: insights, apps: groups.prefix(20).map(AppSummary.init)))
    } else {
        print(Render.status(system: system, wall: wall.status(), apps: groups, insights: insights, style: style), terminator: "")
    }

case "apps":
    let groups = AppGrouper.group(ProcessSampler.snapshot())
    if flags.contains("--json") { printJSON(groups.map(AppSummary.init)) }
    else { print(Render.apps(groups, all: flags.contains("--all"), style: style), terminator: "") }

case "agents":
    var cpu = CPUHistory()
    cpu.add(ProcessSampler.snapshot())
    usleep(1_000_000)
    let snap = ProcessSampler.snapshot()
    cpu.add(snap)
    let sessions = AgentClassifier.sessions(snap, cpuHistory: cpu)
    let leftovers = AgentClassifier.leftovers(snap, cpuHistory: cpu)
    if flags.contains("--quit-archived") {
        let archived = sessions.filter { AgentClassifier.safeToQuitArchived($0) }
        guard !archived.isEmpty else { print("No archived Claude Code sessions are running quietly (busy or recently used ones are left alone)."); exit(0) }
        for s in archived { print("  \(s.label) · \(Format.bytes(s.footprint)) · pid \(s.id)") }
        guard flags.contains("--yes") else {
            print("These sessions are archived in the Claude app but still running. Quit them with  ram agents --quit-archived --yes")
            exit(0)
        }
        var failed = 0
        for s in archived {
            guard let head = s.members.first(where: { $0.pid == s.id }) else { continue }
            switch SafeKill.terminate(head, escalate: false) {
            case .ok: print("Quit \(s.label) (\(Format.bytes(s.footprint)))")
            case .refused(let why): failed += 1; FileHandle.standardError.write(Data("Could not quit \(s.label): \(why)\n".utf8))
            }
        }
        exit(failed == 0 ? 0 : 4)
    }
    if flags.contains("--json") {
        struct AgentsJSON: Encodable { var sessions: [AgentSession]; var leftovers: [Leftover]; var duplicates: [DuplicateServer] }
        printJSON(AgentsJSON(sessions: sessions, leftovers: leftovers, duplicates: AgentClassifier.duplicateServers(sessions)))
    } else {
        print(Render.agents(sessions, leftovers: leftovers, duplicates: AgentClassifier.duplicateServers(sessions), style: style), terminator: "")
    }

case "download":
    warnInterruptedHold()
    let dryRun = flags.contains("--dry-run")
    let backend: any ReliefBackend
    if dryRun {
        backend = NullBackend()   // identical measurement, no signal: shows this Mac's natural drift
    } else {
        let availability = await ReliefAvailability.detect()
        guard let b = availability.backend() else {
            if case .unavailable(let reason) = availability { fail(reason + "\n(Or measure without the signal:  ram download --dry-run)", code: 3) }
            fail(ReliefError.notPermitted.description, code: 3)
        }
        backend = b
    }
    let hold: Int
    switch InputLimits.holdSeconds(value("--hold")) {
    case .success(let s): hold = s * 1000
    case .failure(let why): fail(why.message, code: 2)
    }
    var levers: [LeverKind]
    switch LeverKind.parse(value("--levers")) {
    case .success(let l): levers = l
    case .failure(let why): fail(why.message, code: 2)
    }
    let json = flags.contains("--json")
    // Levers that quit processes the classifier picked: list them first, then ask (or --yes).
    let quitKinds = levers.filter { $0 == .leftovers || $0 == .archivedSessions }
    if !quitKinds.isEmpty {
        var cpu = CPUHistory()
        cpu.add(ProcessSampler.snapshot())
        usleep(500_000)
        let snap = ProcessSampler.snapshot()
        cpu.add(snap)
        let targets = LeverPreview.targets(quitKinds, sessions: AgentClassifier.sessions(snap, cpuHistory: cpu),
                                           leftovers: AgentClassifier.leftovers(snap, cpuHistory: cpu))
        let out = json ? FileHandle.standardError : FileHandle.standardOutput
        if targets.isEmpty {
            out.write(Data(style.dim("Nothing for \(quitKinds.map(\.rawValue).joined(separator: " or ")) to quit right now.\n").utf8))
        } else {
            out.write(Data((style.bold(dryRun ? "Would quit, if still idle after the signal:" : "Will quit, if still idle after the signal:") + "\n").utf8))
            for t in targets {
                out.write(Data("  \(t.record.name) (pid \(t.record.pid), \(Format.bytes(t.record.footprint)))  \(style.dim(t.why))\n".utf8))
            }
            if !dryRun && !flags.contains("--yes") {
                guard isTTY && !json && isatty(STDIN_FILENO) != 0 else {
                    fail("Add --yes to quit them, or leave \(quitKinds.map(\.rawValue).joined(separator: "/")) out of --levers.", code: 2)
                }
                print("Quit them? [y/N] ", terminator: "")
                fflush(stdout)
                let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                if answer != "y" && answer != "yes" {
                    levers.removeAll { quitKinds.contains($0) }
                    print(style.dim("Leaving them running."))
                }
            }
        }
    }
    if dryRun { levers = [] }
    let namedResume = (value("--levers") ?? "").split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "resume" }
    let engine = ReliefEngine(backend: backend, holdMs: hold, settleMs: 5_000, wall: { s in
        var m = WallModel(); m.add(s); return m.status()?.percent ?? 0
    }, levers: levers, forceResume: namedResume)
    let recordPath = value("--record")
    let recorder = FrameRecorder()
    if !json {
        if dryRun {
            print(style.bold("Dry run") + style.dim(" — same measurement, no signal: this is the natural drift a real download has to beat"))
        } else {
            print(style.bold("Downloading RAM") + style.dim(" — macOS memory-pressure signal (critical, \(hold / 1000)s) via \(backend.name), measured with phys_footprint"))
        }
    }
    let onProgress: @Sendable (ReliefProgress) -> Void = { p in
        recorder.add(p)
        guard !json else { return }
        if isTTY {
            FileHandle.standardOutput.write(Data(("\r\u{1B}[2K" + Render.progress(p, style: style)).utf8))
        } else if p.phase == .done || Int(p.elapsed * 2) % 4 == 0 {
            print(Render.progress(p, style: style))
        }
    }
    do {
        let receipt: Receipt
        do {
            receipt = try await engine.run(progress: onProgress)
        } catch let ReliefError.refused(why) where ReliefError.retryAfter(why) != nil {
            // The helper spaces downloads 20 s apart: wait it out once instead of failing.
            let wait = ReliefError.retryAfter(why)!
            if isTTY && !json { print("") }
            if !json { print(style.dim("The helper spaces downloads apart; starting again in \(wait) s…")) }
            recorder.reset()
            try await Task.sleep(nanoseconds: UInt64(wait + 1) * 1_000_000_000)
            receipt = try await engine.run(progress: onProgress)
        }
        if isTTY && !json { print("") }
        let url = dryRun ? nil : try? receipt.save()
        if let recordPath { try? RealUser.asUser { try recorder.write(to: URL(fileURLWithPath: recordPath), receipt: receipt) } }
        if json { printJSON(receipt) }
        else {
            print(Render.receipt(receipt, style: style), terminator: "")
            if let url { print(style.dim("  Receipt: \(url.deletingPathExtension().path).md")) }
        }
    } catch let e as ReliefError {
        if isTTY { print("") }
        fail("\(e)", code: e == .notPermitted ? 3 : 4)
    } catch {
        fail("\(error)", code: 1)
    }

case "quit":
    guard let pidText = args.dropFirst().first, let pid = Int32(pidText) else { fail("usage: ram quit <pid> [--force]", code: 2) }
    guard let record = ProcessSampler.record(pid: pid) else { fail("No process \(pid) that you can read.", code: 1) }
    switch SafeKill.terminate(record, escalate: flags.contains("--force")) {
    case .ok: print("Sent \(flags.contains("--force") ? "SIGKILL" : "SIGTERM") to \(record.name) (\(pid)), \(Format.bytes(record.footprint)).")
    case .refused(let why): fail("Refused: \(why)", code: 4)
    }

case "resume":
    let paused = PausedApps.current()
    guard !paused.isEmpty else { print("No apps are paused by macOS's out-of-memory action."); exit(0) }
    if geteuid() != 0 && !HelperInstaller.isInstalled {
        print("macOS paused \(paused.count) process\(paused.count == 1 ? "" : "es") at the memory wall: " + paused.map { "\($0.name) (\($0.pid))" }.joined(separator: ", "))
        fail("Resuming needs root: click Resume in the Force Quit panel, or run  sudo ram resume  (or install the helper:  sudo ram helper install)", code: 3)
    }
    var failures = 0
    for r in paused {
        do {
            if geteuid() == 0 {
                if case .failure(let why) = PausedApps.resume(pid: r.pid) { throw why }
            } else {
                try await HelperBackend().resumePaused(pid: r.pid)
            }
            print("Resumed \(r.name) (\(r.pid))")
        } catch {
            failures += 1
            FileHandle.standardError.write(Data("Could not resume \(r.name) (\(r.pid)): \(error)\n".utf8))
        }
    }
    exit(failures == 0 ? 0 : 4)

case "restore":
    let backend: any ReliefBackend = geteuid() == 0 ? DirectSysctlBackend() : HelperBackend()
    do { try await backend.restore(); print("Kernel memory pressure reporting is back to normal.") }
    catch { fail("\(error)", code: 4) }

case "helper":
    switch args.dropFirst().first ?? "status" {
    case "install":
        do {
            try HelperInstaller.install()
            print("Installed \(HelperConstants.label). Downloads now work without sudo:  ram download")
        } catch { fail("\(error)", code: 4) }
    case "uninstall":
        do { try HelperInstaller.uninstall(); print("Removed the helper (and restored normal pressure).") }
        catch { fail("\(error)", code: 4) }
    default:
        guard HelperInstaller.isInstalled else { print("Helper: not installed. Install with  sudo ram helper install"); exit(0) }
        do {
            let s = try await HelperBackend().status()
            print("Helper: installed, version \(s.version)\(s.busy ? ", downloading now" : ""), \(s.reliefsThisHour) downloads this hour")
        } catch { fail("Helper: installed but not answering (\(error))", code: 4) }
    }

case "receipt":
    let which = args.dropFirst().first ?? "last"
    let receipt = which == "last" ? Receipt.latest() : try? Receipt.load(URL(fileURLWithPath: which))
    guard let receipt else { fail("No receipt found. Run  ram download  first.", code: 1) }
    if flags.contains("--json") { printJSON(receipt) } else { print(receipt.markdown()) }

case "doctor":
    let days = max(1, min(90, Int(value("--days") ?? "7") ?? 7))
    let fast = flags.contains("--fast")
    if isTTY && !fast { FileHandle.standardError.write(Data(style.dim("Reading the last \(days) days of system logs (this takes a while; --fast skips it)…\n").utf8)) }
    let events = fast ? [] : ((try? WallEventLog.read(days: days)) ?? [])
    guard let system = try? SystemSampler.read() else { fail("Could not read memory statistics", code: 1) }
    var wallModel = WallModel()
    wallModel.add(system)
    var cpu = CPUHistory()
    cpu.add(ProcessSampler.snapshot())
    usleep(fast ? 250_000 : 1_000_000)
    let snap = ProcessSampler.snapshot()
    cpu.add(snap)
    let doctorSessions = AgentClassifier.sessions(snap, cpuHistory: cpu)
    let diagnosis = Diagnosis.make(system: system, wall: wallModel.status(), snapshot: snap,
                                   sessions: doctorSessions,
                                   leftovers: AgentClassifier.leftovers(snap, cpuHistory: cpu),
                                   reliefAvailable: await ReliefAvailability.detect().backend() != nil,
                                   firefoxProfile: FirefoxLevers.defaultProfile(), cpu: cpu,
                                   duplicates: AgentClassifier.duplicateServers(doctorSessions))
    let crisis = fast ? (reports: [JetsamReport](), unreadable: 0) : JetsamReports.load(days: days)
    let jetsam = JetsamReports.episodes(crisis.reports)
    if flags.contains("--json") {
        struct DoctorJSON: Encodable { var events: [WallEvent]; var jetsam: [JetsamEpisode]; var jetsamUnreadable: Int; var diagnosis: Diagnosis }
        printJSON(DoctorJSON(events: events, jetsam: jetsam, jetsamUnreadable: crisis.unreadable, diagnosis: diagnosis))
    } else {
        // Crisis reports name processes, not apps: label a coalition by the app its process belongs to today.
        var appNames: [String: String] = [:]
        for r in snap.records where appNames[r.name] == nil {
            if let bundle = r.path.flatMap(AppGrouper.outermostBundlePath) { appNames[r.name] = AppGrouper.bundleDisplayName(bundlePath: bundle) }
        }
        print(Render.doctor(diagnosis, events: events, days: days, system: system, style: style,
                            jetsam: jetsam, jetsamUnreadable: crisis.unreadable, appNames: appNames), terminator: "")
    }

case "firefox":
    let sub = Array(args.dropFirst())
    switch (sub.first ?? "status", sub.dropFirst().first ?? "status") {
    case ("unloader", let action):
        guard let profile = FirefoxLevers.defaultProfile() else { fail("No Firefox profile found.", code: 1) }
        switch action {
        case "on":
            do { try FirefoxLevers.enableUnloader(profile: profile) } catch { fail("\(error)", code: 1) }
            print("Added browser.lowMemoryResponseMask = 3 to \(profile.lastPathComponent)/user.js. It applies the next time Firefox starts (or set it now in about:config). Undo:  ram firefox unloader off")
        case "off":
            do { try FirefoxLevers.disableUnloader(profile: profile) } catch { fail("\(error)", code: 1) }
            print("Removed the line Download More RAM added to \(profile.lastPathComponent)/user.js.")
        default:
            let mask = FirefoxLevers.lowMemoryResponseMask(profile: profile)
            print("Firefox low-memory tab unloading: \((mask ?? 0) != 0 ? "on" : "off") (browser.lowMemoryResponseMask = \(mask.map(String.init) ?? "0, the release default")) · profile \(profile.lastPathComponent)")
        }
    case ("gpu-restart", _):
        guard let gpu = FirefoxLevers.gpuProcess(in: ProcessSampler.snapshot()) else { fail("Firefox's GPU process is not running.", code: 1) }
        switch FirefoxLevers.restartGPU(gpu) {
        case .restarted: print("Restarted Firefox's GPU process (it held \(Format.bytes(gpu.footprint))). Firefox relaunches it on its own; WebGL and canvas content resets.")
        case .tooYoung(let s): fail("It has only been running \(Int(s))s; restarting it now would count as a crash. Try again in a minute.", code: 4)
        case .refused(let why): fail("Refused: \(why)", code: 4)
        }
    default:
        let snap = ProcessSampler.snapshot()
        let gpu = FirefoxLevers.gpuProcess(in: snap)
        let profile = FirefoxLevers.defaultProfile()
        print("Firefox GPU process: \(gpu.map { Format.bytes($0.footprint) } ?? "not running")")
        print("Low-memory tab unloading: \(profile.map { FirefoxLevers.isUnloaderOn(profile: $0) ? "on" : "off" } ?? "no profile")")
        print(style.dim("ram firefox unloader on|off · ram firefox gpu-restart"))
    }

case "watch":
    let autopilotOn = flags.contains("--autopilot")
    let backend = autopilotOn ? await ReliefAvailability.detect().backend() : nil
    if autopilotOn && backend == nil { fail(ReliefError.notPermitted.description, code: 3) }
    var wall = WallModel()
    var policy = AutopilotPolicy()
    var growth = GrowthTracker()
    var tick = 0
    var lastKey = ""
    var lastPrint = Date.distantPast
    print(style.dim("Watching memory every 2 s\(autopilotOn ? " · autopilot on" : ""). Ctrl-C to stop."))
    while true {
        guard let s = try? SystemSampler.read() else { usleep(2_000_000); continue }
        wall.add(s)
        // Who is growing: a process snapshot every 10 s (the system reading above is the cheap one).
        if tick % 5 == 0 { growth.add(ProcessSampler.snapshot(includePaths: true)) }
        tick += 1
        if let w = wall.status() {
            var line = "\(Format.percent(w.percent)) to the wall · swap \(Format.bytes(s.swapUsed)) · pressure \(s.pressureLevel.word)"
            if w.imminent { line += " · IMMINENT" } else if let eta = w.etaSeconds { line += " · ~\(Format.duration(eta)) left" }
            let grower = growth.top(1).first
            if let grower { line += " · growing: " + GrowthTracker.describe(grower) }
            // Print when something that matters changes (not every swap wobble), else every 30 s.
            let key = "\(Int(w.percent))|\(s.pressureLevel.word)|\(w.imminent)|\(w.etaSeconds.map { Int(log2(max(1, $0))) } ?? -1)|\(grower?.app ?? "")"
            if key != lastKey || Date().timeIntervalSince(lastPrint) >= 30 {
                let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                print("\(style.dim(stamp))  \(style.wall(w.percent, line))")
                lastKey = key
                lastPrint = Date()
            }
            if let backend, policy.observe(status: w, pressure: s.pressureLevel, now: Date()) == .download {
                print(style.bold("Autopilot: downloading RAM (\(w.reason))"))
                policy.recordDownload(at: Date())
                if let r = try? await ReliefEngine(backend: backend).run() {
                    _ = try? r.save()
                    print(Render.receipt(r, style: style))
                }
            }
        }
        usleep(2_000_000)
    }

case "bench":
    let scenario = args.dropFirst().first ?? "real"
    let resultsDir: URL = {
        if let out = value("--out") { return URL(fileURLWithPath: out) }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("Sources/RAMKit").path) {
            return cwd.appendingPathComponent("bench/results")
        }
        return Receipt.defaultDirectory.deletingLastPathComponent().appendingPathComponent("bench")
    }()
    if scenario == "report" {
        let files = ((try? FileManager.default.contentsOfDirectory(at: resultsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        let results = files.compactMap { try? BenchResult.load($0) }
        guard !results.isEmpty else { fail("No results in \(resultsDir.path). Run  ram bench real  first.", code: 1) }
        let md = BenchReport.markdown(results)
        let docs = resultsDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/BENCHMARKS.md")
        if FileManager.default.fileExists(atPath: docs.deletingLastPathComponent().path) {
            try? md.write(to: docs, atomically: true, encoding: .utf8)
            print("Wrote \(docs.path)")
        } else {
            print(md)
        }
        let block = BenchReport.readmeBlock(results)
        let readme = resultsDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("README.md")
        if let text = try? String(contentsOf: readme, encoding: .utf8),
           let start = text.range(of: "<!-- BENCH:BEGIN -->"), let end = text.range(of: "<!-- BENCH:END -->"), start.upperBound <= end.lowerBound {
            let updated = text.replacingCharacters(in: start.upperBound..<end.lowerBound,
                with: "\n" + block + "\n\n_Generated by `ram bench report` from `bench/results/`; method and every run in [docs/BENCHMARKS.md](docs/BENCHMARKS.md)._\n")
            try? updated.write(to: readme, atomically: true, encoding: .utf8)
            print("Updated the numbers in \(readme.path)")
        } else {
            print("\nREADME block:\n" + block)
        }
        exit(0)
    }
    let availability = await ReliefAvailability.detect()
    guard let backend = availability.backend() else {
        if case .unavailable(let reason) = availability { fail(reason, code: 3) }
        fail(ReliefError.notPermitted.description, code: 3)
    }
    func checked(_ r: Result<Int, InputError>) -> Int { switch r { case .success(let v): return v; case .failure(let why): fail(why.message, code: 2) } }
    let trials = checked(InputLimits.int(value("--trials"), default: scenario == "perf" ? 5 : 3, range: 1...50, name: "--trials"))
    let hold = checked(InputLimits.holdSeconds(value("--hold"))) * 1000
    let cooldown = Double(checked(InputLimits.int(value("--cooldown"), default: 60, range: 20...600, name: "--cooldown")))
    let headroom = (try? SystemSampler.read().headroomBytes) ?? 0
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let fixture = [exeDir.appendingPathComponent("ram-fixture").path].first { FileManager.default.isExecutableFile(atPath: $0) }
    let runner = BenchRunner(backend: backend, holdMs: hold, settleMs: 5_000, cooldownS: cooldown, fixtureBinary: fixture)
    let log: @Sendable (String) -> Void = { line in print(line); fflush(stdout) }
    do {
        let result: BenchResult
        switch scenario {
        case "real": result = try await runner.real(trials: trials, log: log)
        case "synthetic":
            let hogs = checked(InputLimits.int(value("--hogs"), default: 2, range: 1...8, name: "--hogs"))
            let mb = InputLimits.cappedMB(checked(InputLimits.int(value("--mb"), default: 256, range: 16...2048, name: "--mb")),
                                          headroom: headroom / UInt64(2 * hogs))
            result = try await runner.synthetic(trials: trials, hogs: hogs, mb: mb, log: log)
        case "perf":
            let mb = InputLimits.cappedMB(checked(InputLimits.int(value("--mb"), default: 1024, range: 64...4096, name: "--mb")), headroom: headroom)
            result = try await runner.perf(trials: trials, sizeMB: mb, log: log)
        default: fail("usage: ram bench real|synthetic|perf|report", code: 2)
        }
        let url = try RealUser.asUser { try result.save(to: resultsDir) }
        print("")
        for s in result.summaries {
            let w = s.welch.map { String(format: "  (Welch t = %.2f, p = %@)", $0.t, $0.p < 0.001 ? "< 0.001" : String(format: "%.3f", $0.p)) } ?? ""
            let f: (Double) -> String = s.metric.contains("bytes") ? { Format.bytes(Int64($0), signed: true) } : { String(format: "%.2f", $0) }
            print("\(s.metric): relief \(f(s.relief.mean)) ± \(f(s.relief.sd)) vs control \(f(s.control.mean)) ± \(f(s.control.sd))\(w)")
        }
        print(style.dim("Saved \(url.path)"))
    } catch {
        fail("\(error)", code: 5)
    }

case "measure":
    // Dev tool: average CPU, footprint and wakeups of one process (used by scripts/measure-app.sh).
    guard let pidText = args.dropFirst().first, let pid = Int32(pidText) else { fail("usage: ram measure <pid> [--seconds N]", code: 2) }
    let seconds = Double(value("--seconds") ?? "60") ?? 60
    func read() -> (cpu: UInt64, fp: UInt64, wakes: UInt64)? {
        guard let r = ProcessSampler.record(pid: pid) else { return nil }
        return (r.cpuTimeNs, r.footprint, ProcessSampler.wakeups(pid: pid) ?? 0)
    }
    guard let a = read() else { fail("No readable process \(pid)", code: 1) }
    let t0 = Date()
    var maxFP = a.fp
    while Date().timeIntervalSince(t0) < seconds {
        usleep(1_000_000)
        if let x = read() { maxFP = max(maxFP, x.fp) }
    }
    guard let b = read() else { fail("Process \(pid) exited", code: 1) }
    let dt = Date().timeIntervalSince(t0)
    struct Measure: Encodable { var pid: Int32; var seconds: Double; var idle_cpu_pct: Double; var footprint_mb: Double; var max_footprint_mb: Double; var wakeups_per_s: Double }
    printJSON(Measure(pid: pid, seconds: dt, idle_cpu_pct: Double(b.cpu - a.cpu) / 1e9 / dt * 100,
                      footprint_mb: Double(b.fp) / 1_048_576, max_footprint_mb: Double(maxFP) / 1_048_576,
                      wakeups_per_s: Double(b.wakes - a.wakes) / dt))

case "version", "--version", "-v":
    print("ram \(version)")

case "help", "--help", "-h":
    print(usage)

default:
    fail("Unknown command \(command).\n\n" + usage, code: 2)
}
