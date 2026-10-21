import AppKit
import RAMKit
import SwiftUI

/// The download page (DESIGN.md v2 section 6): the stick fills in frost as the window advances, the
/// measured amount counts in SF Mono, the rate and time left, the apps giving memory back, levers as they land.
struct DownloadView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SheetBody(progress: model.progress, reduceMotion: reduceMotion)
    }
}

/// The download page's content from one progress event (also drawn by the clip renderer).
struct SheetBody: View {
    var progress: ReliefProgress?
    var reduceMotion = false
    /// Fill can be driven directly (the clip interpolates between recorded frames).
    var chipFraction: Double? = nil

    var body: some View {
        let p = progress
        let fraction = chipFraction ?? p.map { $0.total > 0 ? min(1, $0.elapsed / $0.total) : 0 } ?? 0
        let left = p.map { max(0, $0.total - $0.elapsed) } ?? Double(AppModel.holdMs + AppModel.settleMs) / 1000 + 2
        let apps = (p?.topApps ?? []).filter { $0.delta != 0 }.prefix(4)
        let landed = (p?.leversDone ?? []).filter { $0.kind != .kernelSignal }
        let positive = (p?.reclaimedSoFar ?? 0) > 0 && p?.phase != .baseline
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(title(p)).font(Theme.title).foregroundStyle(Theme.ink)
                Spacer()
                Pill(text: phaseWord(p), color: p?.phase == .done ? Theme.frost : Theme.ink2)
            }
            .frame(height: 24)
            MemoryStick(mode: p?.phase == .done ? .done : .downloading(fraction: fraction))
                .padding(.top, 14)
                .animation(reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
            HStack(alignment: .firstTextBaseline) {
                let (number, unit) = amount(p)
                (Text(number).font(Theme.counter) + Text(" " + unit).font(Theme.counterUnit))
                    .foregroundStyle(positive ? Theme.frost : Theme.ink2)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : Theme.enter, value: p?.reclaimedSoFar ?? 0)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(rate(p)).font(Theme.bodyNumber).foregroundStyle(Theme.ink)
                    if p?.lever == nil, p?.phase != .done {
                        Text("\(Format.duration(left)) left").font(Theme.smallNumber).foregroundStyle(Theme.ink3)
                    }
                }
            }
            .padding(.top, 12)
            if !apps.isEmpty {
                VStack(spacing: 6) {
                    ForEach(apps) { a in
                        DeltaRow(name: a.name, delta: a.delta, maxDelta: apps.map { max(0, $0.delta) }.max() ?? 1)
                    }
                }
                .padding(.top, 14)
            }
            if !landed.isEmpty || p?.lever != nil {
                VStack(spacing: 6) {
                    ForEach(landed, id: \.kind) { l in
                        LeverResultRow(result: l)
                    }
                    if let running = p?.lever {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                            Text(LeverResultRow.shortTitle(running) + "…").font(Theme.body).foregroundStyle(Theme.ink2).lineLimit(1)
                            Spacer()
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    private func title(_ p: ReliefProgress?) -> String {
        switch p?.phase {
        case .none, .baseline: "Measuring"
        case .holding, .settling: "Downloading RAM"
        case .done: "Downloaded"
        }
    }

    /// What is happening, in words a newcomer reads: the pressure signal asks apps to give memory back.
    private func phaseWord(_ p: ReliefProgress?) -> String {
        if let lever = p?.lever {
            return switch lever {
            case .kernelSignal: "asking apps…"
            case .firefoxGPU: "restarting…"
            case .leftovers, .archivedSessions: "quitting…"
            case .resumePaused: "resuming…"
            }
        }
        return switch p?.phase {
        case .none, .baseline: "baseline…"
        case .holding: "asking apps…"
        case .settling: "settling…"
        case .done: "done"
        }
    }

    /// "+2.09 GB" → ("+2.09", "GB"), so the unit can sit smaller beside the number.
    private func amount(_ p: ReliefProgress?) -> (String, String) {
        guard let p, p.phase != .baseline else { return ("0", "MB") }
        let (number, unit) = ReceiptRows.split(p.reclaimedSoFar)
        let sign = p.reclaimedSoFar > 0 ? "+" : (p.reclaimedSoFar < 0 ? "−" : "")
        return (sign + number, unit)
    }

    private func rate(_ p: ReliefProgress?) -> String {
        guard let p, p.lever == nil, p.phase == .holding || p.phase == .settling else { return " " }
        return "\(Format.bytes(Int64(p.rateBytesPerSec)))/s"
    }
}

/// An app giving memory back: name, a frost bar, the signed amount.
struct DeltaRow: View {
    var name: String
    var delta: Int64
    var maxDelta: Int64

    var body: some View {
        HStack(spacing: 10) {
            Text(name).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Bar(fraction: delta > 0 ? Double(delta) / Double(max(1, maxDelta)) : 0, height: 4,
                fill: delta > 0 ? Theme.frost : Theme.surface)
                .frame(width: 72)
            SignedBytes(bytes: delta)
        }
    }
}

/// One lever on the receipt or landing on the download page: a short title and its measured bytes.
struct LeverResultRow: View {
    var result: LeverResult

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.shortTitle(result.kind)).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 8)
            if let bytes = result.bytes {
                SignedBytes(bytes: bytes, width: 88)
            } else {
                Text(result.detail ?? "—").font(Theme.smallNumber).foregroundStyle(Theme.ink3).lineLimit(1)
            }
        }
        .help(result.detail ?? "")
    }

    static func shortTitle(_ kind: LeverKind) -> String {
        switch kind {
        case .kernelSignal: "Pressure signal"
        case .firefoxGPU: "Firefox GPU restart"
        case .leftovers: "Leftover servers"
        case .archivedSessions: "Archived sessions"
        case .resumePaused: "Paused apps resumed"
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
        return parts.isEmpty ? nil : "Not counted: " + parts.joined(separator: " · ")
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
            return rows.isEmpty ? "no app changed its footprint \(took)" : "no app gave memory back; others grew \(Format.bytes(grew)) \(took)"
        }
        let who = "\(gave.count) app\(gave.count == 1 ? "" : "s") gave back \(Format.bytes(r.grossFreedBytes))"
        return grew > 0 ? "\(who) · others grew \(Format.bytes(grew)) · \(took)" : "\(who) \(took)"
    }

    static func method(_ r: Receipt) -> String {
        "macOS memory-pressure signal via \(r.backend), \(r.holdMs / 1000) s. Measured with phys_footprint (Activity Monitor's Memory column)."
    }

    /// "2.80 GB" → ("2.80", "GB").
    static func split(_ bytes: Int64) -> (String, String) {
        let s = Format.bytes(abs(bytes))
        guard let space = s.lastIndex(of: " ") else { return (s, "") }
        return (String(s[..<space]), String(s[s.index(after: space)...]))
    }
}

