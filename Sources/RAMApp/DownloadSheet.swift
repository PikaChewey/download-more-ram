import AppKit
import RAMKit
import SwiftUI

/// The download moment: a dialog inside the panel with a segmented bar over elapsed/total, the live
/// measured net reclaim (big, tabular), the rate, the seconds left and the apps giving memory back.
struct DownloadSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let p = model.progress
        let fraction = p.map { $0.total > 0 ? min(1, $0.elapsed / $0.total) : 0 } ?? 0
        let left = p.map { max(0, $0.total - $0.elapsed) } ?? Double(AppModel.holdMs + AppModel.settleMs) / 1000 + 2
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title(p?.phase)).font(Theme.title(13))
                Spacer()
                Text(phaseWord(p?.phase)).font(Theme.small).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Hairline()
            VStack(alignment: .leading, spacing: 10) {
                SegmentedBar(fraction: fraction)
                HStack(alignment: .firstTextBaseline) {
                    Text(amount(p))
                        .font(Theme.monoBig)
                        .foregroundStyle(p?.phase == .baseline ? Theme.tertiary : Theme.accent)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.35), value: p?.reclaimedSoFar ?? 0)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(rate(p)).font(Theme.monoBody).foregroundStyle(Theme.primary)
                        Text("\(Format.duration(left)) left").font(Theme.mono).foregroundStyle(Theme.secondary)
                    }
                }
                Text(subline(p?.phase)).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .padding(12)
            if let apps = p?.topApps, apps.contains(where: { $0.delta != 0 }) {
                Hairline()
                VStack(spacing: 4) {
                    ForEach(apps.filter { $0.delta != 0 }.prefix(5)) { a in
                        DeltaRow(name: a.name, delta: a.delta, maxDelta: apps.map { max(0, $0.delta) }.max() ?? 1)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.separator, lineWidth: Theme.hairline))
        .padding(Theme.gutter)
    }

    private func title(_ phase: ReliefProgress.Phase?) -> String {
        switch phase {
        case .none, .baseline: "Measuring baseline…"
        case .holding, .settling: "Downloading RAM…"
        case .done: "Downloaded"
        }
    }

    private func phaseWord(_ phase: ReliefProgress.Phase?) -> String {
        switch phase {
        case .none, .baseline: "step 1 of 3"
        case .holding: "step 2 of 3"
        case .settling: "step 3 of 3"
        case .done: "done"
        }
    }

    private func subline(_ phase: ReliefProgress.Phase?) -> String {
        switch phase {
        case .none, .baseline: "watching every app for 2 s so busy ones are not counted"
        case .holding: "macOS's own memory-pressure signal, critical, held \(AppModel.holdMs / 1000) s"
        case .settling: "signal over · letting apps settle for \(AppModel.settleMs / 1000) s"
        case .done: "measured with phys_footprint, Activity Monitor's number"
        }
    }

    private func amount(_ p: ReliefProgress?) -> String {
        guard let p, p.phase != .baseline else { return "0 B" }
        return Format.bytes(p.reclaimedSoFar, signed: p.reclaimedSoFar < 0)
    }

    private func rate(_ p: ReliefProgress?) -> String {
        guard let p, p.phase == .holding || p.phase == .settling else { return "" }
        return "\(Format.bytes(Int64(p.rateBytesPerSec)))/s"
    }
}

/// Retro progress: discrete cells that light up one by one.
struct SegmentedBar: View {
    var fraction: Double
    var cells = 32

    var body: some View {
        let lit = Int((min(1, max(0, fraction)) * Double(cells)).rounded(.down))
        HStack(spacing: 2) {
            ForEach(0..<cells, id: \.self) { i in
                Rectangle().fill(i < lit ? Theme.accent : Theme.fill)
            }
        }
        .frame(height: 12)
        .padding(3)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.separator, lineWidth: Theme.hairline))
        .accessibilityLabel("\(Int(fraction * 100)) percent")
    }
}

struct DeltaRow: View {
    var name: String
    var delta: Int64
    var maxDelta: Int64

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(Theme.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Meter(fraction: delta > 0 ? Double(delta) / Double(max(1, maxDelta)) : 0, height: 3,
                  tint: delta > 0 ? Theme.primary : nil)
                .frame(width: 90)
            SignedBytes(bytes: delta)
        }
    }
}

// MARK: Receipt

/// Apps as the receipt shows them: same-named groups (one per agent session) merged into one row.
struct ReceiptRow: Identifiable {
    var id: String { name }
    var name: String
    var before: UInt64
    var after: UInt64
    var delta: Int64 { Int64(clamping: before) - Int64(clamping: after) }
}

