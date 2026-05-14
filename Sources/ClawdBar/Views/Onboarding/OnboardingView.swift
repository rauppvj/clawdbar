import SwiftUI
import AppKit

struct OnboardingView: View {
    @Bindable var settings: AppSettings
    let daemon: UsageDaemon
    var onFinish: () -> Void

    @State private var step: Step = .welcome
    @State private var connectStatus: ConnectStatus = .idle
    @State private var isProbing = false

    enum Step: Int, CaseIterable { case welcome, connect, appearance, behavior, done }

    enum ConnectStatus: Equatable {
        case idle
        case probing
        case success(subscription: String, tier: String)
        case notSignedIn
        case denied
        case otherError(String)

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            stepIndicator
                .padding(.top, 8)

            content
                .frame(maxWidth: .infinity, minHeight: 240)
                .transition(.opacity)

            footer
        }
        .padding(28)
        .frame(width: 520)
        .background(Theme.bgDeep)
        .colorScheme(.dark)
    }

    // MARK: - Indicator

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases.dropLast(), id: \.self) { s in
                Capsule()
                    .fill(s == step ? Theme.accentWarm : Theme.stroke)
                    .frame(width: s == step ? 32 : 14, height: 4)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .connect: connectStep
        case .appearance: appearanceStep
        case .behavior: behaviorStep
        case .done: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            MascotView(mood: .focused, severity: .ok, pixel: 6)
                .frame(width: 96, height: 96)
            Text("Welcome to ClawdBar")
                .font(Theme.retro(size: 20))
                .foregroundStyle(Theme.textPrimary)
            Text("A tiny menu-bar dashboard for your Claude Code 5h and 7d usage. Polls the Anthropic API once a minute (≈ 1 Haiku token per poll).")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: 380)
        }
    }

    private var connectStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accentCool)

            Text("Connect to Claude Code")
                .font(Theme.retro(size: 16))
                .foregroundStyle(Theme.textPrimary)

            Text("ClawdBar reads your existing Claude Code OAuth token from the macOS Keychain. Works with any Claude Code plan (Pro, Max, Max 20×). macOS will ask you to approve once — choose **Always Allow** so future polls run silently.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: 420)

            statusCard

            Button {
                runConnect()
            } label: {
                HStack {
                    if isProbing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: connectStatus.isSuccess ? "checkmark.circle.fill" : "key.fill")
                    }
                    Text(connectStatus.isSuccess ? "Re-test connection" : "Connect")
                }
                .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .tint(connectStatus.isSuccess ? Color.green : Theme.accentWarm)
            .disabled(isProbing)
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        switch connectStatus {
        case .idle:
            EmptyView()
        case .probing:
            EmptyView()
        case .success(let sub, let tier):
            VStack(spacing: 4) {
                Text("✓ Connected — \(prettyPlan(sub, tier: tier))")
                    .font(Theme.retro(size: 11))
                    .foregroundStyle(.green)
                Text(tier)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Color.green.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .notSignedIn:
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude Code is not signed in on this Mac.")
                    .font(.callout.weight(.semibold))
                Text("Open Terminal and run:")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text("claude /login")
                    .font(.system(.body, design: .monospaced))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Theme.bgRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text("…then come back here and click Connect again.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .denied:
            VStack(spacing: 4) {
                Text("Keychain access denied")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text("You can re-try, or open Keychain Access and approve ClawdBar manually.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(12)
            .background(Color.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .otherError(let detail):
            Text(detail)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .padding(.horizontal)
        }
    }

    private var appearanceStep: some View {
        VStack(spacing: 16) {
            Text("Pick your menu-bar look")
                .font(Theme.retro(size: 14))
                .foregroundStyle(Theme.textPrimary)

            VStack(spacing: 6) {
                ForEach(MenuBarStyle.allCases) { style in
                    StylePickerRow(
                        style: style,
                        selected: settings.menuBarStyle == style,
                        onTap: { settings.menuBarStyle = style }
                    )
                }
            }
            .frame(maxWidth: 380)

            Toggle("Show the mascot in popovers", isOn: $settings.showMascot)
                .toggleStyle(.switch)
                .tint(Theme.accentWarm)
                .padding(.top, 4)
        }
    }

    private var behaviorStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A couple of preferences")
                .font(Theme.retro(size: 14))
                .foregroundStyle(Theme.textPrimary)

            Toggle("Launch ClawdBar at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    let ok = LaunchAtLogin.setEnabled(newValue)
                    settings.launchAtLogin = ok ? newValue : LaunchAtLogin.isEnabled
                }
            ))
            .toggleStyle(.switch)
            .tint(Theme.accentWarm)

            Toggle("Show floating window on launch", isOn: $settings.overlayEnabledOnLaunch)
                .toggleStyle(.switch)
                .tint(Theme.accentWarm)

            VStack(alignment: .leading, spacing: 6) {
                Text("Poll interval: \(Int(settings.pollInterval))s")
                    .font(.callout)
                Slider(value: $settings.pollInterval, in: 30...300, step: 5)
                Text("Costs roughly 1 Haiku token per poll.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 420)
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            MascotView(mood: .focused, severity: .ok, pixel: 6)
                .frame(width: 96, height: 96)
            Text("All set")
                .font(Theme.retro(size: 18))
                .foregroundStyle(Theme.textPrimary)
            Text("Your usage will appear in the menu bar within a few seconds. You can change anything later from Preferences (⌘,).")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: 380)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") {
                    withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Button(primaryLabel) {
                advance()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accentWarm)
            .disabled(!canAdvance)
            .keyboardShortcut(.return)
        }
    }

    private var primaryLabel: String {
        switch step {
        case .done: return "Open ClawdBar"
        case .behavior: return "Finish"
        default: return "Continue"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .connect: return connectStatus.isSuccess
        default: return true
        }
    }

    private func advance() {
        if step == .done {
            onFinish()
            return
        }
        if let next = Step(rawValue: step.rawValue + 1) {
            withAnimation { step = next }
        }
    }

    /// Cosmetic label mapping the raw token fields to a human plan name.
    /// Treat every Claude Code plan as a first-class citizen.
    private func prettyPlan(_ subscription: String, tier: String) -> String {
        switch subscription.lowercased() {
        case "max":
            return tier.lowercased().contains("20x") ? "CLAUDE MAX 20×" : "CLAUDE MAX"
        case "pro":  return "CLAUDE PRO"
        case "team": return "CLAUDE TEAM"
        default:     return "CLAUDE \(subscription.uppercased())"
        }
    }

    private func runConnect() {
        isProbing = true
        connectStatus = .probing
        Task { @MainActor in
            do {
                // Route through the daemon's cache so we never fire a second
                // SecItemCopyMatching while another is already in flight (which
                // is what made macOS show two prompts in a row).
                let cred = try daemon.loadCredentials()
                connectStatus = .success(
                    subscription: cred.subscriptionType ?? "unknown",
                    tier: cred.rateLimitTier ?? "default"
                )
            } catch CredentialStore.LoadError.notFound {
                connectStatus = .notSignedIn
            } catch CredentialStore.LoadError.accessDenied {
                connectStatus = .denied
            } catch {
                connectStatus = .otherError("\(error)")
            }
            isProbing = false
        }
    }
}

