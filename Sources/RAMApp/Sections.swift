import AppKit
import RAMKit
import SwiftUI

// MARK: Lever tiles

/// The levers with something to give back, as Control Center tiles (DESIGN.md v2 section 5.6): an icon in
/// a circle, the label, the measured estimate. Only levers with an offer get a tile (the panel never spends
/// its best space on "none"); two per row, an odd last tile full width. Paused apps have their banner
/// instead. A tile that ends or restarts something arms first (its value turns into the question) and runs
/// a download with that lever on the second click within 3 s. Right-click (or the … menu) toggles "Always
/// run with downloads"; an always-on lever's circle fills in frost, the way Control Center shows a toggle
/// that is on.
struct LeverTiles: View {
    @ObservedObject var model: AppModel
    @State private var armed: LeverKind?

    static let order: [LeverKind] = [.firefoxGPU, .leftovers, .archivedSessions]

    static func kinds(_ model: AppModel) -> [LeverKind] {
        order.filter { kind in model.offers.contains { $0.kind == kind } }
    }

    static func hasTiles(_ model: AppModel) -> Bool { !kinds(model).isEmpty }

    var body: some View {
        let kinds = Self.kinds(model)
        VStack(spacing: 8) {
            ForEach(Array(stride(from: 0, to: kinds.count, by: 2)), id: \.self) { i in
                HStack(spacing: 8) {
                    tile(kinds[i])
                    if i + 1 < kinds.count { tile(kinds[i + 1]) }
                }
            }
        }
    }

    private func tile(_ kind: LeverKind) -> some View {
        LeverTile(model: model, kind: kind, offer: model.offers.first { $0.kind == kind }, armed: $armed)
    }
}

struct LeverTile: View {
    @ObservedObject var model: AppModel
    var kind: LeverKind
    var offer: LeverOffer?
    @Binding var armed: LeverKind?

    var body: some View {
        let available = offer != nil && model.canDownload && !model.downloading
        let isArmed = armed == kind
        let always = model.isAlways(kind)
        Button(action: tap) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(always ? Theme.capsuleText : (isArmed ? Theme.frost : (offer != nil ? Theme.ink : Theme.ink3)))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(always ? Theme.frost : Theme.surfaceStrong))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.small).foregroundStyle(Theme.ink2).lineLimit(1).minimumScaleFactor(0.9)
                    Text(isArmed ? question : value)
                        .font(Theme.tileValue)
                        .foregroundStyle(isArmed ? Theme.frost : (offer != nil ? Theme.ink : Theme.ink2))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
                .fill(isArmed ? Theme.frost.opacity(0.14) : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
                .strokeBorder(isArmed ? Theme.frost.opacity(0.55) : Theme.hairlineColor, lineWidth: 1))
        }
        .buttonStyle(BareButtonStyle())
        .disabled(!available)
        .help(offer?.reason ?? "Nothing to do right now")
        .contextMenu {
            Toggle("Always run with downloads", isOn: Binding(get: { model.isAlways(kind) }, set: { model.setAlways(kind, $0) }))
        }
        .animation(.easeOut(duration: 0.15), value: isArmed)
        .accessibilityLabel("\(title): \(isArmed ? question : value)\(model.isAlways(kind) ? ", always runs with downloads" : "")")
    }

    private var symbol: String {
        switch kind {
        case .firefoxGPU: "display"
        case .leftovers: "xmark.circle"
        case .archivedSessions: "archivebox"
        case .resumePaused: "play.circle"
        case .kernelSignal: "arrow.down"
        }
    }

    private var title: String {
        switch kind {
        case .firefoxGPU: "Firefox GPU"
        case .leftovers: "Leftover servers"
        case .archivedSessions: "Archived sessions"
        case .resumePaused: "Paused apps"
        case .kernelSignal: "Signal"
        }
    }

    private var value: String {
        guard let offer else { return "none" }
        if let bytes = offer.estimateBytes { return "~" + Format.bytes(bytes) }
        if kind == .resumePaused {
            let n = model.report.pausedApps.count
            return "\(n) app\(n == 1 ? "" : "s")"
        }
        return "ready"
    }

    private var question: String {
        switch kind {
        case .firefoxGPU: return "Restart it?"
        case .leftovers:
            let n = model.report.leftovers.count
            return "Quit \(n)?"
        case .archivedSessions:
            let n = model.report.sessions.filter { AgentClassifier.safeToQuitArchived($0) }.count
            return "Quit \(max(1, n))?"
        case .resumePaused, .kernelSignal: return value
        }
    }

    private func tap() {
        // Resuming is safe: no confirmation. Everything that ends or restarts a process arms first.
        if kind == .resumePaused {
            model.resumePaused()
            return
        }
        if armed == kind {
            armed = nil
            model.download(trigger: .user, extra: [kind])
            return
        }
        armed = kind
        let mine = kind
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { if armed == mine { armed = nil } }
        }
    }
}

