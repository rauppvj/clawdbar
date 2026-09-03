import SwiftUI
import AppKit

/// 5th carousel page on the floating overlay: status.claude.com condensed to
/// a watch face. One dot per component, incident headline underneath.
struct StatusPage: View {
    @Bindable var monitor: StatusMonitor

    private let rowHeight: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 8) {
                Text("STATUS")
                    .font(Theme.retro(size: 11, weight: .heavy))
                    .tracking(2.5)
                    .foregroundStyle(Theme.textPrimary)

                content(rowBudget: rowBudget(for: geo.size.height))

                Spacer(minLength: 0)

                footer
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        // The overlay is a widget, not a browser — one click goes to the page
        // with the full incident timeline.
        .onTapGesture {
            NSWorkspace.shared.open(ServiceStatus.pageURL)
        }
    }

    /// How many component rows fit once the title, headline, incident line and
    /// pager have taken their cut. Keeps the page honest at 140 pt as well as
    /// at 320 pt.
    private func rowBudget(for height: CGFloat) -> Int {
        let reserved: CGFloat = 100
        return max(2, Int((height - reserved) / rowHeight))
    }

    @ViewBuilder
    private func content(rowBudget: Int) -> some View {
        if let status = monitor.status {
            headline(status)

            let visible = visibleComponents(status, limit: rowBudget)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(visible) { component in
                    componentRow(component)
                }
                if visible.count < status.components.count {
                    Text("+\(status.components.count - visible.count) MORE")
                        .font(Theme.retro(size: 7))
                        .foregroundStyle(Theme.textMuted)
                }
            }

            if let incident = status.incidents.first {
                Text("! \(incident.name)")
                    .font(Theme.retro(size: 7))
                    .foregroundStyle(Theme.color(for: incident.impact))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if monitor.lastError != nil {
            Text("STATUS\nUNAVAILABLE")
                .font(Theme.retro(size: 8))
                .foregroundStyle(Theme.textMuted)
        } else {
            Text("CHECKING…")
                .font(Theme.retro(size: 8))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func headline(_ status: ServiceStatus) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.color(for: status.worstLevel))
                .frame(width: 6, height: 6)
                .shadow(color: Theme.color(for: status.worstLevel).opacity(0.7), radius: 2)
            // The page's own wording ("Minor Service Outage"), coloured by the
            // worst level we can see — which may be ahead of the indicator.
            Text(status.headline)
                .font(Theme.retro(size: 8, weight: .bold))
                .foregroundStyle(Theme.color(for: status.worstLevel))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Spacer(minLength: 0)
        }
    }

    private func componentRow(_ component: ServiceStatus.Component) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.color(for: component.level))
                .frame(width: 4, height: 4)
            Text(component.shortName)
                .font(Theme.retro(size: 7))
                .foregroundStyle(component.level.isHealthy ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 2)
            if !component.level.isHealthy {
                Text(component.level.badge)
                    .font(Theme.retro(size: 7))
                    .foregroundStyle(Theme.color(for: component.level))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(height: rowHeight - 3)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 4) {
            Text("status.claude.com")
                .font(Theme.retro(size: 7))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            if monitor.isFetching {
                Text("···")
                    .font(Theme.retro(size: 7))
                    .foregroundStyle(Theme.textMuted)
            } else if monitor.lastError != nil, monitor.status != nil {
                Text("STALE")
                    .font(Theme.retro(size: 7))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    /// When the list has to be cut, whatever is broken goes first — that's the
    /// reason anyone flips to this page.
    private func visibleComponents(_ status: ServiceStatus, limit: Int) -> [ServiceStatus.Component] {
        guard status.components.count > limit else { return status.components }
        let degraded = status.components.filter { !$0.level.isHealthy }
        let healthy = status.components.filter { $0.level.isHealthy }
        return Array((degraded + healthy).prefix(limit))
    }
}
