import AppKit
import RAMKit
import SwiftUI

/// The shareable receipt: a 1200x675 PNG with the headline, per-app bars, machine summary, swap
/// before/after and the repo. No session labels, paths or project names (privacy).
struct ShareCardView: View {
    var receipt: Receipt

    static let size = CGSize(width: 1200, height: 675)
    private let background = Color(red: 0.067, green: 0.067, blue: 0.075)
    private let dim = Color(white: 0.62)
    private let faint = Color(white: 0.22)
    private let accent = Color(red: 0.25, green: 0.56, blue: 1.0)

    var body: some View {
        let rows = ReceiptRows.merged(receipt.apps).filter { !$0.name.contains("/") && !$0.name.hasPrefix("~") }.prefix(5)
        let maxDelta = rows.map { max(0, $0.delta) }.max() ?? 1
        ZStack(alignment: .topLeading) {
            background
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        if receipt.headlineBytes > 0 {
                            Text("Downloaded").font(.system(size: 34, weight: .medium)).foregroundStyle(dim)
                            HStack(alignment: .lastTextBaseline, spacing: 18) {
                                Text(Format.bytes(receipt.headlineBytes)).font(.system(size: 104, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                                Text("of RAM").font(.system(size: 54, weight: .semibold)).foregroundStyle(dim)
                            }
                        } else {
                            Text("Download More RAM").font(.system(size: 34, weight: .medium)).foregroundStyle(dim)
                            Text("Nothing came back this time").font(.system(size: 72, weight: .bold)).foregroundStyle(.white)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    Spacer(minLength: 0)
                    DIMMMark(fill: 1, arrow: true).frame(width: 200, height: 150).padding(.top, 6)
                }
                Spacer(minLength: 24)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(rows) { row in
                        HStack(spacing: 24) {
                            Text(row.name).font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
                                .lineLimit(1).frame(width: 330, alignment: .leading)
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4).fill(faint).frame(height: 18)
                                if row.delta > 0 {
                                    RoundedRectangle(cornerRadius: 4).fill(accent)
                                        .frame(width: max(8, 500 * Double(row.delta) / Double(max(1, maxDelta))), height: 18)
                                }
                            }
                            .frame(width: 500)
                            Text(Format.bytes(row.delta, signed: true)).font(.system(size: 30, weight: .medium, design: .monospaced).monospacedDigit())
                                .foregroundStyle(row.delta > 0 ? .white : dim).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    if rows.isEmpty {
                        Text("No app changed its footprint during the window.").font(.system(size: 30)).foregroundStyle(dim)
                    }
                }
                Spacer(minLength: 24)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 18) {
                        Text("\(receipt.machine.summary) · \(receipt.machine.osVersion)").font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                        Text("swap \(Format.bytes(receipt.systemBefore.swapUsed)) → \(Format.bytes(receipt.systemAfter.swapUsed))")
                            .font(.system(size: 24, design: .monospaced).monospacedDigit()).foregroundStyle(dim)
                        if let b = receipt.wallBefore, let a = receipt.wallAfter {
                            Text("wall \(Format.percent(b)) → \(Format.percent(a))").font(.system(size: 24, design: .monospaced).monospacedDigit()).foregroundStyle(dim)
                        }
                        Spacer()
                    }
                    HStack {
                        Text("macOS's own memory-pressure signal · measured with phys_footprint")
                            .font(.system(size: 20)).foregroundStyle(dim).lineLimit(1)
                        Spacer(minLength: 24)
                        Text("github.com/PikaChewey/download-more-ram").font(.system(size: 20, weight: .medium)).foregroundStyle(dim)
                            .lineLimit(1).fixedSize()
                    }
                }
            }
            .padding(.horizontal, 64).padding(.top, 54).padding(.bottom, 48)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
    }
}

