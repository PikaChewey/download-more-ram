import Foundation
import Testing
@testable import RAMKit

@Suite("Leak detector")
struct LeakDetectorTests {
    func feed(_ d: inout LeakDetector, minutes: Int, mb: (Int) -> Double) {
        for m in 0...minutes {
            let t = Date(timeIntervalSince1970: Double(m) * 60)
            let r = rec(77, name: "Claude Helper (Renderer)", mb: UInt64(max(0, mb(m))), start: 5)
            d.add(ProcessSnapshot(timestamp: t, records: [r]))
        }
    }

    @Test func steadyGrowthIsALeak() throws {
        var d = LeakDetector()
        // 600 MB/h for an hour, +-20 MB noise, starting at 800 MB.
        feed(&d, minutes: 60) { m in 800 + 10 * Double(m) + (m % 2 == 0 ? 20 : -20) }
        let leaks = d.leaks(now: Date(timeIntervalSince1970: 3600))
        let leak = try #require(leaks.first)
        #expect(leaks.count == 1)
        #expect(abs(leak.slopeBytesPerHour - 600 * 1_048_576) < 60 * 1_048_576)
        #expect(leak.growthBytes > 500_000_000)
        #expect(leak.name == "Claude Helper (Renderer)")
    }

    @Test func garbageCollectionSawtoothIsNotALeak() {
        var d = LeakDetector()
        feed(&d, minutes: 90) { m in 1000 + Double((m % 10) * 60) }   // climbs 540 MB then drops, repeatedly
        #expect(d.leaks(now: Date(timeIntervalSince1970: 5400)).isEmpty)
    }

    @Test func shortWindowIsNotALeak() {
        var d = LeakDetector()
        feed(&d, minutes: 20) { m in 800 + 50 * Double(m) }   // steep, but only 20 minutes
        #expect(d.leaks(now: Date(timeIntervalSince1970: 1200)).isEmpty)
    }

    @Test func smallProcessesAreNotTracked() {
        var d = LeakDetector()
        feed(&d, minutes: 60) { m in 10 + 0.1 * Double(m) }
        #expect(d.trackedCount == 0)
    }
}

@Suite("Wall event log")
struct WallEventLogTests {
    static let excerpt = """
        2026-10-20 03:23:47.799 Df loginwindow[405:1090] [com.apple.loginwindow.logging:Standard] -[ProcessPanelController showLowMemoryPanel] | enter
        2026-10-20 03:33:51.170 Df loginwindow[405:1090] [com.apple.loginwindow.logging:Standard] -[LowMemoryPanel anyAppIsLowMemSuspended] |      app: Firefox is low mem paused
        2026-10-20 03:34:18.878 Df loginwindow[405:1090] [com.apple.loginwindow.logging:Standard] -[LowMemoryPanel anyAppIsLowMemSuspended] |      app: Firefox is low mem paused
        2026-10-20 03:36:44.496 Df loginwindow[405:1090] [com.apple.loginwindow.logging:Standard] -[ProcessPanelController closeProcessPanel] |      closing and releasing lowmemory panel
        2026-10-20 03:40:04.954 Df loginwindow[405:1090] [com.apple.loginwindow.logging:Standard] -[ProcessPanelController showLowMemoryPanel] | enter
        2026-10-20 03:40:10.033 Df loginwindow[405:1090] [com.apple.loginwindow.logging:Standard] -[ProcessPanelController showLowMemoryPanel] | enter
        2026-10-20 03:52:45.523 Df loginwindow[405:1090] [com.apple.loginwindow.logging:Standard] -[LowMemoryPanel anyAppIsLowMemSuspended] |      app: ChatGPT is low mem paused
        2026-10-20 03:52:46.100 Df loginwindow[405:1090] [com.apple.loginwindow.logging:Standard] -[LowMemoryPanel anyAppIsLowMemSuspended] |      app: Discord is low mem paused
        2026-10-20 03:59:35.066 Df loginwindow[405:1090] [com.apple.loginwindow.logging:Standard] -[ProcessPanelController closeProcessPanel] |      closing and releasing lowmemory panel
        2026-10-20 04:10:00.000 Df loginwindow[405:1090] [com.apple.loginwindow.logging:Standard] -[ProcessPanelController showLowMemoryPanel] | enter
        """

    @Test func mergesRepeatedShowsIntoEpisodes() throws {
        let events = WallEventLog.parse(Self.excerpt)
        #expect(events.count == 3)
        let first = events[0]
        #expect(first.pausedApps == ["Firefox"])
        let durationFirst = try #require(first.end).timeIntervalSince(first.start)
        #expect(abs(durationFirst - (12 * 60 + 56.697)) < 0.01)
        #expect(events[1].pausedApps == ["ChatGPT", "Discord"])
        #expect(events[2].end == nil)   // still open at the end of the log
    }

    @Test func ignoresUnrelatedLines() {
        #expect(WallEventLog.parse("2026-10-20 03:00:00.000 Df loginwindow[405:1] WiFi _pause\nnot a log line").isEmpty)
    }
}
