import AppKit
import RAMKit
import SwiftUI

/// The menu bar panel (spec 7): the wall, the button, the sections, the footer. 360 pt wide.
struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.page {
            case .main: MainView(model: model)
            case .downloading: DownloadSheet(model: model)
            case .receipt: ReceiptView(model: model)
            }
        }
        .frame(width: Theme.width)
        .frame(maxHeight: Theme.maxHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.secondary)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            WallHeader(model: model)
            Hairline()
            if model.interruptedHold {
                NoticeRow(text: "An interrupted download may have left simulated memory pressure on. Run  sudo ram restore")
                Hairline()
            }
            DownloadBlock(model: model)
            Hairline()
            ScrollView {
                VStack(spacing: 0) {
                    AppsSection(model: model)
                    AgentsSection(model: model)
                    LeftoversSection(model: model)
                    FirefoxSection(model: model)
                    GrowingSection(model: model)
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: Theme.sectionsMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            Hairline()
            FooterView(model: model)
        }
    }
}

/// Distance to "Your system has run out of application memory", and what macOS does there.
struct WallHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let wall = model.wall
        let pct = wall?.percent ?? 0
        let tint = Theme.wallColor(pct)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(wall.map { Format.percent($0.percent) } ?? "–")
                    .font(Theme.numberBig)
                    .foregroundStyle(tint ?? Theme.primary)
                Text("to the wall").font(Theme.body).foregroundStyle(Theme.secondary)
                Spacer()
                if let wall {
                    if wall.imminent {
                        Text("can appear any second").font(Theme.small.weight(.semibold)).foregroundStyle(Theme.red)
                    } else if let eta = wall.etaSeconds {
                        Text("~\(Format.duration(eta)) at this rate").font(Theme.small).foregroundStyle(tint ?? Theme.secondary)
                    } else {
                        Text("not climbing").font(Theme.small).foregroundStyle(Theme.tertiary)
                    }
                }
            }
            Meter(fraction: pct / 100, height: 5, tint: tint)
            if let wall {
                Text(wall.reason).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let next = model.report.insights?.nextToPauseApp {
                Text("if you hit it, macOS pauses \(next) first").font(Theme.small).foregroundStyle(Theme.secondary)
            }
            if let paused = model.report.insights?.stillPausedApps, !paused.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "pause.circle").font(.system(size: 11)).foregroundStyle(Theme.primary)
                    Text("macOS paused part of \(paused.joined(separator: ", ")) at the last wall and never resumed it — restart \(paused.count == 1 ? "it" : "them")")
                        .font(Theme.small.weight(.medium)).foregroundStyle(Theme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 1)
            }
            if let s = model.system {
                Text("\(Format.bytes(s.memoryUsedBytes)) of \(s.physicalBytes >> 30) GB used · swap \(Format.bytes(s.swapUsed)) · pressure \(s.pressureLevel.word)")
                    .font(Theme.small.monospacedDigit()).foregroundStyle(Theme.secondary)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

/// The big button, or the one-time helper install when downloads are not available yet.
struct DownloadBlock: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 5) {
            Button(action: act) { Text(label) }
                .buttonStyle(BigButtonStyle(enabled: enabled))
                .disabled(!enabled)
            Text(explain).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
    }

    private var enabled: Bool {
        guard model.availability != nil, !model.installing, !model.downloading else { return false }
        return true
    }

    private var label: String {
        if model.installing { return "Installing helper…" }
        guard let availability = model.availability else { return "Download More RAM" }
        if case .unavailable = availability { return "Install helper to download" }
        return "Download More RAM"
    }

    private var explain: String {
        if model.installing { return "waiting for the administrator prompt" }
        guard let availability = model.availability else { return "checking the helper…" }
        if case .unavailable = availability {
            return HelperInstaller.isInstalled ? "the helper is installed but not answering — reinstall it"
                : "installs a small root helper · one administrator prompt"
        }
        return "macOS's own memory-pressure signal · measured per app"
    }

    private func act() {
        guard let availability = model.availability else { return }
        if case .unavailable = availability { model.installHelper() } else { model.download(trigger: .user) }
    }
}

struct NoticeRow: View {
    var text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            Text(text).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.gutter).padding(.vertical, 7)
    }
}

struct FooterView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let message = model.message {
                Text(message).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Toggle(isOn: Binding(get: { model.autopilotOn }, set: { model.setAutopilot($0) })) {
                    Text("Autopilot").font(Theme.small)
                }
                .toggleStyle(MonoToggleStyle())
                Toggle(isOn: $model.menuBarPercent) { Text("% in menu bar").font(Theme.small) }
                    .toggleStyle(MonoToggleStyle())
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Text("At login").font(Theme.small)
                }
                .toggleStyle(MonoToggleStyle())
                Spacer()
            }
            HStack(alignment: .top, spacing: 8) {
                Text(statusLine).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.horizontal, Theme.gutter).padding(.vertical, 9)
    }

    private var statusLine: String {
        var parts = [model.helperStatusText]
        if model.autopilotOn {
            parts.append(model.canDownload ? "Autopilot fires at 85%, 5 min before the wall, or 20 s of critical · once per 2 min"
                                           : "Autopilot waits for the helper")
        }
        return parts.joined(separator: " · ")
    }
}
