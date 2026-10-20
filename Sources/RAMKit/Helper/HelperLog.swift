import Foundation

/// The helper logs every download with its caller's pid ("relief from pid 95399: critical for
/// 10000 ms", v1.0.0 and later), so a benchmark can tell when some other process sent the
/// signal during one of its arms.
public enum HelperLog {
    public static let predicate = """
        subsystem == "\(HelperConstants.label)" AND eventMessage BEGINSWITH "relief from pid"
        """

    /// Pids other than `excluding` that started a download between `from` and `to`, or nil when
    /// the log could not be read.
    public static func reliefCallers(from: Date, to: Date, excluding: Int32) -> [Int32]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["show", "--style", "compact", "--start", formatter.string(from: from),
                       "--end", formatter.string(from: to.addingTimeInterval(1)), "--predicate", predicate]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return callers(String(decoding: data, as: UTF8.self), excluding: excluding)
    }

    static func callers(_ text: String, excluding: Int32) -> [Int32] {
        var pids: [Int32] = []
        for line in text.split(separator: "\n") {
            // "[subsystem:category] relief from pid N…" only: "refused relief from pid N" sent nothing.
            guard let r = line.range(of: "] relief from pid ") ?? (line.hasPrefix("relief from pid ") ? line.range(of: "relief from pid ") : nil)
            else { continue }
            let digits = line[r.upperBound...].prefix { $0.isNumber }
            if let pid = Int32(digits), pid != excluding, !pids.contains(pid) { pids.append(pid) }
        }
        return pids
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
