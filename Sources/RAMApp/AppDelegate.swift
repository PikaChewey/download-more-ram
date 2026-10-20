import AppKit
import Combine
import RAMKit
import SwiftUI

/// A borderless panel that can take keyboard input without activating the app.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows the SwiftUI panel under the status item; closes on an outside click. On macOS 26 the
/// status item's window belongs to Control Center, so the panel is positioned from the button frame.
@MainActor
final class PanelController: NSObject {
    let panel: KeyablePanel
    let hosting: NSHostingController<AnyView>
    private var monitor: Any?
    private var sizeObservation: NSKeyValueObservation?
    private weak var anchor: NSStatusBarButton?
    var onVisibilityChange: ((Bool) -> Void)?

    init(model: AppModel) {
        hosting = NSHostingController(rootView: AnyView(PanelView(model: model)))
        hosting.sizingOptions = [.preferredContentSize]
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
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 11
        effect.layer?.masksToBounds = true
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        sizeObservation = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(from button: NSStatusBarButton) {
        isVisible ? hide() : show(from: button)
    }

    func show(from button: NSStatusBarButton) {
        anchor = button
        onVisibilityChange?(true)
        layout()
        panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        panel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onVisibilityChange?(false)
    }

    /// Keeps the panel's top edge under the status item as its content grows or shrinks.
    func layout() {
        guard let button = anchor, let window = button.window else { return }
        let size = hosting.preferredContentSize == .zero ? hosting.view.fittingSize : hosting.preferredContentSize
        let height = min(max(size.height, 120), Theme.maxHeight)
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = buttonFrame.midX - Theme.width / 2
        x = min(max(x, screen.minX + 6), screen.maxX - Theme.width - 6)
        let y = buttonFrame.minY - height - 4
        panel.setFrame(NSRect(x: x, y: y, width: Theme.width, height: height), display: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var model: AppModel!
    private var observers: Set<AnyCancellable> = []
    private var downloadFrame = 0
    private var animation: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var quitObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        model.$glyph
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.updateButton(state) }
            .store(in: &observers)
        updateButton(model.glyph)
        model.start()

        // Our own memory pressure: drop caches (spec 9).
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        animation?.invalidate()
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        panelController.toggle(from: sender)
    }

    private func updateButton(_ state: GlyphState) {
        guard let button = statusItem?.button else { return }
        button.image = StatusGlyph.image(wallPercent: Double(state.percent), downloading: state.downloading, frame: downloadFrame)
        button.contentTintColor = state.downloading ? nil : Theme.wallTint(Double(state.percent))
        button.title = state.text.isEmpty ? "" : " " + state.text
        button.setAccessibilityLabel("Download More RAM: \(state.percent)% to the wall")
        if state.downloading, animation == nil {
            // One lit chip walking along the stick, 2 Hz, only while a download runs.
            animation = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.downloadFrame += 1
                    self.updateButton(self.model.glyph)
                }
            }
        } else if !state.downloading {
            animation?.invalidate()
            animation = nil
            downloadFrame = 0
        }
    }
}
