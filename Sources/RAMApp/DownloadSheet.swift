import AppKit
import RAMKit
import SwiftUI

/// The download moment: a RAM stick whose chips light up in the accent as the window advances, the
/// live measured net reclaim counting in SF Mono, the rate, the seconds left, the apps giving memory
/// back, and each lever as it lands.
struct DownloadSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SheetBody(progress: model.progress, reduceMotion: reduceMotion)
            .padding(12)
            .background(Theme.surface)
    }
}

/// The sheet's content from one progress event (also drawn by the clip renderer).
struct SheetBody: View {
    var progress: ReliefProgress?
    var reduceMotion = false
    /// Chips can be driven directly (the clip interpolates between recorded frames).
    var chipFraction: Double? = nil

    var body: some View {
        let p = progress
        let fraction = chipFraction ?? p.map { $0.total > 0 ? min(1, $0.elapsed / $0.total) : 0 } ?? 0
        let left = p.map { max(0, $0.total - $0.elapsed) } ?? Double(AppModel.holdMs + AppModel.settleMs) / 1000 + 2
        let apps = (p?.topApps ?? []).filter { $0.delta != 0 }.prefix(5)
        let landed = (p?.leversDone ?? []).filter { $0.kind != .kernelSignal }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title(p)).font(Theme.title).foregroundStyle(Theme.ink)
                Spacer()
                Text(phaseWord(p)).font(Theme.small).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            ChipBar(fraction: fraction)
            HStack(alignment: .firstTextBaseline) {
                Text(amount(p))
                    .font(Theme.monoBig)
                    .foregroundStyle(p == nil || p?.phase == .baseline ? Theme.ink3 : ((p?.reclaimedSoFar ?? 0) > 0 ? Theme.accent : Theme.ink2))
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : Theme.enter, value: p?.reclaimedSoFar ?? 0)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(rate(p)).font(Theme.monoBody).foregroundStyle(Theme.ink)
                    if p?.lever == nil, p?.phase != .done {
                        Text("\(Format.duration(left)) left").font(Theme.mono).foregroundStyle(Theme.ink2)
                    }
                }
            }
            if !apps.isEmpty {
                VStack(spacing: 5) {
                    ForEach(apps) { a in
                        DeltaRow(name: a.name, delta: a.delta, maxDelta: apps.map { max(0, $0.delta) }.max() ?? 1)
                    }
                }
            }
            if !landed.isEmpty || p?.lever != nil {
                Hairline()
                VStack(spacing: 5) {
                    ForEach(landed, id: \.kind) { l in
                        LeverResultRow(result: l)
                    }
                    if let running = p?.lever {
                        HStack {
                            Text(running.title + "…").font(Theme.body).foregroundStyle(Theme.ink2).lineLimit(1)
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSheet))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSheet).strokeBorder(Theme.hairlineColor, lineWidth: Theme.hairline))
    }

    private func title(_ p: ReliefProgress?) -> String {
        switch p?.phase {
        case .none, .baseline: "Measuring"
        case .holding, .settling: "Downloading RAM"
        case .done: "Downloaded"
        }
    }

    private func phaseWord(_ p: ReliefProgress?) -> String {
        if p?.lever != nil { return "running levers" }
        return switch p?.phase {
        case .none, .baseline: "baseline, 2 s"
        case .holding: "signal held \(AppModel.holdMs / 1000) s"
        case .settling: "settling"
        case .done: "done"
        }
    }

    private func amount(_ p: ReliefProgress?) -> String {
        guard let p, p.phase != .baseline else { return "0 B" }
        return Format.bytes(p.reclaimedSoFar, signed: p.reclaimedSoFar < 0)
    }

    private func rate(_ p: ReliefProgress?) -> String {
        guard let p, p.lever == nil, p.phase == .holding || p.phase == .settling else { return "" }
        return "\(Format.bytes(Int64(p.rateBytesPerSec)))/s"
    }
}

/// The signature detail: a DIMM whose chips light up in the accent, column by column, with the pin
/// row and key notch underneath. Nothing animates on its own; `fraction` drives it.
struct ChipBar: View {
    var fraction: Double
    var columns = 12
    var rows = 2

