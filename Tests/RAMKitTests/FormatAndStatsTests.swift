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

@Suite("Welch t-test")
struct WelchTests {
    @Test func matchesTheTextbookExample() throws {
        // Welch (1947)-style example used on Wikipedia; reference values computed independently.
        let a = [27.5, 21.0, 19.0, 23.6, 17.0, 17.9, 16.9, 20.1, 21.9, 22.6, 23.1, 19.6, 19.0, 21.7, 21.4]
        let b = [27.1, 22.0, 20.8, 23.4, 23.4, 23.5, 25.8, 22.0, 24.8, 20.2, 21.9, 22.1, 22.9, 20.5, 24.4]
        let r = try #require(Stats.welch(a, b))
        #expect(abs(r.t - -2.455356) < 1e-5)
        #expect(abs(r.df - 24.988529) < 1e-5)
        #expect(abs(r.p - 0.021378) < 1e-5)
        #expect(abs(r.cohenD - -0.896569) < 1e-5)
    }

    @Test func identicalSamplesAreNotSignificant() throws {
        let r = try #require(Stats.welch([1, 2, 3, 4], [1, 2, 3, 4]))
        #expect(r.p > 0.99)
        #expect(Stats.welch([1], [1, 2]) == nil)
    }
}
