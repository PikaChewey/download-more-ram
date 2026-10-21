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

/// What the status item shows. Emitted only when it changes, so a closed panel costs nothing.
struct GlyphState: Equatable {
    var percent: Int
    var atWall: Bool
    var downloading: Bool
    /// The lit chip while a download runs (from the engine's progress, 2 Hz, never otherwise).
    var frame: Int
    var text: String
}

/// One row of "Where your RAM is": an app grouped like the Force Quit dialog, or one agent session
/// with its real title. Rows are apps and sessions, never pids (DESIGN.md principle 5).
struct AppRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case app, session }

    /// Processes of the row merged by name ("plugin-container ×6").
    struct Member: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var count: Int
        var footprint: UInt64
    }

    var id: String
    var kind: Kind
    var name: String
    /// "Claude Code · in Claude" for a session; nil for an app.
    var detail: String?
    var archived: Bool
    var footprint: UInt64
    var processCount: Int
    /// Bundle whose icon represents the row (the host app for a session).
    var iconPath: String?
    var members: [Member]
}

/// Everything the panel shows from one process snapshot.
struct ProcessReport: Sendable {
    var timestamp: Date
    var rows: [AppRow]
    var totalFootprint: UInt64
    var appCount: Int
    var sessionCount: Int
    var sessions: [AgentSession]
    var leftovers: [Leftover]
    var duplicates: [DuplicateServer]
    var offers: [LeverOffer]
    var insights: WallInsights?
    /// Apps macOS paused at the last wall and never resumed, and what their helpers burn meanwhile.
    var pausedApps: [String]
    var pausedCores: Double
    /// Apps growing fastest over the last two minutes (for the warning before the wall).
    var growers: [GrowthTracker.Grower] = []

    static let empty = ProcessReport(timestamp: .distantPast, rows: [], totalFootprint: 0, appCount: 0, sessionCount: 0,
                                     sessions: [], leftovers: [], duplicates: [], offers: [], insights: nil,
                                     pausedApps: [], pausedCores: 0)

    var isEmpty: Bool { timestamp == .distantPast }
}

/// Per-process lookups the classifier repeats on every pass, cached for the life of the process:
/// argv and the Claude session id never change, cwd rarely does, and a Claude desktop session file
/// (about 1 MB of JSON each, 13 of them on the target) is only re-read when its modification date
/// moves. Measured on the target: this turns a pass from ~29 ms of file reads and lookups into ~12 ms.
final class CachedProcessInfo: ProcessInfoSource, @unchecked Sendable {
    static let cwdTTL: TimeInterval = 600
    static let transcriptTTL: TimeInterval = 60
    static let indexTTL: TimeInterval = 600

    private let lock = NSLock()
    private let root: URL
    private var alive: [Int32: UInt64] = [:]
    private var argvs: [Int32: (start: UInt64, value: [String]?)] = [:]
    private var cwds: [Int32: (start: UInt64, at: Date, value: String?)] = [:]
    private var sessionIDs: [Int32: (start: UInt64, value: String?)] = [:]
    private var transcripts: [String: (at: Date, value: Date?)] = [:]
    private var files: [String: URL] = [:]
    private var sessions: [String: (modified: Date, value: ClaudeDesktopSession?)] = [:]
    private var desktop = ClaudeDesktopSessions()
    private var indexBuilt = Date.distantPast
    private var rebuiltThisPass = false
    private var now = Date()

