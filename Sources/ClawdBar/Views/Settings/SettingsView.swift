import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var notifications: NotificationManager
    let daemon: UsageDaemon
    let status: StatusMonitor
    var onResetOverlaySize: () -> Void = {}

    var body: some View {
        PreferencesShell(
            general: GeneralTab(settings: settings),
            appearance: AppearanceTab(settings: settings),
            floating: FloatingTab(settings: settings, onResetSize: onResetOverlaySize),
            notifications: NotificationsTab(settings: settings, notifications: notifications),
            dataSource: DataSourceTab(settings: settings, daemon: daemon, status: status),
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
    @Bindable var status: StatusMonitor

    @State private var testResult: String?
    @State private var isTesting = false
    @State private var tokenDraft = ""
    @State private var showTokenField = false
    @State private var tokenResult: String?
    @State private var forgetConfirm = false

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
            Section("Saved credential") {
                LabeledContent("Stored") {
                    Text(savedLabel)
                        .foregroundStyle(.secondary)
                }
                Text("ClawdBar keeps its own copy of the token in a keychain item it owns — encrypted by macOS, readable only by ClawdBar, never written to a file. It exists so ClawdBar stops re-reading Claude Code's item, which is what makes macOS ask for your password: the CLI rewrites that item on every token refresh, and each rewrite revokes the access you granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let vaultError = daemon.vaultError {
                    Text(vaultError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
                HStack {
                    Button(showTokenField ? "Cancel" : "Use my own token…") {
                        showTokenField.toggle()
                        tokenDraft = ""
                        tokenResult = nil
                    }
                    Button("Forget saved credential") {
                        forgetConfirm = true
                    }
                    .disabled(daemon.savedCredentialInfo == nil)
                }
                if showTokenField {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run `claude setup-token` in Terminal and paste the long-lived token here. While one is saved, ClawdBar never touches Claude Code's keychain item — so macOS never asks for your password again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            SecureField("sk-ant-oat01-…", text: $tokenDraft)
                                .textFieldStyle(.roundedBorder)
                            Button("Save token") { saveToken() }
                                .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                if let tokenResult {
                    Text(tokenResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
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
            Section("Service status") {
                ToggleRow(
                    label: "Show Claude service status",
                    value: $settings.serviceStatusEnabled,
                    defaultValue: AppSettingsDefaults.serviceStatusEnabled
                )
                Text("Polls the public status page at status.claude.com every 2 minutes so a red usage number can be told apart from an Anthropic incident. Read-only, unauthenticated — no token and no usage data are sent to that host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.serviceStatusEnabled {
                    HStack {
                        Button {
                            Task { await status.refreshNow() }
                        } label: {
                            if status.isFetching {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Check now")
                            }
                        }
                        .disabled(status.isFetching)
                        Link("Open status.claude.com", destination: ServiceStatus.pageURL)
                    }
                    Text(statusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
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
        .confirmationDialog(
            "Forget the saved credential?",
            isPresented: $forgetConfirm,
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                daemon.forgetSavedCredential()
                tokenResult = "Removed. The next poll reads Claude Code's keychain item again — macOS may ask you to approve it."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes ClawdBar's own keychain item. Your Claude Code login is untouched; ClawdBar goes back to reading its credentials, which is what triggers the macOS password prompt.")
        }
    }

    private var statusSummary: String {
        if let snapshot = status.status {
            let components = snapshot.degradedComponents
                .map { "\($0.shortName) \($0.level.badge)" }
                .joined(separator: ", ")
            let head = snapshot.headline.capitalized
            let tail = components.isEmpty ? "" : " — \(components)"
            let error = status.lastError == nil ? "" : " (last refresh failed)"
            return head + tail + error
        }
        if let error = status.lastError { return "Unavailable: \(error)" }
        return status.isPolling ? "Checking…" : "Not polling."
    }

    private var sourceLabel: String {
        if let info = daemon.savedCredentialInfo {
            return info.origin == .pasted
                ? "Your own token, saved in ClawdBar"
                : "macOS Keychain (mirrored into ClawdBar)"
        }
        return daemon.usage.rawHeaders.isEmpty ? "Probing…" : "macOS Keychain"
    }

    private var savedLabel: String {
        guard let info = daemon.savedCredentialInfo else {
            return "Nothing saved yet"
        }
        var parts = [info.origin == .pasted ? "Token you pasted" : "Copy of your Claude Code token"]
        if let expiresAt = info.expiresAt {
            let delta = expiresAt.timeIntervalSinceNow
            parts.append(delta <= 0
                ? "expired"
                : "expires in \(Self.durationLabel(delta))")
        } else {
            parts.append("no expiry")
        }
        return parts.joined(separator: " — ")
    }

    private static func durationLabel(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    private func saveToken() {
        do {
            try daemon.saveUserToken(tokenDraft)
            tokenDraft = ""
            showTokenField = false
            tokenResult = "Saved. Testing it…"
            Task {
                await runTest()
                tokenResult = daemon.lastError == nil
                    ? "Saved and working. ClawdBar will not read Claude Code's keychain item any more."
                    : "Saved, but the API rejected it: \(daemon.lastError ?? "")"
            }
        } catch {
            tokenResult = "Could not save: \(error)"
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
