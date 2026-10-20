import AppKit
import Combine
import Darwin
import Foundation
import RAMKit
import SwiftUI

enum PanelPage: Equatable {
    case main, downloading, receipt
}

enum DownloadTrigger: Equatable {
    case user, autopilot
}

/// What the status item shows. Published only when it changes, so a closed panel costs nothing.
struct GlyphState: Equatable {
    var percent: Int
    var downloading: Bool
    var text: String
}

/// One row of "Where your RAM is": an app grouped like the Force Quit dialog, or every session of
/// one agent tool merged under its name (spec 5.3), with the largest members for the expanded state.
struct AppRow: Identifiable, Equatable, Sendable {
    struct Member: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var footprint: UInt64
        var detail: String
    }

    var id: String
    var name: String
    var footprint: UInt64
    var processCount: Int
    /// Sessions merged into this row (0 for a plain app).
    var sessionCount: Int
    var members: [Member]
}

struct FirefoxState: Equatable, Sendable {
    var running: Bool
    var profile: URL?
    var unloaderOn: Bool
    var gpu: ProcessRecord?

    static let notRunning = FirefoxState(running: false, profile: nil, unloaderOn: false, gpu: nil)
}

/// Everything the panel shows from one process snapshot.
struct ProcessReport: Sendable {
    var timestamp: Date
    var rows: [AppRow]
    var totalFootprint: UInt64
    var unreadableCount: Int
    var sessions: [AgentSession]
    var leftovers: [Leftover]
    var leaks: [Leak]
    var insights: WallInsights?
    var firefox: FirefoxState

    static let empty = ProcessReport(timestamp: .distantPast, rows: [], totalFootprint: 0, unreadableCount: 0, sessions: [],
                                     leftovers: [], leaks: [], insights: nil, firefox: .notRunning)

    var isEmpty: Bool { timestamp == .distantPast }
}

/// Takes process snapshots off the main thread and keeps the histories that need every sample.
actor ProcessAnalyzer {
    static let leakSpacingS: TimeInterval = 30

    private var cpu = CPUHistory()
    private var leaks = LeakDetector()
    private var lastLeakSample: Date?

    func analyze(system: SystemSample?, now: Date = Date()) -> ProcessReport {
        let snap = ProcessSampler.snapshot(includePaths: true, now: now)
        cpu.add(snap)
        if lastLeakSample.map({ now.timeIntervalSince($0) >= Self.leakSpacingS }) ?? true {
            leaks.add(snap)
            lastLeakSample = now
        }
        let groups = AppGrouper.group(snap)
        let sessions = AgentClassifier.sessions(snap, cpuHistory: cpu, now: now)
        let leftovers = AgentClassifier.leftovers(snap, cpuHistory: cpu, now: now)
        return ProcessReport(
            timestamp: now, rows: Self.rows(groups, sessions: sessions), totalFootprint: snap.totalFootprint,
            unreadableCount: snap.unreadableCount, sessions: sessions, leftovers: leftovers, leaks: leaks.leaks(now: now),
            insights: system.map { WallInsights.from(snap, system: $0) }, firefox: Self.firefox(groups, snap))
    }

    /// Apps as grouped, agent sessions merged per tool (the Force Quit dialog lumps them the same way).
    static func rows(_ groups: [AppGroup], sessions: [AgentSession]) -> [AppRow] {
        let labels = Dictionary(sessions.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        var rows: [AppRow] = []
        var agents: [String: AppRow] = [:]
        var order: [String] = []
        for g in groups {
            if g.kind == .agentSession, let tool = g.agent {
                let id = "agent-\(tool.rawValue)"
                var row = agents[id] ?? AppRow(id: id, name: tool.displayName, footprint: 0, processCount: 0, sessionCount: 0, members: [])
                if agents[id] == nil { order.append(id) }
                row.footprint += g.footprint
                row.processCount += g.processCount
                row.sessionCount += 1
                row.members.append(AppRow.Member(id: "session-\(g.id)", name: labels[g.id] ?? g.name, footprint: g.footprint,
                                                 detail: "\(g.processCount) proc"))
                agents[id] = row
            } else {
                let members = g.members.prefix(5).map {
                    AppRow.Member(id: "pid-\($0.pid)", name: $0.name, footprint: $0.footprint, detail: "pid \($0.pid)")
                }
                rows.append(AppRow(id: "app-\(g.id)", name: g.name, footprint: g.footprint, processCount: g.processCount,
                                   sessionCount: 0, members: Array(members)))
            }
        }
        for id in order {
            guard var row = agents[id] else { continue }
            row.members.sort { $0.footprint > $1.footprint }
            row.members = Array(row.members.prefix(6))
            rows.append(row)
        }
        return rows.sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.id < $1.id }
    }

    static func firefox(_ groups: [AppGroup], _ snap: ProcessSnapshot) -> FirefoxState {
        let running = groups.contains { g in
            g.kind == .app && (g.name.hasPrefix("Firefox") || (g.bundlePath.map { ($0 as NSString).lastPathComponent.hasPrefix("Firefox") } ?? false))
        }
        guard running else { return .notRunning }
        let profile = FirefoxLevers.defaultProfile()
        return FirefoxState(running: true, profile: profile,
                            unloaderOn: profile.map { FirefoxLevers.isUnloaderOn(profile: $0) } ?? false,
                            gpu: FirefoxLevers.gpuProcess(in: snap))
    }
}

