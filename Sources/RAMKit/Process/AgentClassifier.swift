import Foundation

/// Lazily looked-up per-process details (injectable for tests).
public protocol ProcessInfoSource: Sendable {
    func cwd(pid: Int32) -> String?
    func argv(pid: Int32) -> [String]?
    func transcriptActivity(sessionID: String) -> Date?
    /// Claude desktop session metadata for a Claude Code process, when the app launched it.
    func desktopSession(pid: Int32) -> ClaudeDesktopSession?
}

extension ProcessInfoSource {
    public func transcriptActivity(sessionID: String) -> Date? { nil }
    public func desktopSession(pid: Int32) -> ClaudeDesktopSession? { nil }
}

public struct LiveProcessInfo: ProcessInfoSource {
    let sessions: ClaudeDesktopSessions
    public init(sessions: ClaudeDesktopSessions = ClaudeDesktopSessions()) { self.sessions = sessions }
    public func cwd(pid: Int32) -> String? { ProcessSampler.cwd(pid: pid) }
    public func argv(pid: Int32) -> [String]? { ProcessSampler.argv(pid: pid) }
    public func transcriptActivity(sessionID: String) -> Date? { ClaudeTranscripts.lastActivity(sessionID: sessionID) }
    public func desktopSession(pid: Int32) -> ClaudeDesktopSession? {
        guard let id = ProcessSampler.env(pid: pid, name: ClaudeDesktopSessions.hostSessionVariable) else { return nil }
        return sessions.session(id: id)
    }
}

/// What the Claude desktop app records about a Code-tab session
/// (~/Library/Application Support/Claude/claude-code-sessions/<org>/<user>/local_<id>.json).
public struct ClaudeDesktopSession: Codable, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var lastActivity: Date?
    public var archived: Bool

    public init(id: String, title: String?, lastActivity: Date?, archived: Bool) {
        self.id = id
        self.title = title
        self.lastActivity = lastActivity
        self.archived = archived
    }
}

/// Index of the desktop app's session files. A Claude Code process the app started carries its
/// session id in `CLAUDE_CODE_HOST_SESSION_ID` (VERIFIED 2026-10-20 on Claude desktop with Claude Code 2.1.299).
public final class ClaudeDesktopSessions: @unchecked Sendable {
    public static let hostSessionVariable = "CLAUDE_CODE_HOST_SESSION_ID"
    let root: URL
    private let lock = NSLock()
    private var paths: [String: URL]?

    public init(root: URL = RealUser.home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)) {
        self.root = root
    }

    public func session(id: String) -> ClaudeDesktopSession? {
        guard id.hasPrefix("local_"), !id.contains("/") else { return nil }
        guard let url = index()[id], let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let ms = (obj["lastActivityAt"] as? NSNumber)?.doubleValue
        return ClaudeDesktopSession(id: id, title: (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                    lastActivity: ms.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) },
                                    archived: (obj["isArchived"] as? Bool) ?? false)
    }

    /// local_<id> -> file, from a two-level directory walk (org/user), built once per instance.
    func index() -> [String: URL] {
        lock.lock(); defer { lock.unlock() }
        if let paths { return paths }
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
        paths = out
        return out
    }
}

/// When each process was last *active*: using more than `activeFraction` of a core between two
/// samples. A plain "CPU went up" test is useless here: every idle Claude Code session still burns
/// 0.4-0.9% of a core on timers (measured on the target, 2026-10-20), working ones 1.1-3.6%.
public struct CPUHistory: Sendable {
    public static let activeFraction = 0.01

    private var previous: [ProcessKey: (cpu: UInt64, at: Date)] = [:]
    private var lastActive: [ProcessKey: Date] = [:]
    private var firstSeen: [ProcessKey: Date] = [:]
    private var rate: [ProcessKey: Double] = [:]

    public init() {}

