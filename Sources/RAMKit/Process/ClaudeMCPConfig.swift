import Foundation

/// Claude Code's user-scope MCP servers (`mcpServers` at the root of ~/.claude.json) start in EVERY
/// session; project-scope ones only where they are configured. Only names, commands and args are read
/// (never `env`, which can hold secrets).
public enum ClaudeMCPConfig {
    public static var defaultPath: URL { RealUser.home.appendingPathComponent(".claude.json") }

    /// name -> [command basename] + args basenames.
    public static func userScopeServers(path: URL = defaultPath) -> [String: [String]] {
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return [:] }
        var out: [String: [String]] = [:]
        for (name, value) in servers {
            guard let spec = value as? [String: Any] else { continue }
            var tokens: [String] = []
            if let command = spec["command"] as? String { tokens.append((command as NSString).lastPathComponent) }
            if let args = spec["args"] as? [String] { tokens += args.map { ($0 as NSString).lastPathComponent } }
            out[name] = tokens
        }
        return out
    }

    /// The user-scope server a duplicate comes from, if every word of its command appears in that server's command line.
    public static func userScopeName(for d: DuplicateServer, servers: [String: [String]]) -> String? {
        let words = d.command.split(separator: " ").map(String.init)
        return servers.first { _, tokens in words.allSatisfy { w in tokens.contains(w) } }?.key
    }
}
