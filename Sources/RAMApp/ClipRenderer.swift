import AppKit
import AVFoundation
import CoreVideo
import CryptoKit
import RAMKit
import SwiftUI

/// `DownloadMoreRAM --render-clip <recording.json> <out.mp4>`: the 18 s hero clip (DESIGN.md section 6)
/// rendered offscreen at 1080x1350 (4:5), 30 fps, from a recording `ram download --record` wrote. Every
/// number is the recording's: the starting wall percent, the panel's rows, the live count, the lever
/// results, the receipt. No screen recording, no sound. A JSON sidecar next to the mp4 names the
/// recording and its sha256.
@MainActor
enum ClipRenderer {
    struct Frame: Decodable {
        var t: Double
        var phase: String
        var reclaimed: Int64
        var rate: Double
        var elapsed: Double
        var total: Double
        var lever: String?
    }

    struct Recording: Decodable {
        var command: String?
        var frames: [Frame]
        var receipt: Receipt
    }

    /// 4:5 portrait, the tallest shape the X feed shows uncropped, so the panel can fill the width.
    static let pixelWidth = 1080
    static let pixelHeight = 1350
    static let fps = 30
    static let seconds = 18.0
    /// The 360 pt panel is drawn at 2.6x: it spans 87% of the frame and 11 pt text is 29 px, readable
    /// in a phone feed (the whole panel plus the menu bar still fits the 519 pt height).
    static let scale: CGFloat = 2.6
    static var pointWidth: CGFloat { CGFloat(pixelWidth) / scale }
    static var pointHeight: CGFloat { CGFloat(pixelHeight) / scale }

    /// The beats, in clip seconds. Cold open: the panel is up on the first frame and the download is
    /// moving before 1 s (feeds autoplay muted and people scroll on), then payoff, receipt, end card.
    enum Beat {
        static let highlight = 0.0
        static let panelIn = -0.3
        static let press = 0.25
        static let blinkOff = 0.37
        static let blinkOn = 0.46
        static let sheet = 0.55
        static let download0 = 0.7
        static let leverPhase = 5.6
        static let payoff = 6.6
        static let receipt = 8.6
        static let close = 14.4
        static let lowerNumber = 14.5
        static let end = 15.0
    }

    enum Failure: Error, CustomStringConvertible {
        case noFrames, writer(String), pixelBuffer, render
        var description: String {
            switch self {
            case .noFrames: "the recording has no frames"
            case .writer(let why): "AVAssetWriter: \(why)"
            case .pixelBuffer: "could not create a pixel buffer"
            case .render: "a frame did not render"
            }
        }
    }

    static func renderCLI(recordingPath: String, outPath: String) -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: recordingPath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let recording = try decoder.decode(Recording.self, from: data)
            let out = URL(fileURLWithPath: outPath)
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            let frames = try render(recording, to: out)
            let sidecar: [String: Any] = [
                "recording": recordingPath,
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                "output": out.lastPathComponent,
                "frames": frames, "fps": fps, "seconds": seconds, "size": "\(pixelWidth)x\(pixelHeight)",
                "headline": ReceiptRows.headline(recording.receipt),
                "renderer": "DownloadMoreRAM --render-clip",
            ]
            let json = try JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: out.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
            print("rendered: \(out.path) \(frames) frames, \(pixelWidth)x\(pixelHeight) @ \(fps) fps, from \(recordingPath)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("render-clip failed: \(error)\n".utf8))
            return 1
        }
    }

    /// Writes the mp4; returns the frame count.
    static func render(_ recording: Recording, to url: URL) throws -> Int {
        guard !recording.frames.isEmpty else { throw Failure.noFrames }
        let data = ClipData(recording)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth, AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: pixelWidth, kCVPixelBufferHeightKey as String: pixelHeight,
        ])
        guard writer.canAdd(input) else { throw Failure.writer("cannot add the video input") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "startWriting failed") }
        writer.startSession(atSourceTime: .zero)

        let count = Int(seconds * Double(fps))
        for i in 0..<count {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            let t = Double(i) / Double(fps)
            guard let image = renderFrame(ClipScene(t: t, data: data)) else { throw Failure.render }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.pixelBuffer }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure.pixelBuffer }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                // Pool buffers come back with old contents: start every frame from opaque black.
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) else {
                throw Failure.writer(writer.error?.localizedDescription ?? "append failed at frame \(i)")
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw Failure.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)") }
        return count
    }

    /// One frame: the scene hosted offscreen in dark appearance, drawn at `scale`.
    static func renderFrame(_ scene: ClipScene) -> CGImage? {
        let host = NSHostingView(rootView: AnyView(scene.environment(\.colorScheme, .dark)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: pointWidth, height: pointHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pointWidth, height: pointHeight)
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }
}

