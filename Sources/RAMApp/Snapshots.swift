#if DEBUG
import AppKit
import RAMKit
import SwiftUI

/// Debug-only: `DownloadMoreRAM --render-ui <dir> [page ...]` renders every panel state offscreen at
/// 2x, light and dark, from the fake machine in SampleData, plus the share card and the glyph at
/// several fill levels, then quits. Activation policy is prohibited; no window is ever ordered front.
@MainActor
enum Snapshots {
    static let pages = ["normal", "near-wall", "imminent", "no-helper", "installing", "downloading", "receipt",
                        "receipt-nothing", "receipt-shared", "sections", "sections-full", "confirm", "autopilot"]
    static let glyphLevels = [0, 38, 72, 91]

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
        // the glyph) to its first finished offscreen render. Median of 5. A running app has already
        // loaded SwiftUI and fonts (the status item is drawn), so warm that up with an unrelated view.
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
                write(renderImage(PanelView(model: model), appearance: appearance), to: dir.appendingPathComponent("\(page)-\(name).png"))
                Theme.maxHeight = 720
                Theme.sectionsMaxHeight = 300
            }
            if only.isEmpty || only.contains("glyph") {
                for level in glyphLevels {
                    let view = GlyphPreview(percent: Double(level), downloading: false, text: "\(level)%")
                    write(renderImage(view, appearance: appearance), to: dir.appendingPathComponent("glyph-\(level)-\(name).png"))
                }
                let view = GlyphPreview(percent: 38, downloading: true, text: "")
                write(renderImage(view, appearance: appearance), to: dir.appendingPathComponent("glyph-downloading-\(name).png"))
                let strip = HStack(spacing: 14) {
                    ForEach(glyphLevels, id: \.self) { GlyphPreview(percent: Double($0), downloading: false, text: "\($0)%") }
                    GlyphPreview(percent: 0, downloading: true, text: "")
                }.padding(6)
                write(renderImage(strip, appearance: appearance), to: dir.appendingPathComponent("glyph-strip-\(name).png"))
            }
        }
        if only.isEmpty || only.contains("share-card") {
            writeCard(fixtures.receipt, to: dir.appendingPathComponent("share-card.png"))
            writeCard(fixtures.receiptNothing, to: dir.appendingPathComponent("share-card-nothing.png"))
        }
        return true
    }

    /// Everything computed once: receipts and progress come from the real engine on a virtual clock.
    struct Fixtures {
        let receipt: Receipt
        let progress: [ReliefProgress]
        let receiptNothing: Receipt
        let systemNormal = SampleData.normalSystem()
        let wallNormal = SampleData.normalWall()
        let systemNear = SampleData.nearWallSystem()
        let wallNear = SampleData.nearWallWall()
        let systemImminent = SampleData.imminentSystem()
        let wallImminent = SampleData.imminentWall()
        let reportNormal: ProcessReport
        let reportBusy: ProcessReport

        init() {
            (receipt, progress) = SampleData.download(nothing: false)
            (receiptNothing, _) = SampleData.download(nothing: true)
            reportNormal = SampleData.report(busy: false, system: systemNormal)
            reportBusy = SampleData.report(busy: true, system: systemNear)
        }

        /// The progress event nearest to 60% of the way through.
        var progress60: ReliefProgress? {
            progress.min { abs($0.elapsed / max($0.total, 1) - 0.6) < abs($1.elapsed / max($1.total, 1) - 0.6) }
        }
    }

    static func makeModel(_ page: String, fixtures f: Fixtures, defaults: UserDefaults) -> AppModel {
        let model = AppModel(live: false, defaults: defaults)
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
        case "no-helper":
            model.availability = .unavailable(reason: ReliefError.notPermitted.description)
        case "installing":
            model.availability = .unavailable(reason: ReliefError.notPermitted.description)
            model.installing = true
        case "downloading":
            model.page = .downloading
            model.downloading = true
            model.progress = f.progress60
        case "receipt":
            model.page = .receipt
            model.receipt = f.receipt
        case "receipt-nothing":
            model.page = .receipt
            model.receipt = f.receiptNothing
        case "receipt-shared":
            model.page = .receipt
            model.receipt = f.receipt
            model.shareNote = "Saved as \(ShareCard.fileName(f.receipt)) and copied"
        case "sections":
            model.report = f.reportBusy
        case "sections-full":
            model.report = f.reportBusy
            model.showAllApps = true
            Theme.maxHeight = 4000
            Theme.sectionsMaxHeight = 4000
        case "confirm":
            model.report = f.reportBusy
            model.expanded = ["app-500", "agent-claudeCode"]
            model.arm("firefox-unloader")
            if let http = f.reportBusy.leftovers.first(where: { $0.record.pid == 800 }) { model.quitAttempted.insert(http.id) }
            model.message = "Sent SIGTERM to Python (800)."
            Theme.maxHeight = 4000
            Theme.sectionsMaxHeight = 4000
        case "autopilot":
            model.autopilotOn = true
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
        let root = view
            .background(Color(white: dark ? 0.17 : 0.95))
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

/// The status item as it appears in the menu bar: template glyph, tinted like the status bar would.
struct GlyphPreview: View {
    var percent: Double
    var downloading: Bool
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: StatusGlyph.image(wallPercent: percent, downloading: downloading, frame: 1))
                .renderingMode(.template)
                .foregroundStyle(downloading ? Theme.primary : (Theme.wallColor(percent) ?? Theme.primary))
            if !text.isEmpty { Text(text).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.primary) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
#endif
