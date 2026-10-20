import Foundation

/// macOS's own record of a memory crisis: the `JetsamEvent-*.ips` files the kernel's memorystatus
/// subsystem leaves in /Library/Logs/DiagnosticReports when it kills processes to free memory
/// (group `_analyticsusers`, so admin users can read them without sudo).
///
/// VERIFIED on macOS 26.5.2 (xnu-12377) against 14 real reports:
/// - `rpages` is the process's phys_footprint in pages (xnu `memorystatus_get_task_page_counts`), the
///   same number as Activity Monitor's Memory column;
/// - entries with a `reason` are processes killed since the previous report: consecutive reports never
///   repeat a pid, and the largest `killDelta` (mach ticks) matches the gap since the previous report;
/// - `coalition` groups an app with everything it launched, which is how Force Quit totals apps;
/// - `age` orders processes by start time, so a coalition's oldest process is the app itself.
public struct JetsamReport: Codable, Sendable, Equatable {
    public struct NameGroup: Codable, Sendable, Equatable {
        public var name: String
        public var count: Int
        public var bytes: UInt64
    }

    /// An app (resource coalition) and everything it launched, named after its oldest process.
    public struct App: Codable, Sendable, Equatable {
        public var name: String
        public var bytes: UInt64
        public var processes: Int
        /// Its biggest group of same-named processes, e.g. 23 × python3.12.
        public var biggest: NameGroup
    }

    public var file: String
    public var date: Date
    public var largestProcess: String?
    /// Biggest apps by memory at the moment of the report.
    public var apps: [App]
    public var killed: Int
    public var killReasons: [String: Int]
    public var mostKilled: [NameGroup]
    /// Memory the compressor occupied, and the uncompressed size of what it held.
    public var compressorBytes: UInt64
    public var compressedDataBytes: UInt64
    /// Every killed name, so a crisis spanning several reports adds up exactly (not written to JSON).
    public var killedByName: [String: NameGroup] = [:]

    enum CodingKeys: String, CodingKey {
        case file, date, largestProcess, apps, killed, killReasons, mostKilled, compressorBytes, compressedDataBytes
    }
}

/// Reports less than `JetsamReports.episodeGapS` apart are one crisis.
public struct JetsamEpisode: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var reports: Int
    public var killed: Int
    public var killReasons: [String: Int]
    public var mostKilled: [JetsamReport.NameGroup]
    /// The report in which the biggest app was at its biggest.
    public var peak: JetsamReport
}

public enum JetsamReports {
    public static let directory = "/Library/Logs/DiagnosticReports"
    public static let episodeGapS: Double = 15 * 60
    public static let topApps = 5
    public static let topKilled = 3

