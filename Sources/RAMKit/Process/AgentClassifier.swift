import Foundation

/// Lazily looked-up per-process details (injectable for tests).
public protocol ProcessInfoSource: Sendable {
    func cwd(pid: Int32) -> String?
    func argv(pid: Int32) -> [String]?
}

public struct LiveProcessInfo: ProcessInfoSource {
    public init() {}
    public func cwd(pid: Int32) -> String? { ProcessSampler.cwd(pid: pid) }
    public func argv(pid: Int32) -> [String]? { ProcessSampler.argv(pid: pid) }
}

/// When each process last used CPU (more than 1 ms since its last active sample).
public struct CPUHistory: Sendable {
    private var lastActive: [ProcessKey: (cpu: UInt64, at: Date)] = [:]

    public init() {}

    public mutating func add(_ s: ProcessSnapshot) {
        var next: [ProcessKey: (cpu: UInt64, at: Date)] = [:]
        next.reserveCapacity(s.records.count)
        for r in s.records {
            if let prev = lastActive[r.key], r.cpuTimeNs <= prev.cpu + 1_000_000 {
                next[r.key] = prev
            } else {
                next[r.key] = (r.cpuTimeNs, s.timestamp)
            }
        }
        lastActive = next
    }

    /// Seconds since the process last used CPU; 0 when it has never been sampled.
    public func idleSeconds(_ key: ProcessKey, now: Date) -> Double {
        guard let at = lastActive[key]?.at else { return 0 }
        return max(0, now.timeIntervalSince(at))
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
            let label = cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? tool.displayName
            return AgentSession(
                id: pid, tool: tool, host: host(of: head, byPid: byPid), cwd: cwd, label: label,
                footprint: list.reduce(0) { $0 + $1.footprint }, members: list,
                topChildren: summarize(list.filter { $0.pid != pid }),
                ageS: age(head, now: now), idleS: cpuHistory.idleSeconds(head.key, now: now))
        }
        .sorted { $0.footprint > $1.footprint }
    }

    public static func leftovers(_ s: ProcessSnapshot, cpuHistory: CPUHistory,
                                 info: ProcessInfoSource = LiveProcessInfo(), now: Date = Date()) -> [Leftover] {
        let byPid = Dictionary(s.records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let uid = getuid()
        var out: [Leftover] = []
        for r in s.records {
            // Orphaned (reparented to launchd) yet still attributed to whoever launched it: a
            // launchd job is responsible for itself, so it never qualifies.
            guard r.uid == uid, r.ppid == 1, r.responsiblePid != r.pid, isDevTool(r) else { continue }
            let ageS = age(r, now: now)
            let lifetimeCPU = ageS > 0 ? Double(r.cpuTimeNs) / 1e9 / ageS : 1
            let idle = max(cpuHistory.idleSeconds(r.key, now: now),
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
