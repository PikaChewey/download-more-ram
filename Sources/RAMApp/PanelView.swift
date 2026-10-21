import AppKit
import RAMKit
import SwiftUI

/// The menu bar panel (DESIGN.md v2 section 5): a 360 pt instrument over the window's material, one page at
/// a time (main, downloading, receipt).
struct PanelView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .top) {
            switch model.page {
            case .main:
                MainView(model: model).transition(pageTransition)
            case .downloading:
                DownloadView(model: model).transition(pageTransition)
            case .receipt:
                ReceiptPanel(model: model).transition(pageTransition)
            }
        }
        .animation(reduceMotion ? Theme.crossFade : Theme.enter, value: model.page)
        .frame(width: Theme.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(reduceTransparency ? Theme.canvas : Theme.tint)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous)
            .strokeBorder(Theme.hairlineColor, lineWidth: 1))
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(model: model)
            MemoryStick(mode: .rest(percent: model.wall?.percent ?? 0, imminent: model.wall?.imminent ?? false))
                .padding(.top, 12)
            HeroView(model: model).padding(.top, 10)
            if !model.report.pausedApps.isEmpty {
                PausedBanner(model: model).padding(.top, 12)
            }
            if model.interruptedHold {
                HoldBanner(model: model).padding(.top, 12)
            }
            ActionBlock(model: model).padding(.top, 14)
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

/// `Memory` · `16 GB` (the chip in the tooltip) and the `…` menu.
struct PanelHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Memory").font(Theme.title).foregroundStyle(Theme.ink)
            Text(Machine.memory).font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(1)
                .help(Machine.summary)
            Spacer(minLength: 8)
            MoreMenu(model: model)
        }
        .frame(height: 24)
    }
}

/// "16 GB" and "16 GB · Apple M5", read once.
enum Machine {
    private static let info = MachineInfo.current()
    private static let gb = Int((Double(info.memoryBytes) / 1_073_741_824).rounded())
    static let memory: String = gb > 0 ? "\(gb) GB" : ""
    static let summary: String = gb > 0 ? "\(gb) GB · \(info.chip)" : info.chip
}

/// The one numeral: distance to the wall, light, with a small unit; what it is in one short caption; the
/// time to the wall as a pill. The reason sits in the tooltip, not on the panel.
struct HeroView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let wall = model.wall
        let pct = wall.map { Int($0.percent.rounded()) }
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(pct.map(String.init) ?? "–").font(Theme.hero).foregroundStyle(Theme.atWall(wall) ? Theme.ember : Theme.ink)
                    .tracking(-1.5)
                Text("%").font(Theme.heroUnit).foregroundStyle(Theme.ink2).padding(.leading, 1)
                Spacer(minLength: 8)
                Pill(text: eta(wall), color: Theme.atWall(wall) ? Theme.ember : Theme.ink2)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 8 }
            }
            Text("to the out-of-memory wall").font(Theme.small).foregroundStyle(Theme.ink2)
        }
        .help(wall?.reason ?? "")
        .accessibilityElement(children: .combine)
    }

    /// The pill names what it measures: when the wall arrives, or that it is not coming.
    private func eta(_ wall: WallStatus?) -> String {
        guard let wall else { return "measuring" }
        if wall.imminent { return "wall any second" }
        if let eta = wall.etaSeconds { return "wall in ~\(Self.rough(eta))" }
        return "steady"
    }

    /// 7 min, 45 s, 2 h: a pill is read at a glance, not to the second.
    static func rough(_ s: Double) -> String {
        if s < 90 { return "\(max(5, Int((s / 5).rounded()) * 5)) s" }
        if s < 3600 { return "\(Int((s / 60).rounded())) min" }
        return "\(Int((s / 3600).rounded())) h"
    }
}

/// "macOS paused 3 apps · their helpers burn 6.0 cores" + Resume, in ember.
struct PausedBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let r = model.report
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.ember)
            VStack(alignment: .leading, spacing: 1) {
                Text("macOS paused \(r.pausedApps.count) app\(r.pausedApps.count == 1 ? "" : "s")")
                    .font(Theme.bodyMedium).foregroundStyle(Theme.ink)
                if r.pausedCores >= 0.5 {
                    Text(String(format: "their helpers burn %.1f cores", r.pausedCores)).font(Theme.small).foregroundStyle(Theme.ink2)
                }
            }
            Spacer(minLength: 8)
            Button(model.resuming ? "Resuming…" : "Resume") { model.resumePaused() }
                .buttonStyle(TintButtonStyle(color: Theme.ember))
                .disabled(model.resuming)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ember.opacity(0.12)))
    }
}

struct HoldBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 14)).foregroundStyle(Theme.amber)
            Text("Pressure may still be simulated").font(Theme.small).foregroundStyle(Theme.ink).lineLimit(2)
            Spacer(minLength: 8)
            if case .helper = model.availability {
                Button("Restore") { model.restoreHold() }.buttonStyle(QuietButtonStyle())
            } else {
                Text("sudo ram restore").font(Theme.mono).foregroundStyle(Theme.ink2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
    }
}

/// The one primary action. It blinks for 90 ms before the download page opens (the menu-item blink).
struct ActionBlock: View {
    @ObservedObject var model: AppModel
    @State private var blink = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                Text(label)
            }
        }
        .buttonStyle(PrimaryButtonStyle(enabled: enabled, blink: blink))
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }

    private var enabled: Bool { model.availability != nil && !model.installing && !model.downloading }

    private var unavailable: Bool {
        if case .unavailable = model.availability { return true }
        return false
    }

    private var symbol: String { unavailable ? "lock.open" : "arrow.down" }

    private var label: String {
        if model.installing { return "Installing helper…" }
        return unavailable ? "Install helper to download" : "Download More RAM"
    }

    private func act() {
        guard model.availability != nil else { return }
        if unavailable {
            model.installHelper()
            return
        }
        Blink.run($blink) { model.download(trigger: .user) }
    }
}

/// The 90 ms off/on blink shared by every control that opens the download page.
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
