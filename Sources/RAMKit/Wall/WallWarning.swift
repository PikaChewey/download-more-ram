import Foundation

/// The one notification before the wall, autopilot or not: when macOS is about to show "Your system
/// has run out of application memory", say so and name who is growing. At most every 30 minutes.
public enum WallWarning {
    public static let repeatAfterS: Double = 30 * 60
    public static let percent = 85.0
    public static let etaS: Double = 15 * 60

    public static func due(_ status: WallStatus, lastWarning: Date, now: Date) -> Bool {
        guard now.timeIntervalSince(lastWarning) >= repeatAfterS else { return false }
        if status.imminent { return true }
        if let eta = status.etaSeconds, status.percent >= percent, eta <= etaS { return true }
        return false
    }

    public static func title(_ status: WallStatus) -> String {
        status.imminent ? "Your Mac is about to run out of memory" : "\(Format.percent(status.percent)) to the memory wall"
    }

    public static func body(_ status: WallStatus, grower: GrowthTracker.Grower?, biggestName: String?, biggestBytes: UInt64,
                            autopilot: Bool) -> String {
        var parts = [status.imminent ? "Swap is full and macOS has not added a swapfile, so it pauses apps next."
                                     : "About \(Format.duration(status.etaSeconds ?? 0)) left at this rate."]
        if let grower { parts.append("Growing fastest: \(GrowthTracker.describe(grower)).") }
        else if let biggestName { parts.append("Using the most: \(biggestName) \(Format.bytes(biggestBytes)).") }
        parts.append(autopilot ? "Autopilot is on." : "Click to open Download More RAM.")
        return parts.joined(separator: " ")
    }
}
