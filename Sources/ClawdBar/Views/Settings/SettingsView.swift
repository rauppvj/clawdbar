import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var notifications: NotificationManager
    let daemon: UsageDaemon
    var onResetOverlaySize: () -> Void = {}

    var body: some View {
        PreferencesShell(
            general: GeneralTab(settings: settings),
            appearance: AppearanceTab(settings: settings),
            floating: FloatingTab(settings: settings, onResetSize: onResetOverlaySize),
            notifications: NotificationsTab(settings: settings, notifications: notifications),
            dataSource: DataSourceTab(settings: settings, daemon: daemon),
            about: AboutTab()
        )
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                SliderRow(
                    label: "Poll interval",
                    value: $settings.pollInterval,
                    range: 30...300, step: 5, unit: "s",
                    defaultValue: AppSettingsDefaults.pollInterval
                )
                Text("Costs ~1 Haiku token per poll. Defaults to 60s; min 30s.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LaunchAtLoginRow(value: $settings.launchAtLogin)
                Text("If toggling fails, move ClawdBar.app into /Applications first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Launch-at-login needs side effects (SMAppService.register) on toggle,
/// so it gets its own row rather than reusing the generic ToggleRow.
private struct LaunchAtLoginRow: View {
    @Binding var value: Bool

    var body: some View {
        HStack {
            Toggle("Launch ClawdBar at login", isOn: Binding(
                get: { value },
                set: { newValue in
                    let ok = LaunchAtLogin.setEnabled(newValue)
                    value = ok ? newValue : LaunchAtLogin.isEnabled
                }
            ))
            Spacer()
            ResetButton(isModified: value != AppSettingsDefaults.launchAtLogin) {
                let _ = LaunchAtLogin.setEnabled(AppSettingsDefaults.launchAtLogin)
                value = AppSettingsDefaults.launchAtLogin
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Menu Bar") {
                PickerRow(
                    label: "Icon style",
                    value: $settings.menuBarStyle,
                    defaultValue: AppSettingsDefaults.menuBarStyle,
                    displayName: { $0.displayName }
                )
            }
            Section {
                ToggleRow(
                    label: "Show mascot in popover and overlay",
                    value: $settings.showMascot,
                    defaultValue: AppSettingsDefaults.showMascot
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Floating

private struct FloatingTab: View {
    @Bindable var settings: AppSettings
    var onResetSize: () -> Void = {}

    var body: some View {
        Form {
            Section {
                ToggleRow(
                    label: "Show floating window on launch",
                    value: $settings.overlayEnabledOnLaunch,
                    defaultValue: AppSettingsDefaults.overlayEnabledOnLaunch
                )
                PercentSliderRow(
                    label: "Opacity",
                    value: $settings.overlayOpacity,
                    range: 0.2...1.0,
                    defaultValue: AppSettingsDefaults.overlayOpacity
                )
                ToggleRow(
                    label: "Click-through (overlay ignores mouse)",
                    value: $settings.overlayClickThrough,
                    defaultValue: AppSettingsDefaults.overlayClickThrough
                )
                PickerRow(
                    label: "Default corner on first show",
                    value: $settings.overlayDefaultCorner,
                    defaultValue: AppSettingsDefaults.overlayDefaultCorner,
                    displayName: { $0.displayName }
                )
                ToggleRow(
                    label: "Lock window size (no resize)",
                    value: $settings.overlayLocked,
                    defaultValue: AppSettingsDefaults.overlayLocked
                )
                ResizeHelperText(locked: settings.overlayLocked)
                HStack {
                    Button {
                        onResetSize()
                    } label: {
                        Label("Reset to default size (200 × 200)", systemImage: "arrow.counterclockwise")
                    }
                    Spacer()
                }
                Text("The default size is intentionally watch-sized — small and unobtrusive on the desktop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ResizeHelperText: View {
    let locked: Bool
    var body: some View {
        if !locked {
            Text("Drag the small ↘ grip in the overlay's bottom-right corner to resize between 140 and 320 pt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Notifications

private struct NotificationsTab: View {
    @Bindable var settings: AppSettings
    @Bindable var notifications: NotificationManager

    var body: some View {
        Form {
            Section {
                ToggleRow(
                    label: "Enable threshold alerts",
                    value: $settings.notificationsEnabled,
                    defaultValue: AppSettingsDefaults.notificationsEnabled
                )
                NotificationAuthStatus(notifications: notifications)
            }
            Section("Thresholds") {
                SliderRow(
                    label: "Warning at",
                    value: $settings.warningThreshold,
                    range: 50...95, step: 1, unit: "%",
                    defaultValue: AppSettingsDefaults.warningThreshold
                )
                SliderRow(
                    label: "Critical at",
                    value: $settings.criticalThreshold,
                    range: 80...100, step: 1, unit: "%",
                    defaultValue: AppSettingsDefaults.criticalThreshold
                )
            }
            Section("Window") {
                ToggleRow(
                    label: "Alert on 5h (session) crossings",
                    value: $settings.notifyForSession,
                    defaultValue: AppSettingsDefaults.notifyForSession
                )
                ToggleRow(
                    label: "Alert on 7d (weekly) crossings",
                    value: $settings.notifyForWeekly,
                    defaultValue: AppSettingsDefaults.notifyForWeekly
                )
                ToggleRow(
                    label: "Play sound",
                    value: $settings.notificationSound,
                    defaultValue: AppSettingsDefaults.notificationSound
                )
            }
        }
        .formStyle(.grouped)
        .task { await notifications.refreshAuthState() }
    }
}

private struct NotificationAuthStatus: View {
    @Bindable var notifications: NotificationManager
    var body: some View {
        switch notifications.authState {
        case .notDetermined:
            Button("Request notification permission") {
                Task { await notifications.requestPermission() }
            }
        case .denied:
            Text("Notifications are blocked. Open System Settings → Notifications → ClawdBar to allow.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .granted:
            Text("Notification permission granted.")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Data Source

private struct DataSourceTab: View {
    @Bindable var settings: AppSettings
    let daemon: UsageDaemon

    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Credentials") {
                LabeledContent("Source") {
                    Text(sourceLabel)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Legacy file path") {
                    Text("~/.claude/.credentials.json")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Section("Connection") {
                HStack {
                    Button {
                        Task { await runTest() }
                    } label: {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Test connection")
                        }
                    }
                    .disabled(isTesting)

                    Button("Re-read credentials") {
                        daemon.invalidateCredentials()
                        Task { await runTest() }
                    }
                    .help("Drop the cached token and re-read the macOS Keychain. Use after running `claude /login`.")
                }
                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
            Section("Advanced") {
                HStack {
                    Text("API base URL")
                        .frame(width: 110, alignment: .leading)
                    TextField("https://api.anthropic.com", text: $settings.apiBaseURL)
                        .textFieldStyle(.roundedBorder)
                    ResetButton(isModified: settings.apiBaseURL != AppSettingsDefaults.apiBaseURL) {
                        settings.apiBaseURL = AppSettingsDefaults.apiBaseURL
                    }
                }
                HStack {
                    Text("Model")
                        .frame(width: 110, alignment: .leading)
                    TextField("claude-haiku-4-5-20251001", text: $settings.apiModel)
                        .textFieldStyle(.roundedBorder)
                    ResetButton(isModified: settings.apiModel != AppSettingsDefaults.apiModel) {
                        settings.apiModel = AppSettingsDefaults.apiModel
                    }
                }
                Text("Restart ClawdBar after editing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var sourceLabel: String {
        switch daemon.usage.rawHeaders.isEmpty {
        case true: return "Probing…"
        case false: return "macOS Keychain"
        }
    }

    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        await daemon.refreshNow()
        if let err = daemon.lastError {
            testResult = "Failed: \(err)"
        } else if daemon.usage.sessionPercent != nil || daemon.usage.weeklyPercent != nil {
            testResult = "OK — session \(daemon.usage.displaySessionPercent.map { "\($0)%" } ?? "—"), weekly \(daemon.usage.displayWeeklyPercent.map { "\($0)%" } ?? "—")."
        } else {
            testResult = "Connected, but no usage headers in response."
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    @State private var resetConfirm = false

    var body: some View {
        VStack(spacing: 14) {
            MascotView(mood: .focused, severity: .ok, pixel: 4)
                .frame(width: 64, height: 64)
            Text("ClawdBar")
                .font(.title2.bold())
            Text("Version 0.1 (dev)")
                .foregroundStyle(.secondary)
            Text("Unofficial. Not affiliated with Anthropic.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("Made by rauppvj", destination: URL(string: "https://github.com/rauppvj")!)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider().padding(.horizontal, 40)
            VStack(alignment: .leading, spacing: 8) {
                Label("Each poll spends approximately one Haiku-tier token against the Anthropic API.", systemImage: "creditcard")
                Label("OAuth token is read from the macOS Keychain. It never leaves your machine except for the API call itself.", systemImage: "lock.shield")
            }
            .font(.caption)
            .padding(.horizontal, 20)

            Spacer()

            Button("Reset onboarding & relaunch…") {
                resetConfirm = true
            }
            .controlSize(.small)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .confirmationDialog(
            "Reset onboarding?",
            isPresented: $resetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset and quit", role: .destructive) {
                let defaults = UserDefaults.standard
                for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("clawdbar.") {
                    defaults.removeObject(forKey: key)
                }
                defaults.synchronize()
                NSApplication.shared.terminate(nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears all ClawdBar preferences and quits. Relaunch to see the onboarding flow again. Your Keychain credentials are untouched.")
        }
    }
}
