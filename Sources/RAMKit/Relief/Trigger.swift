import Foundation

/// `kern.memorypressure_manual_trigger` request codes (xnu `kern_memorystatus.h`, test section).
public enum TriggerRequest: Int32, Sendable {
    case lowMemoryOne = 1
    case lowMemoryAll = 2
    case purgeableOne = 3
    case purgeableAll = 4
    case lowMemoryPurgeableOne = 5
    /// Notify every registered process and purge every purgeable object: what `memory_pressure -S` uses.
    case lowMemoryPurgeableAll = 6
}

/// The root-only kernel switch that simulates memory pressure. Writing a warn/critical value
/// puts the kernel in manual testing mode (the reported pressure level is overridden) until a
/// NORMAL value is written, so every caller must restore.
public enum Trigger {
    public static let sysctlName = "kern.memorypressure_manual_trigger"

    /// `(request << 16) | level`, where level is NOTE_MEMORYSTATUS_PRESSURE_{NORMAL=1, WARN=2, CRITICAL=4}.
    public static func encode(_ request: TriggerRequest, _ level: PressureLevel) -> Int32 {
        (request.rawValue << 16) | Int32(level.rawValue)
    }

    public static func signalValue(_ level: PressureLevel) -> Int32 { encode(.lowMemoryPurgeableAll, level) }
    public static let restoreValue: Int32 = encode(.lowMemoryPurgeableAll, .normal)

    /// Writes the trigger. 0 or errno (EPERM when not root, ENOENT if the oid is missing).
    public static func write(_ value: Int32) -> Int32 { Sysctl.writeInt32(sysctlName, value) }
}
