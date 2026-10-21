import AppKit

/// The menu bar item's image (DESIGN.md v2 section 4): Apple's own `memorychip` symbol, template, 14 pt.
/// While a download runs it alternates with `memorychip.fill` at the engine's 2 Hz (the text beside it counts
/// the measured amount). At the wall (>= 85% or imminent) it is the filled chip in ember, the only time the item
/// has colour, the way a low battery turns red. Nothing animates at rest.
enum StatusGlyph {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    static func image(wallPercent: Double, atWall: Bool = false, downloading: Bool = false, frame: Int = 0) -> NSImage {
        let filled = downloading ? frame % 2 == 1 : atWall
        let ember = atWall && !downloading
        let key = "\(filled ? "f" : "o")\(ember ? "e" : "t")"
        if let cached = cache[key] { return cached }
        let name = filled ? "memorychip.fill" : "memorychip"
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if ember { config = config.applying(NSImage.SymbolConfiguration(paletteColors: [Theme.nsColor("#FF6B47")])) }
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Download More RAM") ?? NSImage()
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = !ember
        cache[key] = image
        return image
    }

    static func dropCache() { cache = [:] }
}
