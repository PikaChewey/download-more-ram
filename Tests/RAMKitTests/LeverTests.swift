import Darwin
import Foundation
import Testing
@testable import RAMKit

/// Records what the levers asked for and flips the fake machine's state accordingly.
final class FakeLeverActions: LeverActions, @unchecked Sendable {
    private let lock = NSLock()
    private var _gpuRestarted = false
    private var _terminated: Set<Int32> = []
    var gpuRestarted: Bool { lock.withLock { _gpuRestarted } }
    var terminated: Set<Int32> { lock.withLock { _terminated } }
    func terminate(_ r: ProcessRecord) -> KillResult { lock.withLock { _ = _terminated.insert(r.pid) }; return .ok }
    func restartFirefoxGPU(_ r: ProcessRecord) -> FirefoxLevers.GPURestart { lock.withLock { _gpuRestarted = true }; return .restarted }
    func resume(pid: Int32) async -> Bool { true }
}

private let ff = "/Applications/Firefox.app/Contents/MacOS/firefox"
private let gpuPath = "/Applications/Firefox.app/Contents/MacOS/gpu-helper.app/Contents/MacOS/Firefox GPU Helper"
private let discord = "/Applications/Discord.app/Contents/MacOS/Discord"

/// Discord gives 300 MB back on the signal; the GPU process drops 6 GB -> 1.5 GB once restarted;
/// the orphaned http.server is gone once terminated.
private func machine(_ actions: FakeLeverActions) -> (Int, Double) -> [ProcessRecord] {
    { _, t in
        var r = [rec(100, name: "firefox", path: ff, mb: 900, start: 1),
                 rec(400, name: "Discord", path: discord, mb: t > 2.5 ? 400 : 700, start: 2)]
        r.append(actions.gpuRestarted
                 ? rec(110, ppid: 100, name: "Firefox GPU Helper", path: gpuPath, mb: 1536, resp: 100, start: 9)
                 : rec(103, ppid: 100, name: "Firefox GPU Helper", path: gpuPath, mb: 6144, resp: 100, start: 3))
        if !actions.terminated.contains(4242) {
            r.append(rec(4242, ppid: 1, uid: getuid(), name: "python3", path: "/usr/bin/python3", mb: 100, resp: 999, cpuNs: 1_000, start: 4))
        }
        return r
    }
}

@Suite("Multi-lever downloads")
struct LeverTests {
    @Test func parsesLeverLists() {
        guard case .success(let a) = LeverKind.parse("firefox-gpu,leftovers") else { Issue.record("parse"); return }
        #expect(a == [.firefoxGPU, .leftovers])
        guard case .success(let all) = LeverKind.parse("all") else { Issue.record("all"); return }
        #expect(all == [.firefoxGPU, .leftovers, .archivedSessions, .resumePaused])
        guard case .failure = LeverKind.parse("nonsense") else { Issue.record("nonsense accepted"); return }
        guard case .failure = LeverKind.parse("signal") else { Issue.record("signal is implicit, not a lever"); return }
        #expect(LeverKind.firefoxGPU.needsConsent && LeverKind.leftovers.needsConsent && !LeverKind.resumePaused.needsConsent)
    }

    @Test func everyByteIsAttributedToAMeasuredLever() async throws {
        let actions = FakeLeverActions()
        let engine = ReliefEngine(backend: FakeBackend(fail: false), holdMs: 3000, settleMs: 2000,
                                  sampling: FakeSampling(script: machine(actions), start: 100_000), levers: [.firefoxGPU, .leftovers],
                                  actions: actions, info: FakeInfo())
        let r = try await engine.run()
        let levers = try #require(r.levers)
        #expect(levers.map(\.kind) == [.kernelSignal, .firefoxGPU, .leftovers])
        #expect(levers[0].bytes == Int64(300) << 20)            // Discord, on the signal
        #expect(levers[1].bytes == Int64(6144 - 1536) << 20)    // Firefox group, GPU restart only
        #expect(levers[2].bytes == Int64(100) << 20)            // the orphaned http.server
        #expect(r.headlineBytes == r.leverSum)
        #expect(r.headlineBytes == (Int64(300) + 4608 + 100) << 20)
        #expect(actions.gpuRestarted)
        #expect(actions.terminated == [4242])
        #expect(r.offers == nil)                                // everything available ran
    }

    @Test func withoutConsentLeversAreOnlyOffered() async throws {
        let actions = FakeLeverActions()
        let engine = ReliefEngine(backend: FakeBackend(fail: false), holdMs: 3000, settleMs: 2000,
                                  sampling: FakeSampling(script: machine(actions), start: 100_000), actions: actions, info: FakeInfo())
        let r = try await engine.run()
        #expect(!actions.gpuRestarted)
        #expect(actions.terminated.isEmpty)
        #expect(r.levers?.count == 1)
        #expect(r.headlineBytes == Int64(300) << 20)
        let offers = try #require(r.offers)
        #expect(offers.map(\.kind).contains(.firefoxGPU))
        #expect(offers.first { $0.kind == .firefoxGPU }?.estimateBytes == UInt64(6144) << 20)
        #expect(offers.map(\.kind).contains(.leftovers))
        #expect(r.markdown().contains("| Restart Firefox's GPU process |") == false)
        #expect(r.markdown().contains("| macOS memory-pressure signal | +300.0 MB |"))
    }

    @Test func smallGPUProcessIsSkippedNotRestarted() async throws {
        let actions = FakeLeverActions()
        let small: (Int, Double) -> [ProcessRecord] = { _, _ in
            [rec(100, name: "firefox", path: ff, mb: 900, start: 1),
             rec(103, ppid: 100, name: "Firefox GPU Helper", path: gpuPath, mb: 400, resp: 100, start: 3)]
        }
        let r = try await LeverRunner(sampling: FakeSampling(script: small), actions: actions, settleMs: 100)
            .run([.firefoxGPU], sessions: [], leftovers: [], wall: nil)
        #expect(r.first?.bytes == nil)
        #expect(r.first?.detail?.contains("under 1 GB") == true)
        #expect(!actions.gpuRestarted)
    }
}
