import AppKit
import RAMKit
import SwiftUI

/// The menu bar panel (DESIGN.md section 5): 360 pt, opaque canvas, one page at a time.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            switch model.page {
            case .main:
                MainView(model: model)
                    .transition(.opacity)
            case .downloading:
                DownloadSheet(model: model)
                    .transition(.opacity)
            case .receipt:
                ReceiptView(model: model)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(reduceMotion ? Theme.crossFade : Theme.spring, value: model.page)
        .frame(width: Theme.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel))
        .tint(Theme.ink2)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeroView(model: model)
            if !model.report.pausedApps.isEmpty {
                PausedLine(model: model)
            }
            Hairline()
            if model.interruptedHold {
                HoldNotice(model: model)
                Hairline()
            }
            ActionBlock(model: model)
            if !model.offers.isEmpty {
                Hairline()
                LeversBlock(model: model)
            }
            Hairline()
            WhereYourRAMIs(model: model)
            Hairline()
            FooterView(model: model)
        }
    }
}

/// Hero: the one numeral, the bar, one reason line, the ETA. Red only at the wall.
struct HeroView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let wall = model.wall
        let pct = wall?.percent ?? 0
        let red = Theme.atWall(wall)
        let ink = red ? Theme.danger : Theme.ink
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(wall.map { Format.percent($0.percent) } ?? "–")
                    .font(Theme.hero)
                    .foregroundStyle(ink)
                    .kerning(-1.5)
                Text("to the wall").font(Theme.body).foregroundStyle(Theme.ink2)
                Spacer(minLength: 8)
                Text(eta(wall))
                    .font(Theme.smallNumber)
                    .foregroundStyle(red ? Theme.danger : Theme.ink3)
                    .multilineTextAlignment(.trailing)
            }
            Bar(fraction: pct / 100, height: 4, fill: ink)
            Text(wall?.reason ?? " ")
                .font(Theme.small).foregroundStyle(Theme.ink2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private func eta(_ wall: WallStatus?) -> String {
        guard let wall else { return "" }
        if wall.imminent { return "can appear any second" }
        if let eta = wall.etaSeconds { return "~\(Format.duration(eta)) at this rate" }
        return "not climbing"
    }
}

/// "macOS paused 5 apps · their helpers burn 6.0 cores" + Resume (the one place the red token appears
/// away from the wall numeral).
struct PausedLine: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let r = model.report
        HStack(spacing: 8) {
            Text(text(r)).font(Theme.small.weight(.medium)).foregroundStyle(Theme.danger)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(model.resuming ? "Resuming…" : "Resume") { model.resumePaused() }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .disabled(model.resuming)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 12)
    }

    private func text(_ r: ProcessReport) -> String {
        let n = r.pausedApps.count
        var s = "macOS paused \(n) app\(n == 1 ? "" : "s")"
        if r.pausedCores >= 0.5 { s += String(format: " · their helpers burn %.1f cores", r.pausedCores) }
        return s
    }
}

struct HoldNotice: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Simulated memory pressure may still be on from an interrupted download")
                .font(Theme.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if case .helper = model.availability {
                Button("Restore") { model.restoreHold() }.buttonStyle(QuietButtonStyle())
            } else {
                Text("sudo ram restore").font(Theme.mono).foregroundStyle(Theme.ink)
            }
        }
        .padding(.horizontal, Theme.gutter).padding(.vertical, 8)
    }
}

/// The one primary action. It blinks off/on for 90 ms before the sheet opens (the menu-item blink).
struct ActionBlock: View {
    @ObservedObject var model: AppModel
    @State private var blink = false

    var body: some View {
        Button(action: act) { Text(label) }
            .buttonStyle(PrimaryButtonStyle(enabled: enabled, blink: blink))
            .disabled(!enabled)
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 12)
    }

    private var enabled: Bool { model.availability != nil && !model.installing && !model.downloading }

    private var label: String {
        if model.installing { return "Installing helper…" }
        guard let availability = model.availability else { return "Download More RAM" }
        if case .unavailable = availability { return "Install helper to download" }
        return "Download More RAM"
    }

    private func act() {
        guard let availability = model.availability else { return }
        if case .unavailable = availability {
            model.installHelper()
            return
        }
        Blink.run($blink) { model.download(trigger: .user) }
    }
}

/// The 90 ms off/on blink shared by every control that opens the sheet.
enum Blink {
    @MainActor static func run(_ blink: Binding<Bool>, then action: @escaping @MainActor () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { blink.wrappedValue = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Theme.blinkMs)) {
            MainActor.assumeIsolated {
                withTransaction(t) { blink.wrappedValue = false }
                action()
            }
        }
    }
}
