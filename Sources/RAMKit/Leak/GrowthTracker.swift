import Foundation

/// Which apps are growing right now (over the last two minutes, not hours like `LeakDetector`):
/// what is pushing the Mac toward the wall, and which of its processes is doing it.
public struct GrowthTracker: Sendable {
    public struct Grower: Codable, Sendable, Equatable {
        public var app: String
        public var bytesPerMinute: Double
        public var footprint: UInt64
        /// The same-named processes inside the app that grew the most, e.g. "python3.12 ×23".
        public var driver: String?
    }

    public static let windowS: Double = 120
    /// Rates need at least this much history, so one noisy pair of samples never names a grower.
    public static let minSpanS: Double = 20
    public static let minBytesPerMinute: Double = 50 * 1_048_576

    struct Point: Sendable {
        var t: Double
        var bytes: UInt64
        var name: String
        /// Footprint and count per process name inside the app.
        var byName: [String: (count: Int, bytes: UInt64)]
    }

    /// Keyed by responsible pid and its start time, so a relaunched app is a new series.
    private var series: [ProcessKey: [Point]] = [:]

    public init() {}

    public mutating func add(_ s: ProcessSnapshot) {
        let t = s.timestamp.timeIntervalSince1970
        var alive: Set<ProcessKey> = []
        for g in AppGrouper.group(s) {
            guard let head = g.members.first(where: { $0.pid == g.id }) else { continue }
            let key = head.key
            alive.insert(key)
            var byName: [String: (count: Int, bytes: UInt64)] = [:]
            for m in g.members {
                let e = byName[m.name] ?? (0, 0)
                byName[m.name] = (e.count + 1, e.bytes + m.footprint)
            }
            var points = series[key] ?? []
            points.append(Point(t: t, bytes: g.footprint, name: g.name, byName: byName))
            points.removeAll { t - $0.t > Self.windowS }
            series[key] = points
        }
        series = series.filter { alive.contains($0.key) }
    }

    /// Apps growing faster than `minBytesPerMinute`, fastest first.
    public func top(_ n: Int = 3) -> [Grower] {
        var out: [Grower] = []
        for points in series.values {
            guard let first = points.first, let last = points.last, last.t - first.t >= Self.minSpanS else { continue }
            let rate = (Double(last.bytes) - Double(first.bytes)) / ((last.t - first.t) / 60)
            guard rate >= Self.minBytesPerMinute else { continue }
            var driver: String?
            var best: Int64 = 0
            for (name, now) in last.byName {
                let then = first.byName[name]?.bytes ?? 0
                let grew = Int64(now.bytes) - Int64(then)
                if grew > best { best = grew; driver = now.count > 1 ? "\(name) ×\(now.count)" : name }
            }
            out.append(Grower(app: last.name, bytesPerMinute: rate, footprint: last.bytes, driver: driver == last.name ? nil : driver))
        }
        return Array(out.sorted { $0.bytesPerMinute > $1.bytesPerMinute }.prefix(n))
    }

    /// "Claude +1.2 GB/min (python3.12 ×23)"
    public static func describe(_ g: Grower) -> String {
        "\(g.app) +\(Format.bytes(UInt64(g.bytesPerMinute)))/min" + (g.driver.map { " (\($0))" } ?? "")
    }
}
