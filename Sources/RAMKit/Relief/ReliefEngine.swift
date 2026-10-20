import Darwin
import Foundation

/// Where the engine gets its readings (injected so tests never touch the system).
public protocol Sampling: Sendable {
    func processSnapshot() -> ProcessSnapshot
    func systemSample() throws -> SystemSample
    func sleep(ms: Int) async throws
    func now() -> Date
}

public struct LiveSampling: Sampling {
    public init() {}
    public func processSnapshot() -> ProcessSnapshot {
        var s = ProcessSampler.snapshot(includePaths: true)
        // Never count our own sampling allocations.
        s.records.removeAll { $0.pid == getpid() }
        return s
    }
    public func systemSample() throws -> SystemSample { try SystemSampler.read() }
    public func sleep(ms: Int) async throws { try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
    public func now() -> Date { Date() }
}

/// Live state of a download, for the progress bar.
public struct ReliefProgress: Sendable {
    public enum Phase: String, Sendable { case baseline, holding, settling, done }
    public var phase: Phase
    public var elapsed: Double
    public var total: Double
    /// Net bytes returned so far by non-busy apps (the number that becomes the headline).
    public var reclaimedSoFar: Int64
    public var rateBytesPerSec: Double
    public var topApps: [AppDelta]
}

/// Runs one "download": baseline, kernel pressure signal, live measurement, receipt.
public actor ReliefEngine {
    public let backend: any ReliefBackend
    public let level: PressureLevel
    public let holdMs: Int
    public let settleMs: Int
    let sampling: any Sampling
    let wall: (@Sendable (SystemSample) -> Double)?

    public static let baselineSamples = 3
    public static let baselineIntervalMs = 1000
    public static let tickMs = 500

    public init(backend: any ReliefBackend, level: PressureLevel = .critical, holdMs: Int = 10_000,
                settleMs: Int = 5_000, sampling: any Sampling = LiveSampling(),
                wall: (@Sendable (SystemSample) -> Double)? = nil) {
        self.backend = backend
        self.level = level
        self.holdMs = holdMs
        self.settleMs = settleMs
        self.sampling = sampling
        self.wall = wall
    }

    public func run(progress: @Sendable (ReliefProgress) -> Void = { _ in }) async throws -> Receipt {
        let started = sampling.now()
        let total = Double(Self.baselineSamples - 1) * Double(Self.baselineIntervalMs) / 1000
            + Double(holdMs + settleMs) / 1000

        // 1. Baseline: drift and CPU decide which apps are too busy to judge.
        var baseline: [ProcessSnapshot] = []
        for i in 0..<Self.baselineSamples {
            if i > 0 { try await sampling.sleep(ms: Self.baselineIntervalMs) }
            baseline.append(sampling.processSnapshot())
            progress(ReliefProgress(phase: .baseline, elapsed: sampling.now().timeIntervalSince(started),
                                    total: total, reclaimedSoFar: 0, rateBytesPerSec: 0, topApps: []))
        }
        let busy = Measurement.busyGroups(baseline: baseline)
        let before = baseline[baseline.count - 1]
        let systemBefore = try sampling.systemSample()

        // 2. Signal the kernel. The backend restores normal pressure on every path.
        let backend = self.backend
        let level = self.level
        let holdMs = self.holdMs
        let relief = Task { try await backend.relieve(level: level, holdMs: holdMs) }

        // 3. Watch apps respond through the hold and the settle window.
        let reliefStart = sampling.now()
        var lastReclaimed: Int64 = 0
        var lastTime = reliefStart
        var rate = 0.0
        while sampling.now().timeIntervalSince(reliefStart) * 1000 < Double(holdMs + settleMs) {
            try await sampling.sleep(ms: Self.tickMs)
            let current = sampling.processSnapshot()
            let m = Measurement.deltas(before: before, after: current, busy: busy)
            let t = sampling.now()
            let dt = t.timeIntervalSince(lastTime)
            if dt > 0 { rate = max(0, Double(m.headline - lastReclaimed) / dt) }
            lastReclaimed = m.headline
            lastTime = t
            let inHold = t.timeIntervalSince(reliefStart) * 1000 < Double(holdMs)
            progress(ReliefProgress(phase: inHold ? .holding : .settling, elapsed: t.timeIntervalSince(started),
                                    total: total, reclaimedSoFar: m.headline, rateBytesPerSec: rate,
                                    topApps: Array(m.apps.prefix(5))))
        }
        try await relief.value

        // 4. Final reading and receipt.
        let after = sampling.processSnapshot()
        let systemAfter = try sampling.systemSample()
        let m = Measurement.deltas(before: before, after: after, busy: busy)
        let finished = sampling.now()
        progress(ReliefProgress(phase: .done, elapsed: finished.timeIntervalSince(started), total: total,
                                reclaimedSoFar: m.headline, rateBytesPerSec: 0, topApps: Array(m.apps.prefix(5))))
        return Receipt(
            id: Receipt.makeID(started), startedAt: started, durationS: finished.timeIntervalSince(started),
            backend: backend.name, level: level, holdMs: holdMs, machine: .current(),
            headlineBytes: m.headline, grossFreedBytes: m.grossFreed, apps: m.apps, excludedBusy: m.excluded,
            newApps: m.new, goneApps: m.gone, systemBefore: systemBefore, systemAfter: systemAfter,
            wallBefore: wall?(systemBefore), wallAfter: wall?(systemAfter))
    }
}