/// Everything the scene needs, derived once from the recording.
@MainActor
final class ClipData {
    let receipt: Receipt
    let frames: [ClipRenderer.Frame]
    let model: AppModel
    let wallBefore: Int
    let wallAfter: Int
    /// Recording time where the signal starts (the 2 s baseline before it is measured, not shown)
    /// and where its window ends (the last frame before levers or `done`).
    let holdStart: Double
    let signalEnd: Double
    let leverFrames: [ClipRenderer.Frame]
    let extraLevers: [LeverResult]
    let clock: String
    /// Page heights measured once per page state (see `panelHeight(at:)`).
    var heights: [String: CGFloat] = [:]

    init(_ r: ClipRenderer.Recording) {
        receipt = r.receipt
        frames = r.frames
        wallBefore = Int((r.receipt.wallBefore ?? 0).rounded())
        wallAfter = Int((r.receipt.wallAfter ?? r.receipt.wallBefore ?? 0).rounded())
        leverFrames = r.frames.filter { $0.lever != nil }
        extraLevers = (r.receipt.levers ?? []).filter { $0.kind != .kernelSignal }
        let signalFrames = r.frames.filter { $0.lever == nil && $0.phase != "done" }
        signalEnd = signalFrames.last?.t ?? r.frames.last?.t ?? 1
        holdStart = min(signalEnd, r.frames.first { $0.phase == "holding" }?.t ?? 0)
        clock = r.receipt.startedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened))

        let model = AppModel(live: false, defaults: UserDefaults(suiteName: "ca.bryanyao.DownloadMoreRAM.clip") ?? .standard)
        model.system = r.receipt.systemBefore
        var wm = WallModel()
        wm.add(r.receipt.systemBefore)
        model.wall = wm.status()
        model.availability = .helper(version: HelperConstants.version)
        model.report = Self.report(r.receipt)
        model.report.offers = Self.offers(r.receipt)
        self.model = model
    }

    /// The panel's rows before the download: every app's `before` footprint from the receipt.
    static func report(_ r: Receipt) -> ProcessReport {
        let all = r.apps + r.excludedBusy
        var rows: [AppRow] = []
        for a in all where a.before > 0 {
            let session = a.kind == .agentSession
            rows.append(AppRow(id: "\(a.id)", kind: session ? .session : .app, name: a.name,
                               detail: session ? "agent session" : nil, archived: false, footprint: a.before,
                               processCount: 1, iconPath: session ? nil : appPath(a.name), members: []))
        }
        rows.sort { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.id < $1.id }
        let total = all.reduce(UInt64(0)) { $0 + $1.before }
        return ProcessReport(timestamp: r.startedAt, rows: rows, totalFootprint: total,
                             appCount: rows.filter { $0.kind == .app }.count, sessionCount: rows.filter { $0.kind == .session }.count,
                             sessions: [], leftovers: [], duplicates: [], offers: [], insights: nil, pausedApps: [], pausedCores: 0)
    }

    /// The tiles before the press: the levers the recording ran, with the estimate the planner shows (for
    /// the GPU restart, the GPU process's size before it, from the lever's own detail line).
    static func offers(_ r: Receipt) -> [LeverOffer] {
        (r.levers ?? []).filter { $0.kind != .kernelSignal }.map { l in
            var estimate: UInt64?
            if let detail = l.detail, let arrow = detail.range(of: " →"),
               let start = detail.range(of: "GPU process ")?.upperBound, start < arrow.lowerBound {
                estimate = Format.parseBytes(String(detail[start..<arrow.lowerBound]))
            }
            return LeverOffer(kind: l.kind, estimateBytes: estimate, reason: l.title)
        }
    }

    /// The app's bundle on this Mac, for its icon (nothing is drawn for apps that are not installed).
    static func appPath(_ name: String) -> String? {
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices"] {
            let path = "\(dir)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Recorded progress at recording time `t`, with the count interpolated between samples.
    func progress(at t: Double) -> ReliefProgress {
        let f = frames.filter { $0.lever == nil }
        guard let first = f.first else { return ReliefProgress(phase: .baseline, elapsed: 0, total: 1, reclaimedSoFar: 0, rateBytesPerSec: 0, topApps: []) }
        var a = first
        var b = first
        for frame in f {
            if frame.t <= t { a = frame } else { b = frame; break }
        }
        let span = max(0.001, b.t - a.t)
        let k = b.t > a.t ? min(1, max(0, (t - a.t) / span)) : 1
        let reclaimed = Int64(Double(a.reclaimed) + (Double(b.reclaimed) - Double(a.reclaimed)) * k)
        let elapsed = a.elapsed + (b.elapsed - a.elapsed) * k
        let phase = ReliefProgress.Phase(rawValue: a.phase) ?? .holding
        return ReliefProgress(phase: phase, elapsed: elapsed, total: a.total, reclaimedSoFar: reclaimed,
                              rateBytesPerSec: a.rate, topApps: [])
    }
}

