// ram-helper: the root launchd daemon behind "Download More RAM".
//
// It does two privileged things: put the kernel into simulated memory pressure for a bounded time
// and take it back out (kern.memorypressure_manual_trigger, the path Apple's `memory_pressure -S`
// uses), and resume apps the kernel itself paused at the memory wall (proc_clear_vmpressure, the
// call behind loginwindow's Resume button). Four XPC calls, validated and rate-limited, logged with
// the caller's pid. Normal pressure is restored on every path: completion (a hold always runs to its
// end, even if the client goes away), every catchable terminating signal (signal-safe guard), and
// SIGKILL/crash (launchd relaunches the daemon on any unsuccessful exit; at startup it restores for
// every hold marker whose owner is gone).
import Darwin
import Foundation
import os
import RAMKit
import Security

let log = Logger(subsystem: HelperConstants.label, category: "helper")

/// Monotonic "now" for rate limits: a wall-clock step must not block downloads for an hour.
func monotonicNow() -> Date { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) }

final class HelperService: NSObject, RAMHelperXPC, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var policy = HelperPolicy()
    private var lastActivity = monotonicNow()
    private var lastRestore: Date?
    private var resumes: [Date] = []
    private let backend = DirectSysctlBackend(name: "helper")
    /// Set when the helper could not read its own signature: it then refuses every caller.
    var refuseAll = false

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard !refuseAll else {
            log.error("refusing pid \(connection.processIdentifier, privacy: .public): own code signature unreadable")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: RAMHelperXPC.self)
        connection.exportedObject = self
        connection.resume()
        touch()
        return true
    }

    func relieve(level: Int, holdMs: Int, reply: @escaping (String?) -> Void) {
        let caller = NSXPCConnection.current()?.processIdentifier ?? -1
        let requested = PressureLevel(rawValue: level) ?? .normal
        let admission = lock.withLock { policy.admit(level: requested, holdMs: holdMs, now: monotonicNow()) }
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
                lock.withLock { policy.finished(now: monotonicNow()) }
                touch()
                reply.call(message)
            }
        }
    }

    /// Rate-limited: each NORMAL write makes the kernel re-notify every registered process.
    func restore(reply: @escaping (String?) -> Void) {
        let caller = NSXPCConnection.current()?.processIdentifier ?? -1
        let now = monotonicNow()
        let tooSoon = lock.withLock { () -> Bool in
            if let last = lastRestore, now.timeIntervalSince(last) < 5 { return true }
            lastRestore = now
            return false
        }
        guard !tooSoon else { reply("wait a few seconds between restores"); return }
        let err = Trigger.write(Trigger.restoreValue)
        if err == 0 { HoldMarkers.orphaned().forEach { HoldMarkers.remove($0.path) } }
        log.notice("restore from pid \(caller, privacy: .public): errno \(err, privacy: .public)")
        touch()
        reply(err == 0 ? nil : ReliefError.restoreFailed(err).description)
    }

    /// Only processes carrying the kernel's own wall-pause flag, only the caller's own processes
    /// (unless the caller is root), at most 20 per 10 s.
    func resumePaused(pid: Int, reply: @escaping (String?) -> Void) {
        let connection = NSXPCConnection.current()
        let caller = connection?.processIdentifier ?? -1
        let callerUID = connection?.effectiveUserIdentifier ?? uid_t.max
        let target = Int32(clamping: pid)
        let now = monotonicNow()
        let limited = lock.withLock { () -> Bool in
            resumes.removeAll { now.timeIntervalSince($0) > 10 }
            if resumes.count >= 20 { return true }
            resumes.append(now)
            return false
        }
        guard !limited else { reply("too many resumes; try again in a few seconds"); return }
        if callerUID != 0 {
            guard let record = ProcessSampler.record(pid: target), record.uid == callerUID else {
                log.notice("refused resume of pid \(target, privacy: .public) for pid \(caller, privacy: .public): not the caller's process")
                reply("you can only resume your own processes")
                return
            }
        }
        switch PausedApps.resume(pid: target) {
        case .success:
            log.notice("resumed pid \(target, privacy: .public) (paused at the memory wall) for pid \(caller, privacy: .public)")
            reply(nil)
        case .failure(let why):
            log.notice("refused resume of pid \(target, privacy: .public) for pid \(caller, privacy: .public): \(why.description, privacy: .public)")
            reply(why.description)
        }
        touch()
    }

    func status(reply: @escaping (String) -> Void) {
        let now = monotonicNow()
        let s = lock.withLock {
            HelperStatus(version: HelperConstants.version, busy: policy.isRunning,
                         lastRelief: nil, reliefsThisHour: policy.reliefsInLastHour(now: now))
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        touch()
        reply(String(decoding: (try? enc.encode(s)) ?? Data("{}".utf8), as: UTF8.self))
    }

    private func touch() { lock.withLock { lastActivity = monotonicNow() } }

    /// launchd relaunches us on demand, so exit after a minute of quiet with nothing held.
    func exitWhenIdle(after seconds: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [self] in
            let idle = lock.withLock { !policy.isRunning && monotonicNow().timeIntervalSince(lastActivity) > seconds }
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

enum CallerPolicy { case teamOnly(String), anyLocalCaller, refuseAll }

/// Team-signed helper -> callers must carry the same team. Ad hoc helper (no team) -> any local
/// caller, bounded by the policy. Signature unreadable -> refuse everyone (fail closed).
func callerPolicy() -> CallerPolicy {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .refuseAll }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .refuseAll }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return .refuseAll }
    if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty { return .teamOnly(team) }
    return .anyLocalCaller
}

// Startup: holds whose owner is gone (SIGKILL, crash, power loss) -> restore normal now.
let orphans = HoldMarkers.orphaned()
if !orphans.isEmpty {
    let err = Trigger.write(Trigger.restoreValue)
    log.notice("found \(orphans.count, privacy: .public) interrupted hold marker(s); restore errno \(err, privacy: .public)")
    if err == 0 { orphans.forEach { HoldMarkers.remove($0.path) } }
}

let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
switch callerPolicy() {
case .teamOnly(let team):
    listener.setConnectionCodeSigningRequirement("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
    log.notice("callers must be signed by team \(team, privacy: .public)")
case .anyLocalCaller:
    log.notice("helper is not team-signed; accepting any local caller (policy-limited)")
case .refuseAll:
    service.refuseAll = true
    log.error("could not read the helper's own code signature; refusing all callers")
}
listener.delegate = service
listener.resume()
service.exitWhenIdle(after: 60)
log.notice("ram-helper \(HelperConstants.version, privacy: .public) listening")
dispatchMain()
