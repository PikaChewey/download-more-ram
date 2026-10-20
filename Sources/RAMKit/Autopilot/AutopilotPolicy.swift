import Foundation

public enum AutopilotAction: Equatable, Sendable {
    case none
    case download
    case notifyTopConsumers
}

/// When autopilot downloads RAM on its own (spec 5.9): the wall is close, coming fast, imminent, or
/// the kernel has reported critical pressure for a while. At most one download per 2 minutes; after
/// two downloads in 10 minutes that did not get the Mac below the threshold it tells the user who is
/// using the memory instead (once per 10 minutes).
public struct AutopilotPolicy: Sendable {
    public static let wallThreshold = 85.0
    public static let etaThreshold: TimeInterval = 300
    public static let criticalFor: TimeInterval = 20
    public static let minInterval: TimeInterval = 120
    public static let escalateAfter = 2
    public static let escalateWindow: TimeInterval = 600

    private var criticalSince: Date?
    private var downloads: [Date] = []
    private var lastNotify: Date?

    public init() {}

    public mutating func observe(status: WallStatus, pressure: PressureLevel, now: Date) -> AutopilotAction {
        if pressure == .critical { criticalSince = criticalSince ?? now } else { criticalSince = nil }
        let longCritical = criticalSince.map { now.timeIntervalSince($0) > Self.criticalFor } ?? false
        let soon = status.etaSeconds.map { $0 < Self.etaThreshold } ?? false
        let trigger = status.percent >= Self.wallThreshold || soon || status.imminent || longCritical
        guard trigger else { return .none }

        downloads.removeAll { now.timeIntervalSince($0) > Self.escalateWindow }
        if downloads.count >= Self.escalateAfter && status.percent >= Self.wallThreshold {
            if let last = lastNotify, now.timeIntervalSince(last) < Self.escalateWindow { return .none }
            lastNotify = now
            return .notifyTopConsumers
        }
        if let last = downloads.last, now.timeIntervalSince(last) < Self.minInterval { return .none }
        return .download
    }

    public mutating func recordDownload(at date: Date) { downloads.append(date) }
}