    init(root: URL = RealUser.home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)) {
        self.root = root
    }

    /// Call once per snapshot before classifying: drops entries of processes that are gone.
    func begin(_ snap: ProcessSnapshot, now: Date) {
        lock.withLock {
            self.now = now
            alive = Dictionary(snap.records.map { ($0.pid, $0.startTime) }, uniquingKeysWith: { a, _ in a })
            argvs = argvs.filter { alive[$0.key] == $0.value.start }
            cwds = cwds.filter { alive[$0.key] == $0.value.start }
            sessionIDs = sessionIDs.filter { alive[$0.key] == $0.value.start }
            transcripts = transcripts.filter { now.timeIntervalSince($0.value.at) < Self.transcriptTTL * 10 }
            rebuiltThisPass = false
            if now.timeIntervalSince(indexBuilt) > Self.indexTTL { rebuildIndex() }
        }
    }

    /// local_<id> -> file (the desktop app's two-level org/user layout), plus a fresh RAMKit reader.
    private func rebuildIndex() {
        var out: [String: URL] = [:]
        let fm = FileManager.default
        for org in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for user in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: user, includingPropertiesForKeys: nil)) ?? []
                where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("local_") {
                    out[file.deletingPathExtension().lastPathComponent] = file
                }
            }
        }
        files = out
        desktop = ClaudeDesktopSessions(root: root)
        indexBuilt = now
        sessions = sessions.filter { out[$0.key] != nil }
    }

    func argv(pid: Int32) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        guard let start = alive[pid] else { return ProcessSampler.argv(pid: pid) }
        if let c = argvs[pid], c.start == start { return c.value }
        let v = ProcessSampler.argv(pid: pid)
        argvs[pid] = (start, v)
        return v
    }

    func cwd(pid: Int32) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let start = alive[pid] else { return ProcessSampler.cwd(pid: pid) }
        if let c = cwds[pid], c.start == start, now.timeIntervalSince(c.at) < Self.cwdTTL { return c.value }
        let v = ProcessSampler.cwd(pid: pid)
        cwds[pid] = (start, now, v)
        return v
    }

    func transcriptActivity(sessionID: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        if let c = transcripts[sessionID], now.timeIntervalSince(c.at) < Self.transcriptTTL { return c.value }
        let v = ClaudeTranscripts.lastActivity(sessionID: sessionID)
        transcripts[sessionID] = (now, v)
        return v
    }

    func desktopSession(pid: Int32) -> ClaudeDesktopSession? {
        lock.lock(); defer { lock.unlock() }
        let id: String?
        if let start = alive[pid], let c = sessionIDs[pid], c.start == start {
            id = c.value
        } else {
            id = ProcessSampler.env(pid: pid, name: ClaudeDesktopSessions.hostSessionVariable)
            if let start = alive[pid] { sessionIDs[pid] = (start, id) }
        }
        guard let id, id.hasPrefix("local_"), !id.contains("/") else { return nil }
        if files[id] == nil, !rebuiltThisPass {
            // A session the app created after the index was built: rebuild once per pass.
            rebuiltThisPass = true
            rebuildIndex()
        }
        guard let url = files[id] else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        if let c = sessions[id], c.modified == modified { return c.value }
        let v = desktop.session(id: id)
        sessions[id] = (modified, v)
        return v
    }
}

