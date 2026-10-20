import Foundation

/// Text rendering for the CLI, kept in RAMKit so it is unit-tested. `color` adds ANSI styling.
public enum Render {
    public struct Style: Sendable {
        public var color: Bool
        public init(color: Bool) { self.color = color }
        public func bold(_ s: String) -> String { color ? "\u{1B}[1m\(s)\u{1B}[0m" : s }
        public func dim(_ s: String) -> String { color ? "\u{1B}[2m\(s)\u{1B}[0m" : s }
        public func green(_ s: String) -> String { color ? "\u{1B}[32m\(s)\u{1B}[0m" : s }
        public func amber(_ s: String) -> String { color ? "\u{1B}[33m\(s)\u{1B}[0m" : s }
        public func red(_ s: String) -> String { color ? "\u{1B}[31m\(s)\u{1B}[0m" : s }
        public func pressure(_ p: PressureLevel) -> String {
            switch p { case .normal: green(p.word); case .warn: amber(p.word); case .critical: red(p.word) }
        }
        public func wall(_ pct: Double, _ text: String) -> String { pct >= 85 ? red(text) : pct >= 70 ? amber(text) : green(text) }
    }

    public static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - s.count)
    }

    public static func lpad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    public static func status(system s: SystemSample, wall: WallStatus?, apps: [AppGroup], insights: WallInsights? = nil,
                              top: Int = 6, style: Style) -> String {
        var out = ""
        out += style.bold("Memory") + "  \(Format.bytes(s.memoryUsedBytes)) used of \(Format.bytes(s.physicalBytes))"
        out += " · pressure \(style.pressure(s.pressureLevel)) · \(s.availablePercent)% available (kernel)\n"
        out += "Swap    \(Format.bytes(s.swapUsed)) used of \(Format.bytes(s.swapTotal)) (\(s.swapfileCount) swapfiles)"
        out += " · compressed \(Format.bytes(s.compressedUncompressedBytes)) into \(Format.bytes(s.compressorOccupiedBytes))\n"
        if let wall {
            let bar = Format.bar(fraction: wall.percent / 100, width: 20, empty: "░")
            out += "Wall    " + style.wall(wall.percent, "\(bar) \(Format.percent(wall.percent))") + "  \(wall.reason)"
            if wall.imminent { out += " · " + style.red("the out-of-memory panel can appear any second") }
            else if let eta = wall.etaSeconds { out += " · " + style.amber("~\(Format.duration(eta)) to the wall") }
            out += "\n"
        }
        if let i = insights {
            if let app = i.nextToPauseApp { out += style.dim("        if you hit it, macOS pauses \(app) first") + "\n" }
            if !i.stillPausedApps.isEmpty {
                out += style.amber("Frozen  macOS paused part of \(i.stillPausedApps.joined(separator: ", ")) at the last wall and never resumed it — restart \(i.stillPausedApps.count == 1 ? "it" : "them")") + "\n"
            }
        }
        out += "\n"
        let shown = apps.prefix(top)
        let maxBytes = Double(shown.first?.footprint ?? 1)
        for g in shown {
            let bar = Format.bar(fraction: Double(g.footprint) / maxBytes, width: 16)
            out += "  \(pad(g.name, 22)) \(lpad(Format.bytes(g.footprint), 9))  \(style.dim(bar))  \(style.dim("\(g.processCount) proc"))\n"
        }
        return out
    }

    public static func apps(_ groups: [AppGroup], all: Bool, style: Style) -> String {
        var out = style.bold(pad("App", 28) + lpad("Memory", 10) + lpad("Procs", 7)) + "\n"
        for g in groups.prefix(all ? groups.count : 25) {
            let kind = g.kind == .agentSession ? style.dim(" agent") : ""
            out += pad(g.name, 28) + lpad(Format.bytes(g.footprint), 10) + lpad("\(g.processCount)", 7) + kind + "\n"
        }
        let total = groups.reduce(UInt64(0)) { $0 + $1.footprint }
        out += style.dim("\(groups.count) apps · \(Format.bytes(total)) total footprint (readable processes)") + "\n"
        return out
    }

    public static func agents(_ sessions: [AgentSession], leftovers: [Leftover], style: Style) -> String {
        var out = ""
        if sessions.isEmpty { out += style.dim("No AI agent sessions running.") + "\n" }
        else {
            let total = sessions.reduce(UInt64(0)) { $0 + $1.footprint }
            out += style.bold("\(sessions.count) agent sessions · \(Format.bytes(total))") + "\n"
            let archived = sessions.filter(\.archived)
            if !archived.isEmpty {
                out += style.amber("  \(archived.count) archived in Claude but still running: \(Format.bytes(archived.reduce(UInt64(0)) { $0 + $1.footprint })) · ram agents --quit-archived --yes") + "\n"
            }
            for s in sessions {
                let tag = s.archived ? style.amber(" [archived]") : ""
                var line = "  \(pad(s.tool.displayName, 12)) \(lpad(Format.bytes(s.footprint), 9))  \(pad(s.label, 34))\(tag) "
                if !s.topChildren.isEmpty { line += style.dim(" \(s.topChildren)") }
                var tail: [String] = []
                if let host = s.host { tail.append("in \(host)") }
                tail.append("up \(Format.duration(s.ageS))")
                if let last = s.lastActive {
                    tail.append("last active \(Format.duration(Date().timeIntervalSince(last))) ago")
                } else if let cpu = s.cpuFraction {
                    tail.append(cpu > CPUHistory.activeFraction ? "working (\(Format.percent(cpu * 100)) CPU)" : "quiet")
                }
                out += line + style.dim(" · " + tail.joined(separator: " · ")) + "\n"
            }
        }
        if !leftovers.isEmpty {
            out += "\n" + style.amber("Leftovers (\(leftovers.count)) · quit with  ram quit <pid>") + "\n"
            for l in leftovers {
                out += "  \(lpad("\(l.record.pid)", 6))  \(lpad(Format.bytes(l.record.footprint), 9))  \(l.reason)\n"
            }
        }
        return out
    }

    /// `Downloading RAM  ████████░░  2.41 GB  380 MB/s  6s left`
    public static func progress(_ p: ReliefProgress, width: Int = 24, style: Style) -> String {
        let frac = p.total > 0 ? p.elapsed / p.total : 0
        let bar = Format.bar(fraction: frac, width: width, empty: "░")
        let left = max(0, p.total - p.elapsed)
        let label: String
        switch p.phase {
        case .baseline: label = "Measuring baseline"
        case .holding: label = "Downloading RAM"
        case .settling: label = "Downloading RAM"
        case .done: label = "Downloaded RAM"
        }
        let amount = p.phase == .baseline ? "" : "  " + style.bold(Format.bytes(max(0, p.reclaimedSoFar)))
        let rate = p.phase == .holding || p.phase == .settling ? "  \(Format.bytes(Int64(p.rateBytesPerSec)))/s" : ""
        return "\(pad(label, 18)) \(style.green(bar))\(amount)\(rate)  \(Format.duration(left)) left"
    }

    public static func receipt(_ r: Receipt, style: Style) -> String {
        var out = "\n" + style.bold(style.green("✓ Downloaded \(Format.bytes(r.headlineBytes)) of RAM")) + " in \(Format.duration(r.durationS))\n\n"
        let shown = r.apps.filter { $0.delta != 0 }.prefix(12)
        let maxGain = Double(shown.map { max(0, $0.delta) }.max() ?? 1)
        for a in shown {
            let bar = a.delta > 0 ? Format.bar(fraction: Double(a.delta) / max(1, maxGain), width: 14) : ""
            let delta = Format.bytes(a.delta, signed: true)
            out += "  \(pad(a.name, 24)) \(lpad(a.delta >= 0 ? style.green(delta) : style.red(delta), style.color ? 19 : 10))  \(style.dim(bar))\n"
        }
        if shown.isEmpty { out += style.dim("  No app gave memory back this time.") + "\n" }
        if !r.excludedBusy.isEmpty {
            out += style.dim("  not counted (busy): " + r.excludedBusy.map { "\($0.name) \(Format.bytes($0.delta, signed: true))" }.joined(separator: ", ")) + "\n"
        }
        let sb = r.systemBefore, sa = r.systemAfter
        out += "\n  Swap \(Format.bytes(sb.swapUsed)) → \(Format.bytes(sa.swapUsed)) · pressure \(sb.pressureLevel.word) → \(sa.pressureLevel.word)"
        if let wb = r.wallBefore, let wa = r.wallAfter { out += " · wall \(Format.percent(wb)) → \(Format.percent(wa))" }
        out += "\n" + style.dim("  Measured with phys_footprint (Activity Monitor's Memory column); busy apps and apps that started/quit are not counted.") + "\n"
        return out
    }

    public static func doctor(_ d: Diagnosis, events: [WallEvent], days: Int, system s: SystemSample, style: Style) -> String {
        var out = style.bold("Download More RAM — doctor") + "\n\n"
        if events.isEmpty {
            out += style.green("No \"out of application memory\" events in the last \(days) days.") + "\n"
        } else {
            out += style.bold("Your Mac hit the memory wall \(events.count) time\(events.count == 1 ? "" : "s") in the last \(days) days") + "\n"
            let f = DateFormatter(); f.dateFormat = "EEE MMM d HH:mm"
            for e in events.suffix(8) {
                let dur = e.end.map { Format.duration($0.timeIntervalSince(e.start)) } ?? "still open"
                let paused = e.pausedApps.isEmpty ? "" : " · paused: " + e.pausedApps.joined(separator: ", ")
                out += "  \(f.string(from: e.start)) (\(dur))\(paused)\n"
            }
        }
        out += "\n" + style.bold("Right now") + "\n"
        if let w = d.wall {
            out += "  " + style.wall(w.percent, "\(Format.percent(w.percent)) to the wall") + " · \(w.reason)"
            if w.imminent { out += " · " + style.red("imminent") } else if let eta = w.etaSeconds { out += " · ~\(Format.duration(eta)) at this rate" }
            out += "\n"
        }
        out += "  memory \(Format.bytes(s.memoryUsedBytes)) of \(Format.bytes(s.physicalBytes)) · swap \(Format.bytes(s.swapUsed)) · pressure \(style.pressure(s.pressureLevel))\n"
        if let next = d.insights.nextToPauseApp { out += "  If you hit it, macOS pauses \(next) first.\n" }
        if !d.insights.stillPausedApps.isEmpty {
            out += "  " + style.amber("macOS paused \(d.insights.stillPausedApps.joined(separator: ", ")) at the wall and never resumed them.") + "\n"
            for sp in d.spinningWhilePaused {
                out += "  " + style.red(String(format: "%@ is paused, but its helpers are using %.1f cores.", sp.app, sp.cores)) + "\n"
            }
        }
        out += "\n" + style.bold("What's using it") + "\n"
        for a in d.topApps { out += "  \(pad(a.name, 22)) \(lpad(Format.bytes(a.footprint), 9))  \(style.dim("\(a.processes) proc"))\n" }
        if d.agentCount > 0 {
            out += "  \(d.agentCount) AI agent sessions hold \(Format.bytes(d.agentBytes))"
            if d.archivedAgentCount > 0 { out += "; " + style.amber("\(d.archivedAgentCount) archived but still running hold \(Format.bytes(d.archivedAgentBytes))") }
            if d.quietAgentCount > 0 { out += "; \(d.quietAgentCount) quiet for > 6 h hold \(Format.bytes(d.quietAgentBytes))" }
            out += "\n"
        }
        if let ff = d.firefoxBytes {
            out += "  Firefox \(Format.bytes(ff))"
            if let g = d.firefoxGPUBytes { out += " (GPU process \(Format.bytes(g)))" }
            if let on = d.firefoxUnloaderOn { out += " · low-memory tab unloading \(on ? "on" : "off")" }
            out += "\n"
        }
        out += "\n" + style.bold("Fixes, biggest first") + "\n"
        if d.fixes.isEmpty { out += style.green("  Nothing to fix right now.") + "\n" }
        for (i, f) in d.fixes.enumerated() {
            let est = f.estimateBytes.map { " " + style.green("~\(Format.bytes($0))") } ?? ""
            out += "  \(i + 1). \(f.title)\(est)\n     \(style.dim(f.how))\n"
        }
        return out
    }
}

