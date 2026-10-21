import CDarwinMem
import Darwin
import Foundation

/// Writes the trigger directly. Only works as root (`sudo ram download`, or inside the helper).
/// Restores normal on success, error, task cancellation and every catchable terminating signal; a
/// per-process marker lets the helper or `ram restore` recover after SIGKILL.
public struct DirectSysctlBackend: ReliefBackend {
    public let name: String
    let markerPrefix: String?

    public init(name: String = "root", markerPrefix: String? = HoldMarkers.defaultPrefix) {
        self.name = name
        self.markerPrefix = markerPrefix
    }

    public func relieve(level: PressureLevel, holdMs: Int) async throws {
        guard geteuid() == 0 else { throw ReliefError.notPermitted }
        // Validate before anything touches the kernel: a bad hold must never trap mid-hold.
        if let invalid = Self.validate(level: level, holdMs: holdMs) { throw invalid }
        // A second hold in this process must not touch the first one's marker (same per-pid path).
        guard dm_restore_guard_is_armed() == 0 else { throw ReliefError.refused("a download is already running in this process") }
        let marker = markerPrefix.flatMap { HoldMarkers.write(prefix: $0) }
        let armed = dm_restore_guard_arm(Trigger.sysctlName, Trigger.restoreValue, marker)
        guard armed == 0 else {
            if let marker { HoldMarkers.remove(marker) }
            throw armed == EBUSY ? ReliefError.refused("a download is already running in this process") : ReliefError.kernel(armed)
        }
        let err = Trigger.write(Trigger.signalValue(level))
        guard err == 0 else {
            // xnu sets manual-testing mode *before* validating the value, so any write that reached
            // the handler must still be followed by a reset. EPERM (root check) and ENOENT (no such
            // oid) never reach it: nothing was set.
            let nothingSet = err == EPERM || err == ENOENT
            let restored = nothingSet ? 0 : Trigger.write(Trigger.restoreValue)
            dm_restore_guard_disarm()
            if restored == 0, let marker { HoldMarkers.remove(marker) }
            if restored != 0 { throw ReliefError.restoreFailed(restored) }
            throw err == EPERM ? ReliefError.notPermitted : ReliefError.kernel(err)
        }
        var waitError: Error?
        do { try await Task.sleep(nanoseconds: UInt64(clamping: holdMs) * 1_000_000) } catch { waitError = error }
        let restored = Trigger.write(Trigger.restoreValue)
        dm_restore_guard_disarm()
        if restored == 0, let marker { HoldMarkers.remove(marker) }
        if restored != 0 { throw ReliefError.restoreFailed(restored) }
        if let waitError { throw waitError }
    }

    static func validate(level: PressureLevel, holdMs: Int) -> ReliefError? {
        if level == .normal { return .refused("normal is not a relief level") }
        if !HelperPolicy.holdRange.contains(holdMs) { return .refused("hold must be 1-30 seconds") }
        return nil
    }

    /// Forces normal pressure and clears markers whose owner is gone (never a live hold's).
    public func restore() async throws {
        guard geteuid() == 0 else { throw ReliefError.notPermitted }
        let restored = Trigger.write(Trigger.restoreValue)
        if restored != 0 { throw ReliefError.restoreFailed(restored) }
        if let markerPrefix { HoldMarkers.orphaned(prefix: markerPrefix).forEach { HoldMarkers.remove($0.path) } }
    }
}

/// Talks to the root helper over XPC (`ca.bryanyao.DownloadMoreRAM.helper`).
public struct HelperBackend: ReliefBackend {
    public let name = "helper"
    let machService: String

    public init(machService: String = HelperConstants.machService) {
        self.machService = machService
    }

    public func relieve(level: PressureLevel, holdMs: Int) async throws {
        let reply: String? = try await call(timeout: Double(holdMs) / 1000 + 15) { proxy, done in
            proxy.relieve(level: level.rawValue, holdMs: holdMs) { done($0) }
        }
        if let reply { throw ReliefError.refused(reply) }
    }

    public func restore() async throws {
        let reply: String? = try await call(timeout: 10) { proxy, done in proxy.restore { done($0) } }
        if let reply { throw ReliefError.refused(reply) }
    }

    public func resumePaused(pid: Int32) async throws {
        let reply: String? = try await call(timeout: 10) { proxy, done in proxy.resumePaused(pid: Int(pid)) { done($0) } }
        if let reply { throw ReliefError.refused(reply) }
    }

    public func status(timeout: Double = 3) async throws -> HelperStatus {
        let json: String? = try await call(timeout: timeout) { proxy, done in proxy.status { done($0) } }
        guard let data = json?.data(using: .utf8),
              let status = try? Receipt.decoder.decode(HelperStatus.self, from: data)
        else { throw ReliefError.helperUnreachable("unreadable status") }
        return status
    }

    /// One request over a fresh privileged connection, failing with `.helperUnreachable` on
    /// connection errors or after `timeout` seconds.
    func call(timeout: Double,
              _ body: @escaping @Sendable (RAMHelperXPC, @escaping @Sendable (String?) -> Void) -> Void) async throws -> String? {
        let conn = NSXPCConnection(machServiceName: machService, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: RAMHelperXPC.self)
        conn.resume()
        defer { conn.invalidate() }
        let once = OnceBox()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            let finish: @Sendable (Result<String?, Error>) -> Void = { result in
                if once.claim() { cont.resume(with: result) }
            }
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                finish(.failure(ReliefError.helperUnreachable(error.localizedDescription)))
            }
            guard let helper = proxy as? RAMHelperXPC else {
                finish(.failure(ReliefError.helperUnreachable("no proxy")))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(ReliefError.helperUnreachable("timed out after \(Int(timeout))s")))
            }
            body(helper) { finish(.success($0)) }
        }
    }
}

final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// Which way (if any) this process can download RAM right now.
public enum ReliefAvailability: Sendable, Equatable {
    case root
    case helper(version: String)
    case unavailable(reason: String)

    public static func detect(helper: HelperBackend = HelperBackend()) async -> ReliefAvailability {
        if geteuid() == 0 { return .root }
        guard FileManager.default.fileExists(atPath: HelperConstants.plistPath) else {
            return .unavailable(reason: ReliefError.notPermitted.description)
        }
        do {
            let status = try await helper.status(timeout: 3)
            return .helper(version: status.version)
        } catch {
            return .unavailable(reason: "The helper is installed but did not answer this copy of ram (\(error)). It only answers binaries signed by the same team: use the signed build (scripts/install.sh) or reinstall with  sudo ram helper install")
        }
    }

    /// The installed helper is an older (or newer) build than the one this copy carries: downloads
    /// still work, but the user should reinstall it to get the current safety rules.
    public var helperOutdated: Bool {
        if case .helper(let version) = self { return version != HelperConstants.version }
        return false
    }

    public var helperVersion: String? {
        if case .helper(let version) = self { return version }
        return nil
    }

    public func backend() -> (any ReliefBackend)? {
        switch self {
        case .root: DirectSysctlBackend()
        case .helper: HelperBackend()
        case .unavailable: nil
        }
    }

    /// A holder died without restoring (SIGKILL, power loss): the kernel may still be in simulated
    /// pressure. A live hold in progress does not count.
    public static var interruptedHoldDetected: Bool { !HoldMarkers.orphaned().isEmpty }
}
