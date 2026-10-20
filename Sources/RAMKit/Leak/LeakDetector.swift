import Foundation

/// A process whose footprint keeps climbing (spec 5.8). Informational only.
public struct Leak: Codable, Sendable, Identifiable {
    public var key: ProcessKey
    public var name: String
    public var slopeBytesPerHour: Double
    public var growthBytes: Int64
    public var windowS: Double
    public var currentFootprint: UInt64
    public var id: ProcessKey { key }
}

/// Footprint history per process with robust trend tests. Only processes above
/// `trackThreshold` are kept so a menu bar app stays small (about 50 series x 720 points).
public struct LeakDetector: Sendable {
    public static let trackThreshold: UInt64 = 100 << 20
    public static let minWindowS: Double = 1800
    public static let minSlopeBytesPerHour: Double = 200_000_000
    public static let minGrowthBytes: Int64 = 500_000_000
    public static let minRho: Double = 0.8
    public static let retentionS: Double = 6 * 3600
    public static let minSpacingS: Double = 25

    struct Series: Sendable {
        var name: String
        var points: [(t: Double, bytes: Double)]
    }

    private var series: [ProcessKey: Series] = [:]

    public init() {}

    public var trackedCount: Int { series.count }

    public mutating func add(_ s: ProcessSnapshot) {
        let t = s.timestamp.timeIntervalSince1970
        var alive: Set<ProcessKey> = []
        for r in s.records where r.footprint >= Self.trackThreshold || series[r.key] != nil {
            alive.insert(r.key)
            var entry = series[r.key] ?? Series(name: r.name, points: [])
            if let last = entry.points.last, t - last.t < Self.minSpacingS { continue }
            entry.points.append((t, Double(r.footprint)))
            if let first = entry.points.first, t - first.t > Self.retentionS {
                entry.points.removeAll { t - $0.t > Self.retentionS }
            }
            series[r.key] = entry
        }
        series = series.filter { alive.contains($0.key) }
    }

    public func leaks(now: Date) -> [Leak] {
        var out: [Leak] = []
        for (key, s) in series {
            guard let first = s.points.first, let last = s.points.last, s.points.count >= 6 else { continue }
            let window = last.t - first.t
            guard window >= Self.minWindowS else { continue }
            guard let slope = Stats.theilSenSlope(s.points.map { ($0.t, $0.bytes) }) else { continue }
            let perHour = slope * 3600
            let head = Stats.median(s.points.prefix(3).map(\.bytes)) ?? first.bytes
            let tail = Stats.median(s.points.suffix(3).map(\.bytes)) ?? last.bytes
            let growth = Int64(tail - head)
            guard perHour > Self.minSlopeBytesPerHour, growth > Self.minGrowthBytes,
                  let rho = Stats.spearman(s.points.map(\.t), s.points.map(\.bytes)), rho > Self.minRho
            else { continue }
            out.append(Leak(key: key, name: s.name, slopeBytesPerHour: perHour, growthBytes: growth,
                            windowS: window, currentFootprint: UInt64(last.bytes)))
        }
        return out.sorted { $0.slopeBytesPerHour > $1.slopeBytesPerHour }
    }
}
