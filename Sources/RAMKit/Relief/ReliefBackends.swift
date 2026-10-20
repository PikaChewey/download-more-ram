import CDarwinMem
import Darwin
import Foundation

/// Writes the trigger directly. Only works as root (`sudo ram download`, or inside the helper).
/// Restores normal on success, error, task cancellation and SIGINT/SIGTERM/SIGHUP; a marker file
/// lets the helper or `ram restore` recover after SIGKILL.
public struct DirectSysctlBackend: ReliefBackend {
    public let name: String
    let marker: String?

    public init(name: String = "root", marker: String? = HelperConstants.holdingMarker) {
        self.name = name
        self.marker = marker
    }

    public func relieve(level: PressureLevel, holdMs: Int) async throws {
        guard geteuid() == 0 else { throw ReliefError.notPermitted }
        guard level != .normal else { throw ReliefError.refused("normal is not a relief level") }
        if let marker { FileManager.default.createFile(atPath: marker, contents: Data("\(getpid())\n".utf8)) }
        dm_restore_guard_arm(Trigger.sysctlName, Trigger.restoreValue)
        let err = Trigger.write(Trigger.signalValue(level))
        guard err == 0 else {
            dm_restore_guard_disarm()
            if let marker { try? FileManager.default.removeItem(atPath: marker) }
            throw err == EPERM ? ReliefError.notPermitted : ReliefError.kernel(err)
        }
        var waitError: Error?
        do { try await Task.sleep(nanoseconds: UInt64(holdMs) * 1_000_000) } catch { waitError = error }
        let restored = Trigger.write(Trigger.restoreValue)
        dm_restore_guard_disarm()
        if restored == 0, let marker { try? FileManager.default.removeItem(atPath: marker) }
        if restored != 0 { throw ReliefError.restoreFailed(restored) }
        if let waitError { throw waitError }
    }

    public func restore() async throws {
        guard geteuid() == 0 else { throw ReliefError.notPermitted }
        let restored = Trigger.write(Trigger.restoreValue)
        if restored != 0 { throw ReliefError.restoreFailed(restored) }
        if let marker { try? FileManager.default.removeItem(atPath: marker) }
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
            return .unavailable(reason: "\(error)")
        }
    }

    public func backend() -> (any ReliefBackend)? {
        switch self {
        case .root: DirectSysctlBackend()
        case .helper: HelperBackend()
        case .unavailable: nil
        }
    }

    /// An interrupted root download (SIGKILL) left the kernel in simulated pressure.
    public static var interruptedHoldDetected: Bool {
        FileManager.default.fileExists(atPath: HelperConstants.holdingMarker)
    }
}
