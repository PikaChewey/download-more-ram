import CDarwinMem
import Darwin
import Foundation
import Testing
@testable import RAMKit

/// Counts calls from @Sendable closures.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}

/// The restore guard is process-wide state, so its review-2 tests (R-1, R-2) join the serialized
/// review-1 suite instead of running beside it.
extension ReviewFixTests {
    static func guardHandler(_ sig: Int32) -> Int {
        var sa = sigaction()
        sigaction(sig, nil, &sa)
        return unsafeBitCast(sa.__sigaction_u.__sa_handler, to: Int.self)
    }

    // R-2: Ctrl-Z (and background tty stops) restore normal pressure too; disarm puts them back.
    @Test func jobControlStopsAreGuarded() {
        let stops = [SIGTSTP, SIGTTIN, SIGTTOU]
        let before = stops.map(Self.guardHandler)
        #expect(dm_restore_guard_arm("kern.ostype", 0, nil) == 0)
        defer { dm_restore_guard_disarm() }
        for (sig, old) in zip(stops, before) {
            if old == 1 { #expect(Self.guardHandler(sig) == 1) } else { #expect(Self.guardHandler(sig) > 1, "signal \(sig) not guarded") }
        }
        dm_restore_guard_disarm()
        #expect(stops.map(Self.guardHandler) == before)
        #expect(dm_restore_guard_is_armed() == 0)
    }

    // R-1: while a hold is armed in this process a second one is refused before any marker is touched.
    @Test func secondHoldNeverTouchesTheFirstMarker() async throws {
        #expect(dm_restore_guard_arm("kern.ostype", 0, nil) == 0)
        defer { dm_restore_guard_disarm() }
        #expect(dm_restore_guard_is_armed() == 1)
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("ram-r1-\(UUID().uuidString)").path
        await #expect(throws: (any Error).self) {
            try await DirectSysctlBackend(markerPrefix: prefix).relieve(level: .critical, holdMs: 1000)
        }
        #expect(HoldMarkers.all(prefix: prefix).isEmpty)
    }

}

/// One test per finding of review 2 (docs/reviews/code-safety.md, R-*) that can run without root,
/// plus the benchmark's redo rules.
@Suite("Review 2 fixes")
struct Review2FixTests {
    // The helper's log names every caller; a refused request sent no signal and does not count.
    @Test func helperLogFindsOtherCallersOnly() {
        let text = """
        2026-10-20 13:26:06.581 Df ca.bryanyao.DownloadMoreRAM.helper[96659:beae88] [ca.bryanyao.DownloadMoreRAM.helper:helper] relief from pid 96656: critical for 3000 ms
        2026-10-20 13:26:34.789 Df ca.bryanyao.DownloadMoreRAM.helper[96659:beb6aa] [ca.bryanyao.DownloadMoreRAM.helper:helper] refused relief from pid 77777: wait 1s between downloads
        2026-10-20 13:26:42.356 Df ca.bryanyao.DownloadMoreRAM.helper[96659:beb6aa] [ca.bryanyao.DownloadMoreRAM.helper:helper] relief from pid 96947: critical for 6000 ms
        2026-10-20 13:27:00.000 Df ca.bryanyao.DownloadMoreRAM.helper[96659:beb6aa] [ca.bryanyao.DownloadMoreRAM.helper:helper] relief from pid 95399: critical for 10000 ms
        2026-10-20 13:28:00.000 Df ca.bryanyao.DownloadMoreRAM.helper[96659:beb6aa] [ca.bryanyao.DownloadMoreRAM.helper:helper] relief from pid 96656: critical for 3000 ms
        """
        #expect(HelperLog.callers(text, excluding: 95399) == [96656, 96947])
        #expect(HelperLog.callers("", excluding: 1).isEmpty)
        #expect(BenchRunner.isTransient("wait 1s between downloads"))
        #expect(BenchRunner.isTransient("a download is already running"))
        #expect(!BenchRunner.isTransient("hold must be 1-30 seconds"))
    }

    static func flatMachine() -> FakeSampling {
        FakeSampling(script: { _, _ in [rec(400, name: "Discord", path: "/Applications/Discord.app/Contents/MacOS/Discord", mb: 700, start: 2)] },
                     start: 100_000)
    }