private struct StylePickerRow: View {
    let style: MenuBarStyle
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accentWarm : Theme.textMuted)
                Text(style.displayName)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                StylePreview(style: style)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(selected ? Theme.bgRaised : Theme.bgPanel)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.accentWarm.opacity(0.5) : Theme.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct StylePreview: View {
    let style: MenuBarStyle
    // Sample data so users can compare styles side-by-side.
    private let sample = UsageData(
        sessionPercent: 47, sessionResetAt: nil,
        weeklyPercent: 21, weeklyResetAt: nil,
        lastUpdated: .now, isStale: false, rawHeaders: [:]
    )

    var body: some View {
        switch style {
        case .numeric:
            Text("S:47% W:21%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
        case .miniBar:
            HStack(spacing: 4) {
                preview(width: 32, percent: 0.47)
                Text("47%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
            }
        case .mascot:
            MascotView(mood: sample.mood, severity: sample.sessionSeverity, pixel: 1)
                .frame(width: 18, height: 18)
        case .dualBar:
            VStack(spacing: 2) {
                preview(width: 28, percent: 0.47)
                preview(width: 28, percent: 0.21)
            }
        case .hybrid:
            HStack(spacing: 4) {
                MascotView(mood: sample.mood, severity: sample.sessionSeverity, pixel: 1)
                    .frame(width: 18, height: 18)
                Text("47%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private func preview(width: CGFloat, percent: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.textMuted.opacity(0.25))
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.color(for: UsageData.severity(for: percent * 100)))
                .frame(width: width * percent)
        }
        .frame(width: width, height: 6)
    }
}
