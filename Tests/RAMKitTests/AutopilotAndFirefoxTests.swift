import Foundation
import Testing
@testable import RAMKit

private func wall(_ pct: Double, eta: Double? = nil, imminent: Bool = false) -> WallStatus {
    WallStatus(percent: pct, etaSeconds: eta, limitingFactor: .swap, reason: "", imminent: imminent)
}

@Suite("Autopilot policy")
struct AutopilotTests {
    let t0 = Date(timeIntervalSince1970: 10_000)

    @Test func firesOnWallETAImminentAndSustainedCritical() {
        var p = AutopilotPolicy()
        #expect(p.observe(status: wall(84.9), pressure: .warn, now: t0) == .none)
        #expect(p.observe(status: wall(85), pressure: .warn, now: t0) == .download)
        var q = AutopilotPolicy()
        #expect(q.observe(status: wall(40, eta: 299), pressure: .normal, now: t0) == .download)
        var r = AutopilotPolicy()
        #expect(r.observe(status: wall(40, imminent: true), pressure: .normal, now: t0) == .download)
        var c = AutopilotPolicy()
        #expect(c.observe(status: wall(40), pressure: .critical, now: t0) == .none)
        #expect(c.observe(status: wall(40), pressure: .critical, now: t0 + 21) == .download)
    }

    @Test func rateLimitsAndEscalates() {
        var p = AutopilotPolicy()
        #expect(p.observe(status: wall(90), pressure: .warn, now: t0) == .download)
        p.recordDownload(at: t0)
        #expect(p.observe(status: wall(90), pressure: .warn, now: t0 + 119) == .none)
        #expect(p.observe(status: wall(90), pressure: .warn, now: t0 + 121) == .download)
        p.recordDownload(at: t0 + 121)
        #expect(p.observe(status: wall(90), pressure: .warn, now: t0 + 250) == .notifyTopConsumers)
        #expect(p.observe(status: wall(90), pressure: .warn, now: t0 + 400) == .none)   // notified recently
    }
}

@Suite("Firefox levers")
struct FirefoxLeverTests {
    func makeSupport() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ram-ff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Profiles/ag8jngqu.default-release"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Profiles/fm0z0227.default"), withIntermediateDirectories: true)
        // The target Mac's real profiles.ini layout.
        try """
            [Profile1]
            Name=default
            IsRelative=1
            Path=Profiles/fm0z0227.default
            Default=1

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/ag8jngqu.default-release

            [General]
            StartWithLastProfile=1

            [Install2656FF1E876E9973]
            Default=Profiles/ag8jngqu.default-release
            Locked=1
            """.write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func picksTheInstallDefaultProfile() throws {
        let root = try makeSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FirefoxLevers.defaultProfile(supportDir: root)?.lastPathComponent == "ag8jngqu.default-release")
    }

    @Test func enableReadsBackAndDisableRestoresTheFile() throws {
        let root = try makeSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Profiles/ag8jngqu.default-release")
        let original = "user_pref(\"browser.startup.page\", 3);\n"
        try original.write(to: profile.appendingPathComponent("user.js"), atomically: true, encoding: .utf8)
        try "user_pref(\"browser.lowMemoryResponseMask\", 0);\n".write(to: profile.appendingPathComponent("prefs.js"), atomically: true, encoding: .utf8)
        #expect(FirefoxLevers.lowMemoryResponseMask(profile: profile) == 0)
        #expect(!FirefoxLevers.isUnloaderOn(profile: profile))
        try FirefoxLevers.enableUnloader(profile: profile)
        try FirefoxLevers.enableUnloader(profile: profile)   // idempotent
        #expect(FirefoxLevers.lowMemoryResponseMask(profile: profile) == 3)
        let text = try String(contentsOf: profile.appendingPathComponent("user.js"), encoding: .utf8)
        #expect(text.components(separatedBy: "browser.lowMemoryResponseMask").count == 2)
        try FirefoxLevers.disableUnloader(profile: profile)
        #expect(try String(contentsOf: profile.appendingPathComponent("user.js"), encoding: .utf8) == original)
    }

    @Test func findsTheGPUProcess() {
        let gpu = rec(57586, name: "Firefox GPU Helper",
                      path: "/Applications/Firefox.app/Contents/MacOS/gpu-helper.app/Contents/MacOS/Firefox GPU Helper", mb: 5334, resp: 57583)
        let snap = ProcessSnapshot(timestamp: Date(), records: [rec(57583, name: "firefox", mb: 900), gpu])
        #expect(FirefoxLevers.gpuProcess(in: snap)?.pid == 57586)
    }

    @Test func refusesToRestartAYoungGPUProcess() {
        let now = Date(timeIntervalSince1970: 1_000)
        let young = rec(9, name: "Firefox GPU Helper", mb: 100, start: UInt64(990 * 1_000_000))
        #expect(FirefoxLevers.restartGPU(young, now: now) == .tooYoung(10))
    }
}

@Suite("Spinning while paused")
struct SpinningWhilePausedTests {
    @Test func helpersBurningCPUBehindAPausedAppAreReported() throws {
        let chatgpt = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
        func snap(_ t: Double, cpu: UInt64) -> ProcessSnapshot {
            var main = rec(57287, name: "ChatGPT", path: chatgpt, mb: 400, start: 1)
            main.bsdFlags = 0x1405410                       // paused at the wall
            let service = rec(57308, name: "Codex (Service)", mb: 250, resp: 57287, cpuNs: cpu, start: 2)
            let renderer = rec(57335, name: "Codex (Renderer)", mb: 990, resp: 57287, cpuNs: cpu, start: 3)
            return ProcessSnapshot(timestamp: Date(timeIntervalSince1970: t), records: [main, service, renderer])
        }
        var history = CPUHistory()
        history.add(snap(0, cpu: 0))
        history.add(snap(2, cpu: 1_900_000_000))           // each helper ~95% of a core
        let d = Diagnosis.make(system: fakeSystem(), wall: nil, snapshot: snap(2, cpu: 1_900_000_000), sessions: [],
                               leftovers: [], reliefAvailable: false, firefoxProfile: nil, cpu: history)
        let s = try #require(d.spinningWhilePaused.first)
        #expect(s.app == "ChatGPT")
        #expect(abs(s.cores - 1.9) < 0.01)
        #expect(d.fixes.first?.title.contains("burning 1.9 cores") == true)
    }
}
