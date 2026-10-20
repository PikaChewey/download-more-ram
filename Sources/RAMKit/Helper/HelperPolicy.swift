import Foundation

public enum HelperRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case badLevel
    case badHold
    case busy
    case tooSoon(retryAfter: TimeInterval)
    case hourlyCap

    public var description: String {
        switch self {
        case .badLevel: "only warn or critical can be signalled"
        case .badHold: "hold must be 1-30 seconds"
        case .busy: "a download is already running"
        case .tooSoon(let s): "wait \(Int(s.rounded(.up)))s between downloads"
        case .hourlyCap: "at most \(HelperPolicy.hourlyCap) downloads per hour"
        }
    }
}

/// What the root helper accepts (spec 5.7): bounded, serialized, rate-limited. Pure logic so it is
/// unit-tested without root.
public struct HelperPolicy: Sendable {
    public struct Ticket: Equatable, Sendable {
        public var level: PressureLevel
        public var holdMs: Int
    }

    public static let holdRange = 1000...30_000
    public static let minGapS: TimeInterval = 20
    public static let hourlyCap = 30

    private var running = false
    private var lastEnd: Date?
    private var starts: [Date] = []

    public init() {}

    public mutating func admit(level: PressureLevel, holdMs: Int, now: Date) -> Result<Ticket, HelperRefusal> {
        guard level == .warn || level == .critical else { return .failure(.badLevel) }
        guard Self.holdRange.contains(holdMs) else { return .failure(.badHold) }
        guard !running else { return .failure(.busy) }
        if let lastEnd, now.timeIntervalSince(lastEnd) < Self.minGapS {
            return .failure(.tooSoon(retryAfter: Self.minGapS - now.timeIntervalSince(lastEnd)))
        }
        starts.removeAll { now.timeIntervalSince($0) >= 3600 }
        guard starts.count < Self.hourlyCap else { return .failure(.hourlyCap) }
        running = true
        starts.append(now)
        return .success(Ticket(level: level, holdMs: holdMs))
    }

    public mutating func finished(now: Date) {
        running = false
        lastEnd = now
    }

    public var isRunning: Bool { running }
    public var lastReliefEnd: Date? { lastEnd }
    public func reliefsInLastHour(now: Date) -> Int { starts.filter { now.timeIntervalSince($0) < 3600 }.count }
}
