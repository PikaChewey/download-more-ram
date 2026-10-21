import Foundation

public enum Format {
    /// Binary units with Apple's labels, as Activity Monitor and the Force Quit dialog show them:
    /// 16 GiB of RAM reads "16.00 GB"; "97.3 MB" is 97.3 MiB.
    public static func bytes<T: BinaryInteger>(_ raw: T, signed: Bool = false) -> String {
        let value = Int64(clamping: raw)
        let sign = value < 0 ? "-" : (signed && value > 0 ? "+" : "")
        let v = Double(value.magnitude)
        let body: String
        let kib = 1024.0, mib = kib * 1024, gib = mib * 1024
        if v >= gib * 0.9995 { body = String(format: "%.2f GB", v / gib) }
        else if v >= mib * 0.9995 { body = String(format: "%.1f MB", v / mib) }
        else if v >= kib { body = String(format: "%.0f KB", v / kib) }
        else { body = "\(Int64(v)) B" }
        return sign + body
    }

    /// The inverse of `bytes` for its own output ("2.50 GB", "926.8 MB", "512 KB", "88 B"), binary units.
    public static func parseBytes(_ text: String) -> UInt64? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 2, let number = Double(parts[0].replacingOccurrences(of: "+", with: "")), number >= 0 else { return nil }
        let unit: Double
        switch parts[1] {
        case "GB": unit = 1024 * 1024 * 1024
        case "MB": unit = 1024 * 1024
        case "KB": unit = 1024
        case "B": unit = 1
        default: return nil
        }
        return UInt64((number * unit).rounded())
    }

    private static let partials: [Character] = ["▏", "▎", "▍", "▌", "▋", "▊", "▉"]

    /// A horizontal bar of `width` cells using eighth blocks for the fractional cell.
    public static func bar(fraction: Double, width: Int, empty: Character = " ") -> String {
        guard width > 0 else { return "" }
        let f = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        let eighths = Int((f * Double(width) * 8).rounded())
        let full = eighths / 8
        let rem = eighths % 8
        var s = String(repeating: "█", count: full)
        if full < width, rem > 0 { s.append(partials[rem - 1]) }
        return s + String(repeating: empty, count: max(0, width - s.count))
    }

    /// "6s", "1m 05s", "2h 03m".
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let s = Int(max(0, min(seconds, 1e9)).rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }

    public static func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }
}
