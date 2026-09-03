import SwiftUI
import AppKit

/// Compact mirror of status.claude.com for the menu-bar popover: overall
/// indicator, a dot per component, and the headline of any live incident.
/// Answers the question a red usage number can't — "is the API itself down?".
struct ServiceStatusView: View {
    @Bindable var monitor: StatusMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            content
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("SERVICE STATUS")
                .font(Theme.retro(size: 10))
                .tracking(2)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if monitor.isFetching {
                ProgressView().controlSize(.small).tint(Theme.accentWarm)
            } else if let age = monitor.snapshotAge, monitor.status != nil {
                Text("upd \(shortAge(age))")
                    .font(Theme.retro(size: 9))
                    .foregroundStyle(Theme.textMuted)
            }
            openPageButton
        }
    }

    private var openPageButton: some View {
        Button {
            NSWorkspace.shared.open(ServiceStatus.pageURL)
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open status.claude.com")
    }

    // MARK: - Body states

    @ViewBuilder
    private var content: some View {
        if let status = monitor.status {
            headline(status)
            componentGrid(status)
            if let incident = status.incidents.first {
                incidentRow(incident)
            }
            if status.incidents.count > 1 {
                Text("+\(status.incidents.count - 1) more incident\(status.incidents.count == 2 ? "" : "s")")
                    .font(Theme.retro(size: 8))
                    .foregroundStyle(Theme.textMuted)
            }
        } else if let error = monitor.lastError {
            Text(unreachableCaption(error))
                .font(Theme.retro(size: 9))
                .foregroundStyle(Theme.textMuted)
        } else {
            Text("CHECKING…")
                .font(Theme.retro(size: 9))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func headline(_ status: ServiceStatus) -> some View {
        HStack(spacing: 7) {
            dot(status.worstLevel, size: 7)
            Text(status.headline)
                .font(Theme.retro(size: 10, weight: .bold))
                .foregroundStyle(Theme.color(for: status.worstLevel))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            // A snapshot kept on screen through a failed refresh should say so.
            if monitor.lastError != nil {
                Text("STALE")
                    .font(Theme.retro(size: 8))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    private func componentGrid(_ status: ServiceStatus) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            alignment: .leading,
            spacing: 5
        ) {
            ForEach(status.components) { component in
                HStack(spacing: 5) {
                    dot(component.level, size: 5)
                    Text(component.shortName)
                        .font(Theme.retro(size: 8))
                        .foregroundStyle(component.level.isHealthy ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if !component.level.isHealthy {
                        Text(component.level.badge)
                            .font(Theme.retro(size: 8))
                            .foregroundStyle(Theme.color(for: component.level))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    Spacer(minLength: 0)
                }
                .help(component.name)
            }
        }
    }

    private func incidentRow(_ incident: ServiceStatus.Incident) -> some View {
        Button {
            NSWorkspace.shared.open(incident.url ?? ServiceStatus.pageURL)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Text("!")
                    .font(Theme.retro(size: 9, weight: .bold))
                    .foregroundStyle(Theme.color(for: incident.impact))
                VStack(alignment: .leading, spacing: 3) {
                    Text(incident.name)
                        .font(Theme.retro(size: 8))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    if !incident.stage.isEmpty {
                        Text(incident.stage.uppercased())
                            .font(Theme.retro(size: 8))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bgPanel)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(incidentTooltip(incident))
    }

    // MARK: - Bits

    private func dot(_ level: ServiceStatus.Level, size: CGFloat) -> some View {
        Circle()
            .fill(Theme.color(for: level))
            .frame(width: size, height: size)
            .shadow(color: Theme.color(for: level).opacity(level.isHealthy ? 0.4 : 0.7), radius: 2)
    }

    private func incidentTooltip(_ incident: ServiceStatus.Incident) -> String {
        [incident.name, incident.latestUpdate]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    private func unreachableCaption(_ error: String) -> String {
        error.localizedCaseInsensitiveContains("network") ? "OFFLINE — STATUS UNKNOWN" : "STATUS PAGE UNREACHABLE"
    }

    private func shortAge(_ age: TimeInterval) -> String {
        if age < 5 { return "now" }
        if age < 60 { return "\(Int(age))s" }
        if age < 3600 { return "\(Int(age / 60))m" }
        return "\(Int(age / 3600))h"
    }
}
