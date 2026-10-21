import AppKit
import RAMKit
import SwiftUI

/// The shareable souvenir (DESIGN.md v2 section 6): a paper thermal receipt on charcoal, one line per lever,
/// the total, the wall and swap before → after, the machine; beside it the payoff numeral and the stick fully
/// lit. 1200 x 675. No session titles, paths or project names ever appear (levers name apps and tools only).
struct ShareCardView: View {
    var receipt: Receipt

    static let size = CGSize(width: 1200, height: 675)
    private let p = Theme.dark

    var body: some View {
        let r = receipt
        let (number, unit) = ReceiptRows.split(r.headlineBytes)
        ZStack {
            RadialGradient(colors: [Theme.fixed("#1E1E22"), Theme.fixed("#0E0E10")], center: .init(x: 0.7, y: 0.4),
                           startRadius: 40, endRadius: 900)
            HStack(alignment: .center, spacing: 64) {
                ThermalReceipt(receipt: r)
                    .frame(width: 440)
                    .rotationEffect(.degrees(-2.2))
                    .shadow(color: .black.opacity(0.55), radius: 30, y: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text("DOWNLOAD MORE RAM").font(.system(size: 18, weight: .semibold)).tracking(3).foregroundStyle(p.ink2)
                    if r.headlineBytes > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("+" + number).font(.system(size: 118, weight: .light).monospacedDigit()).foregroundStyle(p.frost)
                                .kerning(-3)
                            Text(" " + unit).font(.system(size: 48, weight: .light)).foregroundStyle(p.frost)
                        }
                        .padding(.top, 10)
                        Text("of RAM downloaded").font(.system(size: 30, weight: .light)).foregroundStyle(p.ink)
                    } else {
                        Text("Nothing came back").font(.system(size: 64, weight: .light)).foregroundStyle(p.ink).padding(.top, 10)
                        Text("this time, measured").font(.system(size: 30, weight: .light)).foregroundStyle(p.ink2)
                    }
                    MemoryStick(mode: r.headlineBytes > 0 ? .done : .rest(percent: r.wallAfter ?? 0, imminent: false), height: 110, palette: p)
                        .padding(.top, 36)
                    Text("github.com/PikaChewey/download-more-ram").font(.system(size: 20, weight: .medium)).foregroundStyle(p.ink3)
                        .padding(.top, 28)
                }
                .frame(width: 520, alignment: .leading)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
    }
}

/// The paper slip: SF Mono on warm paper, dashed rules, torn top and bottom edges.
struct ThermalReceipt: View {
    var receipt: Receipt
    private let paper = Theme.fixed("#F6F3EA")
    private let ink = Theme.fixed("#1A1A18")
    private let faint = Theme.fixed("#6B6860")

    var body: some View {
        let r = receipt
        let levers = (r.levers ?? []).filter { $0.bytes != nil }
        VStack(alignment: .leading, spacing: 0) {
            Text("DOWNLOAD MORE RAM").font(.system(size: 22, weight: .bold, design: .monospaced)).frame(maxWidth: .infinity)
            Text("RECEIPT  \(Self.date(r.startedAt))").font(.system(size: 15, design: .monospaced)).foregroundStyle(faint)
                .frame(maxWidth: .infinity).padding(.top, 6)
            Rule().padding(.vertical, 14)
            ForEach(levers, id: \.kind) { l in
                line(LeverResultRow.shortTitle(l.kind).uppercased(), Format.bytes(l.bytes ?? 0, signed: true))
            }
            Rule().padding(.vertical, 14)
            line(r.headlineBytes > 0 ? "TOTAL BACK" : "TOTAL", Format.bytes(max(0, r.headlineBytes)), bold: true)
            Rule().padding(.vertical, 14)
            if let b = r.wallBefore, let a = r.wallAfter {
                line("WALL", "\(Format.percent(b)) → \(Format.percent(a))", faded: true)
            }
            line("SWAP", "\(Format.bytes(r.systemBefore.swapUsed)) → \(Format.bytes(r.systemAfter.swapUsed))", faded: true)
            Text(r.machine.summary.uppercased() + " · " + r.machine.osVersion.uppercased())
                .font(.system(size: 14, design: .monospaced)).foregroundStyle(faint).padding(.top, 8)
            Rule().padding(.vertical, 14)
            Text("MEASURED WITH PHYS_FOOTPRINT\nNO TELEMETRY · THANK YOU")
                .font(.system(size: 14, design: .monospaced)).foregroundStyle(faint)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 30)
        .padding(.vertical, 34)
        .background(TornPaper().fill(paper))
    }

    private func line(_ left: String, _ right: String, bold: Bool = false, faded: Bool = false) -> some View {
        HStack {
            Text(left)
            Spacer(minLength: 12)
            Text(right)
        }
        .font(.system(size: bold ? 21 : 17, weight: bold ? .bold : .regular, design: .monospaced))
        .foregroundStyle(faded ? faint : ink)
        .padding(.vertical, 3)
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}

/// A dashed rule, like a till's.
struct Rule: View {
    var body: some View {
        Line().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5])).foregroundStyle(Theme.fixed("#B9B4A6")).frame(height: 1.5)
    }

    struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.width, y: rect.midY))
            return p
        }
    }
}

/// Paper with torn (sawtooth) top and bottom edges.
struct TornPaper: Shape {
    func path(in rect: CGRect) -> Path {
        let tooth: CGFloat = 10, depth: CGFloat = 6
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + depth))
        var x = rect.minX
        var up = true
        while x < rect.maxX {
            x = min(rect.maxX, x + tooth / 2)
            p.addLine(to: CGPoint(x: x, y: up ? rect.minY : rect.minY + depth))
            up.toggle()
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
        x = rect.maxX
        up = true
        while x > rect.minX {
            x = max(rect.minX, x - tooth / 2)
            p.addLine(to: CGPoint(x: x, y: up ? rect.maxY : rect.maxY - depth))
            up.toggle()
        }
        p.closeSubpath()
        return p
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
