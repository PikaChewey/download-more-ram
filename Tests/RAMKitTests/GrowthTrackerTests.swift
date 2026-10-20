import Foundation
import Testing
@testable import RAMKit

@Suite("Growth (who is pushing toward the wall)")
struct GrowthTrackerTests {
    static let claude = "/Applications/Claude.app/Contents/MacOS/Claude"
    static let discord = "/Applications/Discord.app/Contents/MacOS/Discord"

    /// Claude's agent sessions start python workers that grow 100 MB every 10 s each; Discord is flat.
    static func snapshot(_ t: Double) -> ProcessSnapshot {
        var r = [rec(100, name: "Claude", path: claude, mb: 500, start: 1),
                 rec(400, name: "Discord", path: discord, mb: 700, start: 2)]
        for i in 0..<3 {
            r.append(rec(Int32(200 + i), ppid: 100, name: "python3.12", path: "/opt/homebrew/bin/python3.12",
                         mb: 1000 + UInt64(t / 10) * 100, resp: 100, start: UInt64(10 + i)))
        }
        return ProcessSnapshot(timestamp: Date(timeIntervalSince1970: 1_000 + t), records: r)
    }

    @Test func namesTheAppAndTheProcessesDrivingIt() throws {
        var g = GrowthTracker()
        for t in stride(from: 0.0, through: 60, by: 10) { g.add(Self.snapshot(t)) }
        let top = try #require(g.top().first)
        #expect(top.app == "Claude")
        #expect(abs(top.bytesPerMinute - 3 * 600 * 1_048_576) < 1)    // 3 workers × 100 MB / 10 s
        #expect(top.driver == "python3.12 ×3")
        #expect(g.top().count == 1)                                  // Discord is flat
        #expect(GrowthTracker.describe(top).hasPrefix("Claude +1.76 GB/min (python3.12 ×3)"))
    }

    @Test func tooLittleHistoryNamesNobody() {
        var g = GrowthTracker()
        g.add(Self.snapshot(0))
        g.add(Self.snapshot(10))
        #expect(g.top().isEmpty)
    }

    @Test func oldPointsAgeOutAndRelaunchedAppsStartOver() {
        var g = GrowthTracker()
        for t in stride(from: 0.0, through: 300, by: 10) { g.add(Self.snapshot(t)) }
        #expect(g.top().first?.app == "Claude")
        // Claude quits: its series is dropped.
        g.add(ProcessSnapshot(timestamp: Date(timeIntervalSince1970: 1_310), records: [rec(400, name: "Discord", path: Self.discord, mb: 700, start: 2)]))
        #expect(g.top().isEmpty)
    }
}
