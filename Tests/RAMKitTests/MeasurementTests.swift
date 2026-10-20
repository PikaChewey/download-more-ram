import Foundation
import Testing
@testable import RAMKit

private let ffPath = "/Applications/Firefox.app/Contents/MacOS/firefox"
private let discordPath = "/Applications/Discord.app/Contents/MacOS/Discord"
private let renderPath = "/Users/bryan/Library/Application Support/Claude/claude-code/2.1.299/x/claude.app/Contents/MacOS/claude"

private func snap(_ t: Double, _ records: [ProcessRecord]) -> ProcessSnapshot {
    ProcessSnapshot(timestamp: Date(timeIntervalSince1970: t), records: records)
}

@Suite("Honest measurement")
struct MeasurementTests {
    // Firefox: parent + two content processes. Discord: one process. A render session: busy.
    func firefox(content2: UInt64? = 500, parent: UInt64 = 900) -> [ProcessRecord] {
        var r = [rec(100, name: "firefox", path: ffPath, mb: parent),
                 rec(101, ppid: 100, name: "plugin-container", mb: 2200, resp: 100)]
        if let content2 { r.append(rec(102, ppid: 100, name: "plugin-container", mb: content2, resp: 100)) }
        return r
    }

    @Test func busyGroupIsDetectedFromDrift() {
        let base = [
            snap(0, [rec(300, name: "claude", path: renderPath, mb: 1000)] + firefox()),
            snap(1, [rec(300, name: "claude", path: renderPath, mb: 1040)] + firefox()),
            snap(2, [rec(300, name: "claude", path: renderPath, mb: 1080)] + firefox()),
        ]
        let busy = Measurement.busyGroups(baseline: base)
        #expect(busy == [300])
    }

    @Test func busyGroupIsDetectedFromCPU() {
        let base = [
            snap(0, [rec(300, name: "claude", path: renderPath, mb: 1000, cpuNs: 0)]),
            snap(2, [rec(300, name: "claude", path: renderPath, mb: 1000, cpuNs: 1_500_000_000)]),
        ]
        #expect(Measurement.busyGroups(baseline: base) == [300])
    }

    @Test func exitedMemberInsideSurvivingAppCounts() {
        let before = snap(2, firefox(content2: 500))
        let after = snap(14, firefox(content2: nil))   // Firefox unloaded a tab: process 102 exited
        let r = Measurement.deltas(before: before, after: after, busy: [])
        let ff = r.apps.first { $0.name == "Firefox" }
        #expect(ff?.delta == Int64(500) << 20)
        #expect(ff?.exitedMembers == 1)
        #expect(r.headline == Int64(500) << 20)
    }

    @Test func newAndGoneAppsAreListedNotCounted() {
        let before = snap(2, firefox() + [rec(400, name: "Discord", path: discordPath, mb: 700)])
        let after = snap(14, firefox() + [rec(500, name: "Preview", path: "/System/Applications/Preview.app/Contents/MacOS/Preview", mb: 300)])
        let r = Measurement.deltas(before: before, after: after, busy: [])
        #expect(r.headline == 0)
        #expect(r.gone == ["Discord"])
        #expect(r.new == ["Preview"])
    }

    @Test func growthSubtractsAndGrossCountsOnlyGains() {
        let before = snap(2, firefox(parent: 900) + [rec(400, name: "Discord", path: discordPath, mb: 700)])
        let after = snap(14, firefox(parent: 1000) + [rec(400, name: "Discord", path: discordPath, mb: 400)])
        let r = Measurement.deltas(before: before, after: after, busy: [])
        #expect(r.headline == (Int64(300) << 20) - (Int64(100) << 20))
        #expect(r.grossFreed == Int64(300) << 20)
        #expect(r.apps.map(\.name) == ["Discord", "Firefox"])   // sorted by delta, largest first
    }

    @Test func busyAppsAreExcludedFromHeadline() {
        let before = snap(2, firefox() + [rec(300, name: "claude", path: renderPath, mb: 9000)])
        let after = snap(14, firefox(content2: nil) + [rec(300, name: "claude", path: renderPath, mb: 2000)])
        let r = Measurement.deltas(before: before, after: after, busy: [300])
        #expect(r.headline == Int64(500) << 20)
        #expect(r.excluded.map(\.id) == [300])
        #expect(r.excluded.first?.delta == Int64(7000) << 20)
    }

    @Test func pidReuseOfResponsibleHeadIsTreatedAsNewApp() {
        let before = snap(2, [rec(400, name: "Discord", path: discordPath, mb: 700, start: 1)])
        let after = snap(14, [rec(400, name: "Discord", path: discordPath, mb: 100, start: 999)])
        let r = Measurement.deltas(before: before, after: after, busy: [])
        #expect(r.headline == 0)
        #expect(r.gone == ["Discord"])
        #expect(r.new == ["Discord"])
    }
}