enum ReceiptRows {
    static func merged(_ apps: [AppDelta]) -> [ReceiptRow] {
        var rows: [String: ReceiptRow] = [:]
        var order: [String] = []
        for a in apps {
            if rows[a.name] == nil { order.append(a.name) }
            var r = rows[a.name] ?? ReceiptRow(name: a.name, before: 0, after: 0)
            r.before += a.before
            r.after += a.after
            rows[a.name] = r
        }
        return order.compactMap { rows[$0] }.filter { $0.delta != 0 }
            .sorted { $0.delta != $1.delta ? $0.delta > $1.delta : $0.name < $1.name }
    }

    /// "Claude Code (busy, +3.00 GB) · Preview (started during the window) · Pages (quit)".
    static func notCounted(_ r: Receipt) -> String? {
        var parts: [String] = []
        for b in merged(r.excludedBusy) { parts.append("\(b.name) (busy, \(Format.bytes(b.delta, signed: true)))") }
        for n in r.newApps { parts.append("\(n) (started during the window)") }
        for g in r.goneApps { parts.append("\(g) (quit during the window)") }
        return parts.isEmpty ? nil : "not counted: " + parts.joined(separator: " · ")
    }

    static func headline(_ r: Receipt) -> String {
        r.headlineBytes > 0 ? "Downloaded \(Format.bytes(r.headlineBytes)) of RAM" : "Nothing came back this time"
    }

    /// The honest second line: who gave back how much, what grew, in how long.
    static func summary(_ r: Receipt) -> String {
        let rows = merged(r.apps)
        let gave = rows.filter { $0.delta > 0 }
        let grew = r.grossFreedBytes - r.headlineBytes
        let took = "in \(Format.duration(r.durationS))"
        if gave.isEmpty {
            return rows.isEmpty ? "no app changed its footprint \(took)" : "no app gave memory back; others grew \(Format.bytes(grew)) \(took)"
        }
        let who = "\(gave.count) app\(gave.count == 1 ? "" : "s") gave back \(Format.bytes(r.grossFreedBytes))"
        return grew > 0 ? "\(who) · others grew \(Format.bytes(grew)) \(took)" : "\(who) \(took)"
    }
}

struct ReceiptView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let r = model.receipt {
            let rows = ReceiptRows.merged(r.apps)
            let maxDelta = rows.map { max(0, $0.delta) }.max() ?? 1
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    if r.headlineBytes > 0 {
                        (Text("Downloaded ") + Text(Format.bytes(r.headlineBytes)).foregroundStyle(Theme.accent) + Text(" of RAM"))
                            .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    } else {
                        Text("Nothing came back this time").font(.system(size: 20, weight: .semibold))
                    }
                    Text(ReceiptRows.summary(r)).font(Theme.small).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !rows.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(rows.prefix(8)) { row in
                            DeltaRow(name: row.name, delta: row.delta, maxDelta: maxDelta)
                        }
                    }
                    .padding(.top, 2)
                }
                if let note = ReceiptRows.notCounted(r) {
                    Text(note).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Hairline()
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 12) {
                        Text("swap \(Format.bytes(r.systemBefore.swapUsed)) → \(Format.bytes(r.systemAfter.swapUsed))")
                        if let b = r.wallBefore, let a = r.wallAfter { Text("wall \(Format.percent(b)) → \(Format.percent(a))") }
                    }
                    Text("compressed \(Format.bytes(r.systemBefore.compressorOccupiedBytes)) → \(Format.bytes(r.systemAfter.compressorOccupiedBytes))")
                    Text("pressure \(r.systemBefore.pressureLevel.word) → \(r.systemAfter.pressureLevel.word)")
                }
                .font(Theme.mono).foregroundStyle(Theme.secondary).lineLimit(1)
                Text("Measured with phys_footprint, Activity Monitor's number · macOS's own memory-pressure signal via \(r.backend), \(r.holdMs / 1000) s")
                    .font(Theme.small).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Share receipt") { model.shareReceipt() }.buttonStyle(QuietButtonStyle(prominent: true))
                    if let note = model.shareNote {
                        Text(note).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Done") { model.dismissReceipt() }.buttonStyle(QuietButtonStyle())
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 12)
        } else {
            Text("No receipt.").font(Theme.body).foregroundStyle(Theme.secondary).padding(Theme.gutter)
        }
    }
}