/// Takes process snapshots off the main thread and keeps the CPU history that needs every sample.
actor ProcessAnalyzer {
    private var cpu = CPUHistory()
    private var growth = GrowthTracker()
    private let info = CachedProcessInfo()

    func analyze(system: SystemSample?, wall: WallStatus?, reliefAvailable: Bool, now: Date = Date()) -> ProcessReport {
        let snap = ProcessSampler.snapshot(includePaths: true, now: now)
        cpu.add(snap)
        growth.add(snap)
        info.begin(snap, now: now)
        var r = Self.report(snap, cpu: cpu, info: info, system: system, wall: wall, reliefAvailable: reliefAvailable, now: now)
        r.growers = growth.top(2)
        return r
    }

    /// Everything derived from one snapshot (shared with the sample data behind `--render-ui`).
    static func report(_ snap: ProcessSnapshot, cpu: CPUHistory, info: any ProcessInfoSource, system: SystemSample?,
                       wall: WallStatus?, reliefAvailable: Bool, now: Date) -> ProcessReport {
        let groups = AppGrouper.group(snap)
        let sessions = AgentClassifier.sessions(snap, cpuHistory: cpu, info: info, now: now)
        let leftovers = AgentClassifier.leftovers(snap, cpuHistory: cpu, info: info, now: now)
        let duplicates = AgentClassifier.duplicateServers(sessions, info: info)
        let offers = LeverPlanner.offers(snapshot: snap, sessions: sessions, leftovers: leftovers, wall: wall, now: now)
        var insights: WallInsights?
        var paused: [String] = []
        var cores = 0.0
        if let system {
            let d = Diagnosis.make(system: system, wall: wall, snapshot: snap, sessions: sessions, leftovers: leftovers,
                                   reliefAvailable: reliefAvailable, firefoxProfile: nil, cpu: cpu, duplicates: duplicates, now: now)
            insights = d.insights
            paused = d.insights.stillPausedApps
            cores = d.spinningWhilePaused.reduce(0) { $0 + $1.cores }
        }
        let rows = Self.rows(groups, sessions: sessions, snapshot: snap)
        return ProcessReport(timestamp: now, rows: rows, totalFootprint: snap.totalFootprint,
                             appCount: rows.filter { $0.kind == .app }.count, sessionCount: sessions.count,
                             sessions: sessions, leftovers: leftovers, duplicates: duplicates, offers: offers,
                             insights: insights, pausedApps: paused, pausedCores: cores)
    }

    /// Sessions first (with their titles), then every other app group, largest first.
    static func rows(_ groups: [AppGroup], sessions: [AgentSession], snapshot: ProcessSnapshot) -> [AppRow] {
        let byPid = Dictionary(snapshot.records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [AppRow] = []
        var covered: Set<Int32> = []
        for s in sessions {
            covered.insert(s.id)
            var detail = s.tool.displayName
            if let host = s.host { detail += " · in \(host)" }
            rows.append(AppRow(id: "session-\(s.id)", kind: .session, name: s.title ?? s.label, detail: detail,
                               archived: s.archived, footprint: s.footprint, processCount: s.members.count,
                               iconPath: hostBundle(of: s, byPid: byPid), members: merged(s.members.filter { $0.pid != s.id })))
        }
        for g in groups where !covered.contains(g.id) {
            rows.append(AppRow(id: "app-\(g.id)", kind: .app, name: g.name, detail: nil, archived: false,
                               footprint: g.footprint, processCount: g.processCount, iconPath: g.bundlePath,
                               members: merged(g.members)))
        }
        return rows.sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.id < $1.id }
    }

    /// "plugin-container ×6  9.30 GB": same-named processes merged, largest first, five at most.
    static func merged(_ records: [ProcessRecord]) -> [AppRow.Member] {
        var totals: [String: (bytes: UInt64, count: Int)] = [:]
        var order: [String] = []
        for r in records {
            if totals[r.name] == nil { order.append(r.name) }
            totals[r.name, default: (0, 0)].bytes += r.footprint
            totals[r.name]!.count += 1
        }
        return order.map { AppRow.Member(id: $0, name: $0, count: totals[$0]!.count, footprint: totals[$0]!.bytes) }
            .sorted { $0.footprint > $1.footprint }
            .prefix(5)
            .map { $0 }
    }

    /// The bundle of the app that hosts a session (Claude, Terminal, Cursor), for its icon.
    static func hostBundle(of s: AgentSession, byPid: [Int32: ProcessRecord]) -> String? {
        guard var current = byPid[s.id] else { return nil }
        for _ in 0..<12 {
            guard current.ppid > 1, let parent = byPid[current.ppid] else { return nil }
            if let bundle = parent.path.flatMap(AppGrouper.outermostBundlePath),
               AgentTool.detect(name: parent.name, path: parent.path) == nil {
                return bundle
            }
            current = parent
        }
        return nil
    }
}