// MARK: Where it is

struct WhereItIs: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let r = model.report
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel(text: "Where it is")
                Spacer(minLength: 8)
                Text(Format.bytes(r.totalFootprint)).font(Theme.smallNumber).foregroundStyle(Theme.ink3).lineLimit(1)
                if r.rows.count > 4 {
                    Button(model.showAll ? "Top 4" : "All \(r.rows.count)") { model.showAll.toggle() }
                        .buttonStyle(TextButtonStyle())
                }
            }
            if model.showAll {
                ScrollView { rows }
                    .frame(maxHeight: Theme.listMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        let r = model.report
        let visible = model.showAll ? r.rows : Array(r.rows.prefix(4))
        return VStack(spacing: 2) {
            ForEach(visible) { row in
                RowView(model: model, row: row)
            }
            ForEach(r.duplicates.prefix(1)) { d in
                DuplicateRow(duplicate: d)
            }
        }
    }
}

/// Icon, name (+ archived), sub-line, size. Click to see the processes behind it, merged by name.
struct RowView: View {
    @ObservedObject var model: AppModel
    var row: AppRow
    @State private var hover = false

    var body: some View {
        let open = model.expanded.contains(row.id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { model.expanded.remove(row.id) } else { model.expanded.insert(row.id) }
            } label: {
                HStack(spacing: 10) {
                    RowIcon(path: row.iconPath, session: row.kind == .session)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(row.name).font(Theme.body).foregroundStyle(Theme.ink)
                                .lineLimit(1).truncationMode(.middle)
                            if row.archived { Tag(text: "archived") }
                        }
                        if let detail = row.detail {
                            Text(detail).font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(Format.bytes(row.footprint)).font(Theme.bodyNumber).foregroundStyle(Theme.ink)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(open || hover ? Theme.surface : Color.clear))
            }
            .buttonStyle(BareButtonStyle())
            .onHover { hover = $0 }
            if open {
                VStack(spacing: 4) {
                    ForEach(row.members) { m in
                        HStack(spacing: 6) {
                            Text(m.name).font(Theme.small).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
                            if m.count > 1 { Text("×\(m.count)").font(Theme.smallNumber).foregroundStyle(Theme.ink3) }
                            Spacer(minLength: 8)
                            Text(Format.bytes(m.footprint)).font(Theme.smallNumber).foregroundStyle(Theme.ink2)
                        }
                    }
                }
                .padding(.leading, 38)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, -8)
        .accessibilityElement(children: .combine)
    }
}

struct RowIcon: View {
    var path: String?
    var session: Bool

    var body: some View {
        if let image = IconCache.icon(for: path) {
            Image(nsImage: image).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: session ? "terminal" : "app")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.ink2)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface))
        }
    }
}

