import Foundation
import Testing
@testable import RAMKit

@Suite("Kernel trigger encoding")
struct TriggerTests {
    // Values from xnu kern_memorystatus.h / sys/event.h and Apple's memory_pressure.c (-S mode).
    @Test func matchesAppleMemoryPressureTool() {
        #expect(Trigger.encode(.lowMemoryPurgeableAll, .critical) == 393_220)   // (6 << 16) | 4
        #expect(Trigger.encode(.lowMemoryPurgeableAll, .warn) == 393_218)       // (6 << 16) | 2
        #expect(Trigger.encode(.lowMemoryPurgeableAll, .normal) == 393_217)     // reset: (6 << 16) | 1
        #expect(Trigger.encode(.lowMemoryOne, .critical) == 65_540)             // the example in memory_pressure.c
        #expect(Trigger.sysctlName == "kern.memorypressure_manual_trigger")
        #expect(TriggerRequest.lowMemoryPurgeableAll.rawValue == 6)
    }
}

@Suite("Helper admission policy")
struct HelperPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func validatesArguments() {
        var p = HelperPolicy()
        #expect(p.admit(level: .normal, holdMs: 10_000, now: t0) == .failure(.badLevel))
        #expect(p.admit(level: .critical, holdMs: 999, now: t0) == .failure(.badHold))
        #expect(p.admit(level: .critical, holdMs: 30_001, now: t0) == .failure(.badHold))
        #expect(p.admit(level: .warn, holdMs: 1000, now: t0) == .success(HelperPolicy.Ticket(level: .warn, holdMs: 1000)))
    }

    @Test func oneAtATimeAndCooldown() {
        var p = HelperPolicy()
        #expect(p.admit(level: .critical, holdMs: 10_000, now: t0) == .success(.init(level: .critical, holdMs: 10_000)))
        #expect(p.admit(level: .critical, holdMs: 10_000, now: t0 + 1) == .failure(.busy))
        p.finished(now: t0 + 10)
        #expect(p.admit(level: .critical, holdMs: 10_000, now: t0 + 29) == .failure(.tooSoon(retryAfter: 1)))
        #expect(p.admit(level: .critical, holdMs: 10_000, now: t0 + 30) == .success(.init(level: .critical, holdMs: 10_000)))
    }

    @Test func hourlyCap() {
        var p = HelperPolicy()
        var now = t0
        for _ in 0..<30 {
            #expect(p.admit(level: .critical, holdMs: 1000, now: now) == .success(.init(level: .critical, holdMs: 1000)))
            p.finished(now: now + 1)
            now += 21
        }
        #expect(p.admit(level: .critical, holdMs: 1000, now: now) == .failure(.hourlyCap))
        #expect(p.admit(level: .critical, holdMs: 1000, now: t0 + 3601) == .success(.init(level: .critical, holdMs: 1000)))
    }
}
