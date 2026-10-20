import Foundation

/// AI coding agents whose sessions we attribute memory to.
public enum AgentTool: String, Codable, Sendable, CaseIterable {
    case claudeCode, codex, cursor, gemini, aider, opencode

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor Agent"
        case .gemini: "Gemini CLI"
        case .aider: "Aider"
        case .opencode: "opencode"
        }
    }

    /// Detects the agent CLI from the executable name/path, plus argv for interpreter-launched
    /// CLIs (node/python running the agent's entry script).
    public static func detect(name: String, path: String?, argv: [String]? = nil) -> AgentTool? {
        let exe = (path.map { ($0 as NSString).lastPathComponent } ?? name).lowercased()
        switch exe {
        case "claude": return .claudeCode
        case "codex": return .codex
        case "cursor-agent": return .cursor
        case "gemini": return .gemini
        case "opencode": return .opencode
        case "aider": return .aider
        default: break
        }
        if let path, path.contains("/claude-code/") { return .claudeCode }
        guard let argv, argv.count > 1, ["node", "bun", "python", "python3", "deno"].contains(exe)
                || exe.hasPrefix("python") else { return nil }
        let script = (argv[1] as NSString).lastPathComponent.lowercased()
        let full = argv[1].lowercased()
        if script == "claude" || full.contains("@anthropic-ai/claude-code") { return .claudeCode }
        if script == "codex" || full.contains("@openai/codex") { return .codex }
        if script == "gemini" || full.contains("@google/gemini-cli") { return .gemini }
        if script == "aider" || argv.contains("aider") { return .aider }
        if script == "opencode" { return .opencode }
        return nil
    }
}
