import Foundation

public enum WallFactor: String, Codable, Sendable {
    case swap, compressorPages, compressorSegments, none
}

/// How close the Mac is to "Your system has run out of application memory".
public struct WallStatus: Codable, Sendable, Equatable {
    public var percent: Double
    public var etaSeconds: Double?
    public var limitingFactor: WallFactor
    public var reason: String
    /// Swap is nearly full and macOS has not added a swapfile: the panel can appear any second.
    public var imminent: Bool
}

/// Distance to the out-of-memory wall from unprivileged kernel counters, using the limits xnu
/// actually checks (docs/research/xnu.md):
/// - compressor: low on space at 98% of `c_segments_limit` or of `c_segment_pages_compressed_limit`
///   (segments include swapped-out ones, so this caps compressed data in RAM + swap);
/// - swap: macOS adds 1 GiB swapfiles up to 100, as long as the disk can hold them; the wall trips
///   when free swap < 32 MiB and the last swapfile creation failed.
public struct WallModel: Sendable {
    public static let windowS: Double = 300
    public static let nearingFraction = 0.98
    public static let maxSwapfiles: UInt64 = 100
    public static let swapfileBytes: UInt64 = 1 << 30
    public static let diskReserve: UInt64 = 1 << 30
    /// macOS asks for a new swapfile when free swap drops below this (vm_swapfile_hiwater_segs).
    public static let swapHiwater: UInt64 = 256 << 20
    /// ...and declares itself low on swap below this if the creation failed (hiwater / 8).
    public static let swapLow: UInt64 = 32 << 20
    /// A new swapfile normally appears within a few seconds; the kernel retries every 15 s.
    public static let stuckAfterS: Double = 15
    /// A time-to-wall needs this much history: a trend fitted on seconds swings by hours.
    public static let etaMinSpanS: Double = 60

    private var history: [(t: Double, sample: SystemSample)] = []

    public init() {}

    public mutating func add(_ s: SystemSample) {
        let t = s.timestamp.timeIntervalSince1970
        history.append((t, s))
        history.removeAll { t - $0.t > Self.windowS }
    }

    public var latest: SystemSample? { history.last?.sample }

    public func status() -> WallStatus? {
        guard let s = history.last?.sample else { return nil }
        let factors = Self.factors(s)
        guard var worst = factors.max(by: { $0.fraction < $1.fraction }) else { return nil }
        var imminent = false
        if let stuck = stuckSwap() {
            imminent = true
            let floor = s.swapTotal - min(s.swapTotal, s.swapUsed) < Self.swapLow ? 0.99 : 0.97
            if floor > worst.fraction {
                worst = Factor(factor: .swap, fraction: floor,
                               reason: "swap is full and macOS has not added a swapfile for \(Format.duration(stuck))")
            }
        }
        let pct = min(100, max(0, worst.fraction * 100))
        return WallStatus(percent: pct, etaSeconds: imminent ? 0 : eta(for: worst.factor),
                          limitingFactor: pct < 1 ? .none : worst.factor, reason: worst.reason, imminent: imminent)
    }

    struct Factor { var factor: WallFactor; var fraction: Double; var reason: String }

    static func swapCapacity(_ s: SystemSample) -> UInt64 {
        let byFiles = maxSwapfiles * swapfileBytes
        let disk = s.vmVolumeFreeBytes > diskReserve ? s.vmVolumeFreeBytes - diskReserve : 0
        let room = min(byFiles > s.swapTotal ? byFiles - s.swapTotal : 0, disk)
        return s.swapTotal + room
    }

    static func factors(_ s: SystemSample) -> [Factor] {
        var out: [Factor] = []
        if s.compressorSegmentsLimit > 0 {
            let cap = nearingFraction * Double(s.compressorSegmentsLimit)
            let f = Double(s.compressorSegments) / cap
            let capBytes = UInt64(cap * 65_536)
            out.append(Factor(factor: .compressorSegments, fraction: f,
                              reason: "compressed memory fills \(Format.percent(f * 100)) of the \(Format.bytes(capBytes)) macOS can hold"))
        }
        if s.compressorPagesLimit > 0 {
            let f = Double(s.compressorPages) / (nearingFraction * Double(s.compressorPagesLimit))
            out.append(Factor(factor: .compressorPages, fraction: f,
                              reason: "compressor tracks \(Format.percent(f * 100)) of its page limit"))
        }
        let cap = swapCapacity(s)
        if cap > 0 {
            let f = Double(s.swapUsed) / Double(cap)
            out.append(Factor(factor: .swap, fraction: f,
                              reason: "swap \(Format.bytes(s.swapUsed)) of the \(Format.bytes(cap)) it can grow to"))
        }
        return out
    }

