import AppKit
import RAMKit
import SwiftUI

// MARK: Also available (levers)

/// One row per lever the planner found, with its measured estimate, what it does, a `Do it` that
/// runs a download with that lever, and a remembered `Always` toggle. Consent levers start off.
struct LeversBlock: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Also available").font(Theme.title).foregroundStyle(Theme.ink)
            ForEach(model.offers, id: \.kind) { offer in
                LeverRow(model: model, offer: offer)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
    }
}

struct LeverRow: View {
    @ObservedObject var model: AppModel
    var offer: LeverOffer
    @State private var blink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(offer.kind.title).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 8)
                if let bytes = offer.estimateBytes {
                    Text("~" + Format.bytes(bytes)).font(Theme.bodyNumber).foregroundStyle(Theme.ink2)
                }
            }
            HStack(alignment: .center, spacing: 8) {
                Text(offer.reason).font(Theme.small).foregroundStyle(Theme.ink2)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Toggle("Always", isOn: Binding(get: { model.isAlways(offer.kind) }, set: { model.setAlways(offer.kind, $0) }))
                    .toggleStyle(MonoToggleStyle())
                Button(blink ? " " : "Do it") {
                    Blink.run($blink) { model.download(trigger: .user, extra: [offer.kind]) }
                }
                .buttonStyle(QuietButtonStyle(prominent: !blink))
                .disabled(!model.canDownload || model.downloading)
                .frame(minWidth: 44)
            }
        }
    }
}

// MARK: Where your RAM is

struct WhereYourRAMIs: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let r = model.report
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Where your RAM is").font(Theme.title).foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(Format.bytes(r.totalFootprint)).font(Theme.smallNumber).foregroundStyle(Theme.ink2).lineLimit(1)
                if r.rows.count > 5 {
                    Button(model.showAll ? "Top 5" : "All \(r.rows.count)") { model.showAll.toggle() }
                        .buttonStyle(TextButtonStyle())
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 12)
            .padding(.bottom, 6)
            if model.showAll {
                ScrollView {
                    rows
                }
                .frame(maxHeight: Theme.listMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                rows
            }
        }
        .padding(.bottom, 8)
    }

    private var rows: some View {
        let r = model.report
        let maxBytes = Double(r.rows.first?.footprint ?? 1)
        return VStack(spacing: 0) {
            ForEach(model.visibleRows) { row in
                RowView(model: model, row: row, fraction: Double(row.footprint) / max(1, maxBytes))
            }
            ForEach(r.duplicates.prefix(2)) { d in
                DuplicateRow(duplicate: d)
            }
        }
    }

}

/// Icon + title + size (+ "archived"); click to expand the processes behind it, merged by name.
struct RowView: View {
    @ObservedObject var model: AppModel
    var row: AppRow
    var fraction: Double

    var body: some View {
        let open = model.expanded.contains(row.id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { model.expanded.remove(row.id) } else { model.expanded.insert(row.id) }
            } label: {
                HStack(spacing: 8) {
                    RowIcon(path: row.iconPath, session: row.kind == .session)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(row.name).font(Theme.bodyMedium).foregroundStyle(Theme.ink)
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
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 6)
                .background(open ? Theme.surface : Color.clear)
            }
            .buttonStyle(BareButtonStyle())
            Bar(fraction: fraction, height: 2, fill: Theme.ink3)
                .padding(.leading, Theme.gutter + 24)
                .padding(.trailing, Theme.gutter)
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
                .padding(.leading, Theme.gutter + 24)
                .padding(.trailing, Theme.gutter)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
        }
        .padding(.bottom, 2)
    }
}

struct RowIcon: View {
    var path: String?
    var session: Bool

    var body: some View {
        if let image = IconCache.icon(for: path) {
            Image(nsImage: image).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: session ? "terminal" : "app")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.ink3)
                .frame(width: 16, height: 16)
        }
    }
}

/// "16 copies of rea mcp · 3.15 GB", one per agent session. Quiet: no action (quitting them would
/// break those sessions).
struct DuplicateRow: View {
    var duplicate: DuplicateServer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.on.square")
                .font(.system(size: 11, weight: .regular)).foregroundStyle(Theme.ink3).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(duplicate.count) copies of \(duplicate.command)").font(Theme.body).foregroundStyle(Theme.ink2).lineLimit(1)
                Text("one per agent session").font(Theme.small).foregroundStyle(Theme.ink3)
            }
            Spacer(minLength: 8)
            Text(Format.bytes(duplicate.bytes)).font(Theme.bodyNumber).foregroundStyle(Theme.ink2)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 6)
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
                Spacer()
                HelperDot(state: model.helperState)
                MoreMenu(model: model)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
    }
}

/// Filled dot: the helper answers. Hollow: it is missing or silent.
struct HelperDot: View {
    var state: AppModel.HelperState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .strokeBorder(Theme.ink2, lineWidth: state == .ok ? 3.5 : 1)
                .frame(width: 7, height: 7)
            Text(label).font(Theme.small).foregroundStyle(Theme.ink2)
        }
        .help(help)
    }

    private var label: String {
        switch state {
        case .checking: "Helper"
        case .ok: "Helper"
        case .missing: "No helper"
        case .notAnswering: "Helper silent"
        }
    }

    private var help: String {
        switch state {
        case .checking: "Checking the helper"
        case .ok: "The root helper that sends the memory-pressure signal is installed and answering"
        case .missing: "Install the helper to download (one administrator prompt)"
        case .notAnswering: "The helper is installed but not answering: sudo ram helper install"
        }
    }
}

/// "…": % in menu bar, launch at login, quit.
struct MoreMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            Toggle("Show % in menu bar", isOn: $model.menuBarPercent)
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Divider()
            Button("Quit Download More RAM") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink2)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }
}
