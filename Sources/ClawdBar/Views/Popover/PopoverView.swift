import SwiftUI
import AppKit

struct PopoverView: View {
    @Bindable var daemon: UsageDaemon
    var onToggleFloating: () -> Void = {}

    @Environment(\.openSettings) private var openSettings
    @State private var moodPhase: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider().overlay(Theme.stroke)

            VStack(spacing: 16) {
                StatusRowView(
                    title: "CURRENT  ·  5H",
                    percent: daemon.usage.sessionPercent,
                    severity: daemon.usage.sessionSeverity,
                    resetAt: daemon.usage.sessionResetAt,
                    isStale: daemon.usage.isStale
                )
                StatusRowView(
                    title: "WEEKLY  ·  7D",
                    percent: daemon.usage.weeklyPercent,
                    severity: daemon.usage.weeklySeverity,
                    resetAt: daemon.usage.weeklyResetAt,
                    isStale: daemon.usage.isStale
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            footer
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            Divider().overlay(Theme.stroke)

            actionRow
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
        .background(Theme.bgDeep)
        .colorScheme(.dark)
        .onReceive(Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()) { _ in
            moodPhase = (moodPhase + 1) % 4
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusDot
            Text("USAGE")
                .font(Theme.retro(size: 14, weight: .heavy))
                .tracking(3)
                .foregroundStyle(Theme.textPrimary)
            if let plan = planLabel {
                Text(plan)
                    .font(Theme.retro(size: 9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accentWarm.opacity(0.15))
                    .foregroundStyle(Theme.accentWarm)
                    .clipShape(Capsule())
            }
            if let binding = bindingLabel {
                Text(binding)
                    .font(Theme.retro(size: 9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.bgRaised)
                    .foregroundStyle(Theme.accentCool)
                    .clipShape(Capsule())
            }
            Spacer()
            if daemon.isFetching {
                ProgressView().controlSize(.small).tint(Theme.accentWarm)
            }
        }
    }

    private var statusDot: some View {
        let severity = max(daemon.usage.sessionSeverity, daemon.usage.weeklySeverity)
        return Circle()
            .fill(Theme.color(for: severity))
            .frame(width: 8, height: 8)
            .shadow(color: Theme.color(for: severity).opacity(0.7), radius: 3)
    }

    /// User-friendly plan name pulled from the OAuth token's subscriptionType.
    /// Works for every Claude Code plan because the token carries this field
    /// (today seen: "pro", "max"). Falls back to nil if absent.
    private var planLabel: String? {
        guard let sub = daemon.subscriptionType, !sub.isEmpty else { return nil }
        switch sub.lowercased() {
        case "max":
            // Disambiguate Max 5× / Max 20× via the opaque tier id, if present.
            if let tier = daemon.rateLimitTier?.lowercased(), tier.contains("20x") {
                return "MAX 20×"
            }
            return "MAX"
        case "pro":   return "PRO"
        case "team":  return "TEAM"
        default:      return sub.uppercased()
        }
    }

    /// Which window is currently the binding constraint — sent by the API
    /// for every plan that uses the unified rate-limit system.
    private var bindingLabel: String? {
        guard let claim = daemon.usage.rawHeaders["anthropic-ratelimit-unified-representative-claim"] else {
            return nil
        }
        switch claim {
        case "five_hour": return "5H BINDING"
        case "seven_day": return "7D BINDING"
        default: return claim.uppercased()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 10)) { context in
                Text("* \(daemon.usage.mood.label(at: context.date))\(dots)")
                    .font(Theme.retro(size: 11))
                    .foregroundStyle(Theme.accentWarm)
                    .animation(.easeInOut(duration: 0.2), value: moodPhase)
            }
            Spacer()
            if let last = daemon.lastFetchAt {
                Text("upd \(timeAgo(last))")
                    .font(Theme.retro(size: 9))
                    .foregroundStyle(Theme.textMuted)
            } else if let err = daemon.lastError {
                Text(shortError(err))
                    .font(Theme.retro(size: 9))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }

    private var dots: String {
        String(repeating: ".", count: moodPhase)
    }

    private var actionRow: some View {
        HStack(spacing: 4) {
            iconButton("arrow.clockwise", help: "Refresh (⌘R)") {
                Task { await daemon.refreshNow() }
            }
            .keyboardShortcut("r")
            .disabled(daemon.isFetching)

            iconButton("rectangle.on.rectangle", help: "Toggle floating window") {
                onToggleFloating()
            }

            iconButton("gear", help: "Preferences…") {
                // Open the SwiftUI Settings scene. We use the
                // \.openSettings environment action — the older
                // NSApp.sendAction("showSettingsWindow:") approach
                // is silently dropped for LSUIElement (accessory)
                // apps because they have no app menu to route it.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",")

            Spacer()

            iconButton("power", help: "Quit ClawdBar (⌘Q)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 28)
                .foregroundStyle(Theme.textPrimary)
                .background(Theme.bgPanel)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func timeAgo(_ date: Date) -> String {
        let delta = -date.timeIntervalSinceNow
        if delta < 5 { return "now" }
        if delta < 60 { return "\(Int(delta))s" }
        if delta < 3600 { return "\(Int(delta / 60))m" }
        return "\(Int(delta / 3600))h"
    }

    private func shortError(_ s: String) -> String {
        // Trim down to a tag fragment for the footer.
        if s.contains("401") { return "AUTH" }
        if s.contains("429") { return "RATE" }
        if s.localizedCaseInsensitiveContains("network") { return "OFFLINE" }
        if s.localizedCaseInsensitiveContains("keychain") { return "NO KEYCHAIN" }
        return "ERR"
    }
}

extension UsageData.Severity: Comparable {
    private var rank: Int {
        switch self { case .ok: 0; case .warning: 1; case .danger: 2; case .critical: 3 }
    }
    static func < (lhs: UsageData.Severity, rhs: UsageData.Severity) -> Bool {
        lhs.rank < rhs.rank
    }
}
