import AppKit
import Foundation
import RAMKit
import ServiceManagement
import UserNotifications

/// User notifications for autopilot. Only usable from inside the .app bundle (UNUserNotificationCenter
/// aborts in a bare executable), so everything is a no-op during `--render-ui` and dev runs.
@MainActor
final class Notifier {
    let available: Bool

    init() {
        available = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func requestAuthorization() async -> Bool {
        guard available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Launch at login through SMAppService (needs the .app bundle).
@MainActor
final class LoginItem {
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var isEnabled: Bool {
        guard available else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ on: Bool) throws {
        guard available else { return }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Runs the bundled CLI's own installer (`ram helper install`) through the macOS administrator
/// prompt. The password is typed into the system dialog, never seen by this app.
enum HelperSetup {
    enum Failure: Error, CustomStringConvertible {
        case cliMissing(String)
        case cancelled
        case failed(String)

        var description: String {
            switch self {
            case .cliMissing(let p): "The ram command is missing from the app bundle (looked at \(p))."
            case .cancelled: "Install cancelled."
            case .failed(let why): "Install failed: \(why)"
            }
        }
    }

    /// `<bundle>/Contents/Helpers/ram`, or `ram` next to a bare dev executable.
    static func cliPath() -> String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ram").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return exe.deletingLastPathComponent().appendingPathComponent("ram").path
    }

    /// `do shell script (quoted form of "<path>") & " helper install" with administrator privileges`.
    static func script(cliPath: String) -> String {
        let escaped = cliPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script (quoted form of \"\(escaped)\") & \" helper install\" with administrator privileges"
    }

    @MainActor
    static func install() -> Result<Void, Failure> {
        let path = cliPath()
        guard FileManager.default.isExecutableFile(atPath: path) else { return .failure(.cliMissing(path)) }
        guard let apple = NSAppleScript(source: script(cliPath: path)) else { return .failure(.failed("could not compile the install script")) }
        var error: NSDictionary?
        apple.executeAndReturnError(&error)
        guard let error else { return .success(()) }
        let number = error[NSAppleScript.errorNumber] as? Int ?? 0
        if number == -128 { return .failure(.cancelled) }
        let text = (error[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(number)"
        return .failure(.failed(text))
    }
}