    public mutating func add(_ s: ProcessSnapshot) {
        var nextPrev: [ProcessKey: (cpu: UInt64, at: Date)] = [:]
        var nextActive: [ProcessKey: Date] = [:]
        var nextFirst: [ProcessKey: Date] = [:]
        var nextRate: [ProcessKey: Double] = [:]
        for r in s.records {
            let k = r.key
            nextFirst[k] = firstSeen[k] ?? s.timestamp
            if let a = lastActive[k] { nextActive[k] = a }
            if let p = previous[k] {
                let dt = s.timestamp.timeIntervalSince(p.at)
                if dt > 0 {
                    let f = Double(r.cpuTimeNs &- min(r.cpuTimeNs, p.cpu)) / 1e9 / dt
                    nextRate[k] = f
                    if f > Self.activeFraction { nextActive[k] = s.timestamp }
                }
            }
            nextPrev[k] = (r.cpuTimeNs, s.timestamp)
        }
        previous = nextPrev
        lastActive = nextActive
        firstSeen = nextFirst
        rate = nextRate
    }

    /// Seconds since the process was last active (since first sighting if never seen active).
    public func idleSeconds(_ key: ProcessKey, now: Date) -> Double {
        guard let since = lastActive[key] ?? firstSeen[key] else { return 0 }
        return max(0, now.timeIntervalSince(since))
    }

    /// CPU use between the last two samples, as a fraction of one core.
    public func cpuFraction(_ key: ProcessKey) -> Double? { rate[key] }
}

/// Last activity of a Claude Code session from its transcript (~/.claude/projects/*/<id>.jsonl is
/// appended on every message). Only for sessions started with --resume/--session-id; a forked
/// session writes to a new id we cannot see, so callers fall back to CPU.
public enum ClaudeTranscripts {
    public static func sessionID(argv: [String]) -> String? {
        if argv.contains("--fork-session") { return nil }
        for (i, a) in argv.enumerated() {
            for flag in ["--resume", "--session-id"] {
                if a.hasPrefix(flag + "=") { return String(a.dropFirst(flag.count + 1)) }
                if a == flag, i + 1 < argv.count { return argv[i + 1] }
            }
        }
        return nil
    }

    public static func lastActivity(sessionID: String, projectsDir: URL = defaultProjectsDir) -> Date? {
        guard sessionID.count >= 8, !sessionID.contains("/") else { return nil }
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir.path) else { return nil }
        for d in dirs {
            let file = projectsDir.appendingPathComponent(d).appendingPathComponent("\(sessionID).jsonl").path
            if let attrs = try? fm.attributesOfItem(atPath: file), let m = attrs[.modificationDate] as? Date { return m }
        }
        return nil
    }

    public static var defaultProjectsDir: URL {
        RealUser.home.appendingPathComponent(".claude/projects", isDirectory: true)
    }
}

/// One AI agent session and everything it is responsible for.
public struct AgentSession: Codable, Sendable, Identifiable {
    public var id: Int32
    public var tool: AgentTool
    public var host: String?
    public var cwd: String?
    public var label: String
    public var footprint: UInt64
    public var members: [ProcessRecord]
    public var topChildren: String
    public var ageS: Double
    public var idleS: Double
    /// CPU use of the session process between the last two samples (fraction of a core).
    public var cpuFraction: Double?
    /// From the Claude desktop session record, else the session transcript, when known.
    public var lastActive: Date?
    /// The session's title in the Claude desktop app (shown locally only, never on share cards).
    public var title: String?
    /// The user archived this session in the Claude app, yet its processes are still running.
    public var archived: Bool = false
}

/// A process that probably outlived its purpose (spec 5.4). Never acted on without a click.
public struct Leftover: Codable, Sendable, Identifiable {
    public var record: ProcessRecord
    public var reason: String
    public var idleS: Double
    public var id: ProcessKey { record.key }
}

