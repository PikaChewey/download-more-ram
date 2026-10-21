import RAMKit
import SwiftUI

/// The signature object (DESIGN.md v2 section 5.2): a RAM stick drawn as 8 chips of 4 x 4 dot cells on a
/// board, with contact pins and the key notch. Cells light column by column, left to right, so the stick
/// reads as a gauge at rest (the wall percent, in its temperature) and as the download's progress bar
/// while a download runs (frost, with a brighter write head at the edge). Drawn in one Canvas pass;
/// nothing moves unless `mode` changes.
struct MemoryStick: View {
    enum Mode: Equatable {
        /// Distance to the wall, 0...100.
        case rest(percent: Double, imminent: Bool)
        /// Download progress, 0...1.
        case downloading(fraction: Double)
        /// Every cell in frost (the payoff).
        case done
    }

    var mode: Mode
    var height: CGFloat = 64
    /// Fixed palette for offscreen renders (share card, clip); nil follows the appearance.
    var palette: Theme.Palette? = nil
    @Environment(\.colorScheme) private var scheme

    static let chips = 8
    static let side = 4
    static var columns: Int { chips * side }
    static var cellCount: Int { columns * side }

    var body: some View {
        let p = palette ?? (scheme == .dark ? Theme.dark : Theme.light)
        let (litColumns, color, head) = state(p)
        Canvas { ctx, size in
            // The board runs the full height and its bottom strip is the edge connector (contacts printed on
            // the board, the key notch cut into its edge): one object, not a meter over a second bar.
            let board = CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1)
            let connector: CGFloat = 9
            let boardPath = Path(roundedRect: board, cornerRadius: 8, style: .continuous)
            ctx.fill(boardPath, with: .color(p.surface))
            ctx.stroke(boardPath, with: .color(p.stroke), lineWidth: 1)

            // Chips: 8 packages, evenly spaced above the connector.
            let margin: CGFloat = 9, gap: CGFloat = 6
            let chipW = (board.width - 2 * margin - CGFloat(Self.chips - 1) * gap) / CGFloat(Self.chips)
            let chipH = board.height - margin - connector - 3
            let dot = min((chipW - 8) / CGFloat(Self.side) - 2, (chipH - 8) / CGFloat(Self.side) - 2)
            let dotGapX = (chipW - 8 - dot * CGFloat(Self.side)) / CGFloat(Self.side - 1)
            let dotGapY = (chipH - 8 - dot * CGFloat(Self.side)) / CGFloat(Self.side - 1)
            var lit: [CGRect] = []
            for chip in 0..<Self.chips {
                let cx = board.minX + margin + CGFloat(chip) * (chipW + gap)
                let chipRect = CGRect(x: cx, y: board.minY + margin, width: chipW, height: chipH)
                ctx.fill(Path(roundedRect: chipRect, cornerRadius: 4, style: .continuous), with: .color(p.surface))
                for col in 0..<Self.side {
                    let column = chip * Self.side + col
                    for row in 0..<Self.side {
                        let r = CGRect(x: chipRect.minX + 4 + CGFloat(col) * (dot + dotGapX),
                                       y: chipRect.minY + 4 + CGFloat(row) * (dot + dotGapY), width: dot, height: dot)
                        let path = Path(roundedRect: r, cornerRadius: 1.5)
                        if column < litColumns {
                            let isHead = head && column == litColumns - 1
                            ctx.fill(path, with: .color(isHead ? p.ink : color))
                            lit.append(r)
                        } else {
                            ctx.fill(path, with: .color(p.ink3.opacity(0.22)))
                        }
                    }
                }
            }
            // A faint glow under the lit cells: LEDs, not paint.
            if !lit.isEmpty {
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 4))
                    for r in lit { layer.fill(Path(roundedRect: r.insetBy(dx: -1, dy: -1), cornerRadius: 2), with: .color(color.opacity(0.35))) }
                }
            }

            // Contacts along the bottom edge, inside the board, with the key notch about 62% along.
            let pins = 34
            let pinArea = CGRect(x: board.minX + 16, y: board.maxY - connector + 2, width: board.width - 32, height: connector - 4)
            let step = pinArea.width / CGFloat(pins)
            let notch = Int(Double(pins) * 0.62)
            for i in 0..<pins where i != notch {
                let r = CGRect(x: pinArea.minX + CGFloat(i) * step + step * 0.25, y: pinArea.minY, width: step * 0.5, height: pinArea.height)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(p.ink3.opacity(0.30)))
            }
            var cut = ctx
            cut.blendMode = .clear
            let notchX = pinArea.minX + (CGFloat(notch) + 0.5) * step
            cut.fill(Path(roundedRect: CGRect(x: notchX - 3, y: board.maxY - 4, width: 6, height: 6), cornerRadius: 2.5), with: .color(.black))
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(accessibility)
    }

    /// Lit columns, their colour, and whether the last lit column is the write head.
    private func state(_ p: Theme.Palette) -> (Int, Color, Bool) {
        switch mode {
        case .rest(let percent, let imminent):
            let f = imminent ? 1 : max(0, min(1, percent / 100))
            let columns = f > 0 ? max(1, Int((f * Double(Self.columns)).rounded())) : 0
            return (columns, temperature(percent, imminent: imminent, p), false)
        case .downloading(let fraction):
            let f = max(0, min(1, fraction.isFinite ? fraction : 0))
            return (Int((f * Double(Self.columns)).rounded(.down)), p.frost, f > 0 && f < 1)
        case .done:
            return (Self.columns, p.frost, false)
        }
    }

    private func temperature(_ percent: Double, imminent: Bool, _ p: Theme.Palette) -> Color {
        if palette != nil {
            // Fixed palettes interpolate their own frost/amber/ember (always the dark set in renders).
            return Color(nsColor: Theme.temperatureNSColor(percent, imminent: imminent, dark: true))
        }
        return Color(nsColor: Theme.temperatureNSColor(percent, imminent: imminent, dark: scheme == .dark))
    }

    private var accessibility: String {
        switch mode {
        case .rest(let percent, let imminent):
            imminent ? "Memory: at the out-of-memory wall" : "Memory: \(Int(percent.rounded())) percent of the way to the out-of-memory wall"
        case .downloading(let fraction): "Downloading: \(Int((fraction * 100).rounded())) percent"
        case .done: "Download finished"
        }
    }
}
