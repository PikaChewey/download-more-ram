#if DEBUG
import AppKit
import RAMKit
import SwiftUI

/// Debug-only: `DownloadMoreRAM --render-ui <dir> [state ...]` renders every panel state offscreen at
/// 2x, light and dark, from the fake machine in SampleData, plus the glyph at several fill levels,
/// the share cards and a sample recording (`clip` also renders the mp4 from it). Review only; never
/// for marketing. Activation policy is prohibited; no window is ever ordered front.
@MainActor
enum Snapshots {
    static let pages = ["normal", "near-wall", "imminent", "paused", "no-helper", "installing", "levers", "expanded", "all",
                        "downloading", "downloading-levers", "receipt", "receipt-nothing", "receipt-shared"]
    static let glyphLevels = [0, 38, 72, 85, 96]

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--render-ui"), args.count > flag + 1 else { return false }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let only = Set(args.dropFirst(flag + 2))
        let suite = "ca.bryanyao.DownloadMoreRAM.render-ui"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let fixtures = Fixtures()

        // Panel first paint: from creating the panel view (data already loaded, as when the user clicks
        // the glyph) to its first finished offscreen render. A running app has already loaded SwiftUI
        // and fonts (the status item is drawn), so warm that up with an unrelated view.
        _ = renderImage(Text("Download More RAM").font(.system(size: 12)), appearance: .aqua)
        let first = makeModel("normal", fixtures: fixtures, defaults: defaults)
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = renderImage(PanelView(model: first), appearance: .aqua)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let median = samples.sorted()[samples.count / 2]
        try? String(format: "%.1f\n", samples[0]).write(to: dir.appendingPathComponent("first-paint-ms.txt"), atomically: true, encoding: .utf8)
        print(String(format: "first-paint-ms %.1f (median of 5: %.1f)", samples[0], median))

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for page in pages where only.isEmpty || only.contains(page) {
                let model = makeModel(page, fixtures: fixtures, defaults: defaults)
                write(renderImage(MaterialStandIn(content: PanelView(model: model)), appearance: appearance),
                      to: dir.appendingPathComponent("\(page)-\(name).png"))
            }
            if only.isEmpty || only.contains("glyph") {
                let strip = HStack(spacing: 16) {
                    ForEach(glyphLevels, id: \.self) { GlyphPreview(percent: Double($0), atWall: $0 >= 85, downloading: false, text: "\($0)%") }
                    GlyphPreview(percent: 38, atWall: false, downloading: true, frame: 1, text: "")
                    GlyphPreview(percent: 38, atWall: false, downloading: false, text: "")
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                write(renderImage(strip, appearance: appearance), to: dir.appendingPathComponent("glyph-strip-\(name).png"))
            }
        }
        if only.isEmpty || only.contains("share-card") {
            writeCard(fixtures.receiptLevers, to: dir.appendingPathComponent("share-card.png"))
            writeCard(fixtures.receipt, to: dir.appendingPathComponent("share-card-signal-only.png"))
            writeCard(fixtures.receiptNothing, to: dir.appendingPathComponent("share-card-nothing.png"))
        }
        if only.isEmpty || only.contains("recording") || only.contains("clip") {
            let url = dir.appendingPathComponent("sample-recording.json")
            try? SampleData.recordingJSON(receipt: fixtures.receiptLevers, progress: fixtures.progressLevers).write(to: url)
            print("wrote:", url.lastPathComponent, "(sample data)")
            if only.contains("clip") {
                _ = ClipRenderer.renderCLI(recordingPath: url.path, outPath: dir.appendingPathComponent("sample-clip.mp4").path)
            }
        }
        if only.contains("clip-frames") {
            // Stills of the clip at its beats, for review without playing the video.
            if let data = try? Data(contentsOf: dir.appendingPathComponent("sample-recording.json")) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let rec = try? decoder.decode(ClipRenderer.Recording.self, from: data) {
                    let clip = ClipData(rec)
                    for t in [0.0, 0.9, 2.0, 3.16, 5.0, 7.5, 8.6, 9.5, 12.5, 15.0, 17.0] {
                        if let cg = ClipRenderer.renderFrame(ClipScene(t: t, data: clip)) {
                            let rep = NSBitmapImageRep(cgImage: cg)
                            write(rep, to: dir.appendingPathComponent(String(format: "clip-%04.1fs.png", t)))
                        }
                    }
                }
            }
        }
        return true
    }

    /// Everything computed once: receipts and progress come from the real engine on a virtual clock.
    struct Fixtures {
        let receipt: Receipt
        let progress: [ReliefProgress]
        let receiptLevers: Receipt
        let progressLevers: [ReliefProgress]
        let receiptNothing: Receipt
        let systemNormal = SampleData.normalSystem()
        let wallNormal = SampleData.normalWall()
        let systemNear = SampleData.nearWallSystem()
        let wallNear = SampleData.nearWallWall()
        let systemImminent = SampleData.imminentSystem()
        let wallImminent = SampleData.imminentWall()
        let reportNormal: ProcessReport
        let reportLevers: ProcessReport
        let reportBusy: ProcessReport
        let reportPaused: ProcessReport

        init() {
            (receipt, progress) = SampleData.download(nothing: false)
            (receiptLevers, progressLevers) = SampleData.download(nothing: false, levers: [.firefoxGPU, .leftovers])
            (receiptNothing, _) = SampleData.download(nothing: true)
            reportNormal = SampleData.report(SampleData.Machine(busy: false, bigGPU: false), system: systemNormal, wall: wallNormal)
            reportLevers = SampleData.report(SampleData.Machine(busy: true, bigGPU: true), system: systemNormal, wall: wallNormal)
            reportBusy = SampleData.report(SampleData.Machine(busy: true, bigGPU: true), system: systemNear, wall: wallNear)
            reportPaused = SampleData.report(SampleData.Machine(busy: false, bigGPU: false, paused: true), system: systemNormal, wall: wallNormal)
        }

        /// The progress event nearest to `fraction` of the way through the window.
        func progress(_ list: [ReliefProgress], at fraction: Double) -> ReliefProgress? {
            list.min { abs($0.elapsed / max($0.total, 1) - fraction) < abs($1.elapsed / max($1.total, 1) - fraction) }
        }
    }

    static func makeModel(_ page: String, fixtures f: Fixtures, defaults: UserDefaults) -> AppModel {
        let model = AppModel(live: false, defaults: defaults)
        // One suite serves every page: clear what an earlier page set.
        for kind in LeverKind.allCases where kind != .kernelSignal { model.setAlways(kind, false) }
        model.system = f.systemNormal
        model.wall = f.wallNormal
        model.report = f.reportNormal
        model.availability = .helper(version: HelperConstants.version)
        switch page {
        case "near-wall":
            model.system = f.systemNear
            model.wall = f.wallNear
            model.report = f.reportBusy
        case "imminent":
            model.system = f.systemImminent
            model.wall = f.wallImminent
            model.report = f.reportBusy
        case "paused":
            model.report = f.reportPaused
        case "no-helper":
            model.availability = .unavailable(reason: ReliefError.notPermitted.description)
        case "installing":
            model.availability = .unavailable(reason: ReliefError.notPermitted.description)
            model.installing = true
        case "levers":
            model.report = f.reportLevers
            model.setAlways(.firefoxGPU, true)
        case "expanded":
            model.report = f.reportLevers
            model.expanded = [f.reportLevers.rows.first?.id ?? ""]
        case "all":
            model.report = f.reportBusy
            model.showAll = true
        case "downloading":
            model.page = .downloading
            model.downloading = true
            model.progress = f.progress(f.progress, at: 0.6)
        case "downloading-levers":
            model.page = .downloading
            model.downloading = true
            model.progress = f.progressLevers.last { $0.lever != nil }
        case "receipt":
            model.page = .receipt
            model.receipt = f.receiptLevers
        case "receipt-nothing":
            model.page = .receipt
            model.receipt = f.receiptNothing
        case "receipt-shared":
            model.page = .receipt
            model.receipt = f.receiptLevers
            model.shareNote = "Saved as \(ShareCard.fileName(f.receiptLevers)) and copied"
        default:
            break
        }
        return model
    }

    /// Runs async engine work to completion from the calling thread (render mode only).
    nonisolated static func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    final class ResultBox<T>: @unchecked Sendable { var value: T? }

    static func renderImage(_ view: some View, appearance: NSAppearance.Name) -> NSBitmapImageRep? {
        let dark = appearance == .darkAqua
        // A soft wallpaper behind the panel, so the panel's edge, shadow and translucency read as on a desk.
        let root = view
            .padding(24)
            .background(LinearGradient(colors: dark ? [Theme.fixed("#3B4252"), Theme.fixed("#1C1F26")] : [Theme.fixed("#C8D3E2"), Theme.fixed("#EEF1F5")],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: AnyView(root))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    static func write(_ rep: NSBitmapImageRep?, to url: URL) {
        guard let rep, let data = rep.representation(using: .png, properties: [:]) else {
            print("render failed:", url.lastPathComponent)
            return
        }
        try? data.write(to: url)
        print("rendered:", url.lastPathComponent, rep.pixelsWide, "x", rep.pixelsHigh)
    }

    static func writeCard(_ receipt: Receipt, to url: URL) {
        guard let data = ShareCard.pngData(receipt) else {
            print("render failed:", url.lastPathComponent)
            return
        }
        try? data.write(to: url)
        print("rendered:", url.lastPathComponent, Int(ShareCardView.size.width), "x", Int(ShareCardView.size.height))
    }
}

/// The status item as it appears in the menu bar: the template glyph in the label colour, or the ember
/// chip as drawn at the wall.
struct GlyphPreview: View {
    var percent: Double
    var atWall: Bool
    var downloading: Bool
    var frame: Int = 0
    var text: String

    var body: some View {
        let image = StatusGlyph.image(wallPercent: percent, atWall: atWall, downloading: downloading, frame: frame)
        HStack(spacing: 4) {
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .foregroundStyle(Theme.ink)
            if !text.isEmpty { Text(text).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }
}

/// Offscreen renders have no window material: this stands in for the popover material over a wallpaper (a
/// blurred mid tone under the panel's own tint), with the window shadow.
struct MaterialStandIn<Content: View>: View {
    var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous)
                .fill(scheme == .dark ? Theme.fixed("#2B2D33") : Theme.fixed("#E4E7EC")))
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.22), radius: 18, y: 8)
    }
}
#endif
