import CDarwinMem
import Darwin
import Foundation
import Testing
@testable import RAMKit

/// One test per finding in docs/reviews/code-safety.md that can be exercised without root.
@Suite("Review 1 fixes", .serialized)
struct ReviewFixTests {
    // #1: a bad hold is rejected before anything touches the kernel.
    @Test func holdIsValidatedBeforeTheWrite() {
        #expect(DirectSysctlBackend.validate(level: .critical, holdMs: -5000) != nil)
        #expect(DirectSysctlBackend.validate(level: .critical, holdMs: 999) != nil)
        #expect(DirectSysctlBackend.validate(level: .critical, holdMs: 30_001) != nil)
        #expect(DirectSysctlBackend.validate(level: .critical, holdMs: Int.max) != nil)
        #expect(DirectSysctlBackend.validate(level: .normal, holdMs: 10_000) != nil)
        #expect(DirectSysctlBackend.validate(level: .critical, holdMs: 10_000) == nil)
        guard case .failure = InputLimits.holdSeconds("-5") else { Issue.record("-5 accepted"); return }
        guard case .failure = InputLimits.holdSeconds("9223372036854775") else { Issue.record("huge accepted"); return }
        guard case .failure = InputLimits.holdSeconds("abc") else { Issue.record("abc accepted"); return }
        guard case .success(10) = InputLimits.holdSeconds(nil) else { Issue.record("default"); return }
        guard case .success(30) = InputLimits.holdSeconds("30") else { Issue.record("30 rejected"); return }
    }