/// Main-actor state for the status item and the panel. Sampling (spec 9): the system every 2 s
/// while the panel is open and every 5 s while it is closed; processes on every open tick and every
/// 30 s (sixth closed tick) otherwise. While the panel is closed nothing is published to SwiftUI:
/// the glyph goes through its own subject, and only when its state changes.
@MainActor
final class AppModel: ObservableObject {
    nonisolated static let openIntervalS: TimeInterval = 2
    nonisolated static let closedIntervalS: TimeInterval = 5
    nonisolated static let closedProcessEveryTicks = 6
    nonisolated static let holdMs = 10_000
    nonisolated static let settleMs = 5_000

    @Published var system: SystemSample?
    @Published var wall: WallStatus?
    @Published var report = ProcessReport.empty
    /// nil while the first check runs.
    @Published var availability: ReliefAvailability?
    @Published var page: PanelPage = .main
    @Published var progress: ReliefProgress?
    @Published var receipt: Receipt?
    @Published var message: String?
    @Published var shareNote: String?
    @Published var expanded: Set<String> = []
    @Published var showAllApps = false
    @Published var quitAttempted: Set<ProcessKey> = []
    @Published var forceAttempted: Set<ProcessKey> = []
    @Published var pendingConfirm: String?
    @Published var installing = false
    @Published var downloading = false
    @Published var interruptedHold = false
    /// What the status item shows. Not @Published on purpose: a change here must not invalidate the
    /// (possibly hidden) SwiftUI panel. Emits only when the state changes.
    let glyphSubject = CurrentValueSubject<GlyphState, Never>(GlyphState(percent: 0, downloading: false, text: ""))
    var glyph: GlyphState { glyphSubject.value }
    @Published var autopilotOn: Bool {
        didSet { defaults.set(autopilotOn, forKey: Keys.autopilot) }
    }
    @Published var menuBarPercent: Bool {
        didSet { defaults.set(menuBarPercent, forKey: Keys.menuBarPercent); publishGlyph() }
    }
    @Published var launchAtLogin: Bool

    private(set) var panelOpen = false
    let live: Bool
    let defaults: UserDefaults
    let notifier: Notifier
    let loginItem: LoginItem

