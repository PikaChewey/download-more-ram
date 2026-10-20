import Foundation

/// One concrete thing the user can do, with the memory it should return and how.
public struct Fix: Codable, Sendable, Equatable {
    public var title: String
    public var estimateBytes: UInt64?
    public var how: String
}

/// Everything `ram doctor` and the app's summary need, computed from one look at the system.
public struct Diagnosis: Codable, Sendable {
    public var wall: WallStatus?
    public var insights: WallInsights
    public var topApps: [AppSummaryLine]
    public var agentCount: Int
    public var agentBytes: UInt64
    public var quietAgentCount: Int
    public var quietAgentBytes: UInt64
    public var leftovers: [Leftover]
    public var firefoxBytes: UInt64?
    public var firefoxGPUBytes: UInt64?
    public var firefoxUnloaderOn: Bool?
    public var reliefAvailable: Bool
    /// Apps whose main process macOS paused while their helper processes keep burning CPU
    /// (observed 2026-10-20: ChatGPT's Codex helpers at ~4 cores for hours, on battery).
    public var spinningWhilePaused: [SpinningApp]
    public var fixes: [Fix]

    public struct SpinningApp: Codable, Sendable, Equatable {
        public var app: String
        public var cores: Double
    }

    public struct AppSummaryLine: Codable, Sendable {
        public var name: String
        public var footprint: UInt64
        public var processes: Int
    }

    /// Sessions quiet for longer than this count as "quiet" (they still hold their memory).
    public static let quietAfterS: Double = 6 * 3600

    public static func make(system: SystemSample, wall: WallStatus?, snapshot: ProcessSnapshot, sessions: [AgentSession],
                            leftovers: [Leftover], reliefAvailable: Bool, firefoxProfile: URL?, cpu: CPUHistory? = nil,
                            now: Date = Date()) -> Diagnosis {
        let groups = AppGrouper.group(snapshot)
        var spinning: [SpinningApp] = []
        if let cpu {
            for g in groups where g.head?.pausedByWall == true {
                let cores = g.members.filter { !$0.pausedByWall }.compactMap { cpu.cpuFraction($0.key) }.reduce(0, +)
                if cores >= 0.5 { spinning.append(SpinningApp(app: g.name, cores: cores)) }
            }
            spinning.sort { $0.cores > $1.cores }
        }
        let insights = WallInsights.from(snapshot, system: system)
        let quiet = sessions.filter { s in
            if let last = s.lastActive { return now.timeIntervalSince(last) > quietAfterS }
            return false
        }
        let firefox = groups.first { $0.bundlePath?.hasSuffix("/Firefox.app") ?? false }
        let gpu = FirefoxLevers.gpuProcess(in: snapshot)
        let unloader = firefox != nil ? firefoxProfile.map(FirefoxLevers.isUnloaderOn) : nil

        var fixes: [Fix] = []
        if !insights.stillPausedApps.isEmpty {
            var title = "Resume \(insights.stillPausedApps.joined(separator: ", ")): macOS paused them at the memory wall and never resumed them"
            let burn = spinning.reduce(0) { $0 + $1.cores }
            if burn >= 0.5 { title += String(format: " (their helpers are burning %.1f cores meanwhile)", burn) }
            fixes.append(Fix(title: title, estimateBytes: nil,
                             how: reliefAvailable ? "ram resume" : "click Resume in the Force Quit panel, or: sudo ram resume"))
        }
        if let gpu, gpu.footprint > 1 << 30 {
            fixes.append(Fix(title: "Restart Firefox's GPU process (Firefox relaunches it; WebGL/canvas reset)",
                             estimateBytes: gpu.footprint, how: "ram firefox gpu-restart"))
        }
        if !quiet.isEmpty {
            let bytes = quiet.reduce(UInt64(0)) { $0 + $1.footprint }
            fixes.append(Fix(title: "Close \(quiet.count) agent session\(quiet.count == 1 ? "" : "s") quiet for more than 6 h",
                             estimateBytes: bytes, how: "end them in the app that runs them (ram agents lists them)"))
        }
        if !leftovers.isEmpty {
            let bytes = leftovers.reduce(UInt64(0)) { $0 + $1.record.footprint }
            fixes.append(Fix(title: "Quit \(leftovers.count) leftover process\(leftovers.count == 1 ? "" : "es") agents forgot",
                             estimateBytes: bytes, how: "ram agents, then ram quit <pid>"))
        }
        if unloader == false {
            fixes.append(Fix(title: "Let Firefox unload idle tabs when memory is critical (off in release builds)",
                             estimateBytes: nil, how: "ram firefox unloader on (applies at the next Firefox start)"))
        }
        if !reliefAvailable {
            fixes.append(Fix(title: "Install the helper so downloads and autopilot work", estimateBytes: nil,
                             how: "sudo ram helper install"))
        }
        fixes.sort { ($0.estimateBytes ?? 0) > ($1.estimateBytes ?? 0) }

        return Diagnosis(
            wall: wall, insights: insights,
            topApps: groups.prefix(6).map { AppSummaryLine(name: $0.name, footprint: $0.footprint, processes: $0.processCount) },
            agentCount: sessions.count, agentBytes: sessions.reduce(0) { $0 + $1.footprint },
            quietAgentCount: quiet.count, quietAgentBytes: quiet.reduce(0) { $0 + $1.footprint },
            leftovers: leftovers, firefoxBytes: firefox?.footprint, firefoxGPUBytes: gpu?.footprint,
            firefoxUnloaderOn: unloader, reliefAvailable: reliefAvailable, spinningWhilePaused: spinning, fixes: fixes)
    }
}