private typealias Beat = ClipRenderer.Beat

extension ClipData {
    // MARK: Timeline (shared by the panel and the menu bar strip)

    /// Recording time for the sheet: the signal window stretched from `download0` to `leverPhase` (or
    /// to `payoff` when no lever ran), then the levers landing until the payoff.
    func sheetProgress(at t: Double) -> ReliefProgress {
        let hasLevers = !extraLevers.isEmpty
        let windowEnd = hasLevers ? Beat.leverPhase : Beat.payoff
        if t < windowEnd {
            let k = max(0, (t - Beat.download0) / (windowEnd - Beat.download0))
            return progress(at: holdStart + k * (signalEnd - holdStart))
        }
        // Lever phase: the receipt's results landing in order.
        var p = progress(at: signalEnd)
        p.phase = .settling
        let k = min(1, (t - windowEnd) / (Beat.payoff - windowEnd))
        let n = extraLevers.count
        let landed = min(n, Int(k * Double(n) + 0.0001))
        let signal = (receipt.levers ?? []).filter { $0.kind == .kernelSignal }
        p.leversDone = signal + Array(extraLevers.prefix(landed))
        p.lever = landed < n ? extraLevers[landed].kind : nil
        p.reclaimedSoFar = p.leversDone.compactMap(\.bytes).reduce(0, +)
        if landed == n { p.phase = .done; p.reclaimedSoFar = receipt.headlineBytes }
        return p
    }

    func chipFraction(at t: Double) -> Double {
        let end = extraLevers.isEmpty ? Beat.payoff : Beat.leverPhase
        if t < end { return max(0, (t - Beat.download0) / (end - Beat.download0)) }
        return 1
    }

    // MARK: Panel height

    /// The panel's height at `t`: each page's own height, eased across a page change, the way the real
    /// panel resizes with its content (a cut reads as a glitch at 30 fps).
    func panelHeight(at t: Double) -> CGFloat {
        guard t >= Beat.sheet else { return mainHeight }
        if t < Beat.payoff { return Self.mix(mainHeight, sheetHeight(around: t), (t - Beat.sheet) / 0.28) }
        let sheetEnd = sheetHeight(at: Beat.payoff - 0.001)
        if t < Beat.receipt { return Self.mix(sheetEnd, payoffHeight, (t - Beat.payoff) / 0.28) }
        return Self.mix(payoffHeight, receiptHeight, (t - Beat.receipt) / 0.32)
    }

    private static func mix(_ a: CGFloat, _ b: CGFloat, _ x: Double) -> CGFloat {
        let k = min(1, max(0, x))
        return a + (b - a) * CGFloat(k * k * (3 - 2 * k))
    }

    /// The sheet grows a row as each lever lands: the last 0.24 s averaged, so the growth eases in.
    private func sheetHeight(around t: Double) -> CGFloat {
        let samples = [0, 0.08, 0.16, 0.24].map { max(Beat.sheet, t - $0) }
        return samples.map { sheetHeight(at: $0) }.reduce(0, +) / CGFloat(samples.count)
    }

    private func sheetHeight(at t: Double) -> CGFloat {
        let p = sheetProgress(at: t)
        let key = "sheet|\(p.phase.rawValue)|\(p.leversDone.count)|\(p.lever?.rawValue ?? "-")"
        return measured(key) { SheetBody(progress: p, reduceMotion: true, chipFraction: chipFraction(at: t)) }
    }

    var mainHeight: CGFloat { measured("main") { ClipMain(model: model, pressed: false, blink: false) } }
    var payoffHeight: CGFloat { measured("payoff") { PayoffView(receipt: receipt) } }
    var receiptHeight: CGFloat { measured("receipt") { ReceiptCard(receipt: receipt, shareNote: nil, share: {}, done: {}) } }

