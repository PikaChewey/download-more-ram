import Foundation
import RAMKit

/// `DownloadMoreRAM --profile-loop`: how long each step of the closed-panel loop takes on this Mac,
/// cold (fresh lookups) and warm (the app's per-process cache). Prints milliseconds; exits.
enum ProfileLoop {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--profile-loop") else { return false }
        func ms(_ n: Int = 5, _ body: () -> Void) -> String {
            var samples: [Double] = []
            for _ in 0..<n {
                let t0 = DispatchTime.now().uptimeNanoseconds
                body()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            samples.sort()
            return String(format: "%7.2f ms (min %.2f, max %.2f)", samples[samples.count / 2], samples[0], samples[samples.count - 1])
        }
        let now = Date()
        print("system sample          ", ms { _ = try? SystemSampler.read() })
        var wm = WallModel()
        if let s = try? SystemSampler.read() { for i in 0..<30 { var c = s; c.timestamp = now.addingTimeInterval(Double(i - 30) * 10); wm.add(c) } }
        print("wall status (30 pts)   ", ms { _ = wm.status() })
        var snap = ProcessSampler.snapshot(includePaths: true, now: now)
        print("process snapshot       ", ms { snap = ProcessSampler.snapshot(includePaths: true, now: now) }, "(\(snap.records.count) readable)")
        print("snapshot, no paths     ", ms { _ = ProcessSampler.snapshot(includePaths: false, now: now) })
        var cpu = CPUHistory()
        cpu.add(snap)
        print("cpu history add        ", ms { var c = cpu; c.add(snap) })
        var groups = AppGrouper.group(snap)
        print("group                  ", ms { groups = AppGrouper.group(snap) }, "(\(groups.count) groups)")
        let live = LiveProcessInfo()
        var sessions = AgentClassifier.sessions(snap, cpuHistory: cpu, info: live, now: now)
        print("sessions, live info    ", ms(3) { sessions = AgentClassifier.sessions(snap, cpuHistory: cpu, info: LiveProcessInfo(), now: now) }, "(\(sessions.count) sessions)")
        let cached = CachedProcessInfo()
        cached.begin(snap, now: now)
        _ = AgentClassifier.sessions(snap, cpuHistory: cpu, info: cached, now: now)
        print("sessions, cached info  ", ms { _ = AgentClassifier.sessions(snap, cpuHistory: cpu, info: cached, now: now) })
        print("sessions, null info    ", ms { _ = AgentClassifier.sessions(snap, cpuHistory: cpu, info: NullInfo(), now: now) })
        let heads = sessions.map(\.id)
        print("detect x records       ", ms { for r in snap.records { _ = AgentTool.detect(name: r.name, path: r.path, argv: nil) } })
        print("desktopSession x heads ", ms { for pid in heads { _ = cached.desktopSession(pid: pid) } }, "(\(heads.count))")
        print("cwd x heads (cached)   ", ms { for pid in heads { _ = cached.cwd(pid: pid) } })
        print("argv x node (cached)   ", ms { for r in snap.records where r.name == "node" { _ = cached.argv(pid: r.pid) } })
        print("leftovers, live info   ", ms(3) { _ = AgentClassifier.leftovers(snap, cpuHistory: cpu, info: LiveProcessInfo(), now: now) })
        print("leftovers, cached      ", ms { _ = AgentClassifier.leftovers(snap, cpuHistory: cpu, info: cached, now: now) })
        print("duplicates, live       ", ms(3) { _ = AgentClassifier.duplicateServers(sessions, info: LiveProcessInfo()) })
        print("duplicates, cached     ", ms { _ = AgentClassifier.duplicateServers(sessions, info: cached) })
        let leftovers = AgentClassifier.leftovers(snap, cpuHistory: cpu, info: cached, now: now)
        if let s = try? SystemSampler.read() {
            print("diagnosis              ", ms { _ = Diagnosis.make(system: s, wall: wm.status(), snapshot: snap, sessions: sessions, leftovers: leftovers, reliefAvailable: true, firefoxProfile: nil, cpu: cpu, now: now) })
            print("diagnosis + firefox io ", ms { _ = Diagnosis.make(system: s, wall: wm.status(), snapshot: snap, sessions: sessions, leftovers: leftovers, reliefAvailable: true, firefoxProfile: FirefoxLevers.defaultProfile(), cpu: cpu, now: now) })
        }
        print("offers                 ", ms { _ = LeverPlanner.offers(snapshot: snap, sessions: sessions, leftovers: leftovers, wall: wm.status(), now: now) })
        print("rows                   ", ms { _ = ProcessAnalyzer.rows(groups, sessions: sessions, snapshot: snap) })
        let analyzer = ProcessAnalyzer()
        let system = try? SystemSampler.read()
        let status = wm.status()
        print("full analysis (actor)  ", ms(4) { _ = blocking { await analyzer.analyze(system: system, wall: status, reliefAvailable: true) } })
        return true
    }

    struct NullInfo: ProcessInfoSource {
        func cwd(pid: Int32) -> String? { nil }
        func argv(pid: Int32) -> [String]? { nil }
    }

    final class ResultBox<T>: @unchecked Sendable { var value: T? }

    nonisolated static func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }
}