/// The RAM stick as a vector mark: body, chips, pins, key notch, and an optional arrow coming down into it.
struct DIMMMark: View {
    var fill: Double
    var arrow: Bool
    var color: Color = .white

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let stickH = h * 0.42
            let stick = CGRect(x: 0, y: h - stickH, width: w, height: stickH)
            let line = max(2, w * 0.03)
            ctx.stroke(Path(roundedRect: stick, cornerRadius: w * 0.06), with: .color(color), lineWidth: line)
            let chipCount = 4
            let gap = w * 0.05
            let chipW = (w - gap * CGFloat(chipCount + 1)) / CGFloat(chipCount)
            let chipH = stickH * 0.42
            for i in 0..<chipCount {
                let chip = CGRect(x: stick.minX + gap + CGFloat(i) * (chipW + gap), y: stick.minY + stickH * 0.16, width: chipW, height: chipH)
                let f = max(0, min(1, fill * Double(chipCount) - Double(i)))
                ctx.stroke(Path(roundedRect: chip, cornerRadius: w * 0.012), with: .color(color), lineWidth: line * 0.6)
                if f > 0 {
                    ctx.fill(Path(roundedRect: CGRect(x: chip.minX, y: chip.minY, width: chip.width * f, height: chip.height), cornerRadius: w * 0.012), with: .color(color))
                }
            }
            let pinY = stick.maxY - stickH * 0.3
            let pinH = stickH * 0.16
            let pinCount = 14
            let pinStep = (w - gap * 2) / CGFloat(pinCount)
            for i in 0..<pinCount where i != 9 {
                let x = stick.minX + gap + CGFloat(i) * pinStep + pinStep * 0.25
                ctx.fill(Path(CGRect(x: x, y: pinY, width: pinStep * 0.5, height: pinH)), with: .color(color))
            }
            if arrow {
                let cx = w / 2
                let top = h * 0.02
                let bottom = stick.minY - h * 0.1
                var shaft = Path()
                shaft.move(to: CGPoint(x: cx, y: top))
                shaft.addLine(to: CGPoint(x: cx, y: bottom))
                ctx.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: line * 1.6, lineCap: .round))
                var head = Path()
                let half = w * 0.14
                head.move(to: CGPoint(x: cx - half, y: bottom - half))
                head.addLine(to: CGPoint(x: cx, y: bottom))
                head.addLine(to: CGPoint(x: cx + half, y: bottom - half))
                ctx.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: line * 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

@MainActor
enum ShareCard {
    private static var cached: (key: String, image: CGImage)?

    static func cgImage(_ receipt: Receipt) -> CGImage? {
        let key = "\(receipt.id)/\(receipt.headlineBytes)/\(receipt.apps.count)"
        if let cached, cached.key == key { return cached.image }
        let renderer = ImageRenderer(content: ShareCardView(receipt: receipt))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(ShareCardView.size)
        guard let image = renderer.cgImage else { return nil }
        cached = (key, image)
        return image
    }

    static func pngData(_ receipt: Receipt) -> Data? {
        guard let cg = cgImage(receipt) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// "RAM-2.41GB.png", "RAM-nothing.png".
    static func fileName(_ receipt: Receipt) -> String {
        guard receipt.headlineBytes > 0 else { return "RAM-nothing.png" }
        return "RAM-" + Format.bytes(receipt.headlineBytes).replacingOccurrences(of: " ", with: "") + ".png"
    }

    enum Failure: Error, LocalizedError {
        case render
        var errorDescription: String? { "the card did not render" }
    }

    /// Writes the card to ~/Downloads (the RAM lands in Downloads), copies it to the clipboard, returns the file.
    static func export(_ receipt: Receipt, directory: URL? = nil) throws -> URL {
        guard let data = pngData(receipt), let cg = cgImage(receipt) else { throw Failure.render }
        let dir = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = fileName(receipt)
        var url = dir.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(base.replacingOccurrences(of: ".png", with: "-\(n).png"))
            n += 1
        }
        try data.write(to: url, options: .atomic)
        let image = NSImage(cgImage: cg, size: ShareCardView.size)
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([image, url as NSURL])
        return url
    }

    static func dropCache() { cached = nil }
}
