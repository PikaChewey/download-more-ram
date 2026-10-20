import Darwin
import Foundation

/// "A hold is in progress" files, one per holding process: `<prefix>.<pid>` containing
/// "<pid> <startTime>". The holder removes its own after a successful restore (also from the signal
/// guard); the helper at startup and `ram restore` restore normal pressure for markers whose owner
/// is gone (or whose pid now belongs to a different process), and never for a live hold.
public struct HoldMarker: Sendable, Equatable {
    public var path: String
    public var pid: Int32
    public var startTime: UInt64
}

public enum HoldMarkers {
    public static let defaultPrefix = HelperConstants.holdingMarkerPrefix

    public static func path(prefix: String = defaultPrefix, pid: Int32 = getpid()) -> String { "\(prefix).\(pid)" }

    /// Writes this process's marker; returns its path (nil if it could not be written).
    public static func write(prefix: String = defaultPrefix) -> String? {
        let pid = getpid()
        let start = ProcessSampler.record(pid: pid)?.startTime ?? 0
        let p = path(prefix: prefix, pid: pid)
        return FileManager.default.createFile(atPath: p, contents: Data("\(pid) \(start)\n".utf8)) ? p : nil
    }

    public static func remove(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    /// Every marker under `prefix`, including the v1.0 single file `<prefix>` itself.
    public static func all(prefix: String = defaultPrefix) -> [HoldMarker] {
        let url = URL(fileURLWithPath: prefix)
        let dir = url.deletingLastPathComponent().path
        let base = url.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0 == base || $0.hasPrefix(base + ".") }.compactMap { name in
            let full = dir + "/" + name
            let text = (try? String(contentsOfFile: full, encoding: .utf8)) ?? ""
            let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
            let pid = parts.first.flatMap { Int32($0) } ?? Int32(name.split(separator: ".").last ?? "") ?? 0
            let start = parts.dropFirst().first.flatMap { UInt64($0) } ?? 0
            return HoldMarker(path: full, pid: pid, startTime: start)
        }
    }

    /// Whether the marker's owner is still that same process. Precise (start time) when we can read
    /// the owner; otherwise falls back to "a process with that pid exists".
    public static func isLive(_ m: HoldMarker) -> Bool {
        guard m.pid > 0 else { return false }
        if m.startTime > 0, let r = ProcessSampler.record(pid: m.pid) { return r.startTime == m.startTime }
        return kill(m.pid, 0) == 0 || errno == EPERM
    }

    public static func orphaned(prefix: String = defaultPrefix) -> [HoldMarker] {
        all(prefix: prefix).filter { !isLive($0) }
    }
}