/// "21 copies of rea mcp · 3.97 GB", one per agent session. No action: quitting them would break those sessions.
struct DuplicateRow: View {
    var duplicate: DuplicateServer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.on.square")
                .font(.system(size: 12, weight: .regular)).foregroundStyle(Theme.ink2)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(duplicate.count)× \(duplicate.command)").font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1)
                Text("one copy per agent session").font(Theme.small).foregroundStyle(Theme.ink3)
            }
            Spacer(minLength: 8)
            Text(Format.bytes(duplicate.bytes)).font(Theme.bodyNumber).foregroundStyle(Theme.ink)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Footer

struct FooterView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.message {
                Text(message).font(Theme.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Toggle(isOn: Binding(get: { model.autopilotOn }, set: { model.setAutopilot($0) })) { Text("Autopilot") }
                    .toggleStyle(MonoToggleStyle())
                    .help("Downloads RAM by itself when the wall is near")
                Spacer()
                // A working helper is not news (the … menu says it); only a state that needs a click shows.
                if model.helperState.needsAction {
                    HelperDot(state: model.helperState, act: { model.installHelper() })
                }
            }
        }
    }
}

extension AppModel.HelperState {
    /// Missing, outdated or silent: the footer shows it, and a click installs or updates it.
    var needsAction: Bool { self == .outdated || self == .missing || self == .notAnswering }

    var menuLine: String {
        switch self {
        case .checking: "Checking the helper…"
        case .ok: "Helper \(HelperConstants.version) installed"
        case .outdated: "Update the helper…"
        case .missing: "Install the helper…"
        case .notAnswering: "Helper not answering: reinstall…"
        }
    }
}

/// Helper state: a filled dot when it answers; `Update helper` / `No helper` act on click.
struct HelperDot: View {
    var state: AppModel.HelperState
    var act: () -> Void = {}

    var body: some View {
        let dot = HStack(spacing: 6) {
            Circle()
                .fill(state == .ok ? Theme.frost : Color.clear)
                .overlay(Circle().strokeBorder(state == .ok ? Color.clear : Theme.ink2, lineWidth: 1))
                .frame(width: 7, height: 7)
            Text(label).font(Theme.small.weight(.medium)).foregroundStyle(state == .outdated || state == .missing ? Theme.ink : Theme.ink2)
        }
        .help(help)
        if state == .outdated || state == .missing {
            Button(action: act) { dot }.buttonStyle(BareButtonStyle())
        } else {
            dot
        }
    }

    private var label: String {
        switch state {
        case .checking: "Helper"
        case .ok: "Helper"
        case .outdated: "Update helper"
        case .missing: "No helper"
        case .notAnswering: "Helper silent"
        }
    }

    private var help: String {
        switch state {
        case .checking: "Checking the helper"
        case .ok: "The root helper that sends the memory-pressure signal is installed and answering"
        case .outdated: "An older helper is installed; click to update it (one administrator prompt)"
        case .missing: "Install the helper to download (one administrator prompt)"
        case .notAnswering: "The helper is installed but not answering: sudo ram helper install"
        }
    }
}

/// "…": the helper's state, levers that always run, % in menu bar, launch at login, quit.
struct MoreMenu: View {
    @ObservedObject var model: AppModel

    static func alwaysTitle(_ kind: LeverKind) -> String {
        switch kind {
        case .firefoxGPU: "Restart Firefox's GPU process"
        case .leftovers: "Quit leftover servers"
        case .archivedSessions: "Quit archived sessions"
        case .resumePaused: "Resume paused apps"
        case .kernelSignal: "Pressure signal"
        }
    }

    var body: some View {
        Menu {
            Button(model.helperState.menuLine) { model.installHelper() }
                .disabled(!model.helperState.needsAction)
            Menu("Always run with downloads") {
                ForEach(LeverKind.allCases.filter { $0 != .kernelSignal }, id: \.self) { kind in
                    Toggle(Self.alwaysTitle(kind), isOn: Binding(get: { model.isAlways(kind) }, set: { model.setAlways(kind, $0) }))
                }
            }
            Divider()
            Toggle("Show % in menu bar", isOn: $model.menuBarPercent)
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Divider()
            Button("Quit Download More RAM") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.surface))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }
}
