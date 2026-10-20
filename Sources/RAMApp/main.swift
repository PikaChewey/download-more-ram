// Download More RAM.app: menu bar glyph + panel. LSUIElement; never opens a window by itself.
import AppKit
import RAMKit

MainActor.assumeIsolated {
    #if DEBUG
    if Snapshots.runIfRequested() { exit(0) }
    #endif
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
