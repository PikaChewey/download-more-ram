import Foundation
import Testing
@testable import RAMKit

private let gib: UInt64 = 1 << 30
private let mib: UInt64 = 1 << 20

func wallSample(t: Double, swapTotal: UInt64 = 11 * gib, swapUsed: UInt64, segments: UInt64 = 243_585,
                pages: UInt64 = 2_090_000, diskFree: UInt64 = 93 * gib, files: Int = 11) -> SystemSample {
    var s = fakeSystem()
    s.timestamp = Date(timeIntervalSince1970: t)
    s.swapTotal = swapTotal
    s.swapUsed = swapUsed
    s.swapfileCount = files
    s.vmVolumeFreeBytes = diskFree
    s.compressorSegments = segments
    s.compressorSegmentsLimit = 805_810
    s.compressorPages = pages
    s.compressorPagesLimit = 6_446_480
    return s
}

@Suite("Wall model")
struct WallModelTests {
    @Test func swapStuckFullIsImminent() throws {
        // The 03:23 / 03:40 situation: swap fills its 11 swapfiles and macOS fails to add a 12th.
        var m = WallModel()
        for i in 0...15 {
            let used = 11 * gib - 300 * mib + UInt64(i) * 18 * mib     // free swap falls from 300 MiB to 30 MiB
            m.add(wallSample(t: Double(i) * 2, swapUsed: used))
        }
        let w = try #require(m.status())
        #expect(w.percent >= 95)
        #expect(w.limitingFactor == .swap)
        #expect(w.reason.contains("swapfile"))
    }

    @Test func healthySwapWithRoomToGrowIsLow() throws {
        var m = WallModel()
        m.add(wallSample(t: 0, swapTotal: 3 * gib, swapUsed: 2 * gib, files: 3))
        let w = try #require(m.status())
        #expect(w.percent < 70)
        #expect(w.etaSeconds == nil)
    }

    @Test func compressorSegmentLimitIsTheWall() throws {
        var m = WallModel()
        m.add(wallSample(t: 0, swapTotal: 40 * gib, swapUsed: 30 * gib, segments: 780_000, files: 40))
        let w = try #require(m.status())
        #expect(w.limitingFactor == .compressorSegments)
        #expect(abs(w.percent - 98.77) < 0.1)    // 780,000 / (0.98 x 805,810)
    }

    @Test func diskShortageCapsSwapGrowth() throws {
        var m = WallModel()
        m.add(wallSample(t: 0, swapTotal: 8 * gib, swapUsed: 7 * gib + 900 * mib, diskFree: 1 * gib + 512 * mib, files: 8))
        let w = try #require(m.status())
        #expect(w.limitingFactor == .swap)
        #expect(w.percent > 90)
    }

    @Test func etaFollowsTheTrend() throws {
        var m = WallModel()
        // Segments grow 1,000 per 10 s from 70% of the 98% limit: about 31 minutes to go.
        let limit98 = 0.98 * 805_810
        for i in 0..<30 {
            m.add(wallSample(t: Double(i) * 10, swapTotal: 40 * gib, swapUsed: 20 * gib,
                             segments: UInt64(0.7 * limit98) + UInt64(i) * 1000, files: 40))
        }
        let w = try #require(m.status())
        let remainingSegments = limit98 - (0.7 * limit98 + 29_000)
        let expected = remainingSegments / 100        // 100 segments per second
        let eta = try #require(w.etaSeconds)
        #expect(abs(eta - expected) / expected < 0.1)
    }

    @Test func flatHistoryHasNoETA() throws {
        var m = WallModel()
        for i in 0..<10 { m.add(wallSample(t: Double(i) * 10, swapUsed: 5 * gib)) }
        #expect(try #require(m.status()).etaSeconds == nil)
    }
}

@Suite("Wall insights")
struct WallInsightsTests {
    @Test func predictsWhoGetsPausedAndWhoIsStillPaused() {
        var firefox = rec(100, name: "firefox", path: "/Applications/Firefox.app/Contents/MacOS/firefox", mb: 9000)
        firefox.residentBytes = 1000 << 20
        firefox.bsdFlags = 0x400                    // registered: suspend at the wall
        var discord = rec(400, name: "Discord", path: "/Applications/Discord.app/Contents/MacOS/Discord", mb: 1200)
        discord.residentBytes = 200 << 20
        discord.bsdFlags = 0x400
        var raycastNet = rec(1149, name: "com.apple.WebKit.Networking", mb: 30, resp: 1042)
        raycastNet.bsdFlags = 0x1000 | 0x400        // paused at the wall and never resumed
        let snap = ProcessSnapshot(timestamp: Date(), records: [firefox, discord, raycastNet,
            rec(1042, name: "Raycast", path: "/Applications/Raycast.app/Contents/MacOS/Raycast", mb: 300)])
        var sys = fakeSystem()
        sys.compressedUncompressedBytes = 30 << 30
        let i = WallInsights.from(snap, system: sys)
        #expect(i.nextToPause?.pid == 100)
        #expect(i.nextToPauseApp == "Firefox")
        #expect(i.stillPaused.map(\.pid) == [1149])
        #expect(i.stillPausedApps == ["Raycast"])
    }
}
