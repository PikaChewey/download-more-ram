import CDarwinMem
import Darwin
import Foundation

/// Undoing the kernel's out-of-memory pause. macOS suspends apps at the wall and only resumes them
/// when someone clicks Resume in the Force Quit panel, even hours after memory has recovered.
public enum PausedApps {
    public enum ResumeError: Error, Equatable, Sendable, CustomStringConvertible {
        case notPausedByWall
        case notRoot
        case failed(Int32)

        public var description: String {
            switch self {
            case .notPausedByWall: "macOS did not pause that process at the memory wall"
            case .notRoot: "Resuming needs the helper:  sudo ram helper install  (or sudo ram resume)"
            case .failed(let e): "the kernel refused (errno \(e))"
            }
        }
    }

    /// Processes the kernel suspended at the wall and has not resumed (any user's; cross-user readable).
    public static func current() -> [ProcessRecord] {
        ProcessSampler.snapshot().records.filter(\.pausedByWall)
    }

    /// The guard the helper applies: only processes carrying the kernel's own pause flag.
    public static func mayResume(_ flags: UInt32) -> Bool { flags & 0x1000 != 0 }

    /// Root only: re-checks the flag right before resuming.
    public static func resume(pid: Int32) -> Result<Void, ResumeError> {
        guard geteuid() == 0 else { return .failure(.notRoot) }
        var bsd = dm_bsdinfo()
        guard dm_proc_bsdinfo(pid, &bsd) == 0, mayResume(bsd.flags) else { return .failure(.notPausedByWall) }
        let err = dm_resume_paused(pid)
        return err == 0 ? .success(()) : .failure(.failed(err))
    }

    /// "Safe to resume": the wall has receded and nothing says it is coming back right away.
    public static func safeToResume(_ wall: WallStatus?, system: SystemSample?) -> Bool {
        guard let wall else { return false }
        return !wall.imminent && wall.percent < 70 && system?.pressureLevel != .critical
    }
}
