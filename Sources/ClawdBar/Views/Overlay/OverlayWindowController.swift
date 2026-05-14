import AppKit
import SwiftUI
import Observation

@MainActor
final class OverlayWindowController: NSObject {
    private let daemon: UsageDaemon
    let settings = OverlaySettings()
    private(set) var window: NSPanel?

    init(daemon: UsageDaemon) {
        self.daemon = daemon
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if window == nil {
            window = buildWindow()
        }
        applySettings()
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func applySettings() {
        guard let window else { return }
        window.alphaValue = settings.opacity
        window.ignoresMouseEvents = settings.clickThrough
        window.isMovableByWindowBackground = !settings.locked
    }

    /// Enables or disables user-driven resizing. With borderless panels the
    /// system resize handles are stripped anyway, so the visible affordance
    /// is the SwiftUI ResizeGrip overlay — we mirror the flag here so the
    /// hosted SwiftUI view can show/hide its custom grip and so the panel's
    /// own resizable mask matches (some macOS gestures use it).
    func setResizable(_ resizable: Bool) {
        guard let window else { return }
        if resizable {
            window.styleMask.insert(.resizable)
        } else {
            window.styleMask.remove(.resizable)
        }
        rebuildHostingView(resizable: resizable)
    }

    /// Applies an incremental size delta from a drag-gesture tick.
    /// Bounded by minSize/maxSize that buildWindow() set on the panel.
    func resize(by delta: CGSize) {
        guard let window else { return }
        let current = window.frame
        let newWidth = max(window.minSize.width, min(window.maxSize.width, current.width + delta.width))
        let newHeight = max(window.minSize.height, min(window.maxSize.height, current.height + delta.height))
        // Keep the top-left corner stable while resizing from bottom-right.
        let topLeft = NSPoint(x: current.minX, y: current.maxY)
        let newFrame = NSRect(x: topLeft.x, y: topLeft.y - newHeight, width: newWidth, height: newHeight)
        window.setFrame(newFrame, display: true, animate: false)
    }

    /// Restores the overlay to its "smartwatch" default size (200×200pt),
    /// anchored at the current top-left corner.
    func resetSize() {
        guard let window else { return }
        let current = window.frame
        let topLeft = NSPoint(x: current.minX, y: current.maxY)
        let size = NSSize(width: 200, height: 200)
        let newFrame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        window.setFrame(newFrame, display: true, animate: true)
    }

    private func rebuildHostingView(resizable: Bool) {
        guard let window else { return }
        let hosting = NSHostingView(rootView: makeRoot(resizable: resizable))
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
    }

    private func buildWindow() -> NSPanel {
        let initialRect = NSRect(x: 0, y: 0, width: 200, height: 200)
        // styleMask is set without .resizable; we toggle resize on/off
        // via min/max content size below so the user-facing "Lock size"
        // toggle has a clean effect at runtime.
        let panel = OverlayPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        // Always cap the upper bound so an accidental drag can't make the
        // widget take over the screen.
        panel.minSize = NSSize(width: 140, height: 140)
        panel.maxSize = NSSize(width: 320, height: 320)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.setFrameAutosaveName("ClawdBarOverlay")
        if panel.frameAutosaveName.isEmpty {
            panel.center()
        }

        let hosting = NSHostingView(rootView: makeRoot(resizable: false))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    private func makeRoot(resizable: Bool) -> some View {
        OverlayCarouselHost(
            daemon: daemon,
            settings: settings,
            isResizable: resizable,
            onHide: { [weak self] in self?.hide() },
            onSnap: { [weak self] corner in self?.snap(to: corner) },
            onSettingsChange: { [weak self] in self?.applySettings() },
            onResize: { [weak self] delta in self?.resize(by: delta) }
        )
    }

    private func snap(to corner: OverlayContentView.Corner) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let margin: CGFloat = 16
        let origin: CGPoint
        switch corner {
        case .topLeft:
            origin = CGPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin)
        case .topRight:
            origin = CGPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
        case .bottomLeft:
            origin = CGPoint(x: visible.minX + margin, y: visible.minY + margin)
        case .bottomRight:
            origin = CGPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
        }
        window.setFrameOrigin(origin)
        window.saveFrame(usingName: "ClawdBarOverlay")
    }
}

/// NSPanel subclass that can become key so context menus and toggles work,
/// without stealing main-app focus.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
