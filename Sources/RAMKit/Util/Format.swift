import Foundation

public enum Format {
    /// Decimal units like Activity Monitor: "4.11 GB", "97.3 MB", "512 KB".
    public static func bytes<T: BinaryInteger>(_ raw: T, signed: Bool = false) -> String {
        let value = Int64(clamping: raw)
        let sign = value < 0 ? "-" : (signed && value > 0 ? "+" : "")
        let v = Double(value.magnitude)
        let body: String
        if v >= 1e9 { body = String(format: "%.2f GB", v / 1e9) }
        else if v >= 1e6 { body = String(format: "%.1f MB", v / 1e6) }
        else if v >= 1e3 { body = String(format: "%.0f KB", v / 1e3) }
        else { body = "\(Int64(v)) B" }
        return sign + body
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
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }

    public static func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }
}
