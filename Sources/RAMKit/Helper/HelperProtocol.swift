import Foundation

/// The root helper's entire surface: four calls, no paths, no shell, no arbitrary sysctl.
@objc public protocol RAMHelperXPC {
    /// Signals `level` (2 = warn, 4 = critical) for `holdMs`, then restores normal. Replies nil on
    /// success or a human-readable refusal/error.
    func relieve(level: Int, holdMs: Int, reply: @escaping (String?) -> Void)
    /// Forces the kernel back to normal pressure (manual mode off).
    func restore(reply: @escaping (String?) -> Void)
    /// JSON: {"version": ..., "busy": ..., "lastRelief": ...}.
    func status(reply: @escaping (String) -> Void)
    /// Resumes `pid` only if the kernel suspended it at the memory wall (PROC_FLAG_PA_SUSP), the way
    /// loginwindow's Resume button does. Replies nil on success or a reason.
    func resumePaused(pid: Int, reply: @escaping (String?) -> Void)
}

public enum HelperConstants {
    public static let label = "ca.bryanyao.DownloadMoreRAM.helper"
    public static let machService = label
    public static let installedBinary = "/Library/PrivilegedHelperTools/\(label)"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    /// v1.0 single marker (still recognised); v1.1+ writes per-process markers `<prefix>.<pid>`.
    public static let holdingMarker = "/var/run/\(label).holding"
    public static let holdingMarkerPrefix = "/var/run/\(label).holding"
    public static let version = "1.1.0"
}

public struct HelperStatus: Codable, Sendable {
    public var version: String
    public var busy: Bool
    public var lastRelief: Date?
    public var reliefsThisHour: Int

    public init(version: String, busy: Bool, lastRelief: Date?, reliefsThisHour: Int) {
        self.version = version
        self.busy = busy
        self.lastRelief = lastRelief
        self.reliefsThisHour = reliefsThisHour
    }
}