    private var wallModel = WallModel()
    private var autopilot = AutopilotPolicy()
    private let analyzer = ProcessAnalyzer()
    private var timer: Timer?
    private var ticks = 0
    private var analyzing = false
    private var analyzeAgain = false
    private var pendingSystem: SystemSample?
    private var pendingWall: WallStatus?
    private var pendingReport: ProcessReport?
    /// The newest wall status whether or not the panel is open (drives the glyph).
    private var latestWall: WallStatus?
    private var receiptUnseen = false
    private var latestProgress: ReliefProgress?
    private var lastAvailabilityCheck: Date?
    private var confirmReset: Task<Void, Never>?
    private var refreshAfterAction: Task<Void, Never>?

    enum Keys {
        static let autopilot = "autopilot"
        static let menuBarPercent = "menuBarPercent"
    }

    init(live: Bool, defaults: UserDefaults = .standard, notifier: Notifier = Notifier(), loginItem: LoginItem = LoginItem()) {
        self.live = live
        self.defaults = defaults
        self.notifier = notifier
        self.loginItem = loginItem
        autopilotOn = defaults.bool(forKey: Keys.autopilot)
        menuBarPercent = defaults.bool(forKey: Keys.menuBarPercent)
        launchAtLogin = live ? loginItem.isEnabled : false
    }

    // MARK: Loop

    func start() {
        guard live else { return }
        interruptedHold = ReliefAvailability.interruptedHoldDetected
        tick()
        Task { await checkAvailability(force: true) }
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One timer: 2 s while the panel is open, 5 s while it is closed, 25% tolerance so the
    /// kernel can coalesce the wakeup.
    private func schedule() {
        timer?.invalidate()
        let interval = panelOpen ? Self.openIntervalS : Self.closedIntervalS
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval * 0.25
        timer = t
    }

    private func tick() {
        guard let s = try? SystemSampler.read() else { return }
        wallModel.add(s)
        let status = wallModel.status()
        latestWall = status
        if panelOpen {
            system = s
            wall = status
        } else {
            pendingSystem = s
            pendingWall = status
        }
        publishGlyph()
        ticks += 1
        if panelOpen || ticks % Self.closedProcessEveryTicks == 0 { analyzeProcesses() }
        runAutopilot(status: status, sample: s)
    }

    private func analyzeProcesses() {
        guard !analyzing else { analyzeAgain = true; return }
        analyzing = true
        let sample = system ?? pendingSystem
        Task { [weak self] in
            guard let self else { return }
            let r = await self.analyzer.analyze(system: sample)
            self.analyzing = false
            if self.panelOpen { self.report = r } else { self.pendingReport = r }
            if self.analyzeAgain {
                self.analyzeAgain = false
                self.analyzeProcesses()
            }
        }
    }

    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        if live { schedule() }
        guard open else {
            message = nil
            shareNote = nil
            pendingConfirm = nil
            return
        }
        if let s = pendingSystem { system = s; pendingSystem = nil }
        if let w = pendingWall { wall = w; pendingWall = nil }
        if let r = pendingReport { report = r; pendingReport = nil }
        if downloading {
            page = .downloading
            if let p = latestProgress { progress = p }
        } else if page == .receipt, !receiptUnseen {
            page = .main
        }
        if live {
            // A fresh system sample now (the pending one can be 5 s old); an open tick also
            // takes the process snapshot.
            tick()
            Task { await checkAvailability(force: false) }
        }
    }

    // MARK: Glyph

    private func publishGlyph() {
        let pct = Int(latestWall?.percent.rounded() ?? 0)
        let next = GlyphState(percent: pct, downloading: downloading, text: menuBarPercent && latestWall != nil ? "\(pct)%" : "")
        if next != glyphSubject.value { glyphSubject.send(next) }
    }

    // MARK: Relief availability

    func checkAvailability(force: Bool) async {
        if !force, let last = lastAvailabilityCheck, Date().timeIntervalSince(last) < 60 { return }
        lastAvailabilityCheck = Date()
        let a = await ReliefAvailability.detect()
        availability = a
        if interruptedHold, case .helper = a {
            // The helper can take the kernel out of simulated pressure for us.
            try? await HelperBackend().restore()
            interruptedHold = ReliefAvailability.interruptedHoldDetected
        }
    }