    /// A page's own height at the panel's width, laid out the way a frame is (dark, offscreen), once.
    private func measured<V: View>(_ key: String, _ view: () -> V) -> CGFloat {
        if let h = heights[key] { return h }
        let host = NSHostingView(rootView: view().frame(width: Theme.width).environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        let h = host.fittingSize.height
        heights[key] = h
        return h
    }
}

/// The whole frame at clip time `t`: the desk, the menu bar strip, the panel on its page, the end card.
/// The frame is top-aligned: the menu bar is always in shot, and the main page (taller than the frame
/// at this scale) runs off the bottom into a fade.
struct ClipScene: View {
    var t: Double
    var data: ClipData

    var body: some View {
        let downloading = t >= Beat.download0 && t < Beat.receipt
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                MenuBarStrip(percent: t < Beat.lowerNumber ? data.wallBefore : data.wallAfter,
                             atWall: data.wallBefore >= 85, highlighted: t >= Beat.highlight && t < Beat.close,
                             clock: data.clock,
                             count: downloading ? Format.bytes(data.sheetProgress(at: t).reclaimedSoFar, signed: true) : nil,
                             frame: Int(t * 2))
                if t >= Beat.panelIn, t < Beat.close + 0.2 {
                    let enter = Spring.value((t - Beat.panelIn) / 0.3)
                    let exit = t >= Beat.close ? min(1, (t - Beat.close) / 0.12) : 0
                    ClipPanel(t: t, data: data)
                        .scaleEffect(0.97 + 0.03 * enter - 0.02 * exit, anchor: .top)
                        .opacity(enter * (1 - exit))
                        .padding(.top, 6)
                }
            }
            if t >= Beat.end {
                EndCard().opacity(min(1, (t - Beat.end) / 0.3))
            }
        }
        .frame(width: ClipRenderer.pointWidth, height: ClipRenderer.pointHeight, alignment: .top)
        .background(ClipDesk())
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [ClipDesk.bottom.opacity(0), ClipDesk.bottom], startPoint: .top, endPoint: .bottom)
                .frame(height: 64)
                .opacity(t >= Beat.end ? 0 : 1)
        }
        .clipped()
    }
}

/// The desk under the panel: a dark, cool gradient with a faint frost glow, the clip's only backdrop.
struct ClipDesk: View {
    static let top = Theme.fixed("#2A2F3C")
    static let bottom = Theme.fixed("#101216")

    var body: some View {
        LinearGradient(colors: [Self.top, Self.bottom], startPoint: .top, endPoint: .bottom)
            .overlay(RadialGradient(colors: [Theme.fixed("#9ED8FF").opacity(0.10), .clear],
                                    center: UnitPoint(x: 0.78, y: 0.12), startRadius: 0, endRadius: 320))
    }
}

/// Critically damped spring (response 0.30 s), position 0 → 1 over `x` in units of the response.
enum Spring {
    static func value(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        let w = 2 * Double.pi * x   // omega * t with t in units of the response time
        return min(1, 1 - (1 + w) * exp(-w))
    }
}

/// A drawn menu bar: the status item as the app draws it (the chip and the wall percent, or the live
/// count while a download runs), the system's own symbols and the recording's start time. Nothing else
/// is invented.
struct MenuBarStrip: View {
    var percent: Int
    var atWall: Bool
    var highlighted: Bool
    var clock: String
    /// `+31.4 MB` while a download runs, in place of the percent.
    var count: String? = nil
    /// The engine's 2 Hz beat: the chip alternates outline and filled while counting.
    var frame: Int = 0

    var body: some View {
        let glyph = StatusGlyph.image(wallPercent: Double(percent), atWall: atWall, downloading: count != nil, frame: frame)
        HStack(spacing: 14) {
            Image(systemName: "apple.logo").font(.system(size: 13)).foregroundStyle(Theme.ink)
            Spacer()
            HStack(spacing: 5) {
                Image(nsImage: glyph)
                    .renderingMode(glyph.isTemplate ? .template : .original)
                    .foregroundStyle(Theme.ink)
                Text(count ?? "\(percent)%").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(highlighted ? Theme.ink.opacity(0.18) : Color.clear))
            Image(systemName: "wifi").font(.system(size: 12)).foregroundStyle(Theme.ink)
            Image(systemName: "battery.75percent").font(.system(size: 13)).foregroundStyle(Theme.ink)
            Text(clock).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Theme.hairlineColor)
    }
}

/// The panel at clip time `t`: main (press + blink), sheet, payoff, receipt. Pages hand over in sequence
/// (the old one fades out in 0.12 s, then the new one rises 6 pt as it fades in, as in the app) while the
/// panel's height eases to the new page.
struct ClipPanel: View {
    var t: Double
    var data: ClipData