/// Main-actor state for the status item and the panel.
///
/// Sampling: the system every 2 s while the panel is open; every 10 s while it is closed (5 s from
/// 70% on, so autopilot and the imminent check stay prompt). Processes every 6 s while open, every
/// 120 s while closed (30 s from 70% on), and at once when the panel opens. While the panel is
/// closed nothing is published to SwiftUI: the glyph goes through its own subject, only on change.
@MainActor
final class AppModel: ObservableObject {
    nonisolated static let openIntervalS: TimeInterval = 2
    nonisolated static let closedIntervalS: TimeInterval = 10
    nonisolated static let closedNearWallIntervalS: TimeInterval = 5
    nonisolated static let openAnalysisS: TimeInterval = 6
    nonisolated static let closedAnalysisS: TimeInterval = 120
    nonisolated static let closedNearWallAnalysisS: TimeInterval = 30
    nonisolated static let nearWallPercent = 70.0
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
    private var lastWallWarning = Date.distantPast
    private var lastDownloadExtra: [LeverKind] = []
    private var retryingAfterRefusal = false
    @Published var showAll = false
    @Published var installing = false
    @Published var downloading = false
    @Published var resuming = false
    @Published var interruptedHold = false
    /// Levers that run with every download (remembered per lever; consent levers start off).
    @Published private(set) var alwaysLevers: Set<LeverKind>
    @Published var autopilotOn: Bool {
        didSet { defaults.set(autopilotOn, forKey: Keys.autopilot) }
    }
    @Published var menuBarPercent: Bool {
        didSet { defaults.set(menuBarPercent, forKey: Keys.menuBarPercent); publishGlyph() }
    }
    @Published var launchAtLogin: Bool

    /// What the status item shows. Not @Published on purpose: a change here must not invalidate the
    /// (possibly hidden) SwiftUI panel. Emits only when the state changes.
    let glyphSubject = CurrentValueSubject<GlyphState, Never>(GlyphState(percent: 0, atWall: false, downloading: false, frame: 0, text: ""))
    var glyph: GlyphState { glyphSubject.value }

    private(set) var panelOpen = false
    let live: Bool
    let defaults: UserDefaults
    let notifier: Notifier
    let loginItem: LoginItem

    private var wallModel = WallModel()
    private var autopilot = AutopilotPolicy()
    private let analyzer = ProcessAnalyzer()
    private var timer: Timer?
    private var nearWall = false
    private var analyzing = false
    private var analyzeAgain = false
    private var lastAnalysis = Date.distantPast
    private var pendingSystem: SystemSample?
    private var pendingWall: WallStatus?
    private var pendingReport: ProcessReport?
    /// The newest wall status whether or not the panel is open (drives the glyph).
    private var latestWall: WallStatus?
    private var receiptUnseen = false
    private var latestProgress: ReliefProgress?
    private var downloadFrame = 0
    private var lastAvailabilityCheck: Date?

    enum Keys {
        static let autopilot = "autopilot"
        static let menuBarPercent = "menuBarPercent"
        static func always(_ kind: LeverKind) -> String { "lever.always.\(kind.rawValue)" }
    }

