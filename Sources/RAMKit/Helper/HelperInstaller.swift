import Darwin
import Foundation

/// Installs/uninstalls the root helper as a launchd daemon. Must run as root (`sudo ram helper
/// install`); the app runs the same command through the macOS administrator prompt.
public enum HelperInstaller {
    public enum Failure: Error, CustomStringConvertible {
        case notRoot
        case helperBinaryMissing(String)
        case io(String)
        case launchctl(Int32, String)

        public var description: String {
            switch self {
            case .notRoot: "Run it with sudo:  sudo ram helper install"
            case .helperBinaryMissing(let p): "ram-helper not found next to ram (looked at \(p))"
            case .io(let m): m
            case .launchctl(let code, let out): "launchctl failed (\(code)): \(out)"
            }
        }
    }

    public static func plist(binary: String = HelperConstants.installedBinary) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(HelperConstants.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>\(HelperConstants.machService)</key>
                <true/>
            </dict>
            <!-- Runs once at boot so an interrupted hold is restored, then exits when idle (exit 0);
                 launchd relaunches it on demand and after any unsuccessful exit, including SIGKILL. -->
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>

        """
    }

    /// `ram-helper` next to the running `ram` binary (both live in .build/<config>/ or in the app
    /// bundle's Contents/Helpers/). Whoever can write that directory decides what runs as root at
    /// boot, so never put `ram helper install` in a restricted sudoers rule.
    public static func bundledHelperPath() -> String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let dir = (Bundle.main.executableURL ?? exe).resolvingSymlinksInPath().deletingLastPathComponent()
        return dir.appendingPathComponent("ram-helper").path
    }

    public static func install(helperBinary: String = bundledHelperPath()) throws {
        guard geteuid() == 0 else { throw Failure.notRoot }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: helperBinary) else { throw Failure.helperBinaryMissing(helperBinary) }
        _ = try? launchctl(["bootout", "system/\(HelperConstants.label)"])
        do {
            try fm.createDirectory(atPath: "/Library/PrivilegedHelperTools", withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
            if fm.fileExists(atPath: HelperConstants.installedBinary) { try fm.removeItem(atPath: HelperConstants.installedBinary) }
            try fm.copyItem(atPath: helperBinary, toPath: HelperConstants.installedBinary)
            try fm.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                                 ofItemAtPath: HelperConstants.installedBinary)
            try plist().write(toFile: HelperConstants.plistPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                                 ofItemAtPath: HelperConstants.plistPath)
        } catch {
            throw Failure.io("\(error.localizedDescription)")
        }
        let (code, out) = try launchctl(["bootstrap", "system", HelperConstants.plistPath])
        guard code == 0 else { throw Failure.launchctl(code, out) }
    }

    public static func uninstall() throws {
        guard geteuid() == 0 else { throw Failure.notRoot }
        // Never leave simulated pressure behind.
        _ = Trigger.write(Trigger.restoreValue)
        _ = try? launchctl(["bootout", "system/\(HelperConstants.label)"])
        let fm = FileManager.default
        for path in [HelperConstants.plistPath, HelperConstants.installedBinary] + HoldMarkers.all().map(\.path)
        where fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
        }
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: HelperConstants.plistPath)
            && FileManager.default.fileExists(atPath: HelperConstants.installedBinary)
    }

    @discardableResult
    static func launchctl(_ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
