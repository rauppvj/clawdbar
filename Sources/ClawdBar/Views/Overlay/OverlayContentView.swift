import SwiftUI

struct OverlayContentView: View {
    @Bindable var daemon: UsageDaemon
    @Bindable var settings: OverlaySettings
    var onHide: () -> Void
    var onSnap: (Corner) -> Void
    var onSettingsChange: () -> Void = {}
    var onResize: (CGSize) -> Void = { _ in }
    var isResizable: Bool = false
    /// When hosted inside the carousel, the parent owns background + grip +
    /// context menu, so this view skips those.
    var asPage: Bool = false

    enum Corner: String, CaseIterable, Identifiable {
        case topLeft = "Top Left"
        case topRight = "Top Right"
        case bottomLeft = "Bottom Left"
        case bottomRight = "Bottom Right"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            if !asPage {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.bgDeep)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 1)
                    )
            }

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.color(for: bigSeverity))
                        .frame(width: 6, height: 6)
                        .shadow(color: Theme.color(for: bigSeverity).opacity(0.7), radius: 2)
                    Text("USAGE")
                        .font(Theme.retro(size: 9))
                        .tracking(3)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                Spacer(minLength: 0)

                Text(bigPercentText)
                    .font(Theme.retro(size: 56, weight: .heavy))
                    .foregroundStyle(Theme.color(for: bigSeverity))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text("5H · \(resetText(daemon.usage.sessionResetAt))")
                    .font(Theme.retro(size: 8))
                    .tracking(2)
                    .foregroundStyle(Theme.textMuted)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    miniStat("7D", percent: daemon.usage.weeklyPercent, severity: daemon.usage.weeklySeverity)
                    Spacer()
                    TimelineView(.animation(minimumInterval: 10)) { context in
                        Text(daemon.usage.mood.label(at: context.date).uppercased())
                            .font(Theme.retro(size: 9))
                            .foregroundStyle(Theme.accentWarm)
                    }
                }
                .padding(.horizontal, 14)
                // Reserve room for the carousel pager that lives in the
                // parent ZStack. Without this, the 7D / mood line sits
                // exactly where the chevrons render and they collide.
                .padding(.bottom, asPage ? 30 : 10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isResizable && !asPage {
                ResizeGrip(onResize: onResize)
                    .padding(2)
            }
        }
        .opacity(asPage ? 1 : settings.opacity)
        .applyIf(!asPage) { v in
            v
                .colorScheme(.dark)
                .contextMenu {
                    Button("Hide", action: onHide)
                    Divider()
                    Menu("Snap to Corner") {
                        ForEach(Corner.allCases) { corner in
                            Button(corner.rawValue) { onSnap(corner) }
                        }
                    }
                    Menu("Opacity") {
                        opacityChoice("100%", value: 1.0)
                        opacityChoice("75%", value: 0.75)
                        opacityChoice("50%", value: 0.5)
                        opacityChoice("25%", value: 0.25)
                    }
                    Toggle("Click-Through", isOn: $settings.clickThrough)
                    Toggle("Lock Position", isOn: $settings.locked)
                }
                .onChange(of: settings.opacity) { _, _ in onSettingsChange() }
                .onChange(of: settings.clickThrough) { _, _ in onSettingsChange() }
                .onChange(of: settings.locked) { _, _ in onSettingsChange() }
        }
    }

    private var bigPercentText: String {
        guard let p = daemon.usage.sessionPercent else { return "––" }
        return "\(Int(p.rounded()))%"
    }

    private var bigSeverity: UsageData.Severity { daemon.usage.sessionSeverity }

    private func miniStat(_ label: String, percent: Double?, severity: UsageData.Severity) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(Theme.retro(size: 9))
                .foregroundStyle(Theme.textMuted)
            Text(percent.map { "\(Int($0.rounded()))%" } ?? "––")
                .font(Theme.retro(size: 12, weight: .bold))
                .foregroundStyle(Theme.color(for: severity))
        }
    }

    @ViewBuilder
    private func opacityChoice(_ title: String, value: Double) -> some View {
        Button(title) { settings.opacity = value }
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let delta = date.timeIntervalSinceNow
        if delta < 0 { return "NOW" }
        if delta < 3600 { return "\(Int(delta / 60))M" }
        if delta < 86_400 {
            let h = Int(delta / 3600)
            let m = Int(delta.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? "\(h)H \(m)M" : "\(h)H"
        }
        return "\(Int(delta / 86_400))D"
    }
}
