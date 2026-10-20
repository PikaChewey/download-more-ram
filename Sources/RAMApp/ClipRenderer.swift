import AppKit
import AVFoundation
import CoreVideo
import CryptoKit
import RAMKit
import SwiftUI

/// `DownloadMoreRAM --render-clip <recording.json> <out.mp4>`: the 18 s hero clip (DESIGN.md section 6)
/// rendered offscreen at 1080x1080, 30 fps, from a recording `ram download --record` wrote. Every
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

    static let pixels = 1080
    static let fps = 30
    static let seconds = 18.0
    /// Logical points per frame edge: the 360 pt panel is rendered at 2x (11 pt text = 22 px).
    static let scale: CGFloat = 2
    static var points: CGFloat { CGFloat(pixels) / scale }

    /// The beats, in clip seconds.
    enum Beat {
        static let highlight = 0.55
        static let panelIn = 0.75
        static let press = 3.0
        static let blinkOff = 3.12
        static let blinkOn = 3.21
        static let sheet = 3.35
        static let download0 = 3.6
        static let leverPhase = 8.2
        static let payoff = 9.0
        static let receipt = 11.0
        static let close = 14.0
        static let lowerNumber = 14.3
        static let end = 16.0
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
                "frames": frames, "fps": fps, "seconds": seconds, "size": "\(pixels)x\(pixels)",
                "headline": ReceiptRows.headline(recording.receipt),
                "renderer": "DownloadMoreRAM --render-clip",
            ]
            let json = try JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: out.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
            print("rendered: \(out.path) \(frames) frames, \(pixels)x\(pixels) @ \(fps) fps, from \(recordingPath)")
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
            AVVideoWidthKey: pixels, AVVideoHeightKey: pixels,
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
            kCVPixelBufferWidthKey as String: pixels, kCVPixelBufferHeightKey as String: pixels,
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
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: pixels, height: pixels, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
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

    /// One frame: the scene hosted offscreen in dark appearance, drawn at 2x.
    static func renderFrame(_ scene: ClipScene) -> CGImage? {
        let host = NSHostingView(rootView: AnyView(scene.environment(\.colorScheme, .dark)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: points, height: points)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: points, height: points)
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
    /// Recording time where the signal window ends (the last frame before levers or `done`).
    let signalEnd: Double
    let leverFrames: [ClipRenderer.Frame]
    let extraLevers: [LeverResult]
    let clock: String

    init(_ r: ClipRenderer.Recording) {
        receipt = r.receipt
        frames = r.frames
        wallBefore = Int((r.receipt.wallBefore ?? 0).rounded())
        wallAfter = Int((r.receipt.wallAfter ?? r.receipt.wallBefore ?? 0).rounded())
        leverFrames = r.frames.filter { $0.lever != nil }
        extraLevers = (r.receipt.levers ?? []).filter { $0.kind != .kernelSignal }
        let signalFrames = r.frames.filter { $0.lever == nil && $0.phase != "done" }
        signalEnd = signalFrames.last?.t ?? r.frames.last?.t ?? 1
        clock = r.receipt.startedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened))

        let model = AppModel(live: false, defaults: UserDefaults(suiteName: "ca.bryanyao.DownloadMoreRAM.clip") ?? .standard)
        model.system = r.receipt.systemBefore
        var wm = WallModel()
        wm.add(r.receipt.systemBefore)
        model.wall = wm.status()
        model.availability = .helper(version: HelperConstants.version)
        model.report = Self.report(r.receipt)
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

/// The whole frame at clip time `t`: desktop, menu bar strip, the panel on its page, the end card.
struct ClipScene: View {
    var t: Double
    var data: ClipData

    private let p = Theme.dark

