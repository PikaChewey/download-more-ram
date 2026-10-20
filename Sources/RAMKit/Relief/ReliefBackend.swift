import Foundation

public enum ReliefError: Error, Sendable, Equatable, CustomStringConvertible {
    case notPermitted
    case helperUnreachable(String)
    case refused(String)
    case kernel(Int32)
    case restoreFailed(Int32)

    public var description: String {
        switch self {
        case .notPermitted: "Downloads need the helper: run  sudo ram helper install  (or sudo ram download)"
        case .helperUnreachable(let why): "The helper did not answer (\(why)). Reinstall it with  sudo ram helper install"
        case .refused(let why): "The helper refused: \(why)"
        case .kernel(let e): "The kernel refused the pressure trigger (errno \(e): \(String(cString: strerror(e))))"
        case .restoreFailed(let e): "Restoring normal pressure failed (errno \(e)). Run  sudo ram restore"
        }
    }
}

/// Something that can put the kernel into simulated memory pressure and take it back out.
public protocol ReliefBackend: Sendable {
    var name: String { get }
    /// Signals `level` system-wide, holds it for `holdMs`, then restores normal. Must restore on
    /// every path (error, cancellation) before returning or throwing.
    func relieve(level: PressureLevel, holdMs: Int) async throws
    /// Forces the kernel back to normal (manual testing mode off).
    func restore() async throws
}