struct ReceiptPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let r = model.receipt {
            ReceiptCard(receipt: r, shareNote: model.shareNote, share: { model.shareReceipt() }, done: { model.dismissReceipt() })
        } else {
            Text("No receipt.").font(Theme.body).foregroundStyle(Theme.ink2).padding(Theme.gutter)
        }
    }
}

/// The slip: the payoff, one line per lever, one quiet line of system numbers, Share and Done. The fine print
/// (what was not counted, how it was measured) waits behind Details.
struct ReceiptCard: View {
    var receipt: Receipt
    var shareNote: String?
    var share: (() -> Void)?
    var done: (() -> Void)?
    @State private var details = false

    var body: some View {
        let r = receipt
        let levers = (r.levers ?? []).filter { $0.bytes != nil || $0.kind != .kernelSignal }
        let (number, unit) = ReceiptRows.split(r.headlineBytes)
        let gotSome = r.headlineBytes > 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: gotSome ? "checkmark.circle.fill" : "minus.circle")
                    .font(.system(size: 15)).foregroundStyle(gotSome ? Theme.frost : Theme.ink3)
                Text(gotSome ? "Downloaded" : "Finished").font(Theme.title).foregroundStyle(Theme.ink)
                Spacer()
                Text("in \(Format.duration(r.durationS))").font(Theme.small).foregroundStyle(Theme.ink3)
            }
            .frame(height: 24)
            if r.headlineBytes > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("+" + number).font(Theme.payoff).foregroundStyle(Theme.frost).kerning(-1)
                    Text(" " + unit).font(Theme.heroUnit).foregroundStyle(Theme.frost)
                    Text(" back").font(Theme.heroUnit).foregroundStyle(Theme.ink2)
                }
                .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing came back").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.ink)
                    Text(ReceiptRows.summary(r)).font(Theme.small).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            }
            if !levers.isEmpty {
                VStack(spacing: 7) {
                    ForEach(levers, id: \.kind) { LeverResultRow(result: $0) }
                }
                .padding(.top, 12)
            }
            Text(systemLine(r)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink3)
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.top, 12)
            if details {
                VStack(alignment: .leading, spacing: 4) {
                    if let note = ReceiptRows.notCounted(r) { Text(note) }
                    Text(ReceiptRows.method(r))
                }
                .font(Theme.small).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            }
            if share != nil || done != nil {
                // One primary action: Share when something came back, Done when nothing did.
                HStack(spacing: 8) {
                    if let share, gotSome {
                        Button { share() } label: { Label("Share receipt", systemImage: "square.and.arrow.up") }
                            .buttonStyle(QuietButtonStyle(prominent: true))
                    }
                    Button(details ? "Less" : "Details") { details.toggle() }.buttonStyle(TextButtonStyle())
                    if let shareNote {
                        Text(shareNote).font(Theme.small).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                    Spacer()
                    if let done { Button("Done") { done() }.buttonStyle(QuietButtonStyle(prominent: !gotSome)) }
                }
                .padding(.top, 14)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    private func systemLine(_ r: Receipt) -> String {
        var parts: [String] = []
        if let b = r.wallBefore, let a = r.wallAfter { parts.append("wall \(Format.percent(b)) → \(Format.percent(a))") }
        parts.append("swap \(Format.bytes(r.systemBefore.swapUsed)) → \(Format.bytes(r.systemAfter.swapUsed))")
        return parts.joined(separator: " · ")
    }
}
