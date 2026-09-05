import SwiftUI
import AppKit

@main
struct ClawdBarApp: App {
    @State private var settings: AppSettings
    @State private var notifications = NotificationManager()
    @State private var daemon: UsageDaemon
    @State private var status: StatusMonitor
    @State private var tokens: TokenUsageMonitor
    @State private var overlay: OverlayWindowController?
    @State private var onboarding: OnboardingWindowController

    init() {
        let args = CommandLine.arguments
        if args.contains(ProbeCommand.flag) {
            exit(ProbeCommand.run())
        }
        if args.contains(APIProbeCommand.flag) {
            exit(APIProbeCommand.run())
        }
        if args.contains(ResetCommand.flag) {
            exit(ResetCommand.run())
        }
        if args.contains(ExportIconCommand.flag) {
            exit(ExportIconCommand.run(arguments: args))
        }
        if args.contains(StatusProbeCommand.flag) {
            exit(StatusProbeCommand.run())
        }
        if args.contains(TokenRenderCommand.flag) {
            exit(TokenRenderCommand.run(arguments: args))
        }
        if args.contains(TokenProbeCommand.flag) {
            exit(TokenProbeCommand.run())
        }
        if args.contains(ForgetCredentialCommand.flag) {
            exit(ForgetCredentialCommand.run())
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        BundledFont.registerAll()

        let loadedSettings = AppSettings()
        let client = AnthropicAPIClient(
            configuration: .init(
                baseURL: URL(string: loadedSettings.apiBaseURL) ?? AnthropicAPIClient.Configuration.default.baseURL,
                model: loadedSettings.apiModel,
                apiVersion: AnthropicAPIClient.Configuration.default.apiVersion,
                timeout: AnthropicAPIClient.Configuration.default.timeout
            )
        )
        // Don't auto-start polling. On a fresh install we want onboarding
        // to drive the first keychain read so we don't issue two concurrent
        // SecItemCopyMatching calls (which would each trigger a prompt).
        let daemon = UsageDaemon(client: client, autoStart: false)
        daemon.pollInterval = loadedSettings.pollInterval
        if loadedSettings.onboardingDone {
            daemon.start()
        }
        // Status polling is independent of credentials and of onboarding —
        // the page is public, so it can start right away and give a fresh
        // install something true to show on first open.
        let statusMonitor = StatusMonitor()
        if loadedSettings.serviceStatusEnabled {
            statusMonitor.start()
        }
        // Token spend comes from files Claude Code already wrote, so the first
        // scan can run right away — no credentials, no network, no prompt.
        let tokenMonitor = TokenUsageMonitor(autoStart: loadedSettings.tokenUsageEnabled)

        _settings = State(initialValue: loadedSettings)
        _daemon = State(initialValue: daemon)
        _status = State(initialValue: statusMonitor)
        _tokens = State(initialValue: tokenMonitor)
        _onboarding = State(initialValue: OnboardingWindowController(settings: loadedSettings, daemon: daemon))
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                daemon: daemon,
                status: status,
                tokens: tokens,
                settings: settings,
                onToggleFloating: toggleOverlay
            )
            .onAppear {
                onboarding.presentIfNeeded()
                if settings.overlayEnabledOnLaunch && overlay == nil {
                    toggleOverlay()
                }
            }
            .onChange(of: daemon.usage) { _, newUsage in
                Task { await notifications.evaluate(usage: newUsage, settings: settings) }
            }
        } label: {
            MenuBarLabelView(daemon: daemon, settings: settings)
        }
        .menuBarExtraStyle(.window)

        Settings {
            // .onChange handlers MUST be attached here, not to the MenuBarExtra
            // content. macOS lazy-loads the menu bar popover content view, so
            // .onChange there only fires while the popover is open. The user
            // adjusts these sliders inside Preferences (a separate scene),
            // where the SettingsView IS the alive view at that moment.
            SettingsView(
                settings: settings,
                notifications: notifications,
                daemon: daemon,
                status: status,
                tokens: tokens,
                onResetOverlaySize: { overlay?.resetSize() }
            )
            .onChange(of: settings.pollInterval) { _, newValue in
                daemon.pollInterval = newValue
            }
            .onChange(of: settings.overlayOpacity) { _, newValue in
                overlay?.settings.opacity = newValue
                overlay?.applySettings()
            }
            .onChange(of: settings.overlayClickThrough) { _, newValue in
                overlay?.settings.clickThrough = newValue
                overlay?.applySettings()
            }
            .onChange(of: settings.overlayLocked) { _, newValue in
                overlay?.setResizable(!newValue)
            }
            .onChange(of: settings.tokenUsageEnabled) { _, newValue in
                // Turning it back on should have numbers ready by the time the
                // user closes Preferences and opens the popover.
                if newValue {
                    Task { await tokens.refreshNow() }
                }
            }
            .onChange(of: settings.serviceStatusEnabled) { _, newValue in
                if newValue {
                    status.start()
                    Task { await status.refreshNow() }
                } else {
                    status.stop()
                }
            }
        }
        // Pin the Preferences window so it doesn't auto-resize while a slider
        // is being dragged. Auto-resize is what made the tab-bar icons
        // "dance" — when the SwiftUI content recomputed its intrinsic size on
        // every slider tick, the NSToolbar above re-flowed to match.
        .windowResizability(.contentSize)
        .defaultSize(width: 580, height: 440)
    }

    private func toggleOverlay() {
        if overlay == nil {
            overlay = OverlayWindowController(daemon: daemon, status: status)
        }
        // Re-sync from AppSettings every time we show, so the Preferences
        // slider stays the source of truth — even if the user adjusted it
        // while the overlay was hidden.
        overlay?.settings.opacity = settings.overlayOpacity
        overlay?.settings.clickThrough = settings.overlayClickThrough
        overlay?.toggle()
        overlay?.setResizable(!settings.overlayLocked)
    }
}