public enum AgentClassifier {
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby"]
    static let devTools: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "java", "php", "perl", "ffmpeg",
        "llama-server", "ollama", "esbuild", "vite", "next-server", "tsserver", "gopls", "rust-analyzer",
        "pyright", "uvicorn", "gunicorn", "chrome-headless-shell", "google chrome for testing",
        "chromium", "headless_shell", "playwright", "puppeteer", "mcp", "npx", "uv", "uvx",
    ]
    /// Leftovers must have been idle at least this long.
    public static let idleThreshold: Double = 600

    public static func sessions(_ s: ProcessSnapshot, cpuHistory: CPUHistory,
                                info: ProcessInfoSource = LiveProcessInfo(), now: Date = Date()) -> [AgentSession] {
        let byPid = Dictionary(s.records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var tools: [Int32: AgentTool] = [:]
        for r in s.records {
            let exe = r.name.lowercased()
            let argv = interpreters.contains(exe) || exe.hasPrefix("python") ? info.argv(pid: r.pid) : nil
            if let tool = AgentTool.detect(name: r.name, path: r.path, argv: argv) { tools[r.pid] = tool }
        }
        // A session head is an agent process that is not itself attributed to another agent.
        let heads = tools.keys.filter { pid in
            guard let r = byPid[pid] else { return false }
            return r.responsiblePid == pid || tools[r.responsiblePid] == nil
        }
        let children = Dictionary(grouping: s.records, by: \.ppid)

        return heads.compactMap { pid -> AgentSession? in
            guard let head = byPid[pid], let tool = tools[pid] else { return nil }
            var members: [Int32: ProcessRecord] = [pid: head]
            for r in s.records where r.responsiblePid == pid { members[r.pid] = r }
            var stack = [pid]
            while let p = stack.popLast() {
                for c in children[p] ?? [] where members[c.pid] == nil { members[c.pid] = c; stack.append(c.pid) }
            }
            let list = members.values.sorted { $0.footprint > $1.footprint }
            let cwd = info.cwd(pid: pid)
            let desktop = tool == .claudeCode ? info.desktopSession(pid: pid) : nil
            let lastActive = desktop?.lastActivity ?? (tool == .claudeCode
                ? info.argv(pid: pid).flatMap(ClaudeTranscripts.sessionID).flatMap { info.transcriptActivity(sessionID: $0) }
                : nil)
            let label = desktop?.title ?? cwd.map(Self.label(forCwd:)) ?? tool.displayName
            return AgentSession(
                id: pid, tool: tool, host: host(of: head, byPid: byPid), cwd: cwd, label: label,
                footprint: list.reduce(0) { $0 + $1.footprint }, members: list,
                topChildren: summarize(list.filter { $0.pid != pid }),
                ageS: age(head, now: now), idleS: cpuHistory.idleSeconds(head.key, now: now),
                cpuFraction: cpuHistory.cpuFraction(head.key), lastActive: lastActive,
                title: desktop?.title, archived: desktop?.archived ?? false)
        }
        .sorted { $0.footprint > $1.footprint }
    }

    public static func leftovers(_ s: ProcessSnapshot, cpuHistory: CPUHistory,
                                 info: ProcessInfoSource = LiveProcessInfo(), now: Date = Date()) -> [Leftover] {
        let byPid = Dictionary(s.records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let uid = RealUser.uid
        var out: [Leftover] = []
        for r in s.records {
            // Orphaned (reparented to launchd) yet still attributed to whoever launched it: a
            // launchd job is responsible for itself, so it never qualifies.
            guard r.uid == uid, r.ppid == 1, r.responsiblePid != r.pid, isDevTool(r) else { continue }
            let ageS = age(r, now: now)
            let lifetimeCPU = ageS > 0 ? Double(r.cpuTimeNs) / 1e9 / ageS : 1
            let activeNow = (cpuHistory.cpuFraction(r.key) ?? 0) > CPUHistory.activeFraction
            let idle = activeNow ? 0 : max(cpuHistory.idleSeconds(r.key, now: now),
                                           lifetimeCPU < 0.005 && ageS >= 1800 ? ageS : 0)
            guard idle >= idleThreshold else { continue }
            let what = describe(r, argv: info.argv(pid: r.pid))
            let owner: String
            if let resp = byPid[r.responsiblePid] {
                let tool = AgentTool.detect(name: resp.name, path: resp.path)
                owner = tool.map { "from a \($0.displayName) session (still running)" } ?? "from \(resp.name)"
            } else {
                owner = "from a session that has exited"
            }
            out.append(Leftover(record: r, reason: "orphaned \(what) \(owner) · idle \(Format.duration(idle))", idleS: idle))
        }
        return out.sorted { $0.record.footprint > $1.record.footprint }
    }

    /// Archived in the Claude app AND quiet: not using CPU now and no recorded activity for 30 min.
    /// (The archived flag comes from an id the process got at launch, so it alone is not enough.)
    public static func safeToQuitArchived(_ s: AgentSession, now: Date = Date()) -> Bool {
        guard s.archived else { return false }
        if let cpu = s.cpuFraction, cpu > CPUHistory.activeFraction { return false }
        if let last = s.lastActive, now.timeIntervalSince(last) < 1800 { return false }
        return true
    }

    /// "~" for the home folder, "~/Projects/stdout" -> "stdout", "/" -> "/".
    static func label(forCwd cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home || cwd == home + "/" { return "~" }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? cwd : last
    }

    static func isDevTool(_ r: ProcessRecord) -> Bool {
        let exe = ((r.path.map { ($0 as NSString).lastPathComponent }) ?? r.name).lowercased()
        return devTools.contains(exe) || exe.hasPrefix("python3.") || exe.hasSuffix("-language-server")
            || exe.hasSuffix("-mcp") || exe.hasPrefix("mcp-")
    }

    /// "http.server :8765", "node vite", "ffmpeg".
    static func describe(_ r: ProcessRecord, argv: [String]?) -> String {
        guard let argv, argv.count > 1 else { return r.name }
        if let m = argv.firstIndex(of: "-m"), m + 1 < argv.count {
            let module = argv[m + 1]
            if module == "http.server", let port = argv.dropFirst(m + 2).first(where: { Int($0) != nil }) {
                return "http.server :\(port)"
            }
            return module
        }
        let script = (argv[1] as NSString).lastPathComponent
        return script.hasPrefix("-") ? r.name : "\(r.name) \(script)"
    }

    static func host(of head: ProcessRecord, byPid: [Int32: ProcessRecord]) -> String? {
        var current = head
        for _ in 0..<12 {
            guard current.ppid > 1, let parent = byPid[current.ppid] else { return nil }
            if let bundle = parent.path.flatMap(AppGrouper.outermostBundlePath),
               AgentTool.detect(name: parent.name, path: parent.path) == nil {
                return AppGrouper.bundleDisplayName(bundlePath: bundle)
            }
            current = parent
        }
        return nil
    }

    /// "Blender ×2, ffmpeg, Python": the three largest child names by total footprint.
    static func summarize(_ records: [ProcessRecord]) -> String {
        var totals: [String: (bytes: UInt64, count: Int)] = [:]
        for r in records { totals[r.name, default: (0, 0)].bytes += r.footprint; totals[r.name]!.count += 1 }
        return totals.sorted { $0.value.bytes > $1.value.bytes }.prefix(3)
            .map { $0.value.count > 1 ? "\($0.key) ×\($0.value.count)" : $0.key }
            .joined(separator: ", ")
    }

    static func age(_ r: ProcessRecord, now: Date) -> Double {
        guard r.startTime > 0 else { return 0 }
        return max(0, now.timeIntervalSince1970 - Double(r.startTime) / 1e6)
    }
}
