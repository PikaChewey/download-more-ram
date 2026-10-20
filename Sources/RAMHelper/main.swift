// ram-helper: the root launchd daemon behind "Download More RAM".
//
// It does exactly one privileged thing: put the kernel into simulated memory pressure for a
// bounded time and take it back out (kern.memorypressure_manual_trigger, the path Apple's
// `memory_pressure -S` uses). Three XPC calls, validated and rate-limited by HelperPolicy,
// logged with the caller's pid. Normal pressure is restored on every path: completion, client
// disconnect, SIGTERM/SIGINT/SIGHUP (signal-safe guard), and crash/SIGKILL (launchd relaunches
// the daemon, which finds the marker file at startup and restores).
import Darwin
import Foundation
import os
import RAMKit
import Security

let log = Logger(subsystem: HelperConstants.label, category: "helper")

final class HelperService: NSObject, RAMHelperXPC, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var policy = HelperPolicy()
    private var lastActivity = Date()
    private let backend = DirectSysctlBackend(name: "helper")

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: RAMHelperXPC.self)
        connection.exportedObject = self
        connection.resume()
        touch()
        return true
    }

    func relieve(level: Int, holdMs: Int, reply: @escaping (String?) -> Void) {
        let caller = NSXPCConnection.current()?.processIdentifier ?? -1
        let requested = PressureLevel(rawValue: level) ?? .normal
        let admission = lock.withLock { policy.admit(level: requested, holdMs: holdMs, now: Date()) }
        switch admission {
        case .failure(let refusal):
            log.notice("refused relief from pid \(caller, privacy: .public): \(refusal.description, privacy: .public)")
            reply(refusal.description)
        case .success(let ticket):
            log.notice("relief from pid \(caller, privacy: .public): \(ticket.level.word, privacy: .public) for \(ticket.holdMs, privacy: .public) ms")
            let backend = self.backend
            let reply = ReplyBox(reply)
            Task.detached { [self] in
                var message: String?
                do { try await backend.relieve(level: ticket.level, holdMs: ticket.holdMs) }
                catch { message = "\(error)"; log.error("relief failed: \(message ?? "", privacy: .public)") }
                lock.withLock { policy.finished(now: Date()) }
                touch()
                reply.call(message)
            }
        }
    }

    func restore(reply: @escaping (String?) -> Void) {
        let caller = NSXPCConnection.current()?.processIdentifier ?? -1
        let err = Trigger.write(Trigger.restoreValue)
        if err == 0 { try? FileManager.default.removeItem(atPath: HelperConstants.holdingMarker) }
        log.notice("restore from pid \(caller, privacy: .public): errno \(err, privacy: .public)")
        touch()
        reply(err == 0 ? nil : ReliefError.restoreFailed(err).description)
    }

    func status(reply: @escaping (String) -> Void) {
        let now = Date()
        let s = lock.withLock {
            HelperStatus(version: HelperConstants.version, busy: policy.isRunning,
                         lastRelief: policy.lastReliefEnd, reliefsThisHour: policy.reliefsInLastHour(now: now))
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        touch()
        reply(String(decoding: (try? enc.encode(s)) ?? Data("{}".utf8), as: UTF8.self))
    }

    private func touch() { lock.withLock { lastActivity = Date() } }

    /// launchd relaunches us on demand, so exit after a minute of quiet with nothing held.
    func exitWhenIdle(after seconds: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [self] in
            let idle = lock.withLock { !policy.isRunning && Date().timeIntervalSince(lastActivity) > seconds }
            if idle { log.info("idle, exiting"); exit(0) }
        }
        timer.resume()
        idleTimer = timer
    }
    private var idleTimer: DispatchSourceTimer?
}

/// XPC reply blocks are not Sendable; the helper calls each exactly once from the hold task.
final class ReplyBox: @unchecked Sendable {
    private let fn: (String?) -> Void
    init(_ fn: @escaping (String?) -> Void) { self.fn = fn }
    func call(_ value: String?) { fn(value) }
}

/// Requires callers signed by the same team when the helper itself has a team identifier
/// (release builds). Ad hoc builds accept any local caller; the policy still bounds what they get.
func applyCallerRequirement(_ listener: NSXPCListener) {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any], let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
    else {
        log.notice("helper is not team-signed; accepting any local caller (policy-limited)")
        return
    }
    listener.setConnectionCodeSigningRequirement("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
    log.notice("callers must be signed by team \(team, privacy: .public)")
}

// Startup: an earlier hold was interrupted (SIGKILL/crash/power loss) -> restore normal now.
if FileManager.default.fileExists(atPath: HelperConstants.holdingMarker) {
    let err = Trigger.write(Trigger.restoreValue)
    log.notice("found interrupted hold marker; restore errno \(err, privacy: .public)")
    if err == 0 { try? FileManager.default.removeItem(atPath: HelperConstants.holdingMarker) }
}

let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
applyCallerRequirement(listener)
listener.delegate = service
listener.resume()
service.exitWhenIdle(after: 60)
log.notice("ram-helper \(HelperConstants.version, privacy: .public) listening")
dispatchMain()
