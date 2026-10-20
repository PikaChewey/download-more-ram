import AppKit

/// The menu bar glyph, drawn in code as a template image: a RAM stick (DIMM) seen from the side,
/// a hairline body with four chips and a pin row with the key notch. The chips fill left to right
/// with the distance to the out-of-memory wall (38% = 1.5 chips). While a download runs one lit
/// chip walks along the stick (two frames a second, never otherwise).
enum StatusGlyph {
    static let size = NSSize(width: 22, height: 16)

    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    static func image(wallPercent: Double, downloading: Bool = false, frame: Int = 0) -> NSImage {
        let pct = max(0, min(100, wallPercent.isFinite ? wallPercent : 0))
        let key = downloading ? "d\(frame % 4)" : "p\(Int(pct.rounded()))"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: size, flipped: false) { _ in
            draw(percent: pct, downloading: downloading, frame: frame)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Download More RAM: \(Int(pct.rounded()))% to the wall"
        cache[key] = image
        return image
    }

    static func dropCache() { cache = [:] }

    private static func draw(percent: Double, downloading: Bool, frame: Int) {
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let body = NSRect(x: 1, y: 3, width: 20, height: 10)
        let outline = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1
        outline.stroke()

        // Pin row along the bottom edge, with the key notch two thirds along.
        for x in stride(from: 3.0, through: 19.0, by: 2.0) where x != 13 {
            NSBezierPath(rect: NSRect(x: x, y: 4.25, width: 1, height: 1.5)).fill()
        }

        // Four chips; each fills with its share of the wall percent.
        let chipCount = 4
        let chipSize: CGFloat = 3
        let gap: CGFloat = 1.5
        let totalWidth = CGFloat(chipCount) * chipSize + CGFloat(chipCount - 1) * gap
        let startX = body.midX - totalWidth / 2
        for i in 0..<chipCount {
            let chip = NSRect(x: startX + CGFloat(i) * (chipSize + gap), y: 7.5, width: chipSize, height: chipSize)
            let fraction: CGFloat
            if downloading {
                fraction = (frame % chipCount) == i ? 1 : 0
            } else {
                fraction = max(0, min(1, CGFloat(percent) / 100 * CGFloat(chipCount) - CGFloat(i)))
            }
            if fraction >= 0.999 {
                NSBezierPath(roundedRect: chip, xRadius: 0.5, yRadius: 0.5).fill()
            } else {
                let empty = NSBezierPath(roundedRect: chip.insetBy(dx: 0.25, dy: 0.25), xRadius: 0.5, yRadius: 0.5)
                empty.lineWidth = 0.5
                empty.stroke()
                if fraction > 0.05 {
                    let inner = chip.insetBy(dx: 0.5, dy: 0.5)
                    NSBezierPath(rect: NSRect(x: inner.minX, y: inner.minY, width: inner.width * fraction, height: inner.height)).fill()
                }
            }
        }
    }
}
