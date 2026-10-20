#if DEBUG
import Foundation
import RAMKit

/// A fake 16 GB Mac for `--render-ui`: records go through the real grouper, classifier, wall
/// model, leak detector and relief engine, so every number in a snapshot is produced the way
/// the app produces it, just from scripted processes instead of libproc.
enum SampleData {
    static let now = Date(timeIntervalSince1970: 1_792_382_400)

    static func rec(_ pid: Int32, ppid: Int32 = 1, name: String, path: String? = nil, mb: Double, resp: Int32? = nil,
                    ageS: Double = 7200, cpuS: Double = 5, flags: UInt32 = 0, residentMB: Double? = nil) -> ProcessRecord {
        let bytes = UInt64(mb * 1_048_576)
        return ProcessRecord(pid: pid, ppid: ppid, uid: 501, name: name, path: path,
                             startTime: UInt64((now.timeIntervalSince1970 - ageS) * 1_000_000), footprint: bytes,
                             lifetimeMaxFootprint: bytes, residentBytes: UInt64((residentMB ?? mb * 0.7) * 1_048_576),
                             cpuTimeNs: UInt64(cpuS * 1e9), responsiblePid: resp ?? pid, coalitionId: nil, bsdFlags: flags)
    }

    // MARK: Paths

    static let firefox = "/Applications/Firefox.app/Contents/MacOS/firefox"
    static let container = "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container"
    static let gpuHelper = "/Applications/Firefox.app/Contents/MacOS/gpu-helper.app/Contents/MacOS/Firefox GPU Helper"
    static let claudeApp = "/Applications/Claude.app/Contents/MacOS/Claude"
    static let disclaimer = "/Applications/Claude.app/Contents/Helpers/disclaimer"
    static let claudeCLI = "/Users/bryan/Library/Application Support/Claude/claude-code/2.1.303/4fa9694b7975/claude.app/Contents/MacOS/claude"
    static let python = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
    static let node = "/opt/homebrew/bin/node"
    static let webkitNet = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"

    // MARK: System samples (SystemSample has no public init: decode one)

    struct Sys {
        var swapUsedGiB: Double
        var swapTotalGiB: Double = 11
        var diskFreeGiB: Double = 93
        var segments: UInt64 = 300_000
        var pressure: PressureLevel = .normal
        var appGiB: Double = 6.9
        var wiredGiB: Double = 2.9
        var compressedGiB: Double = 1.3
        var available = 44
    }

