import Foundation

/// The same helper process (typically a stdio MCP server) running once per agent session.
/// Each Claude Code session starts its own copy of every configured stdio MCP server, so N sessions
/// mean N copies (observed 2026-10-20: 16 x `rea mcp` at ~202 MB each, 3.2 GB).
public struct DuplicateServer: Codable, Sendable, Identifiable, Equatable {
    public var command: String
    public var count: Int
    public var sessions: Int
    public var bytes: UInt64
    public var pids: [Int32]
    public var id: String { command }
}

extension AgentClassifier {
    static let notServers: Set<String> = ["zsh", "bash", "sh", "fish", "login", "disclaimer", "caffeinate", "sleep",
                                          "claude", "codex", "git", "ssh", "rg", "find"]

    /// Commands that appear in at least `minSessions` different sessions, averaging >= 20 MB each.
    public static func duplicateServers(_ sessions: [AgentSession], info: ProcessInfoSource = LiveProcessInfo(),
                                        minSessions: Int = 3) -> [DuplicateServer] {
        var groups: [String: (pids: [Int32], bytes: UInt64, sessions: Set<Int32>)] = [:]
        for s in sessions {
            for m in s.members where m.pid != s.id {
                guard let key = serverKey(m, argv: info.argv(pid: m.pid)) else { continue }
                var g = groups[key] ?? ([], 0, [])
                g.pids.append(m.pid)
                g.bytes += m.footprint
                g.sessions.insert(s.id)
                groups[key] = g
            }
        }
        return groups.compactMap { key, g in
            guard g.sessions.count >= minSessions, g.bytes / UInt64(max(1, g.pids.count)) >= 20 << 20 else { return nil }
            return DuplicateServer(command: key, count: g.pids.count, sessions: g.sessions.count, bytes: g.bytes, pids: g.pids.sorted())
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// "rea mcp" for `node /opt/homebrew/bin/rea mcp`, "server-github" for `npx -y @modelcontextprotocol/server-github`,
    /// "github-mcp-server stdio" for a native binary with a subcommand.
    static func serverKey(_ r: ProcessRecord, argv: [String]?) -> String? {
        let exe = ((r.path.map { ($0 as NSString).lastPathComponent }) ?? r.name)
        if notServers.contains(exe.lowercased()) { return nil }
        let tokens = (argv ?? []).dropFirst().filter { !$0.hasPrefix("-") }.map { ($0 as NSString).lastPathComponent }
        let launchers: Set<String> = ["node", "bun", "deno", "npx", "uv", "uvx", "python", "python3", "pipx", "bunx"]
        if launchers.contains(exe.lowercased()) || exe.lowercased().hasPrefix("python3.") {
            guard !tokens.isEmpty else { return exe }
            return tokens.prefix(2).joined(separator: " ")
        }
        return tokens.first.map { "\(exe) \($0)" } ?? exe
    }
}
