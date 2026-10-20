// Download More RAM.app: menu bar glyph + panel. LSUIElement; never opens a window by itself.
//
//   DownloadMoreRAM                                   the app
//   DownloadMoreRAM --open-panel [--exit-after N]     the app with the panel shown at launch (for `ram measure`)
//   DownloadMoreRAM --render-share <receipt.json> <out.png>
//   DownloadMoreRAM --render-clip <recording.json> <out.mp4>
//   DownloadMoreRAM --render-ui <dir> [state ...]     (debug builds) every panel state from sample data
//   DownloadMoreRAM --profile-loop                    cost of each step of the sampling loop on this Mac
import AppKit
import RAMKit

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--render-share"), args.count > i + 2 {
        exit(ShareCard.renderCLI(receiptPath: args[i + 1], outPath: args[i + 2]))
    }
    if let i = args.firstIndex(of: "--render-clip"), args.count > i + 2 {
        exit(ClipRenderer.renderCLI(recordingPath: args[i + 1], outPath: args[i + 2]))
    }
    if ProfileLoop.runIfRequested() { exit(0) }
    #if DEBUG
    if Snapshots.runIfRequested() { exit(0) }
    #endif
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
