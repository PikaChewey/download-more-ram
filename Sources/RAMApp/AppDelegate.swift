import AppKit
import Combine
import RAMKit
import SwiftUI

/// A borderless panel that can take keyboard input without activating the app.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's opaque canvas: the token colour, the 10 pt radius and a hairline edge. No blur.
final class CanvasView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.canvasNSColor.cgColor
        layer?.borderColor = Theme.hairlineNSColor.cgColor
    }
}

/// Shows the SwiftUI panel under the status item; closes on an outside click or Escape. The SwiftUI
/// tree is built on the first open and kept (nothing is published to it while the panel is closed).
/// On macOS 26 the status item's window belongs to Control Center, so the panel is positioned from
/// the button frame.
@MainActor
final class PanelController: NSObject {
    let panel: KeyablePanel
    private let model: AppModel
    private var hosting: NSHostingController<AnyView>?
    private var monitor: Any?
    private var keyMonitor: Any?
    private var sizeObservation: NSKeyValueObservation?
    private weak var anchor: NSStatusBarButton?
    var onVisibilityChange: ((Bool) -> Void)?

    init(model: AppModel) {
        self.model = model
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Theme.width, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace]
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: Theme.width, height: 200))
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = Theme.radiusPanel
        canvas.layer?.cornerCurve = .continuous
        canvas.layer?.masksToBounds = true
        canvas.layer?.borderWidth = Theme.hairline
        panel.contentView = canvas
    }

    var isVisible: Bool { panel.isVisible }

    private func ensureHosting() {
        guard hosting == nil, let canvas = panel.contentView else { return }
        let h = NSHostingController(rootView: AnyView(PanelView(model: model)))
        h.sizingOptions = [.preferredContentSize]
        h.view.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(h.view)
        NSLayoutConstraint.activate([
            h.view.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            h.view.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            h.view.topAnchor.constraint(equalTo: canvas.topAnchor),
            h.view.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
        ])
        sizeObservation = h.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        hosting = h
    }

    func toggle(from button: NSStatusBarButton) {
        isVisible ? hide() : show(from: button)
    }

    func show(from button: NSStatusBarButton) {
        let start = DispatchTime.now().uptimeNanoseconds
        anchor = button
        ensureHosting()
        onVisibilityChange?(true)
        layout()
        panel.makeKeyAndOrderFront(nil)
        if ProcessInfo.processInfo.arguments.contains("--open-panel") {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            FileHandle.standardError.write(Data(String(format: "panel shown in %.1f ms\n", ms).utf8))
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Escape
            MainActor.assumeIsolated { self?.hide() }
            return nil
        }
    }

    /// Loads SwiftUI's renderer and the fonts once, a few seconds after launch, so the first click
    /// builds the panel in tens of milliseconds instead of hundreds. The throwaway view is released.
    func warmUp() {
        guard hosting == nil else { return }
        let host = NSHostingView(rootView: Text("Download More RAM").font(Theme.body))
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        host.layoutSubtreeIfNeeded()
        host.display()
    }

    func hide() {
        panel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        monitor = nil
        keyMonitor = nil
        onVisibilityChange?(false)
    }

    /// Keeps the panel's top edge under the status item as its content grows or shrinks.
    func layout() {
        guard let button = anchor, let window = button.window, let hosting else { return }
        let size = hosting.preferredContentSize == .zero ? hosting.view.fittingSize : hosting.preferredContentSize
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let height = min(max(size.height, 120), max(200, screen.height - 16))
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonFrame.midX - Theme.width / 2
        x = min(max(x, screen.minX + 6), screen.maxX - Theme.width - 6)
        let y = buttonFrame.minY - height - 4
        panel.setFrame(NSRect(x: x, y: y, width: Theme.width, height: height), display: true)
    }
}

/// Debug and measurement switches: `--open-panel` shows the panel at launch (so panel-open CPU can
/// be measured with `ram measure`), `--exit-after N` quits after N seconds.
struct LaunchFlags {
    var openPanel = false
    var exitAfter: Double?

    static func parse(_ args: [String]) -> LaunchFlags {
        var f = LaunchFlags()
        f.openPanel = args.contains("--open-panel")
        if let i = args.firstIndex(of: "--exit-after"), args.count > i + 1 { f.exitAfter = Double(args[i + 1]) }
        return f
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var model: AppModel!
    private var observers: Set<AnyCancellable> = []
    private var pressureSource: DispatchSourceMemoryPressure?
    private var quitObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let flags = LaunchFlags.parse(CommandLine.arguments)
        model = AppModel(live: true)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        panelController = PanelController(model: model)
        panelController.onVisibilityChange = { [weak self] open in self?.model.setPanelOpen(open) }
        // The subject replays its current value and emits only on change, on the main actor.
        model.glyphSubject
            .sink { [weak self] state in self?.updateButton(state) }
            .store(in: &observers)
        model.start()

        // Our own memory pressure: drop caches.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.model.dropCaches() }
        }
        source.resume()
        pressureSource = source

        quitObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("ca.bryanyao.DownloadMoreRAM.quit"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.panelController.warmUp() }
        }
        if flags.openPanel {
            // After the warm-up, as a first click would be.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let button = self.statusItem.button else { return }
                    self.panelController.show(from: button)
                }
            }
        }
        if let seconds = flags.exitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        panelController.toggle(from: sender)
    }

    /// Template image only: never tinted (the menu bar decides the colour).
    private func updateButton(_ state: GlyphState) {
        guard let button = statusItem?.button else { return }
        button.image = StatusGlyph.image(wallPercent: Double(state.percent), atWall: state.atWall,
                                         downloading: state.downloading, frame: state.frame)
        button.title = state.text.isEmpty ? "" : " " + state.text
        button.setAccessibilityLabel("Download More RAM: \(state.percent)% to the wall")
    }
}