    static func system(_ s: Sys, at t: Date) -> SystemSample {
        func gib(_ v: Double) -> UInt64 { UInt64(v * 1_073_741_824) }
        let dict: [String: Any] = [
            "timestamp": t.timeIntervalSinceReferenceDate,
            "physicalBytes": UInt64(16) << 30, "pageSize": 16384,
            "freeBytes": gib(0.12), "activeBytes": gib(4.5), "inactiveBytes": gib(4.3), "speculativeBytes": gib(0.1),
            "wiredBytes": gib(s.wiredGiB), "purgeableBytes": gib(0.05), "fileBackedBytes": gib(1.8),
            "anonymousBytes": gib(s.appGiB + 0.05), "compressorOccupiedBytes": gib(s.compressedGiB),
            "compressedUncompressedBytes": gib(s.compressedGiB * 3.2),
            "swapTotal": gib(s.swapTotalGiB), "swapUsed": gib(s.swapUsedGiB), "swapfileCount": Int(s.swapTotalGiB),
            "vmVolumeFreeBytes": gib(s.diskFreeGiB),
            "swapins": 0, "swapouts": 0, "pageins": 0, "compressions": 0, "decompressions": 0,
            "pressureLevel": s.pressure.rawValue, "availablePercent": s.available,
            "compressorPages": 2_090_000, "compressorPagesLimit": 6_446_480,
            "compressorSegments": s.segments, "compressorSegmentsLimit": 805_810,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(SystemSample.self, from: data)
    }

    /// Wall status from a short history of samples (the model needs a few points for an ETA).
    static func wall(_ samples: [SystemSample]) -> WallStatus? {
        var m = WallModel()
        for s in samples { m.add(s) }
        return m.status()
    }

    static func normalSystem() -> SystemSample { system(Sys(swapUsedGiB: 4.1), at: now) }

    static func normalWall() -> WallStatus? {
        wall((0..<5).map { system(Sys(swapUsedGiB: 4.1), at: now.addingTimeInterval(Double($0 - 4) * 2)) })
    }

    /// Swap 10 GB of an 11 GB cap, growing 140 MB/min: about 7 minutes to the wall.
    static func nearWallSystem() -> SystemSample {
        system(Sys(swapUsedGiB: 10.0, diskFreeGiB: 1.0, pressure: .warn, appGiB: 8.6, compressedGiB: 2.2, available: 23), at: now)
    }

    static func nearWallWall() -> WallStatus? {
        wall((0..<11).map { i in
            let t = Double(i - 10) * 30
            return system(Sys(swapUsedGiB: 10.0 + 0.14 / 60 * t, diskFreeGiB: 1.0, pressure: .warn, appGiB: 8.6, compressedGiB: 2.2, available: 23),
                          at: now.addingTimeInterval(t))
        })
    }

    /// Free swap under the hiwater mark for 40 s with no new swapfile: the panel can appear any second.
    static func imminentSystem() -> SystemSample {
        system(Sys(swapUsedGiB: 10.95, diskFreeGiB: 93, pressure: .critical, appGiB: 9.1, compressedGiB: 2.4, available: 12), at: now)
    }

    static func imminentWall() -> WallStatus? {
        wall((0..<21).map { i in
            let t = Double(i - 20) * 2
            return system(Sys(swapUsedGiB: 10.95, diskFreeGiB: 93, pressure: .critical, appGiB: 9.1, compressedGiB: 2.4, available: 12),
                          at: now.addingTimeInterval(t))
        })
    }

    // MARK: Processes

    /// The machine with a few agent sessions; `busy` adds 21 more sessions, two leftovers and a leak.
    static func records(busy: Bool, cpuOffsetS: Double = 0) -> [ProcessRecord] {
        var r: [ProcessRecord] = [
            rec(500, name: "firefox", path: firefox, mb: 1250, ageS: 6 * 3600),
            rec(501, ppid: 500, name: "plugin-container", path: container, mb: 2300, resp: 500, flags: 0x400, residentMB: 800),
            rec(502, ppid: 500, name: "plugin-container", path: container, mb: 2000, resp: 500, flags: 0x400),
            rec(503, ppid: 500, name: "plugin-container", path: container, mb: 1600, resp: 500, flags: 0x400),
            rec(504, ppid: 500, name: "plugin-container", path: container, mb: 1300, resp: 500, flags: 0x400),
            rec(505, ppid: 500, name: "plugin-container", path: container, mb: 1100, resp: 500, flags: 0x400),
            rec(506, ppid: 500, name: "plugin-container", path: container, mb: 1000, resp: 500, flags: 0x400),
            rec(507, ppid: 500, name: "Firefox GPU Helper", path: gpuHelper, mb: 5360, resp: 500, ageS: 2 * 3600),

            rec(600, name: "Claude", path: claudeApp, mb: 919, ageS: 30 * 3600),
            rec(601, ppid: 600, name: "disclaimer", path: disclaimer, mb: 1, resp: 600, ageS: 30 * 3600),
            rec(610, ppid: 601, name: "claude", path: claudeCLI, mb: 431, ageS: 3 * 3600 + 900, cpuS: 50 + cpuOffsetS),
            rec(611, ppid: 610, name: "Blender", path: "/Applications/Blender.app/Contents/MacOS/Blender", mb: 1748, resp: 610, ageS: 99),
            rec(612, ppid: 610, name: "Blender", path: "/Applications/Blender.app/Contents/MacOS/Blender", mb: 1718, resp: 610, ageS: 99),
            rec(613, ppid: 610, name: "ffmpeg", path: "/opt/homebrew/bin/ffmpeg", mb: 1603, resp: 610, ageS: 90),
            rec(620, ppid: 601, name: "claude", path: claudeCLI, mb: 398, ageS: 5 * 3600 + 1200, cpuS: 80),
            rec(621, ppid: 620, name: "node", path: node, mb: 210, resp: 620, ageS: 5 * 3600),
            rec(622, ppid: 620, name: "node", path: node, mb: 180, resp: 620, ageS: 5 * 3600),
            rec(623, ppid: 620, name: "node", path: node, mb: 160, resp: 620, ageS: 5 * 3600),
            rec(650, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", mb: 120, ageS: 20 * 3600),
            rec(640, ppid: 650, name: "zsh", path: "/bin/zsh", mb: 4, resp: 650, ageS: 2 * 3600),
            rec(630, ppid: 640, name: "claude", path: claudeCLI, mb: 380, ageS: 1800, cpuS: 40 + cpuOffsetS * 3),

            rec(850, name: "Raycast", path: "/Applications/Raycast.app/Contents/MacOS/Raycast", mb: 310, ageS: 40 * 3600),
            rec(851, ppid: 850, name: "com.apple.WebKit.Networking", path: webkitNet, mb: 45, resp: 850, ageS: 40 * 3600,
                flags: busy ? 0x400 | 0x1000 : 0x400),

            rec(900, name: "ChatGPT", path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", mb: 3900, ageS: 9 * 3600),
            rec(901, ppid: 900, name: "ChatGPT Helper (Renderer)", path: "/Applications/ChatGPT.app/Contents/Frameworks/ChatGPT Helper (Renderer).app/Contents/MacOS/ChatGPT Helper (Renderer)", mb: 250, resp: 900, ageS: 9 * 3600),
            rec(910, name: "Discord", path: "/Applications/Discord.app/Contents/MacOS/Discord", mb: 400, ageS: 12 * 3600),
            rec(911, ppid: 910, name: "Discord Helper (Renderer)", path: "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)", mb: 820, resp: 910, ageS: 12 * 3600),
            rec(912, ppid: 910, name: "Discord Helper (GPU)", path: "/Applications/Discord.app/Contents/Frameworks/Discord Helper (GPU).app/Contents/MacOS/Discord Helper (GPU)", mb: 180, resp: 910, ageS: 12 * 3600),
            rec(913, ppid: 910, name: "Discord Helper", path: "/Applications/Discord.app/Contents/Frameworks/Discord Helper.app/Contents/MacOS/Discord Helper", mb: 90, resp: 910, ageS: 12 * 3600),
            rec(920, name: "Spotify", path: "/Applications/Spotify.app/Contents/MacOS/Spotify", mb: 610, ageS: 5 * 3600),
            rec(930, name: "Messages", path: "/System/Applications/Messages.app/Contents/MacOS/Messages", mb: 190, ageS: 40 * 3600),
            rec(940, name: "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", mb: 180, ageS: 40 * 3600),
            rec(950, name: "Tutto", path: "/Applications/Tutto.app/Contents/MacOS/Tutto", mb: 92, ageS: 40 * 3600),
            rec(960, name: "DownloadMoreRAM", path: "/Applications/Download More RAM.app/Contents/MacOS/DownloadMoreRAM", mb: 26, ageS: 3600),
            rec(970, name: "Mail", path: "/System/Applications/Mail.app/Contents/MacOS/Mail", mb: 300, ageS: 40 * 3600),
        ]
        guard busy else { return r }
        for i in 0..<21 {
            let pid = Int32(700 + i)
            r.append(rec(pid, ppid: 601, name: "claude", path: claudeCLI, mb: 255 + Double(i * 37 % 163), ageS: Double(1800 + i * 2400), cpuS: 2))
            if i % 3 == 0 {
                r.append(rec(pid + 100, ppid: pid, name: "node", path: node, mb: 120 + Double(i * 11), resp: pid, ageS: Double(1700 + i * 2400), cpuS: 1))
            }
        }
        r.append(rec(800, name: "Python", path: python, mb: 11, resp: 999, ageS: 3 * 3600 + 1368, cpuS: 0.4))
        r.append(rec(801, name: "node", path: node, mb: 184, resp: 620, ageS: 3000, cpuS: 0.9))
        return r
    }

    /// cwd, argv and transcript activity for the scripted processes.
    struct Info: ProcessInfoSource {
        func cwd(pid: Int32) -> String? {
            switch pid {
            case 610: "/Users/bryan/Projects/stdout"
            case 620: "/Users/bryan/Documents/XCode/DownloadMoreRAM"
            case 630: "/Users/bryan/Documents/XCode/Reaper"
            case 700...720: "/Users/bryan/Library/Application Support/Claude/scratch-workspaces/c4ac/878f/scratch-2026-10-\(10 + Int(pid) % 9)-\(String(format: "%06x", Int(pid) * 7919))"
            default: nil
            }
        }
        func argv(pid: Int32) -> [String]? {
            switch pid {
            case 620: [SampleData.claudeCLI, "--resume", "2f1c8a9e-5b3d-4a7e-9c1f-0d2e4b6a8c13"]
            case 800: [SampleData.python, "-m", "http.server", "8765", "--bind", "127.0.0.1"]
            case 801: [SampleData.node, "/Users/bryan/Projects/stdout/node_modules/.bin/vite"]
            case 621, 622, 623: [SampleData.node, "/Users/bryan/.local/share/rea/mcp.js"]
            default: nil
            }
        }
        func transcriptActivity(sessionID: String) -> Date? { SampleData.now.addingTimeInterval(-2 * 3600 - 300) }
    }

    /// Two snapshots 2 s apart feed the CPU history; the leak detector gets 35 minutes of growth.
    static func report(busy: Bool, system: SystemSample?) -> ProcessReport {
        var cpu = CPUHistory()
        let earlier = ProcessSnapshot(timestamp: now.addingTimeInterval(-2), records: records(busy: busy), unreadableCount: 155)
        let snap = ProcessSnapshot(timestamp: now, records: records(busy: busy, cpuOffsetS: 0.08), unreadableCount: 155)
        cpu.add(earlier)
        cpu.add(snap)
        let info = Info()
        let groups = AppGrouper.group(snap)
        let sessions = AgentClassifier.sessions(snap, cpuHistory: cpu, info: info, now: now)
        let leftovers = AgentClassifier.leftovers(snap, cpuHistory: cpu, info: info, now: now)
        var leaks: [Leak] = []
        if busy {
            var detector = LeakDetector()
            for i in 0..<8 {
                let t = now.addingTimeInterval(Double(i - 7) * 300)
                let grown = records(busy: busy).map { r -> ProcessRecord in
                    guard r.pid == 911 else { return r }
                    var g = r
                    g.footprint = UInt64((820 + 83 * Double(i)) * 1_048_576)
                    return g
                }
                detector.add(ProcessSnapshot(timestamp: t, records: grown))
            }
            leaks = detector.leaks(now: now)
        }
        let profile = URL(fileURLWithPath: "/Users/bryan/Library/Application Support/Firefox/Profiles/ag8jngqu.default-release")
        return ProcessReport(
            timestamp: now, rows: ProcessAnalyzer.rows(groups, sessions: sessions), totalFootprint: snap.totalFootprint,
            unreadableCount: 155, sessions: sessions, leftovers: leftovers, leaks: leaks,
            insights: system.map { WallInsights.from(snap, system: $0) },
            firefox: FirefoxState(running: true, profile: profile, unloaderOn: false, gpu: FirefoxLevers.gpuProcess(in: snap)))
    }

    // MARK: A scripted download through the real engine

    /// Readings on a virtual clock: sleeping advances time instantly.
    final class Sampling: RAMKit.Sampling, @unchecked Sendable {
        private let lock = NSLock()
        private var clock: Double = 0
        private var calls = 0
        let script: @Sendable (Int, Double) -> [ProcessRecord]
        let systemAt: @Sendable (Double) -> SystemSample

        init(script: @escaping @Sendable (Int, Double) -> [ProcessRecord], systemAt: @escaping @Sendable (Double) -> SystemSample) {
            self.script = script
            self.systemAt = systemAt
        }

        func processSnapshot() -> ProcessSnapshot {
            lock.lock(); defer { lock.unlock() }
            let s = ProcessSnapshot(timestamp: SampleData.now.addingTimeInterval(clock), records: script(calls, clock))
            calls += 1
            return s
        }
        func systemSample() throws -> SystemSample { lock.lock(); defer { lock.unlock() }; return systemAt(clock) }
        func sleep(ms: Int) async throws { lock.withLock { clock += Double(ms) / 1000 } }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return SampleData.now.addingTimeInterval(clock) }
    }

    struct Backend: ReliefBackend {
        let name = "helper"
        func relieve(level: PressureLevel, holdMs: Int) async throws {}
        func restore() async throws {}
    }

    /// Apps respond between 3 s and 11 s: Firefox unloads a tab and trims its GPU process, Discord and
    /// ChatGPT shrink, Mail grows, a Claude Code session is busy (excluded), Pages quits, Preview starts.
    @Sendable static func downloadScript(_ call: Int, _ t: Double) -> [ProcessRecord] {
        let f = min(1, max(0, (t - 3) / 8))
        var r: [ProcessRecord] = [
            rec(500, name: "firefox", path: firefox, mb: 1250),
            rec(501, ppid: 500, name: "plugin-container", path: container, mb: 2300 - 120 * f, resp: 500),
            rec(502, ppid: 500, name: "plugin-container", path: container, mb: 2000 - 100 * f, resp: 500),
            rec(503, ppid: 500, name: "plugin-container", path: container, mb: 1600 - 80 * f, resp: 500),
            rec(504, ppid: 500, name: "plugin-container", path: container, mb: 1300, resp: 500),
            rec(505, ppid: 500, name: "plugin-container", path: container, mb: 1100, resp: 500),
            rec(507, ppid: 500, name: "Firefox GPU Helper", path: gpuHelper, mb: 5360 - 460 * f, resp: 500),
            rec(910, name: "Discord", path: "/Applications/Discord.app/Contents/MacOS/Discord", mb: 400),
            rec(911, ppid: 910, name: "Discord Helper (Renderer)", path: "/Applications/Discord.app/Contents/MacOS/Discord Helper (Renderer)", mb: 820 - 420 * f, resp: 910),
            rec(900, name: "ChatGPT", path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", mb: 4150 - 200 * f),
            rec(920, name: "Spotify", path: "/Applications/Spotify.app/Contents/MacOS/Spotify", mb: 610 - 20 * f),
            rec(970, name: "Mail", path: "/System/Applications/Mail.app/Contents/MacOS/Mail", mb: 300 + 100 * f),
            rec(610, name: "claude", path: claudeCLI, mb: 431 + 40 * min(t, 2)),
            rec(611, ppid: 610, name: "Blender", path: "/Applications/Blender.app/Contents/MacOS/Blender", mb: 1748 - 1500 * f, resp: 610),
            rec(612, ppid: 610, name: "Blender", path: "/Applications/Blender.app/Contents/MacOS/Blender", mb: 1718 - 1500 * f, resp: 610),
        ]
        if f < 0.5 { r.append(rec(506, ppid: 500, name: "plugin-container", path: container, mb: 1000, resp: 500)) }
        if t < 3 { r.append(rec(980, name: "Pages", path: "/Applications/Pages.app/Contents/MacOS/Pages", mb: 410)) }
        if t > 5 { r.append(rec(990, name: "Preview", path: "/System/Applications/Preview.app/Contents/MacOS/Preview", mb: 95)) }
        return r
    }

    /// Nobody gives anything back; Mail and Spotify grow a little, Preview starts.
    @Sendable static func nothingScript(_ call: Int, _ t: Double) -> [ProcessRecord] {
        let f = min(1, max(0, (t - 3) / 8))
        var r: [ProcessRecord] = [
            rec(500, name: "firefox", path: firefox, mb: 1250),
            rec(501, ppid: 500, name: "plugin-container", path: container, mb: 2300, resp: 500),
            rec(507, ppid: 500, name: "Firefox GPU Helper", path: gpuHelper, mb: 5360, resp: 500),
            rec(910, name: "Discord", path: "/Applications/Discord.app/Contents/MacOS/Discord", mb: 1490),
            rec(900, name: "ChatGPT", path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", mb: 4150),
            rec(920, name: "Spotify", path: "/Applications/Spotify.app/Contents/MacOS/Spotify", mb: 610 + 37 * f),
            rec(970, name: "Mail", path: "/System/Applications/Mail.app/Contents/MacOS/Mail", mb: 300 + 100 * f),
        ]
        if t > 5 { r.append(rec(990, name: "Preview", path: "/System/Applications/Preview.app/Contents/MacOS/Preview", mb: 95)) }
        return r
    }

    @Sendable static func downloadSystem(_ t: Double) -> SystemSample {
        t < 2.5 ? system(Sys(swapUsedGiB: 10.0, diskFreeGiB: 1.0, pressure: .warn, appGiB: 8.6, compressedGiB: 2.2, available: 23), at: now.addingTimeInterval(t))
                : system(Sys(swapUsedGiB: 8.1, diskFreeGiB: 1.0, pressure: .normal, appGiB: 7.1, compressedGiB: 1.6, available: 38), at: now.addingTimeInterval(t))
    }

    @Sendable static func nothingSystem(_ t: Double) -> SystemSample {
        system(Sys(swapUsedGiB: 4.1 + (t < 2.5 ? 0 : 0.05)), at: now.addingTimeInterval(t))
    }

    /// Runs the engine on the virtual clock; returns the receipt and every progress event.
    static func download(nothing: Bool) -> (Receipt, [ReliefProgress]) {
        let sampling = Sampling(script: nothing ? nothingScript : downloadScript, systemAt: nothing ? nothingSystem : downloadSystem)
        let engine = ReliefEngine(backend: Backend(), holdMs: AppModel.holdMs, settleMs: AppModel.settleMs, sampling: sampling, wall: { s in
            var m = WallModel()
            m.add(s)
            return m.status()?.percent ?? 0
        })
        let log = ProgressLog()
        let receipt = Snapshots.blocking { try! await engine.run { log.append($0) } }
        return (receipt, log.all)
    }

    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ReliefProgress] = []
        func append(_ p: ReliefProgress) { lock.lock(); items.append(p); lock.unlock() }
        var all: [ReliefProgress] { lock.lock(); defer { lock.unlock() }; return items }
    }
}
#endif