    // #2/#5: the guard covers every terminating signal, refuses a second hold, keeps SIGPIPE ignored.
    @Test func guardCoversSignalsAndRefusesSecondHold() {
        let previousPipe = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previousPipe) }
        // Arm against a harmless sysctl: nothing is written unless a signal arrives.
        #expect(dm_restore_guard_arm("kern.ostype", 0, nil) == 0)
        defer { dm_restore_guard_disarm() }
        #expect(dm_restore_guard_is_armed() == 1)
        #expect(dm_restore_guard_arm("kern.ostype", 0, nil) == EBUSY)
        // Raw handler values: SIG_DFL is 0, SIG_IGN is 1, anything else is our guard.
        func handler(_ sig: Int32) -> Int {
            var sa = sigaction()
            sigaction(sig, nil, &sa)
            return unsafeBitCast(sa.__sigaction_u.__sa_handler, to: Int.self)
        }
        for sig in [SIGQUIT, SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGTERM, SIGINT, SIGHUP, SIGUSR1] {
            #expect(handler(sig) > 1, "signal \(sig) not guarded")
        }
        #expect(handler(SIGPIPE) == 1)          // ignored stays ignored
        dm_restore_guard_disarm()
        #expect(dm_restore_guard_is_armed() == 0)
        #expect(handler(SIGQUIT) == 0)          // back to the default
    }

    // #4/#7: per-process markers; a live hold is never "interrupted"; a dead owner's marker is.
    @Test func holdMarkersTellLiveFromOrphaned() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("ram-hold-\(UUID().uuidString)").path
        defer { HoldMarkers.all(prefix: prefix).forEach { HoldMarkers.remove($0.path) } }
        let mine = try #require(HoldMarkers.write(prefix: prefix))
        #expect(mine.hasSuffix(".\(getpid())"))
        var dead: Int32 = 90_000
        while kill(dead, 0) == 0 || errno == EPERM { dead += 1 }
        try "\(dead) 12345\n".write(toFile: "\(prefix).\(dead)", atomically: true, encoding: .utf8)
        // A live pid whose start time does not match = the pid was reused: orphaned.
        try "\(getppid()) 1\n".write(toFile: "\(prefix).\(getppid())", atomically: true, encoding: .utf8)
        let all = HoldMarkers.all(prefix: prefix)
        #expect(all.count == 3)
        let orphaned = Set(HoldMarkers.orphaned(prefix: prefix).map(\.pid))
        #expect(!orphaned.contains(getpid()))
        #expect(orphaned.contains(dead))
        #expect(orphaned.contains(getppid()))
        // The v1.0 single-file marker is still recognised.
        try "\(dead)\n".write(toFile: prefix, atomically: true, encoding: .utf8)
        #expect(HoldMarkers.orphaned(prefix: prefix).contains { $0.path == prefix })
    }

    // #9: under sudo, user-file writes run as the user; otherwise a plain call.
    @Test(.enabled(if: geteuid() != 0)) func asUserIsAPassThroughWithoutSudo() throws {
        #expect(try RealUser.asUser { 42 } == 42)
    }

    // #15: the next victim includes kill/throttle registrants, skips acted-on ones, and reports the action.
    @Test func nextVictimFollowsTheKernelsRules() {
        var claude = rec(57329, name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude", mb: 900)
        claude.residentBytes = 100 << 20; claude.bsdFlags = 0x400                 // suspend registrant, 800 MB compressed
        var worker = rec(800, name: "mdworker_shared", mb: 2000)
        worker.residentBytes = 100 << 20; worker.bsdFlags = 0x600                 // kill registrant, 1.9 GB compressed
        var throttled = rec(801, name: "acted", mb: 5000)
        throttled.residentBytes = 0; throttled.bsdFlags = 0x200 | 0x800          // already throttled: skipped
        var sys = fakeSystem()
        sys.compressedUncompressedBytes = 30 << 30
        let i = WallInsights.from(ProcessSnapshot(timestamp: Date(), records: [claude, worker, throttled]), system: sys)
        #expect(i.nextToPause?.pid == 800)
        #expect(i.nextAction == .kill)
        // One unregistered process holding more than half of all compressed memory is killed outright.
        var hog = rec(900, name: "node", mb: 20_000)
        hog.residentBytes = 0
        let j = WallInsights.from(ProcessSnapshot(timestamp: Date(), records: [claude, hog]), system: sys)
        #expect(j.nextToPause?.pid == 900)
        #expect(j.nextAction == .kill)
    }

    // #16: same-user system binaries are protected.
    @Test func systemBinariesAreProtected() {
        let r = rec(1234, uid: getuid(), name: "mds_stores", path: "/System/Library/Frameworks/CoreServices.framework/mds_stores", mb: 50)
        #expect(SafeKill.check(r, current: r) == .refused(.protected("mds_stores")))
    }

    // #17: a server that is busy right now is not an idle leftover, whatever its lifetime average.
    @Test func recentlyActiveOrphanIsNotIdle() {
        let python = "/usr/bin/python3"
        func snap(_ t: Double, cpu: UInt64) -> ProcessSnapshot {
            ProcessSnapshot(timestamp: Date(timeIntervalSince1970: t),
                            records: [rec(4242, ppid: 1, uid: getuid(), name: "python3", path: python, mb: 40, resp: 999, cpuNs: cpu, start: 1)])
        }
        var h = CPUHistory()
        h.add(snap(100_000, cpu: 1_000_000))
        h.add(snap(100_002, cpu: 400_000_000))          // 20% of a core in the last 2 s
        let left = AgentClassifier.leftovers(snap(100_002, cpu: 400_000_000), cpuHistory: h, info: FakeInfo(),
                                             now: Date(timeIntervalSince1970: 100_002))
        #expect(left.isEmpty)
    }

    // #18: archived alone is not enough to quit a session.
    @Test func archivedSessionsMustAlsoBeQuiet() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func session(archived: Bool, cpu: Double?, lastActiveAgo: Double?) -> AgentSession {
            AgentSession(id: 1, tool: .claudeCode, host: nil, cwd: nil, label: "x", footprint: 1, members: [], topChildren: "",
                         ageS: 9999, idleS: 0, cpuFraction: cpu, lastActive: lastActiveAgo.map { now.addingTimeInterval(-$0) },
                         title: nil, archived: archived)
        }
        #expect(AgentClassifier.safeToQuitArchived(session(archived: true, cpu: 0.004, lastActiveAgo: 7200), now: now))
        #expect(!AgentClassifier.safeToQuitArchived(session(archived: true, cpu: 0.05, lastActiveAgo: 7200), now: now))
        #expect(!AgentClassifier.safeToQuitArchived(session(archived: true, cpu: 0.0, lastActiveAgo: 60), now: now))
        #expect(!AgentClassifier.safeToQuitArchived(session(archived: false, cpu: 0.0, lastActiveAgo: 7200), now: now))
    }

    // #19: swap under the hiwater mark on a quiet system (no swap-outs) is not "imminent".
    @Test func quietSwapIsNotImminent() throws {
        var m = WallModel()
        for i in 0...15 {
            m.add(wallSample(t: Double(i) * 2, swapUsed: 11 * (1 << 30) - (100 << 20), swapouts: 5_000))   // flat
        }
        #expect(try #require(m.status()).imminent == false)
    }

    // #20: bench inputs are bounded and fixtures are sized from headroom.
    @Test func benchInputsAreBounded() {
        guard case .failure = InputLimits.int("-1", default: 3, range: 1...50, name: "--trials") else { Issue.record("negative trials"); return }
        guard case .failure = InputLimits.int("10", default: 60, range: 20...600, name: "--cooldown") else { Issue.record("short cooldown"); return }
        #expect(InputLimits.cappedMB(1024, headroom: 1 << 30) == 256)       // a quarter of 1 GiB of headroom
        #expect(InputLimits.cappedMB(1024, headroom: 64 << 30) == 1024)
        #expect(InputLimits.cappedMB(1024, headroom: 0) == 16)
    }

    // #23: non-finite durations never trap.
    @Test func nonFiniteDurations() {
        #expect(Format.duration(.nan) == "—")
        #expect(Format.duration(.infinity) == "—")
        #expect(Format.duration(-5) == "0s")
    }
}
