import AppKit
import RAMKit
import SwiftUI

// MARK: Where your RAM is

struct AppsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let report = model.report
        if !report.rows.isEmpty {
            SectionHeader(title: "Where your RAM is", detail: "\(Format.bytes(report.totalFootprint)) · \(report.rows.count) apps")
            let maxBytes = Double(report.rows.first?.footprint ?? 1)
            ForEach(model.visibleRows) { row in
                AppRowView(model: model, row: row, fraction: Double(row.footprint) / max(1, maxBytes))
            }
            if report.rows.count > 8 {
                Button(model.showAllApps ? "Show the top 8" : "All \(report.rows.count) apps") { model.showAllApps.toggle() }
                    .buttonStyle(QuietButtonStyle())
                    .padding(.horizontal, Theme.gutter).padding(.top, 4).padding(.bottom, 2)
            }
        }
    }
}

struct AppRowView: View {
    @ObservedObject var model: AppModel
    var row: AppRow
    var fraction: Double

    var body: some View {
        let open = model.expanded.contains(row.id)
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if open { model.expanded.remove(row.id) } else { model.expanded.insert(row.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary).frame(width: 10)
                    Text(row.name).font(Theme.body.weight(.medium)).lineLimit(1)
                    if row.sessionCount > 0 {
                        Text("\(row.sessionCount) session\(row.sessionCount == 1 ? "" : "s")").font(Theme.small).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(Format.bytes(row.footprint)).font(Theme.mono)
                    Text("\(row.processCount)").font(Theme.mono).foregroundStyle(Theme.tertiary).frame(minWidth: 22, alignment: .trailing)
                }
            }
            .buttonStyle(BareButtonStyle())
            Meter(fraction: fraction, height: 2).padding(.leading, 16).padding(.trailing, 26)
            if open {
                ForEach(row.members) { m in
                    HStack(spacing: 6) {
                        Text(m.name).font(Theme.small).lineLimit(1).truncationMode(.middle)
                        Text(m.detail).font(Theme.mono).foregroundStyle(Theme.tertiary)
                        Spacer(minLength: 4)
                        Text(Format.bytes(m.footprint)).font(Theme.mono).foregroundStyle(Theme.secondary)
                    }
                    .padding(.leading, 16).padding(.trailing, 26).padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, Theme.gutter).padding(.vertical, 5)
    }
}

// MARK: AI agents

struct AgentsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let sessions = model.report.sessions
        if !sessions.isEmpty {
            let total = sessions.reduce(UInt64(0)) { $0 + $1.footprint }
            SectionHeader(title: "AI agents", detail: "\(sessions.count) session\(sessions.count == 1 ? "" : "s") · \(Format.bytes(total))")
            ForEach(sessions) { s in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(s.tool.displayName).font(Theme.body.weight(.medium))
                        Text(s.label).font(Theme.body).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Format.bytes(s.footprint)).font(Theme.mono)
                    }
                    Text(detail(s)).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                .padding(.horizontal, Theme.gutter).padding(.vertical, 4)
            }
        }
    }

    private func detail(_ s: AgentSession) -> String {
        var parts: [String] = []
        if let host = s.host { parts.append("in \(host)") }
        if !s.topChildren.isEmpty { parts.append(s.topChildren) }
        if let last = s.lastActive {
            parts.append("last active \(Format.duration(max(0, model.report.timestamp.timeIntervalSince(last)))) ago")
        } else if let cpu = s.cpuFraction {
            parts.append(cpu > CPUHistory.activeFraction ? "working" : "quiet")
        }
        parts.append("up \(Format.duration(s.ageS))")
        return parts.joined(separator: " · ")
    }
}

// MARK: Leftovers

