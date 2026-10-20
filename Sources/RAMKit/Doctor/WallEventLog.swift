import Foundation

/// One time macOS showed "Your system has run out of application memory".
public struct WallEvent: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date?
    public var pausedApps: [String]
}

/// Reconstructs wall episodes from loginwindow's LowMemoryPanel log lines (VERIFIED on macOS
/// 26.5.2: `showLowMemoryPanel`, `<App> is low mem paused`, `closing and releasing lowmemory panel`).
public enum WallEventLog {
    public static let predicate = """
        process == "loginwindow" AND (eventMessage CONTAINS "showLowMemoryPanel" \
        OR eventMessage CONTAINS "is low mem paused" OR eventMessage CONTAINS "releasing lowmemory panel")
        """

    public static func parse(_ text: String) -> [WallEvent] {
        var events: [WallEvent] = []
        var open: WallEvent?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count > 23, let date = timestamp(line.prefix(23)) else { continue }
            if line.contains("showLowMemoryPanel") {
                if open == nil { open = WallEvent(start: date, end: nil, pausedApps: []) }
            } else if let range = line.range(of: "app: "), let paused = line.range(of: " is low mem paused") {
                let app = String(line[range.upperBound..<paused.lowerBound])
                if open == nil { open = WallEvent(start: date, end: nil, pausedApps: []) }
                if !(open!.pausedApps.contains(app)) { open!.pausedApps.append(app) }
            } else if line.contains("releasing lowmemory panel"), var e = open {
                e.end = date
                events.append(e)
                open = nil
            }
        }
        if let open { events.append(open) }
        return events
    }

    /// Runs `/usr/bin/log show` over the last `days` days (admin users need no sudo). Slow on
    /// busy systems (tens of seconds), so callers show progress.
    public static func read(days: Int) throws -> [WallEvent] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["show", "--last", "\(max(1, days))d", "--style", "compact", "--predicate", predicate]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func timestamp(_ s: Substring) -> Date? {
        formatter.date(from: String(s))
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}
