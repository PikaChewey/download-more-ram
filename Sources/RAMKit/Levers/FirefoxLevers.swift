import Foundation

/// The two Firefox levers that really exist on macOS (docs/research/apps.md):
/// 1. Firefox's own low-memory tab unloader responds to critical pressure only when
///    `browser.lowMemoryResponseMask` is non-zero; release builds ship 0 (Nightly 3).
/// 2. The GPU process ("Firefox GPU Helper") is designed to be relaunched when it dies; a kill
///    after 30 s of uptime does not count toward `layers.gpu-process.max_restarts`.
public enum FirefoxLevers {
    public static let prefName = "browser.lowMemoryResponseMask"
    public static let enabledValue = 3
    static let marker = "// added by Download More RAM: let Firefox unload idle tabs under critical memory pressure"
    public static let gpuMinUptimeS: Double = 30

    public static var supportDir: URL {
        RealUser.home.appendingPathComponent("Library/Application Support/Firefox", isDirectory: true)
    }

    /// The profile Firefox opens by default: the `[Install…]` section's Default=, else the
    /// `[Profile…]` with Default=1.
    public static func defaultProfile(supportDir: URL = supportDir) -> URL? {
        guard let ini = try? String(contentsOf: supportDir.appendingPathComponent("profiles.ini"), encoding: .utf8) else { return nil }
        var section = ""
        var installDefault: String?
        var profilePath: String?
        var profileIsDefault = false
        var markedDefault: String?
        func closeProfile() {
            if profileIsDefault, let p = profilePath { markedDefault = p }
            profilePath = nil
            profileIsDefault = false
        }
        for raw in ini.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { closeProfile(); section = line; continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if section.hasPrefix("[Install"), parts[0] == "Default" { installDefault = installDefault ?? parts[1] }
            if section.hasPrefix("[Profile") {
                if parts[0] == "Path" { profilePath = parts[1] }
                if parts[0] == "Default", parts[1] == "1" { profileIsDefault = true }
            }
        }
        closeProfile()
        guard let rel = installDefault ?? markedDefault else { return nil }
        let url = rel.hasPrefix("/") ? URL(fileURLWithPath: rel) : supportDir.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The effective mask: user.js wins over prefs.js; nil when neither sets it (release default 0).
    public static func lowMemoryResponseMask(profile: URL) -> Int? {
        for file in ["user.js", "prefs.js"] {
            guard let text = try? String(contentsOf: profile.appendingPathComponent(file), encoding: .utf8) else { continue }
            if let v = lastIntPref(prefName, in: text) { return v }
        }
        return nil
    }

    public static func isUnloaderOn(profile: URL) -> Bool { (lowMemoryResponseMask(profile: profile) ?? 0) != 0 }

    /// Firefox's main process (not a content, GPU or crash-helper process).
    public static func mainProcess(in snapshot: ProcessSnapshot) -> ProcessRecord? {
        snapshot.records.first { $0.name == "firefox" && ($0.path?.hasSuffix(".app/Contents/MacOS/firefox") ?? false) }
    }

    /// The pref is in user.js but the running Firefox started before it was written. Firefox reads
    /// user.js only at launch, so the unloader is not active until Firefox restarts.
    public static func unloaderNeedsRestart(profile: URL, snapshot: ProcessSnapshot) -> Bool {
        guard isUnloaderOn(profile: profile), let main = mainProcess(in: snapshot),
              let written = (try? FileManager.default.attributesOfItem(atPath: profile.appendingPathComponent("user.js").path))?[.modificationDate] as? Date
        else { return false }
        return Date(timeIntervalSince1970: Double(main.startTime) / 1_000_000) < written
    }

    /// Appends our line to user.js (replacing an earlier one of ours). Takes effect at the next Firefox start.
    public static func enableUnloader(profile: URL) throws {
        let url = profile.appendingPathComponent("user.js")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text = removingOurLines(text)
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\(marker)\nuser_pref(\"\(prefName)\", \(enabledValue));\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Removes exactly what `enableUnloader` added.
    public static func disableUnloader(profile: URL) throws {
        let url = profile.appendingPathComponent("user.js")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        try removingOurLines(text).write(to: url, atomically: true, encoding: .utf8)
    }

    static func removingOurLines(_ text: String) -> String {
        var out: [Substring] = []
        var skipNext = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if skipNext { skipNext = false; if line.contains(prefName) { continue } }
            if line == marker { skipNext = true; continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    static func lastIntPref(_ name: String, in text: String) -> Int? {
        var found: Int?
        for line in text.split(separator: "\n") where line.contains("\"\(name)\"") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            guard let comma = line.lastIndex(of: ","), let close = line.lastIndex(of: ")") , comma < close else { continue }
            if let v = Int(line[line.index(after: comma)..<close].trimmingCharacters(in: .whitespaces)) { found = v }
        }
        return found
    }

    /// Firefox's GPU process (`gpu-helper.app/.../Firefox GPU Helper`).
    public static func gpuProcess(in snapshot: ProcessSnapshot) -> ProcessRecord? {
        snapshot.records.first { r in
            (r.path?.contains("/gpu-helper.app/") ?? false) || r.name == "Firefox GPU Helper"
        }
    }

    public enum GPURestart: Equatable, Sendable { case restarted, tooYoung(Double), refused(KillRefusal) }

    /// SIGTERMs the GPU process if it has been up long enough not to count as an unstable crash.
    public static func restartGPU(_ r: ProcessRecord, now: Date = Date()) -> GPURestart {
        let uptime = now.timeIntervalSince1970 - Double(r.startTime) / 1e6
        guard r.startTime > 0, uptime > gpuMinUptimeS else { return .tooYoung(uptime) }
        switch SafeKill.terminate(r, escalate: false) {
        case .ok: return .restarted
        case .refused(let why): return .refused(why)
        }
    }
}
