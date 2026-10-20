import Foundation

/// How much one app gave back between two snapshots. Positive `delta` = memory returned.
public struct AppDelta: Codable, Sendable, Equatable, Identifiable {
    public var id: Int32
    public var name: String
    public var kind: AppKind
    public var before: UInt64
    public var after: UInt64
    public var busy: Bool
    public var exitedMembers: Int
    public var newMembers: Int

    public var delta: Int64 { Int64(clamping: before) - Int64(clamping: after) }
}

public struct MeasurementResult: Sendable, Equatable {
    /// Matched, non-busy apps sorted by delta (largest gain first).
    public var apps: [AppDelta]
    /// Matched apps that were busy during the baseline (shown, never counted).
    public var excluded: [AppDelta]
    /// Apps that appeared or disappeared inside the window (shown, never counted).
    public var new: [String]
    public var gone: [String]

    /// Net memory returned by non-busy apps (growth subtracts).
    public var headline: Int64 { apps.reduce(0) { $0 + $1.delta } }
    /// Sum of the gains only.
    public var grossFreed: Int64 { apps.reduce(0) { $0 + max(0, $1.delta) } }
}

/// The honest-accounting rules (spec 5.6). Pure functions over snapshots, so they are testable
/// without touching the system.
public enum Measurement {
    /// A group is busy when its footprint drifts more than this per second during the baseline...
    public static let busyDriftBytesPerSecond: Double = 15_000_000
    /// ...or it burns more than half a core.
    public static let busyCPUFraction: Double = 0.5

    public static func busyGroups(baseline: [ProcessSnapshot]) -> Set<Int32> {
        guard let first = baseline.first, let last = baseline.last, baseline.count >= 2 else { return [] }
        let dt = last.timestamp.timeIntervalSince(first.timestamp)
        guard dt > 0 else { return [] }
        let firstGroups = Dictionary(uniqueKeysWithValues: AppGrouper.group(first).map { ($0.id, $0) })
        var busy: Set<Int32> = []
        for group in AppGrouper.group(last) {
            guard let start = firstGroups[group.id] else { continue }
            // Drift: robust slope over every baseline sample that contains the group.
            var points: [(Double, Double)] = []
            for s in baseline {
                let fp = s.records.lazy.filter { $0.responsiblePid == group.id }.reduce(UInt64(0)) { $0 + $1.footprint }
                points.append((s.timestamp.timeIntervalSince(first.timestamp), Double(fp)))
            }
            let slope = Stats.theilSenSlope(points) ?? 0
            // CPU: only members alive in both endpoints (so exits/spawns don't fake usage).
            let startCPU = Dictionary(start.members.map { ($0.key, $0.cpuTimeNs) }, uniquingKeysWith: { a, _ in a })
            var cpuNs: UInt64 = 0
            for m in group.members { if let c0 = startCPU[m.key], m.cpuTimeNs > c0 { cpuNs += m.cpuTimeNs - c0 } }
            let cpuFraction = Double(cpuNs) / 1e9 / dt
            if abs(slope) > busyDriftBytesPerSecond || cpuFraction > busyCPUFraction { busy.insert(group.id) }
        }
        return busy
    }

    public static func deltas(before: ProcessSnapshot, after: ProcessSnapshot, busy: Set<Int32>) -> MeasurementResult {
        let b = AppGrouper.group(before)
        let a = Dictionary(uniqueKeysWithValues: AppGrouper.group(after).map { ($0.id, $0) })
        var matchedAfter: Set<Int32> = []
        var apps: [AppDelta] = []
        var excluded: [AppDelta] = []
        var gone: [String] = []

        for g0 in b {
            guard let g1 = a[g0.id], sameApp(g0, g1) else { gone.append(g0.name); continue }
            matchedAfter.insert(g1.id)
            let keys0 = Set(g0.members.map(\.key))
            let keys1 = Set(g1.members.map(\.key))
            let d = AppDelta(id: g0.id, name: g0.name, kind: g0.kind, before: g0.footprint, after: g1.footprint,
                             busy: busy.contains(g0.id), exitedMembers: keys0.subtracting(keys1).count,
                             newMembers: keys1.subtracting(keys0).count)
            if d.busy { excluded.append(d) } else { apps.append(d) }
        }
        let new = a.values.filter { !matchedAfter.contains($0.id) }.sorted { $0.footprint > $1.footprint }.map(\.name)
        apps.sort { $0.delta != $1.delta ? $0.delta > $1.delta : $0.id < $1.id }
        excluded.sort { $0.delta > $1.delta }
        return MeasurementResult(apps: apps, excluded: excluded, new: new, gone: gone)
    }

    /// Same responsible pid AND the same responsible process instance when both heads are known
    /// (a reused pid is a different app).
    static func sameApp(_ x: AppGroup, _ y: AppGroup) -> Bool {
        guard x.id == y.id else { return false }
        let hx = x.members.first { $0.pid == x.id }
        let hy = y.members.first { $0.pid == y.id }
        if let hx, let hy { return hx.startTime == hy.startTime }
        return true
    }
}
