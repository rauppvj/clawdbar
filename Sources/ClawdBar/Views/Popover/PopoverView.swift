import SwiftUI
import AppKit

struct PopoverView: View {
    @Bindable var daemon: UsageDaemon
    @Bindable var status: StatusMonitor
    @Bindable var tokens: TokenUsageMonitor
    @Bindable var settings: AppSettings
    var onToggleFloating: () -> Void = {}

    @Environment(\.openSettings) private var openSettings
    @State private var moodPhase: Int = 0
    /// Remembered across opens so the popover comes back where it was left.
    @AppStorage("clawdbar.popover.tab") private var storedTab: String = PopoverTab.tokens.rawValue

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

            if !availableTabs.isEmpty {
                Divider().overlay(Theme.stroke)

                panel
            }

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
        // Opening the menu bar is the moment the answer matters most, so top
        // the snapshots up — both `refreshIfStale` calls coalesce repeated opens.
        .onAppear {
            if status.isPolling {
                Task { await status.refreshIfStale() }
            }
            if settings.tokenUsageEnabled {
                Task { await tokens.refreshIfStale() }
            }
            surfaceIncidentIfNeeded()
        }
    }

    // MARK: - Tabbed panel

    /// Tokens first: it moves every session. Service status only earns a slot
    /// when the user has polling on at all.
    private var availableTabs: [PopoverTab] {
        var tabs: [PopoverTab] = []
        if settings.tokenUsageEnabled { tabs.append(.tokens) }
        if status.isPolling { tabs.append(.status) }
        return tabs
    }

    private var selectedTab: PopoverTab {
        let stored = PopoverTab(rawValue: storedTab) ?? .tokens
        return availableTabs.contains(stored) ? stored : (availableTabs.first ?? .tokens)
    }

    private var tabSelection: Binding<PopoverTab> {
        Binding(get: { selectedTab }, set: { storedTab = $0.rawValue })
    }

    @ViewBuilder
    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if availableTabs.count > 1 {
                PopoverTabStrip(tabs: availableTabs, selection: tabSelection, badge: badge(for:))
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            // Both panels stay in the layout and only their opacity changes,
            // so the ZStack is as tall as the taller one and the popover keeps
            // one height across tab switches instead of jumping. It also grows
            // on its own when an incident adds rows to the status panel — a
            // fixed height would clip that. Same trick as OverlayCarousel.
            ZStack(alignment: .topLeading) {
                if availableTabs.contains(.tokens) {
                    TokenUsageView(monitor: tokens)
                        .opacity(selectedTab == .tokens ? 1 : 0)
                        .allowsHitTesting(selectedTab == .tokens)
                        .accessibilityHidden(selectedTab != .tokens)
                }
                if availableTabs.contains(.status) {
                    ServiceStatusView(monitor: status)
                        .opacity(selectedTab == .status ? 1 : 0)
                        .allowsHitTesting(selectedTab == .status)
                        .accessibilityHidden(selectedTab != .status)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: selectedTab)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The panels sit side by side conceptually, so a horizontal flick
        // moves between them the way the tab strip does.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    guard availableTabs.count > 1,
                          abs(value.translation.width) > abs(value.translation.height) else { return }
                    step(by: value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    private func step(by delta: Int) {
        guard let index = availableTabs.firstIndex(of: selectedTab) else { return }
        let next = index + delta
        guard availableTabs.indices.contains(next) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { storedTab = availableTabs[next].rawValue }
    }

    /// A dot on the SERVICE tab whenever the status page isn't all-green —
    /// the whole point of demoting the panel is that you shouldn't have to
    /// go looking, so the tab has to come find you.
    private func badge(for tab: PopoverTab) -> Color? {
        guard tab == .status, let level = status.status?.worstLevel, !level.isHealthy else { return nil }
        return Theme.color(for: level)
    }

    /// Pop the status panel to the front when something is actually wrong.
    /// Only on open, and only for a live problem — otherwise the user's own
    /// choice of tab wins.
    private func surfaceIncidentIfNeeded() {
        guard availableTabs.contains(.status),
              let level = status.status?.worstLevel, !level.isHealthy else { return }
        storedTab = PopoverTab.status.rawValue
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
                    .help(PlanBadge.help)
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

    /// User-friendly plan name pulled from the OAuth token's claims.
    /// See `PlanBadge` for why this can lag a plan change.
    private var planLabel: String? {
        PlanBadge.label(
            subscriptionType: daemon.subscriptionType,
            rateLimitTier: daemon.rateLimitTier
        )
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
                if status.isPolling {
                    Task { await status.refreshNow() }
                }
                if settings.tokenUsageEnabled {
                    Task { await tokens.refreshNow() }
                }
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