    var body: some View {
        let total = columns * rows
        let lit = Int((min(1, max(0, fraction)) * Double(total)).rounded(.down))
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(0..<columns, id: \.self) { col in
                            let index = col * rows + row
                            RoundedRectangle(cornerRadius: 2)
                                .fill(index < lit ? Theme.accent : Theme.surface)
                                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(index < lit ? Color.clear : Theme.hairlineColor, lineWidth: Theme.hairline))
                                .frame(height: 10)
                        }
                    }
                }
            }
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl).strokeBorder(Theme.hairlineColor, lineWidth: Theme.hairline))
            PinRow().frame(height: 4).padding(.horizontal, 10).padding(.top, 1)
        }
        .accessibilityLabel("\(Int(fraction * 100)) percent")
    }
}

/// The DIMM's contact pins with the key notch two thirds along.
struct PinRow: View {
    var body: some View {
        Canvas { ctx, size in
            let count = 36
            let step = size.width / CGFloat(count)
            for i in 0..<count where i != 24 {
                let rect = CGRect(x: CGFloat(i) * step + step * 0.2, y: 0, width: step * 0.6, height: size.height)
                ctx.fill(Path(rect), with: .color(Theme.ink3.opacity(0.6)))
            }
        }
    }
}

struct DeltaRow: View {
    var name: String
    var delta: Int64
    var maxDelta: Int64

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Bar(fraction: delta > 0 ? Double(delta) / Double(max(1, maxDelta)) : 0, height: 3,
                fill: delta > 0 ? Theme.accent : Theme.surface)
                .frame(width: 80)
            SignedBytes(bytes: delta)
        }
    }
}

/// One lever on the receipt or landing in the sheet: title, measured bytes, what it did.
struct LeverResultRow: View {
    var result: LeverResult

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(result.title).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 8)
                if let bytes = result.bytes {
                    SignedBytes(bytes: bytes, width: 84)
                } else {
                    Text("—").font(Theme.mono).foregroundStyle(Theme.ink3).frame(width: 84, alignment: .trailing)
                }
            }
            if let detail = result.detail, !detail.isEmpty {
                Text(detail).font(Theme.small).foregroundStyle(Theme.ink2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    /// "not counted: Claude Code (busy, +845.7 MB) · 71 started and 73 quit during the window".
    /// System daemons come and go by the dozen, so only short lists are named.
    static func notCounted(_ r: Receipt) -> String? {
        var parts: [String] = []
        for b in merged(r.excludedBusy) {
            let change = b.delta < 0 ? "grew \(Format.bytes(-b.delta))" : "dropped \(Format.bytes(b.delta))"
            parts.append("\(b.name) (busy, \(change))")
        }
        let churn = r.newApps.count + r.goneApps.count
        if churn > 0 && churn <= 3 {
            parts += r.newApps.map { "\($0) (started during the window)" }
            parts += r.goneApps.map { "\($0) (quit during the window)" }
        } else if churn > 3 {
            parts.append("\(r.newApps.count) started and \(r.goneApps.count) quit during the window")
        }
        return parts.isEmpty ? nil : "not counted: " + parts.joined(separator: " · ")
    }

    static func headline(_ r: Receipt) -> String {
        r.headlineBytes > 0 ? "\(Format.bytes(r.headlineBytes)) back" : "Nothing came back this time"
    }

    /// The honest second line: who gave back how much, what grew, in how long.
    static func summary(_ r: Receipt) -> String {
        let rows = merged(r.apps)
        let gave = rows.filter { $0.delta > 0 }
        let grew = r.grossFreedBytes - rows.reduce(Int64(0)) { $0 + $1.delta }
        let took = "in \(Format.duration(r.durationS))"
        if gave.isEmpty {
            return rows.isEmpty ? "no app changed its footprint \(took)" : "no app gave memory back on the signal; others grew \(Format.bytes(grew)) \(took)"
        }
        let who = "\(gave.count) app\(gave.count == 1 ? "" : "s") gave back \(Format.bytes(r.grossFreedBytes)) on the signal"
        return grew > 0 ? "\(who) · others grew \(Format.bytes(grew)) · \(took)" : "\(who) \(took)"
    }

    static func method(_ r: Receipt) -> String {
        "macOS memory-pressure signal via \(r.backend), \(r.holdMs / 1000) s · phys_footprint, Activity Monitor's number"
    }
}

struct ReceiptView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let r = model.receipt {
            ReceiptCard(receipt: r, shareNote: model.shareNote, share: { model.shareReceipt() }, done: { model.dismissReceipt() })
                .padding(12)
                .background(Theme.surface)
        } else {
            Text("No receipt.").font(Theme.body).foregroundStyle(Theme.ink2).padding(Theme.gutter)
        }
    }
}

