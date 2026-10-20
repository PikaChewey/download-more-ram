import Foundation
import Testing
@testable import RAMKit

@Suite("Formatting")
struct FormatTests {
    @Test func bytesLikeActivityMonitor() {
        let gib = 1_073_741_824.0, mib = 1_048_576.0
        #expect(Format.bytes(Int64(4.11 * gib)) == "4.11 GB")
        #expect(Format.bytes(Int64(17.68 * gib)) == "17.68 GB")
        #expect(Format.bytes(UInt64(16) << 30) == "16.00 GB")     // a 16 GB Mac, as Activity Monitor shows it
        #expect(Format.bytes(Int64(97.3 * mib)) == "97.3 MB")
        #expect(Format.bytes(512 * 1024) == "512 KB")
        #expect(Format.bytes(0) == "0 B")
        #expect(Format.bytes(Int64(-1.2 * gib), signed: true) == "-1.20 GB")
        #expect(Format.bytes(Int64(1.2 * gib), signed: true) == "+1.20 GB")
        #expect(Format.bytes(Int64(-97.3 * mib)) == "-97.3 MB")
    }

    @Test func bars() {
        #expect(Format.bar(fraction: 0, width: 4) == "    ")
        #expect(Format.bar(fraction: 1, width: 4) == "████")
        #expect(Format.bar(fraction: 0.5, width: 4) == "██  ")
        #expect(Format.bar(fraction: 0.5, width: 4, empty: "░") == "██░░")
        #expect(Format.bar(fraction: 1.7, width: 3) == "███")
        #expect(Format.bar(fraction: 0.0625, width: 2) == "▉ ".replacingOccurrences(of: "▉", with: "▏"))
    }

    @Test func durations() {
        #expect(Format.duration(6.4) == "6s")
        #expect(Format.duration(65) == "1m 05s")
        #expect(Format.duration(7380) == "2h 03m")
    }
}

@Suite("Robust statistics")
struct StatsTests {
    @Test func theilSenIgnoresOutlier() throws {
        var pts: [(Double, Double)] = []
        for x in 0..<40 {
            let noise: Double = x % 3 == 0 ? 0.3 : -0.2
            let xd = Double(x)
            pts.append((xd, 2 * xd + noise))
        }
        pts[20].1 = 500
        let slope = try #require(Stats.theilSenSlope(pts))
        #expect(abs(slope - 2) < 0.05)
    }

    @Test func spearmanOfMonotone() throws {
        let xs = (0..<10).map(Double.init)
        let ys = xs.map { $0 * $0 }
        #expect(try #require(Stats.spearman(xs, ys)) == 1)
        #expect(try #require(Stats.spearman(xs, ys.reversed())) == -1)
        #expect(Stats.spearman([1], [1]) == nil)
    }

    @Test func meanAndSD() {
        let (m, sd) = Stats.meanSD([2, 4, 4, 4, 5, 5, 7, 9])
        #expect(m == 5)
        #expect(abs(sd - 2.138) < 0.001) // sample SD
    }
}