    var canDownload: Bool { availability?.backend() != nil }

    // MARK: Download

    func download(trigger: DownloadTrigger) {
        guard !downloading, let backend = availability?.backend() else { return }
        downloading = true
        progress = nil
        latestProgress = nil
        receipt = nil
        shareNote = nil
        message = nil
        if trigger == .user || panelOpen { page = .downloading }
        publishGlyph()
        let engine = ReliefEngine(backend: backend, holdMs: Self.holdMs, settleMs: Self.settleMs, wall: { s in
            var m = WallModel()
            m.add(s)
            return m.status()?.percent ?? 0
        })
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await engine.run { p in
                    Task { @MainActor [weak self] in self?.progressed(p) }
                }
                _ = try? receipt.save()
                self.finished(receipt, trigger: trigger)
            } catch {
                self.failed(error, trigger: trigger)
            }
        }
    }

    private func progressed(_ p: ReliefProgress) {
        latestProgress = p
        if panelOpen { progress = p }
    }

    private func finished(_ r: Receipt, trigger: DownloadTrigger) {
        downloading = false
        receipt = r
        receiptUnseen = true
        if panelOpen || trigger == .user { page = .receipt } else { page = .main }
        publishGlyph()
        if trigger == .autopilot {
            let top = r.apps.first { $0.delta > 0 }.map { " · \($0.name) gave back \(Format.bytes($0.delta))" } ?? ""
            notifier.post(title: r.headlineBytes > 0 ? "Downloaded \(Format.bytes(r.headlineBytes)) of RAM" : "Nothing came back this time",
                          body: "Autopilot: wall \(Format.percent(r.wallBefore ?? 0)) → \(Format.percent(r.wallAfter ?? 0))\(top)")
        }
        analyzeProcesses()
    }

    private func failed(_ error: Error, trigger: DownloadTrigger) {
        downloading = false
        page = .main
        publishGlyph()
        let text = (error as? ReliefError)?.description ?? error.localizedDescription
        message = text
        if trigger == .autopilot { notifier.post(title: "Autopilot could not download RAM", body: text) }
        if case .helperUnreachable = error as? ReliefError { Task { await checkAvailability(force: true) } }
        if error as? ReliefError == .notPermitted { Task { await checkAvailability(force: true) } }
    }

    func dismissReceipt() {
        page = .main
        shareNote = nil
        receiptUnseen = false
    }

    // MARK: Autopilot (spec 5.9)

    private func runAutopilot(status: WallStatus?, sample: SystemSample) {
        guard autopilotOn, let status, !downloading, canDownload else { return }
        switch autopilot.observe(status: status, pressure: sample.pressureLevel, now: Date()) {
        case .none:
            break
        case .download:
            autopilot.recordDownload(at: Date())
            download(trigger: .autopilot)
        case .notifyTopConsumers:
            let rows = (panelOpen ? report : (pendingReport ?? report)).rows.prefix(3)
            let list = rows.map { "\($0.name) \(Format.bytes($0.footprint))" }.joined(separator: " · ")
            notifier.post(title: "Still \(Format.percent(status.percent)) of the way to the wall",
                          body: list.isEmpty ? "Two downloads did not bring it down." : "Two downloads did not bring it down. Using the most: \(list)")
        }
    }

    func setAutopilot(_ on: Bool) {
        autopilotOn = on
        if on { Task { _ = await notifier.requestAuthorization() } }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try loginItem.setEnabled(on)
        } catch {
            message = "Couldn't change Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = loginItem.isEnabled
    }

    // MARK: Helper install

    func installHelper() {
        guard !installing else { return }
        installing = true
        message = nil
        // Let the panel paint "Installing…" before the administrator prompt blocks this thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let result = HelperSetup.install()
                self.installing = false
                switch result {
                case .success:
                    self.message = "Helper installed. Downloads run without a password from now on."
                    Task { await self.checkAvailability(force: true) }
                case .failure(let failure):
                    self.message = failure.description
                }
            }
        }
    }

    // MARK: Share

    func shareReceipt() {
        guard let receipt else { return }
        do {
            let url = try ShareCard.export(receipt)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            shareNote = "Saved as \(url.lastPathComponent) and copied"
        } catch {
            shareNote = "Couldn't save the card: \(error.localizedDescription)"
        }
    }

    // MARK: Two-click confirmation

    func arm(_ id: String) {
        pendingConfirm = id
        confirmReset?.cancel()
        confirmReset = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled, self?.pendingConfirm == id { self?.pendingConfirm = nil }
        }
    }

    func cancelConfirm() {
        pendingConfirm = nil
        confirmReset?.cancel()
    }

    func isArmed(_ id: String) -> Bool { pendingConfirm == id }

    // MARK: Leftovers (spec 5.4: SIGTERM on a click, SIGKILL only on a second explicit click)

    func quit(_ leftover: Leftover, force: Bool) {
        cancelConfirm()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        switch SafeKill.terminate(leftover.record, escalate: force, frontmostPid: front) {
        case .ok:
            if force { forceAttempted.insert(leftover.id) } else { quitAttempted.insert(leftover.id) }
            message = "Sent \(force ? "SIGKILL" : "SIGTERM") to \(leftover.record.name) (\(leftover.record.pid))."
            refreshSoon()
        case .refused(let why):
            message = "\(leftover.record.name): \(why)."
        }
    }

    /// Force is offered once a plain Quit was sent and the process is still in the list.
    func offersForce(_ leftover: Leftover) -> Bool {
        quitAttempted.contains(leftover.id) && !forceAttempted.contains(leftover.id)
    }

    private func refreshSoon() {
        refreshAfterAction?.cancel()
        refreshAfterAction = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { self?.analyzeProcesses() }
        }
    }

    // MARK: Firefox levers (spec 6)

    func setFirefoxUnloader(_ on: Bool) {
        cancelConfirm()
        guard let profile = report.firefox.profile else {
            message = "No default Firefox profile found in profiles.ini."
            return
        }
        do {
            if on {
                try FirefoxLevers.enableUnloader(profile: profile)
                message = "Added one line to \(profile.lastPathComponent)/user.js. Applies when Firefox next starts."
            } else {
                try FirefoxLevers.disableUnloader(profile: profile)
                message = FirefoxLevers.isUnloaderOn(profile: profile)
                    ? "Removed our line, but Firefox still sets it (prefs.js). Change it in about:config."
                    : "Removed our line from user.js. Applies when Firefox next starts."
            }
        } catch {
            message = "Couldn't write user.js: \(error.localizedDescription)"
        }
        refreshSoon()
    }

    func restartFirefoxGPU() {
        cancelConfirm()
        guard let gpu = report.firefox.gpu else { return }
        switch FirefoxLevers.restartGPU(gpu) {
        case .restarted:
            message = "Asked the GPU process to quit. Firefox relaunches it; WebGL and canvas content resets."
        case .tooYoung(let up):
            message = "The GPU process started \(Format.duration(up)) ago. Firefox counts a restart inside 30 s as a crash; try again shortly."
        case .refused(let why):
            message = "Not restarted: \(why)."
        }
        refreshSoon()
    }

    // MARK: Memory pressure in this process

    /// Drops what we can rebuild: expanded rows, pending reports, image caches.
    func dropCaches() {
        expanded = []
        showAllApps = false
        pendingReport = nil
        if !panelOpen { report = .empty }
        latestProgress = nil
        StatusGlyph.dropCache()
        ShareCard.dropCache()
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    // MARK: Derived text

    var helperStatusText: String {
        switch availability {
        case .none: "Checking helper…"
        case .root: "Running as root"
        case .helper(let v): "Helper \(v)"
        case .unavailable: HelperInstaller.isInstalled ? "Helper not answering" : "No helper"
        }
    }

    var visibleRows: [AppRow] {
        showAllApps ? report.rows : Array(report.rows.prefix(8))
    }
}