    var body: some View {
        ZStack(alignment: .top) {
            if t < Beat.sheet + 0.12 {
                ClipMain(model: data.model, pressed: t >= Beat.press && t < Beat.blinkOff, blink: t >= Beat.blinkOff && t < Beat.blinkOn)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(Self.fadeOut(t, from: Beat.sheet))
            }
            if t >= Beat.sheet + Self.handover, t < Beat.payoff + 0.12 {
                let k = Self.fadeIn(t - Beat.sheet - Self.handover)
                SheetBody(progress: data.sheetProgress(at: t), reduceMotion: true, chipFraction: data.chipFraction(at: t))
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: 6 * (1 - k))
                    .opacity(k * Self.fadeOut(t, from: Beat.payoff))
            }
            if t >= Beat.payoff + Self.handover, t < Beat.receipt + 0.12 {
                let k = Self.fadeIn(t - Beat.payoff - Self.handover)
                PayoffView(receipt: data.receipt)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: 6 * (1 - k))
                    .opacity(k * Self.fadeOut(t, from: Beat.receipt))
            }
            if t >= Beat.receipt + Self.handover {
                let k = Spring.value((t - Beat.receipt - Self.handover) / 0.35)
                ReceiptCard(receipt: data.receipt, shareNote: nil, share: {}, done: {})
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: -24 * (1 - k))
                    .opacity(k)
            }
        }
        .frame(width: Theme.width, height: data.panelHeight(at: t), alignment: .top)
        .background(Theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous).strokeBorder(Theme.hairlineColor, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    /// The next page starts once the last one is gone (its fade-out is 0.12 s).
    static let handover = 0.12

    /// 0 → 1 over 0.18 s, eased.
    static func fadeIn(_ dt: Double) -> Double {
        let x = min(1, max(0, dt / 0.18))
        return x * x * (3 - 2 * x)
    }

    /// 1 → 0 over 0.12 s from `start`.
    static func fadeOut(_ t: Double, from start: Double) -> Double {
        t < start ? 1 : 1 - min(1, (t - start) / 0.12)
    }
}

/// The main page with the press and the blink forced from the timeline (the same layout as `MainView`).
struct ClipMain: View {
    @ObservedObject var model: AppModel
    var pressed: Bool
    var blink: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(model: model)
            MemoryStick(mode: .rest(percent: model.wall?.percent ?? 0, imminent: model.wall?.imminent ?? false))
                .padding(.top, 12)
            HeroView(model: model).padding(.top, 10)
            Button {} label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down").font(.system(size: 13, weight: .bold))
                    Text("Download More RAM")
                }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: true, blink: blink, pressed: pressed))
            .padding(.top, 14)
            if LeverTiles.hasTiles(model) {
                LeverTiles(model: model).padding(.top, 8)
            }
            WhereItIs(model: model).padding(.top, 18)
            FooterView(model: model).padding(.top, 10)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

/// "921.2 MB back": the payoff beat between the sheet and the receipt.
struct PayoffView: View {
    var receipt: Receipt

    var body: some View {
        let r = receipt
        let (number, unit) = ReceiptRows.split(r.headlineBytes)
        VStack(spacing: 14) {
            MemoryStick(mode: r.headlineBytes > 0 ? .done : .rest(percent: r.wallAfter ?? 0, imminent: false))
            if r.headlineBytes > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("+" + number).font(Theme.payoff).foregroundStyle(Theme.frost).kerning(-1)
                    Text(" " + unit).font(Theme.heroUnit).foregroundStyle(Theme.frost)
                    Text(" back").font(Theme.heroUnit).foregroundStyle(Theme.ink2)
                }
            } else {
                Text("Nothing came back").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.ink)
            }
            HStack(spacing: 12) {
                if let b = r.wallBefore, let a = r.wallAfter { Text("wall \(Format.percent(b)) → \(Format.percent(a))") }
                Text("swap \(Format.bytes(r.systemBefore.swapUsed)) → \(Format.bytes(r.systemAfter.swapUsed))")
            }
            .font(Theme.mono).foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 28)
    }
}

/// "Download More RAM · free · native", over the stick lit in frost.
struct EndCard: View {
    private let p = Theme.dark

    var body: some View {
        ZStack {
            p.canvas
            VStack(spacing: 18) {
                // Wide enough for full-size LEDs (a narrow stick shrinks its dots to specks).
                MemoryStick(mode: .done, height: 58, palette: p).frame(width: 330)
                Text("Download More RAM").font(.system(size: 36, weight: .semibold)).foregroundStyle(p.ink)
                Text("free · native").font(.system(size: 18)).foregroundStyle(p.ink2)
                Text("github.com/PikaChewey/download-more-ram").font(.system(size: 14)).foregroundStyle(p.ink3)
            }
        }
    }
}
