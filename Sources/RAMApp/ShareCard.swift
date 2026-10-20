import AppKit
import RAMKit
import SwiftUI

/// The shareable receipt: a 1200x675 PNG on the dark tokens with the payoff, one row per lever,
/// the machine, swap and wall before → after, and the repo. No session titles, paths or project
/// names ever appear (lever rows name apps and tools only).
struct ShareCardView: View {
    var receipt: Receipt

    static let size = CGSize(width: 1200, height: 675)
    private let p = Theme.dark

    var body: some View {
        let r = receipt
        let levers = (r.levers ?? []).prefix(4)
        let rows = ReceiptRows.merged(r.apps).filter { !$0.name.contains("/") && !$0.name.hasPrefix("~") }.prefix(4)
        ZStack(alignment: .topLeading) {
            p.canvas
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Download More RAM").font(.system(size: 26, weight: .medium)).foregroundStyle(p.ink2)
                        if r.headlineBytes > 0 {
                            HStack(alignment: .lastTextBaseline, spacing: 20) {
                                Text(Format.bytes(r.headlineBytes)).font(.system(size: 116, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(p.accent).kerning(-3)
                                Text("back").font(.system(size: 54, weight: .medium)).foregroundStyle(p.ink2)
                            }
                        } else {
                            Text("Nothing came back this time").font(.system(size: 64, weight: .semibold)).foregroundStyle(p.ink)
                                .lineLimit(1).minimumScaleFactor(0.7).padding(.top, 18)
                        }
                    }
                    Spacer(minLength: 0)
                    DIMMMark(fill: 1, arrow: true, color: p.ink).frame(width: 190, height: 140).padding(.top, 8)
                }
                Spacer(minLength: 16)
                VStack(alignment: .leading, spacing: 14) {
                    if !levers.isEmpty {
                        ForEach(levers, id: \.kind) { l in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 24) {
                                    Text(l.title).font(.system(size: 30, weight: .medium)).foregroundStyle(p.ink).lineLimit(1)
                                    Spacer(minLength: 16)
                                    Text(l.bytes.map { Format.bytes($0, signed: true) } ?? "—")
                                        .font(.system(size: 30, weight: .medium, design: .monospaced).monospacedDigit())
                                        .foregroundStyle((l.bytes ?? 0) > 0 ? p.accent : p.ink2)
                                }
                                if let detail = l.detail, !detail.isEmpty {
                                    Text(detail).font(.system(size: 21)).foregroundStyle(p.ink2).lineLimit(1)
                                }
                            }
                        }
                    } else if !rows.isEmpty {
                        let maxDelta = rows.map { max(0, $0.delta) }.max() ?? 1
                        ForEach(rows) { row in
                            HStack(spacing: 24) {
                                Text(row.name).font(.system(size: 30, weight: .medium)).foregroundStyle(p.ink)
                                    .lineLimit(1).frame(width: 330, alignment: .leading)
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4).fill(p.surface).frame(height: 14)
                                    if row.delta > 0 {
                                        RoundedRectangle(cornerRadius: 4).fill(p.accent)
                                            .frame(width: max(8, 480 * Double(row.delta) / Double(max(1, maxDelta))), height: 14)
                                    }
                                }
                                .frame(width: 480)
                                Text(Format.bytes(row.delta, signed: true)).font(.system(size: 30, weight: .medium, design: .monospaced).monospacedDigit())
                                    .foregroundStyle(row.delta > 0 ? p.accent : p.ink2).frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    } else {
                        Text("No app changed its footprint during the window.").font(.system(size: 30)).foregroundStyle(p.ink2)
                    }
                }
                Spacer(minLength: 16)
                Rectangle().fill(p.hairline).frame(height: 1).padding(.bottom, 18)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 20) {
                        Text("\(r.machine.summary) · \(r.machine.osVersion)").font(.system(size: 24, weight: .medium)).foregroundStyle(p.ink)
                        Text("swap \(Format.bytes(r.systemBefore.swapUsed)) → \(Format.bytes(r.systemAfter.swapUsed))")
                            .font(.system(size: 24, design: .monospaced).monospacedDigit()).foregroundStyle(p.ink2)
                        if let b = r.wallBefore, let a = r.wallAfter {
                            Text("wall \(Format.percent(b)) → \(Format.percent(a))").font(.system(size: 24, design: .monospaced).monospacedDigit()).foregroundStyle(p.ink2)
                        }
                        Spacer()
                    }
                    HStack {
                        Text("macOS's own memory-pressure signal · phys_footprint, per app")
                            .font(.system(size: 20)).foregroundStyle(p.ink3).lineLimit(1)
                        Spacer(minLength: 24)
                        Text("github.com/PikaChewey/download-more-ram").font(.system(size: 20, weight: .medium)).foregroundStyle(p.ink2)
                            .lineLimit(1).fixedSize()
                    }
                }
            }
            .padding(.horizontal, 64).padding(.top, 50).padding(.bottom, 44)
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

    /// `DownloadMoreRAM --render-share <receipt.json|recording.json> <out.png>`: the card from a saved
    /// receipt, or from the receipt inside a `ram download --record` file (docs/share-card.png is made
    /// this way from the same real recording as the clip). Returns the exit code.
    static func renderCLI(receiptPath: String, outPath: String) -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            let url = URL(fileURLWithPath: receiptPath)
            let receipt: Receipt
            if let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], object["frames"] != nil {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                receipt = try decoder.decode(ClipRenderer.Recording.self, from: Data(contentsOf: url)).receipt
            } else {
                receipt = try Receipt.load(url)
            }
            guard let data = pngData(receipt) else { throw Failure.render }
            let out = URL(fileURLWithPath: outPath)
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: out, options: .atomic)
            print("rendered: \(out.path) \(Int(ShareCardView.size.width))x\(Int(ShareCardView.size.height)) from \(receipt.id) (\(ReceiptRows.headline(receipt)))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("render-share failed: \(error)\n".utf8))
            return 1
        }
    }
}