    init(live: Bool, defaults: UserDefaults = .standard, notifier: Notifier = Notifier(), loginItem: LoginItem = LoginItem()) {
        self.live = live
        self.defaults = defaults
        self.notifier = notifier
        self.loginItem = loginItem
        autopilotOn = defaults.bool(forKey: Keys.autopilot)
        menuBarPercent = defaults.bool(forKey: Keys.menuBarPercent)
        launchAtLogin = live ? loginItem.isEnabled : false
        alwaysLevers = Set(LeverKind.allCases.filter { $0 != .kernelSignal && defaults.bool(forKey: Keys.always($0)) })
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

    private var sampleInterval: TimeInterval {
        panelOpen ? Self.openIntervalS : (nearWall ? Self.closedNearWallIntervalS : Self.closedIntervalS)
    }

    private var analysisInterval: TimeInterval {
        panelOpen ? Self.openAnalysisS : (nearWall ? Self.closedNearWallAnalysisS : Self.closedAnalysisS)
    }

    /// One timer, 25% tolerance so the kernel can coalesce the wakeup.
    private func schedule() {
        timer?.invalidate()
        let interval = sampleInterval
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
        let near = (status?.percent ?? 0) >= Self.nearWallPercent || (status?.imminent ?? false)
        if near != nearWall {
            nearWall = near
            if live { schedule() }
        }
        if Date().timeIntervalSince(lastAnalysis) >= analysisInterval { analyzeProcesses() }
        runAutopilot(status: status, sample: s)
        warnBeforeTheWall(status: status)
    }

    /// One notification when the panel is seconds away, autopilot or not, naming who is growing.
    private func warnBeforeTheWall(status: WallStatus?) {
        guard live, let status, !downloading, WallWarning.due(status, lastWarning: lastWallWarning, now: Date()) else { return }
        lastWallWarning = Date()
        let r = panelOpen ? report : (pendingReport ?? report)
        let title = WallWarning.title(status)
        let body = WallWarning.body(status, grower: r.growers.first, biggestName: r.rows.first?.name,
                                    biggestBytes: r.rows.first?.footprint ?? 0, autopilot: autopilotOn)
        let notifier = self.notifier
        Task {
            _ = await notifier.requestAuthorization()
            notifier.post(title: title, body: body)
        }
    }

    func analyzeProcesses() {
        guard !analyzing else { analyzeAgain = true; return }
        analyzing = true
        lastAnalysis = Date()
        let sample = system ?? pendingSystem
        let wallNow = latestWall
        let relief = canDownload
        Task { [weak self] in
            guard let self else { return }
            let r = await self.analyzer.analyze(system: sample, wall: wallNow, reliefAvailable: relief)
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
            showAll = false
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
            // A fresh system sample now (the pending one can be 10 s old) and a process pass unless one just ran.
            if Date().timeIntervalSince(lastAnalysis) > 2 { lastAnalysis = .distantPast }
            tick()
            Task { await checkAvailability(force: false) }
        }
    }

    // MARK: Glyph

    private func publishGlyph() {
        let pct = Int(latestWall?.percent.rounded() ?? 0)
        let next = GlyphState(percent: pct, atWall: Theme.atWall(latestWall), downloading: downloading, frame: downloadFrame,
                              text: menuBarPercent && latestWall != nil ? "\(pct)%" : "")
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

    enum HelperState: Equatable { case checking, ok, outdated, missing, notAnswering }

    var helperState: HelperState {
        switch availability {
        case .none: .checking
        case .root: .ok
        case .helper: availability?.helperOutdated == true ? .outdated : .ok
        case .unavailable(let reason): reason == ReliefError.notPermitted.description ? .missing : .notAnswering
        }
    }

    // MARK: Levers

    func setAlways(_ kind: LeverKind, _ on: Bool) {
        if on { alwaysLevers.insert(kind) } else { alwaysLevers.remove(kind) }
        defaults.set(on, forKey: Keys.always(kind))
    }

    func isAlways(_ kind: LeverKind) -> Bool { alwaysLevers.contains(kind) }

    /// Offers the panel shows: what the planner found, minus nothing (an "Always" lever still shows
    /// its row so the toggle can be turned off).
    var offers: [LeverOffer] { report.offers }

    // MARK: Download

    /// Runs the kernel signal plus the remembered levers plus `extra` (the "Do it" lever), in the
    /// engine's fixed order; each lever is measured on its own.
    func download(trigger: DownloadTrigger, extra: [LeverKind] = []) {
        guard !downloading, let backend = availability?.backend() else { return }
        lastDownloadExtra = extra
        let wanted = alwaysLevers.union(extra)
        let levers = LeverKind.allCases.filter { $0 != .kernelSignal && wanted.contains($0) }
        downloading = true
        downloadFrame = 0
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
        }, levers: levers)
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
        downloadFrame = Int(p.elapsed * 2) % 4
        publishGlyph()
        if panelOpen { progress = p }
    }