    /// Seconds that free swap has stayed under the hiwater mark without swap growing, if at least
    /// `stuckAfterS` (the kernel's creation retry delay): macOS tried and failed to add a swapfile.
    func stuckSwap() -> Double? {
        guard let last = history.last?.sample, last.swapTotal > 0 else { return nil }
        let free = last.swapTotal - min(last.swapTotal, last.swapUsed)
        guard free < Self.swapHiwater else { return nil }
        var since = history.last!.t
        var firstSwapouts = last.swapouts
        for (t, s) in history.reversed() {
            let f = s.swapTotal - min(s.swapTotal, s.swapUsed)
            guard f < Self.swapHiwater, s.swapTotal == last.swapTotal else { break }
            since = t
            firstSwapouts = s.swapouts
        }
        let stuck = history.last!.t - since
        // macOS only tries to add a swapfile while it is swapping out; a quiet system can sit under
        // the hiwater mark indefinitely without being anywhere near the wall.
        guard last.swapouts > firstSwapouts else { return nil }
        return stuck >= Self.stuckAfterS ? stuck : nil
    }

    func eta(for factor: WallFactor) -> Double? {
        guard history.count >= 4, let first = history.first, let last = history.last,
              last.t - first.t >= Self.etaMinSpanS else { return nil }
        let pts = history.map { ($0.t - first.t, Self.factors($0.sample).first { $0.factor == factor }?.fraction ?? 0) }
        guard let slope = Stats.theilSenSlope(pts), slope > 1e-7, let last = pts.last else { return nil }
        let remaining = (1 - last.1) / slope
        return remaining.isFinite && remaining > 0 && remaining < 7 * 86_400 ? remaining : nil
    }
}

/// Who macOS will pause next if the wall is hit, and who it paused and never resumed.
public struct WallInsights: Codable, Sendable {
    public var nextToPause: ProcessRecord?
    public var nextToPauseApp: String?
    /// What macOS will do to it: suspend (the usual "(paused)"), kill, or throttle.
    public var nextAction: ProcessRecord.PauseAction?
    public var stillPaused: [ProcessRecord]
    public var stillPausedApps: [String]

    /// xnu `no_paging_space_action()`: the largest process (by compressed memory) that registered to be
    /// suspended and has not been acted on yet. Compressed size is approximated by footprint - resident.
    public static func from(_ s: ProcessSnapshot, system: SystemSample) -> WallInsights {
        func compressed(_ r: ProcessRecord) -> UInt64 { r.footprint - min(r.footprint, r.residentBytes) }
        let byPid = Dictionary(s.records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func appName(_ r: ProcessRecord) -> String {
            let head = byPid[r.responsiblePid] ?? r
            if let bundle = head.path.flatMap(AppGrouper.outermostBundlePath) { return AppGrouper.bundleDisplayName(bundlePath: bundle) }
            return head.name
        }
        // xnu: a process that did NOT register and holds > 50% of all compressed pages is killed outright;
        // otherwise the largest registrant (throttle/suspend/kill) not yet acted on (PA_* clear) gets its action.
        let totalCompressed = system.compressedUncompressedBytes
        let outright = s.records.filter { $0.pauseAction == .none }.max { compressed($0) < compressed($1) }
            .flatMap { totalCompressed > 0 && compressed($0) * 2 > totalCompressed ? $0 : nil }
        let next = s.records.filter { $0.pauseAction != .none && $0.bsdFlags & 0x1800 == 0 }.max { compressed($0) < compressed($1) }
        let paused = s.records.filter(\.pausedByWall).sorted { $0.footprint > $1.footprint }
        var apps: [String] = []
        for r in paused where !apps.contains(appName(r)) { apps.append(appName(r)) }
        return WallInsights(nextToPause: outright ?? next, nextToPauseApp: (outright ?? next).map(appName),
                            nextAction: outright != nil ? .kill : next?.pauseAction,
                            stillPaused: paused, stillPausedApps: apps)
    }
}
