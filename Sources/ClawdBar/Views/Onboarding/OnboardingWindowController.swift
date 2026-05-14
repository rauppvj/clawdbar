import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject {
    private let settings: AppSettings
    private let daemon: UsageDaemon
    private var window: NSWindow?

    init(settings: AppSettings, daemon: UsageDaemon) {
        self.settings = settings
        self.daemon = daemon
        super.init()
    }

    func presentIfNeeded() {
        guard !settings.onboardingDone else { return }
        present()
    }

    func present() {
        if window == nil {
            window = build()
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = "ClawdBar"
        win.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: OnboardingView(settings: settings, daemon: daemon) { [weak self] in
            guard let self else { return }
            self.settings.onboardingDone = true
            // Kick off polling now that the user authorized keychain access
            // during the Connect step. The cache is already warm so this
            // first poll uses the in-memory token (no extra prompt).
            self.daemon.start()
            self.window?.close()
        })
        hosting.autoresizingMask = [.width, .height]
        win.contentView = hosting
        return win
    }
}
