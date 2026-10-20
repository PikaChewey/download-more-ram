import CDarwinMem
import Darwin
import Foundation

public enum KillRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case otherUser
    case protected(String)
    case identityChanged
    case notFound
    case failed(Int32)

    public var description: String {
        switch self {
        case .otherUser: "belongs to another user or the system"
        case .protected(let name): "\(name) is protected"
        case .identityChanged: "the process changed since it was listed (pid reused)"
        case .notFound: "the process already exited"
        case .failed(let e): "the signal failed (errno \(e))"
        }
    }
}

public enum KillResult: Equatable, Sendable {
    case ok
    case refused(KillRefusal)
}

/// The only place that signals processes. Same-user only, never protected processes, and
/// identity-checked (start time + audit token) so a reused pid is never hit.
public enum SafeKill {
    public static let protectedNames: Set<String> = [
        "WindowServer", "loginwindow", "Finder", "Dock", "kernel_task", "launchd", "SystemUIServer",
        "ControlCenter", "NotificationCenter", "coreaudiod", "ram", "ram-helper", "Download More RAM",
        "DownloadMoreRAM",
    ]

    /// Pure guard, exposed for tests: `current` is the process as it is right now.
    public static func check(_ r: ProcessRecord, current: ProcessRecord?, frontmostPid: Int32? = nil) -> KillResult {
        if r.uid != getuid() { return .refused(.otherUser) }
        if protectedNames.contains(r.name) { return .refused(.protected(r.name)) }
        if r.pid == getpid() || r.pid <= 1 || r.pid == frontmostPid { return .refused(.protected(r.name)) }
        guard let current else { return .refused(.notFound) }
        if current.startTime != r.startTime || current.uid != r.uid { return .refused(.identityChanged) }
        return .ok
    }

    /// SIGTERM (or SIGKILL when `escalate`) through an audit token.
    public static func terminate(_ r: ProcessRecord, escalate: Bool, frontmostPid: Int32? = nil) -> KillResult {
        // Read the idversion before re-checking identity: if the pid is reused after this point
        // the audit token no longer matches and the kernel refuses the signal.
        var idversion: Int32 = 0
        let haveVersion = dm_proc_idversion(r.pid, &idversion) == 0
        let verdict = check(r, current: ProcessSampler.record(pid: r.pid), frontmostPid: frontmostPid)
        guard verdict == .ok else { return verdict }
        guard haveVersion else { return .refused(.notFound) }
        let err = dm_signal_audit(r.pid, idversion, escalate ? SIGKILL : SIGTERM)
        switch err {
        case 0: return .ok
        case ESRCH: return .refused(.identityChanged)
        default: return .refused(.failed(err))
        }
    }
}