    /// Reports from the last `days` days (chosen by file name, so old reports are never opened).
    /// `unreadable` counts reports that exist but could not be read (not an admin user).
    public static func load(days: Int, directory: String = directory, now: Date = Date()) -> (reports: [JetsamReport], unreadable: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return ([], 0) }
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86_400)
        var reports: [JetsamReport] = []
        var unreadable = 0
        for name in names.sorted() where name.hasPrefix("JetsamEvent-") && name.hasSuffix(".ips") {
            guard let stamp = fileDate(name), stamp >= cutoff else { continue }
            guard let data = FileManager.default.contents(atPath: directory + "/" + name) else { unreadable += 1; continue }
            if let r = parse(data, file: name) { reports.append(r) }
        }
        return (reports.sorted { $0.date < $1.date }, unreadable)
    }

    public static func parse(_ data: Data, file: String) -> JetsamReport? {
        // Line 1 is a short JSON header; the report itself follows.
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any],
              let processes = body["processes"] as? [[String: Any]],
              let status = body["memoryStatus"] as? [String: Any],
              let date = (body["date"] as? String).flatMap(reportDate)
        else { return nil }
        let pageSize = UInt64(max(0, int(status["pageSize"]) ?? 16_384))
        func bytes(_ p: [String: Any]) -> UInt64 { UInt64(max(0, int(p["rpages"]) ?? 0)) * pageSize }
        func name(_ p: [String: Any]) -> String { p["name"] as? String ?? "?" }
        func groups(_ ps: [[String: Any]]) -> [JetsamReport.NameGroup] {
            var byName: [String: JetsamReport.NameGroup] = [:]
            for p in ps {
                byName[name(p), default: JetsamReport.NameGroup(name: name(p), count: 0, bytes: 0)].count += 1
                byName[name(p)]!.bytes += bytes(p)
            }
            return Array(byName.values)
        }

        let killed = processes.filter { !($0["reason"] as? String ?? "").isEmpty }
        let alive = processes.filter { ($0["reason"] as? String ?? "").isEmpty }

        var coalitions: [Int: [[String: Any]]] = [:]
        for p in alive {
            // A process without a coalition stands alone (negative keys never collide with real ids).
            coalitions[int(p["coalition"]) ?? -1 - (int(p["pid"]) ?? 0), default: []].append(p)
        }
        let apps = coalitions.values.compactMap { members -> JetsamReport.App? in
            guard let oldest = members.max(by: { (int($0["age"]) ?? 0) < (int($1["age"]) ?? 0) }),
                  let biggest = groups(members).max(by: { ($0.bytes, $1.name) < ($1.bytes, $0.name) }) else { return nil }
            return JetsamReport.App(name: name(oldest), bytes: members.reduce(0) { $0 + bytes($1) },
                                    processes: members.count, biggest: biggest)
        }
        .sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }

        var reasons: [String: Int] = [:]
        for p in killed { if let r = p["reason"] as? String { reasons[r, default: 0] += 1 } }
        let killedGroups = groups(killed)

        return JetsamReport(
            file: file, date: date, largestProcess: body["largestProcess"] as? String,
            apps: Array(apps.prefix(topApps)), killed: killed.count, killReasons: reasons,
            mostKilled: top(killedGroups),
            compressorBytes: UInt64(max(0, int(status["compressorSize"]) ?? 0)) * pageSize,
            compressedDataBytes: UInt64(max(0, int(status["uncompressed"]) ?? 0)) * pageSize,
            killedByName: Dictionary(uniqueKeysWithValues: killedGroups.map { ($0.name, $0) }))
    }

    public static func episodes(_ reports: [JetsamReport]) -> [JetsamEpisode] {
        var out: [JetsamEpisode] = []
        var current: [JetsamReport] = []
        func close() {
            guard let first = current.first, let last = current.last,
                  let peak = current.max(by: { ($0.apps.first?.bytes ?? 0) < ($1.apps.first?.bytes ?? 0) }) else { return }
            var reasons: [String: Int] = [:]
            var killedByName: [String: JetsamReport.NameGroup] = [:]
            for r in current {
                for (k, v) in r.killReasons { reasons[k, default: 0] += v }
                for g in r.killedByName.values {
                    killedByName[g.name, default: JetsamReport.NameGroup(name: g.name, count: 0, bytes: 0)].count += g.count
                    killedByName[g.name]!.bytes += g.bytes
                }
            }
            out.append(JetsamEpisode(
                start: first.date, end: last.date, reports: current.count,
                killed: current.reduce(0) { $0 + $1.killed }, killReasons: reasons,
                mostKilled: top(Array(killedByName.values)), peak: peak))
            current = []
        }
        for r in reports.sorted(by: { $0.date < $1.date }) {
            if let last = current.last, r.date.timeIntervalSince(last.date) > episodeGapS { close() }
            current.append(r)
        }
        close()
        return out
    }

    static func top(_ groups: [JetsamReport.NameGroup]) -> [JetsamReport.NameGroup] {
        Array(groups.sorted { ($0.count, $1.name) > ($1.count, $0.name) }.prefix(topKilled))
    }

    /// The reasons behind at least a fifth of the kills, most common first.
    public static func mainReasons(_ reasons: [String: Int]) -> [String] {
        let total = reasons.values.reduce(0, +)
        return reasons.filter { $0.value * 5 >= total }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// A kill reason in words.
    public static func describe(reason: String) -> String {
        switch reason {
        case "vm-compressor-space-shortage": "the compressor ran out of space"
        case "vm-compressor-thrashing": "the compressor was thrashing"
        case "vm-pageshortage": "free pages ran out"
        case "low-swap": "swap ran out"
        case "idle-exit": "idle daemons were asked to exit"
        case "per-process-limit": "processes passed their memory limit"
        case "jettisoned": "memory was short"
        default: reason
        }
    }

    static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    static func reportDate(_ s: String) -> Date? {
        // "2026-10-17 17:24:48.32 -0400": drop the fraction, whose length varies.
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return dateFormatter.date(from: trimmed)
    }

    static func fileDate(_ name: String) -> Date? {
        // JetsamEvent-2026-10-16-040226.ips (local time)
        let stem = name.dropFirst("JetsamEvent-".count).prefix(17)
        return fileFormatter.date(from: String(stem))
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()
}