    var body: some View {
        let side = ClipRenderer.points
        ZStack(alignment: .top) {
            p.surface
            VStack(spacing: 0) {
                MenuBarStrip(percent: t < Beat.lowerNumber ? data.wallBefore : data.wallAfter,
                             atWall: data.wallBefore >= 85, highlighted: t >= Beat.highlight && t < Beat.close,
                             clock: data.clock)
                ZStack(alignment: .top) {
                    if t >= Beat.panelIn, t < Beat.close + 0.2 {
                        let enter = Spring.value((t - Beat.panelIn) / 0.3)
                        let exit = t >= Beat.close ? min(1, (t - Beat.close) / 0.12) : 0
                        ClipPanel(t: t, data: data)
                            .scaleEffect(0.97 + 0.03 * enter - 0.02 * exit, anchor: .top)
                            .opacity(enter * (1 - exit))
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }
            if t >= Beat.end {
                EndCard().opacity(min(1, (t - Beat.end) / 0.3))
            }
        }
        .frame(width: side, height: side)
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

/// A drawn menu bar: the template DIMM glyph with the real wall percent, the system's own symbols
/// and the recording's start time. Nothing else is invented.
struct MenuBarStrip: View {
    var percent: Int
    var atWall: Bool
    var highlighted: Bool
    var clock: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.logo").font(.system(size: 13)).foregroundStyle(Theme.ink)
            Spacer()
            HStack(spacing: 5) {
                Image(nsImage: StatusGlyph.image(wallPercent: Double(percent), atWall: atWall)).renderingMode(.template)
                    .foregroundStyle(Theme.ink)
                Text("\(percent)%").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink)
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

/// The panel at clip time `t`: main (press + blink), sheet, payoff, receipt.
struct ClipPanel: View {
    var t: Double
    var data: ClipData

    var body: some View {
        ZStack(alignment: .top) {
            if t < Beat.sheet + 0.2 {
                ClipMain(model: data.model, pressed: t >= Beat.press && t < Beat.blinkOff, blink: t >= Beat.blinkOff && t < Beat.blinkOn)
                    .opacity(t < Beat.sheet ? 1 : 1 - (t - Beat.sheet) / 0.2)
            }
            if t >= Beat.sheet, t < Beat.payoff + 0.2 {
                SheetBody(progress: sheetProgress, reduceMotion: true, chipFraction: chipFraction)
                    .padding(12)
                    .background(Theme.surface)
                    .opacity(min(1, (t - Beat.sheet) / 0.2) * (t < Beat.payoff ? 1 : 1 - (t - Beat.payoff) / 0.2))
            }
            if t >= Beat.payoff, t < Beat.receipt + 0.2 {
                PayoffView(receipt: data.receipt)
                    .opacity(min(1, (t - Beat.payoff) / 0.2) * (t < Beat.receipt ? 1 : 1 - (t - Beat.receipt) / 0.2))
            }
            if t >= Beat.receipt {
                let slide = Spring.value((t - Beat.receipt) / 0.35)
                ReceiptCard(receipt: data.receipt, shareNote: nil, share: {}, done: {})
                    .padding(12)
                    .background(Theme.surface)
                    .offset(y: -420 * (1 - slide))
                    .opacity(slide)
            }
        }
        .frame(width: Theme.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel).strokeBorder(Theme.hairlineColor, lineWidth: Theme.hairline))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    /// Recording time for the sheet: the signal window stretched over 3.6-8.2 s (or to 9.0 s when
    /// no lever ran), then the levers landing until the payoff.
    private var sheetProgress: ReliefProgress {
        let hasLevers = !data.extraLevers.isEmpty
        let signalEnd = hasLevers ? Beat.leverPhase : Beat.payoff
        if t < signalEnd {
            let k = max(0, (t - Beat.download0) / (signalEnd - Beat.download0))
            return data.progress(at: k * data.signalEnd)
        }
        // Lever phase: recorded beats if the recording has them, else the receipt's results landing in order.
        var p = data.progress(at: data.signalEnd)
        p.phase = .settling
        let k = min(1, (t - signalEnd) / (Beat.payoff - signalEnd))
        let n = data.extraLevers.count
        let landed = min(n, Int(k * Double(n) + 0.0001))
        let signal = (data.receipt.levers ?? []).filter { $0.kind == .kernelSignal }
        p.leversDone = signal + Array(data.extraLevers.prefix(landed))
        p.lever = landed < n ? data.extraLevers[landed].kind : nil
        p.reclaimedSoFar = p.leversDone.compactMap(\.bytes).reduce(0, +)
        if landed == n { p.phase = .done; p.reclaimedSoFar = data.receipt.headlineBytes }
        return p
    }

    private var chipFraction: Double {
        let end = data.extraLevers.isEmpty ? Beat.payoff : Beat.leverPhase
        if t < end { return max(0, (t - Beat.download0) / (end - Beat.download0)) }
        return 1
    }
}

/// The main page with the press and the blink forced from the timeline.
struct ClipMain: View {
    @ObservedObject var model: AppModel
    var pressed: Bool
    var blink: Bool

    var body: some View {
        VStack(spacing: 0) {
            HeroView(model: model)
            Hairline()
            Button {} label: { Text("Download More RAM") }
                .buttonStyle(PrimaryButtonStyle(enabled: true, blink: blink, pressed: pressed))
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 12)
            Hairline()
            WhereYourRAMIs(model: model)
            Hairline()
            FooterView(model: model)
        }
    }
}

/// "921.2 MB back": the payoff beat between the sheet and the receipt.
struct PayoffView: View {
    var receipt: Receipt

    var body: some View {
        let r = receipt
        VStack(spacing: 10) {
            if r.headlineBytes > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Format.bytes(r.headlineBytes)).font(Theme.hero).foregroundStyle(Theme.accent).kerning(-1.5)
                    Text("back").font(.system(size: 20)).foregroundStyle(Theme.ink2)
                }
            } else {
                Text("Nothing came back this time").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            HStack(spacing: 12) {
                if let b = r.wallBefore, let a = r.wallAfter { Text("wall \(Format.percent(b)) → \(Format.percent(a))") }
                Text("swap \(Format.bytes(r.systemBefore.swapUsed)) → \(Format.bytes(r.systemAfter.swapUsed))")
            }
            .font(Theme.monoBody).foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

/// "Download More RAM · free · native".
struct EndCard: View {
    private let p = Theme.dark

    var body: some View {
        ZStack {
            p.canvas
            VStack(spacing: 18) {
                DIMMMark(fill: 1, arrow: true, color: p.ink).frame(width: 120, height: 92)
                Text("Download More RAM").font(.system(size: 36, weight: .semibold)).foregroundStyle(p.ink)
                Text("free · native").font(.system(size: 18)).foregroundStyle(p.ink2)
                Text("github.com/PikaChewey/download-more-ram").font(.system(size: 14)).foregroundStyle(p.ink3)
            }
        }
    }
}
