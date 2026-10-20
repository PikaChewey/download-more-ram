// ram: the Download More RAM command line.
import Darwin
import Foundation
import RAMKit

let version = "1.0.0"
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
      ram agents                AI agent sessions and the leftovers they forgot
      ram download [--hold S]   ask the kernel for its memory-pressure response, measure what came back
      ram quit <pid> [--force]  quit a leftover (SIGTERM; --force sends SIGKILL)
      ram doctor [--days N]     when you hit the wall, what was paused, what to do
      ram receipt [last|FILE]   print a saved download receipt
      ram bench real|synthetic|perf [--trials N] [--hold S] [--cooldown S]
                                relief vs control, Welch's t-test; JSON to bench/results/
      ram bench report          regenerate docs/BENCHMARKS.md from bench/results/
      ram restore               force the kernel back to normal pressure (root)
      ram helper install|uninstall|status
                                the root helper that lets downloads run without sudo

    Every read command takes --json.
    """

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
    if flags.contains("--json") {
        struct AgentsJSON: Encodable { var sessions: [AgentSession]; var leftovers: [Leftover] }
        printJSON(AgentsJSON(sessions: sessions, leftovers: leftovers))
    } else {
        print(Render.agents(sessions, leftovers: leftovers, style: style), terminator: "")
    }

case "download":
    warnInterruptedHold()
    let availability = await ReliefAvailability.detect()
    guard let backend = availability.backend() else {
        if case .unavailable(let reason) = availability { fail(reason, code: 3) }
        fail(ReliefError.notPermitted.description, code: 3)
    }
    let hold = Int(value("--hold") ?? "10").map { $0 * 1000 } ?? 10_000
    let engine = ReliefEngine(backend: backend, holdMs: hold, settleMs: 5_000, wall: { s in
        var m = WallModel(); m.add(s); return m.status()?.percent ?? 0
    })
    let json = flags.contains("--json")
    if !json {
        print(style.bold("Downloading RAM") + style.dim(" — macOS memory-pressure signal (critical, \(hold / 1000)s) via \(backend.name), measured with phys_footprint"))
    }
    do {
        let receipt = try await engine.run { p in
            guard !json else { return }
            if isTTY {
                FileHandle.standardOutput.write(Data(("\r\u{1B}[2K" + Render.progress(p, style: style)).utf8))
            } else if p.phase == .done || Int(p.elapsed * 2) % 4 == 0 {
                print(Render.progress(p, style: style))
            }
        }
        if isTTY && !json { print("") }
        let url = try? receipt.save()
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
    let days = Int(value("--days") ?? "7") ?? 7
    if isTTY { FileHandle.standardError.write(Data(style.dim("Reading the last \(days) days of system logs (this takes a while)…\n").utf8)) }
    let events = (try? WallEventLog.read(days: days)) ?? []
    if flags.contains("--json") { printJSON(events) }
    else {
        if events.isEmpty { print(style.green("No \"out of application memory\" events in the last \(days) days.")) }
        else {
            print(style.bold("Your Mac hit the memory wall \(events.count) time\(events.count == 1 ? "" : "s") in the last \(days) days:"))
            let f = DateFormatter(); f.dateFormat = "EEE MMM d HH:mm"
            for e in events {
                let dur = e.end.map { Format.duration($0.timeIntervalSince(e.start)) } ?? "still open"
                let paused = e.pausedApps.isEmpty ? "" : " · paused: " + e.pausedApps.joined(separator: ", ")
                print("  \(f.string(from: e.start)) (\(dur))\(paused)")
            }
        }
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
        print("\nREADME block:\n" + BenchReport.readmeBlock(results))
        exit(0)
    }
    let availability = await ReliefAvailability.detect()
    guard let backend = availability.backend() else {
        if case .unavailable(let reason) = availability { fail(reason, code: 3) }
        fail(ReliefError.notPermitted.description, code: 3)
    }
    let trials = Int(value("--trials") ?? "") ?? (scenario == "perf" ? 5 : 3)
    let hold = (Int(value("--hold") ?? "") ?? 10) * 1000
    let cooldown = Double(value("--cooldown") ?? "") ?? 60
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let fixture = [exeDir.appendingPathComponent("ram-fixture").path].first { FileManager.default.isExecutableFile(atPath: $0) }
    let runner = BenchRunner(backend: backend, holdMs: hold, settleMs: 5_000, cooldownS: cooldown, fixtureBinary: fixture)
    let log: @Sendable (String) -> Void = { line in print(line); fflush(stdout) }
    do {
        let result: BenchResult
        switch scenario {
        case "real": result = try await runner.real(trials: trials, log: log)
        case "synthetic": result = try await runner.synthetic(trials: trials, hogs: Int(value("--hogs") ?? "") ?? 2,
                                                              mb: Int(value("--mb") ?? "") ?? 256, log: log)
        case "perf": result = try await runner.perf(trials: trials, sizeMB: Int(value("--mb") ?? "") ?? 1024, log: log)
        default: fail("usage: ram bench real|synthetic|perf|report", code: 2)
        }
        let url = try result.save(to: resultsDir)
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

case "version", "--version", "-v":
    print("ram \(version)")

case "help", "--help", "-h":
    print(usage)

default:
    fail("Unknown command \(command).\n\n" + usage, code: 2)
}