    private func finished(_ r: Receipt, trigger: DownloadTrigger) {
        retryingAfterRefusal = false
        message = nil
        downloading = false
        downloadFrame = 0
        receipt = r
        receiptUnseen = true
        if panelOpen || trigger == .user { page = .receipt } else { page = .main }
        publishGlyph()
        if trigger == .autopilot {
            let top = r.apps.first { $0.delta > 0 }.map { " · \($0.name) gave back \(Format.bytes($0.delta))" } ?? ""
            notifier.post(title: r.headlineBytes > 0 ? "\(Format.bytes(r.headlineBytes)) of RAM back" : "Nothing came back this time",
                          body: "Autopilot: wall \(Format.percent(r.wallBefore ?? 0)) → \(Format.percent(r.wallAfter ?? 0))\(top)")
        }
        lastAnalysis = .distantPast
        analyzeProcesses()
    }

    private func failed(_ error: Error, trigger: DownloadTrigger) {
        downloading = false
        downloadFrame = 0
        // The helper spaces downloads 20 s apart: wait it out once instead of failing.
        if case let ReliefError.refused(why)? = error as? ReliefError, let wait = ReliefError.retryAfter(why), !retryingAfterRefusal {
            retryingAfterRefusal = true
            message = "Starting again in \(wait + 1) s (the helper spaces downloads apart)"
            let extra = lastDownloadExtra
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(wait + 1)) { [weak self] in
                MainActor.assumeIsolated { self?.download(trigger: trigger, extra: extra) }
            }
            return
        }
        retryingAfterRefusal = false
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

    // MARK: Paused apps

    /// Resumes every process the kernel suspended at the wall, the way the Force Quit panel's
    /// Resume button does, through the helper (or directly when running as root).
    func resumePaused() {
        guard !resuming else { return }
        guard let availability, availability.backend() != nil else {
            message = "Click Resume in the Force Quit panel (no helper installed)"
            return
        }
        resuming = true
        message = nil
        let asRoot = availability == .root
        Task { [weak self] in
            let pids = await Task.detached { PausedApps.current().map(\.pid) }.value
            var failed = 0
            for pid in pids {
                if asRoot {
                    if case .failure = PausedApps.resume(pid: pid) { failed += 1 }
                } else if (try? await HelperBackend().resumePaused(pid: pid)) == nil {
                    failed += 1
                }
            }
            guard let self else { return }
            self.resuming = false
            if failed > 0 { self.message = "\(failed) of \(pids.count) could not be resumed" }
            self.lastAnalysis = .distantPast
            self.analyzeProcesses()
        }
    }

    // MARK: Autopilot

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
        // Let the panel paint "Installing helper…" before the administrator prompt blocks this thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let result = HelperSetup.install()
                self.installing = false
                switch result {
                case .success:
                    Task { await self.checkAvailability(force: true) }
                case .failure(let failure):
                    self.message = failure.description
                }
            }
        }
    }

    /// Interrupted hold: the helper restores on its own; without it the user runs `sudo ram restore`.
    func restoreHold() {
        guard case .helper = availability else { return }
        Task { [weak self] in
            try? await HelperBackend().restore()
            self?.interruptedHold = ReliefAvailability.interruptedHoldDetected
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

    // MARK: Memory pressure in this process

    /// Drops what we can rebuild: expanded rows, pending reports, image caches.
    func dropCaches() {
        expanded = []
        showAll = false
        pendingReport = nil
        if !panelOpen { report = .empty }
        latestProgress = nil
        StatusGlyph.dropCache()
        ShareCard.dropCache()
        IconCache.drop()
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    // MARK: Derived

    var visibleRows: [AppRow] {
        showAll ? report.rows : Array(report.rows.prefix(5))
    }
}

/// 16 pt app icons for the rows, rendered once per bundle at 2x and kept small.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for path: String?) -> NSImage? {
        guard let path else { return nil }
        if let cached = icons[path] { return cached }
        let source = NSWorkspace.shared.icon(forFile: path)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let small = NSImage(size: NSSize(width: 16, height: 16))
        small.addRepresentation(rep)
        icons[path] = small
        return small
    }

    static func drop() { icons = [:] }
}
