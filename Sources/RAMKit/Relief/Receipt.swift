import Foundation

public struct MachineInfo: Codable, Sendable, Equatable {
    public var model: String
    public var chip: String
    public var memoryBytes: UInt64
    public var osVersion: String

    public static func current() -> MachineInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return MachineInfo(
            model: Sysctl.string("hw.model") ?? "Mac",
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "Apple silicon",
            memoryBytes: Sysctl.uint64("hw.memsize") ?? 0,
            osVersion: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        )
    }

    /// "Apple M5 · 16 GB" (binary GB for installed RAM, as Apple labels it).
    public var summary: String { "\(chip) · \(memoryBytes >> 30) GB" }
}

/// The record of one download: what was triggered, what every app gave back, and the system
/// state before and after. Saved as JSON (machine-readable) and Markdown (human-readable).
public struct Receipt: Codable, Sendable, Identifiable {
    public var id: String
    public var startedAt: Date
    public var durationS: Double
    public var backend: String
    public var level: PressureLevel
    public var holdMs: Int
    public var machine: MachineInfo
    public var headlineBytes: Int64
    public var grossFreedBytes: Int64
    public var apps: [AppDelta]
    public var excludedBusy: [AppDelta]
    public var newApps: [String]
    public var goneApps: [String]
    public var systemBefore: SystemSample
    public var systemAfter: SystemSample
    public var wallBefore: Double?
    public var wallAfter: Double?

    public static let methodNote = """
        Measured with phys_footprint (the number in Activity Monitor's Memory column), summed per \
        app the way the Force Quit dialog groups processes (by responsible process). Apps that were \
        busy during the 2 s baseline (footprint drifting > 15 MB/s or CPU > 50%) and apps that \
        started or quit during the window are listed but not counted.
        """

    public func markdown() -> String {
        var out = "# Downloaded \(Format.bytes(headlineBytes)) of RAM\n\n"
        let when = ISO8601DateFormatter.string(from: startedAt, timeZone: .current,
                                               formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
        out += "\(when) · \(machine.summary) · \(machine.osVersion) · kernel memory-pressure signal "
        out += "(\(level.word)) held \(Format.duration(Double(holdMs) / 1000)) via \(backend) · took \(Format.duration(durationS))\n\n"
        out += "| App | Before | After | Gave back |\n|---|---:|---:|---:|\n"
        for a in apps where a.delta != 0 {
            out += "| \(a.name) | \(Format.bytes(a.before)) | \(Format.bytes(a.after)) | \(Format.bytes(a.delta, signed: true)) |\n"
        }
        out += "\n"
        if !excludedBusy.isEmpty {
            out += "Not counted (busy): " + excludedBusy.map { "\($0.name) \(Format.bytes($0.delta, signed: true))" }.joined(separator: ", ") + "\n\n"
        }
        if !newApps.isEmpty || !goneApps.isEmpty {
            out += "Not counted (started/quit during the window): " + (newApps + goneApps).joined(separator: ", ") + "\n\n"
        }
        let sb = systemBefore, sa = systemAfter
        out += "System: swap used \(Format.bytes(sb.swapUsed)) → \(Format.bytes(sa.swapUsed)) · "
        out += "compressed \(Format.bytes(sb.compressorOccupiedBytes)) → \(Format.bytes(sa.compressorOccupiedBytes)) · "
        out += "pressure \(sb.pressureLevel.word) → \(sa.pressureLevel.word)"
        if let wb = wallBefore, let wa = wallAfter { out += " · wall \(Format.percent(wb)) → \(Format.percent(wa))" }
        out += "\n\nGross freed \(Format.bytes(grossFreedBytes)); net \(Format.bytes(headlineBytes)).\n\n"
        out += "_\(Receipt.methodNote)_\n"
        return out
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DownloadMoreRAM/receipts", isDirectory: true)
    }

    /// Writes `<id>.json` and `<id>.md`; returns the JSON URL.
    @discardableResult
    public func save(to directory: URL = Receipt.defaultDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appendingPathComponent("\(id).json")
        try Receipt.encoder.encode(self).write(to: json, options: .atomic)
        try markdown().write(to: directory.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
        return json
    }

    public static func load(_ url: URL) throws -> Receipt {
        try decoder.decode(Receipt.self, from: Data(contentsOf: url))
    }

    /// The most recent saved receipt, if any.
    public static func latest(in directory: URL = Receipt.defaultDirectory) -> Receipt? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let newest = files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first
        else { return nil }
        return try? load(newest)
    }

    static func makeID(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.string(from: date)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