/// The printed slip: perforated top edge, payoff numeral, one row per lever, what was not counted,
/// swap and wall before → after, the method, Share / Done.
struct ReceiptCard: View {
    var receipt: Receipt
    var shareNote: String?
    var share: (() -> Void)?
    var done: (() -> Void)?

    var body: some View {
        let r = receipt
        let levers = r.levers ?? []
        let rows = ReceiptRows.merged(r.apps)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if r.headlineBytes > 0 {
                    Text(ReceiptRows.headline(r)).font(Theme.payoff).foregroundStyle(Theme.accent)
                } else {
                    Text(ReceiptRows.headline(r)).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                Text(ReceiptRows.summary(r)).font(Theme.small).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !levers.isEmpty {
                VStack(spacing: 6) {
                    ForEach(levers, id: \.kind) { LeverResultRow(result: $0) }
                }
            } else if !rows.isEmpty {
                VStack(spacing: 5) {
                    ForEach(rows.prefix(6)) { row in
                        DeltaRow(name: row.name, delta: row.delta, maxDelta: rows.map { max(0, $0.delta) }.max() ?? 1)
                    }
                }
            }
            if let note = ReceiptRows.notCounted(r) {
                Text(note).font(Theme.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Hairline()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 12) {
                    Text("swap \(Format.bytes(r.systemBefore.swapUsed)) → \(Format.bytes(r.systemAfter.swapUsed))")
                    if let b = r.wallBefore, let a = r.wallAfter { Text("wall \(Format.percent(b)) → \(Format.percent(a))") }
                }
                Text("compressed \(Format.bytes(r.systemBefore.compressorOccupiedBytes)) → \(Format.bytes(r.systemAfter.compressorOccupiedBytes))")
                if r.systemBefore.pressureLevel != r.systemAfter.pressureLevel {
                    Text("pressure \(r.systemBefore.pressureLevel.word) → \(r.systemAfter.pressureLevel.word)")
                }
            }
            .font(Theme.mono).foregroundStyle(Theme.ink2).lineLimit(1)
            Text(ReceiptRows.method(r)).font(Theme.small).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            if share != nil || done != nil {
                HStack(spacing: 8) {
                    if let share { Button("Share receipt") { share() }.buttonStyle(QuietButtonStyle(prominent: true)) }
                    if let shareNote {
                        Text(shareNote).font(Theme.small).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                    Spacer()
                    if let done { Button("Done") { done() }.buttonStyle(QuietButtonStyle()) }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(Theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSheet))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSheet).strokeBorder(Theme.hairlineColor, lineWidth: Theme.hairline))
        .overlay(alignment: .top) { Perforation().frame(height: 6).padding(.horizontal, 12) }
    }
}

/// The tear line: a row of holes along the top edge, showing the surface behind the slip.
struct Perforation: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 9
            var x: CGFloat = step / 2
            while x < size.width {
                let hole = CGRect(x: x - 2, y: -2, width: 4, height: 4)
                ctx.fill(Path(ellipseIn: hole), with: .color(Theme.surface))
                ctx.stroke(Path(ellipseIn: hole), with: .color(Theme.hairlineColor), lineWidth: Theme.hairline)
                x += step
            }
        }
    }
}