    // A foreign signal during an arm (cooldown included) throws that arm away and runs it again.
    @Test func armThatSawSomeoneElsesSignalIsRedone() async throws {
        let calls = CallCounter()
        let runner = BenchRunner(backend: NullBackend(), holdMs: 1000, settleMs: 0, cooldownS: 0,
                                 foreignSignals: { _, _ in calls.next() < 2 ? [96656] : [] }, sampling: Self.flatMachine())
        let r = try await runner.real(trials: 1, log: { _ in })
        #expect(r.arms.count == 2)
        #expect(Set(r.arms.map(\.arm)) == ["relief", "control"])
        #expect(r.redone?.count == 2)
        #expect(r.redone?.allSatisfy { $0.contains("pid 96656 sent the signal") } == true)
    }

    @Test func persistentForeignSignalsStopTheBench() async {
        let runner = BenchRunner(backend: NullBackend(), holdMs: 1000, settleMs: 0, cooldownS: 0,
                                 foreignSignals: { _, _ in [96656] }, sampling: Self.flatMachine())
        await #expect(throws: BenchError.self) { try await runner.real(trials: 1, log: { _ in }) }
    }

    // R-5: the preview lists exactly what the quitting levers would act on.
    @Test func previewListsWhatQuittingLeversWouldQuit() {
        let now = Date()
        let head = rec(77, name: "claude", mb: 300, start: 7)
        let archived = AgentSession(id: 77, tool: .claudeCode, host: "Claude", cwd: nil, label: "x", footprint: 300 << 20,
                                    members: [head, rec(78, ppid: 77, name: "node", mb: 50, resp: 77, start: 8)], topChildren: "",
                                    ageS: 99_999, idleS: 7200, cpuFraction: 0.001, lastActive: now.addingTimeInterval(-7200),
                                    title: "Old refactor", archived: true)
        let active = AgentSession(id: 90, tool: .claudeCode, host: "Claude", cwd: nil, label: "y", footprint: 1, members: [rec(90, name: "claude", mb: 1)],
                                  topChildren: "", ageS: 99_999, idleS: 0, cpuFraction: 0.3, lastActive: now, title: "Live", archived: false)
        let leftover = Leftover(record: rec(4242, name: "python3", mb: 100, start: 4), reason: "orphaned dev server", idleS: 900)
        let t = LeverPreview.targets([.leftovers, .archivedSessions], sessions: [archived, active], leftovers: [leftover])
        #expect(t.map(\.record.pid) == [4242, 77])
        #expect(t[1].why == "archived session \"Old refactor\"")
        #expect(LeverPreview.targets([.firefoxGPU, .resumePaused], sessions: [archived], leftovers: [leftover]).isEmpty)
    }

    // R-6: `all` does not resume paused apps while the wall is near; naming `resume` does.
    @Test func resumeWaitsForTheWallUnlessNamed() async throws {
        var paused = rec(500, name: "ChatGPT", path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", mb: 900, start: 5)
        paused.bsdFlags = 0x1000
        let sampling = FakeSampling(script: { _, _ in [paused] }, start: 100_000)
        let near = WallStatus(percent: 92, etaSeconds: nil, limitingFactor: .swap, reason: "swap", imminent: false)
        let runner = LeverRunner(sampling: sampling, actions: FakeLeverActions())
        let skipped = try await runner.run([.resumePaused], sessions: [], leftovers: [], wall: near)
        #expect(skipped.first?.targets.isEmpty == true)
        #expect(skipped.first?.detail?.contains("wall is still near") == true)
        let forced = try await runner.run([.resumePaused], sessions: [], leftovers: [], wall: near, forceResume: true)
        #expect(forced.first?.targets == ["ChatGPT"])
        let far = WallStatus(percent: 30, etaSeconds: nil, limitingFactor: .swap, reason: "swap", imminent: false)
        #expect(try await runner.run([.resumePaused], sessions: [], leftovers: [], wall: far).first?.targets == ["ChatGPT"])
    }

    // R-8: ownership follows the person behind sudo, not root.
    @Test func ownershipIsThePersonNotRoot() {
        #expect(RealUser.uid == getuid())   // not running under sudo here
        let mine = rec(1234, uid: getuid(), name: "node", path: "/usr/local/bin/node", mb: 10)
        #expect(SafeKill.check(mine, current: mine) == .ok)
        let theirs = rec(1235, uid: getuid() + 1, name: "node", path: "/usr/local/bin/node", mb: 10)
        #expect(SafeKill.check(theirs, current: theirs) == .refused(.otherUser))
    }
}