struct LeftoversSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let leftovers = model.report.leftovers
        if !leftovers.isEmpty {
            let total = leftovers.reduce(UInt64(0)) { $0 + $1.record.footprint }
            SectionHeader(title: "Leftovers", detail: "\(leftovers.count) · \(Format.bytes(total))")
            ForEach(leftovers) { l in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(l.record.name).font(Theme.body.weight(.medium)).lineLimit(1)
                            Text("pid \(l.record.pid)").font(Theme.mono).foregroundStyle(Theme.tertiary)
                        }
                        Text(l.reason).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(Format.bytes(l.record.footprint)).font(Theme.mono)
                        if model.forceAttempted.contains(l.id) {
                            Text("killed").font(Theme.small).foregroundStyle(Theme.secondary)
                        } else if model.offersForce(l) {
                            HStack(spacing: 6) {
                                Text("still running").font(Theme.small).foregroundStyle(Theme.secondary)
                                Button("Force quit") { model.quit(l, force: true) }.buttonStyle(QuietButtonStyle(prominent: true))
                            }
                        } else {
                            Button("Quit") { model.quit(l, force: false) }.buttonStyle(QuietButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, Theme.gutter).padding(.vertical, 5)
            }
        }
    }
}

// MARK: Firefox (spec 6: the two levers that really exist)

struct FirefoxSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let ff = model.report.firefox
        if ff.running {
            SectionHeader(title: "Firefox")
            let armedUnloader = model.isArmed("firefox-unloader")
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Unloads tabs on low memory: \(ff.unloaderOn ? "on" : "off")").font(Theme.body)
                    Spacer(minLength: 4)
                    if ff.unloaderOn {
                        Button("Undo") { model.setFirefoxUnloader(false) }.buttonStyle(QuietButtonStyle())
                    } else if armedUnloader {
                        Button("Cancel") { model.cancelConfirm() }.buttonStyle(QuietButtonStyle())
                        Button("Turn on") { model.setFirefoxUnloader(true) }.buttonStyle(QuietButtonStyle(prominent: true))
                    } else {
                        Button("Turn on") { model.arm("firefox-unloader") }.buttonStyle(QuietButtonStyle())
                    }
                }
                if armedUnloader {
                    Text("Writes one line to the profile's user.js (browser.lowMemoryResponseMask = 3). Applies when Firefox next starts; Firefox then unloads one tab idle for 10 min per critical signal. Undo removes the line.")
                        .font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 5)
            if let gpu = ff.gpu {
                let armedGPU = model.isArmed("firefox-gpu")
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("GPU process").font(Theme.body)
                        Text(Format.bytes(gpu.footprint)).font(Theme.mono)
                        Spacer(minLength: 4)
                        if armedGPU {
                            Button("Cancel") { model.cancelConfirm() }.buttonStyle(QuietButtonStyle())
                            Button("Restart") { model.restartFirefoxGPU() }.buttonStyle(QuietButtonStyle(prominent: true))
                        } else {
                            Button("Restart") { model.arm("firefox-gpu") }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    if armedGPU {
                        Text("Quits Firefox GPU Helper; Firefox relaunches it on its own. WebGL and canvas content resets and windows repaint.")
                            .font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Theme.gutter).padding(.vertical, 5)
            }
        }
    }
}

// MARK: Growing (spec 5.8)

struct GrowingSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let leaks = model.report.leaks
        if !leaks.isEmpty {
            SectionHeader(title: "Growing", detail: "\(leaks.count)")
            ForEach(leaks) { l in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(l.name).font(Theme.body.weight(.medium)).lineLimit(1)
                            Text("pid \(l.key.pid)").font(Theme.mono).foregroundStyle(Theme.tertiary)
                        }
                        Text("growing \(Format.bytes(Int64(l.slopeBytesPerHour)))/h for \(Format.duration(l.windowS)) · +\(Format.bytes(l.growthBytes)) so far")
                            .font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(Format.bytes(l.currentFootprint)).font(Theme.mono)
                }
                .padding(.horizontal, Theme.gutter).padding(.vertical, 5)
            }
        }
    }
}
