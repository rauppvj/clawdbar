import SwiftUI

struct MenuBarLabelView: View {
    let daemon: UsageDaemon
    let settings: AppSettings

    var body: some View {
        if daemon.usage.lastUpdated == .distantPast {
            if daemon.lastError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .symbolRenderingMode(.hierarchical)
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch settings.menuBarStyle {
        case .numeric:
            NumericLabel(usage: daemon.usage)
        case .miniBar:
            MiniBarLabel(usage: daemon.usage)
        case .mascot:
            MascotLabel(usage: daemon.usage)
        case .dualBar:
            DualBarLabel(usage: daemon.usage)
        case .hybrid:
            HybridLabel(usage: daemon.usage)
        }
    }
}

// MARK: - Style implementations
//
// All non-text styles bake their content into NSImage via the helpers in
// MascotImage.swift / BarImage.swift. The macOS menu bar can host arbitrary
// SwiftUI views in principle, but in practice it refuses to drive a render
// loop for TimelineView and sometimes drops Canvas/Shape fills — both look
// like "nothing renders". Static NSImage always works.

private struct NumericLabel: View {
    let usage: UsageData
    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(usage.isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }
    private var text: String {
        let s = usage.displaySessionPercent.map { "\($0)%" } ?? "—"
        let w = usage.displayWeeklyPercent.map { "\($0)%" } ?? "—"
        return "S:\(s) W:\(w)"
    }
}

private struct MiniBarLabel: View {
    let usage: UsageData
    var body: some View {
        HStack(spacing: 4) {
            if let img = BarImage.render(percent: usage.sessionPercent, severity: usage.sessionSeverity, width: 36) {
                Image(nsImage: img)
            }
            if let p = usage.displaySessionPercent {
                Text("\(p)%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
        }
        .opacity(usage.isStale ? 0.6 : 1)
    }
}

private struct DualBarLabel: View {
    let usage: UsageData
    var body: some View {
        if let img = DualBarImage.render(
            sessionPercent: usage.sessionPercent,
            sessionSeverity: usage.sessionSeverity,
            weeklyPercent: usage.weeklyPercent,
            weeklySeverity: usage.weeklySeverity
        ) {
            Image(nsImage: img)
                .opacity(usage.isStale ? 0.6 : 1)
        }
    }
}

private struct MascotLabel: View {
    let usage: UsageData
    var body: some View {
        if let img = MascotImage.render(mood: usage.mood, severity: usage.sessionSeverity, pointSize: 18, monochrome: true) {
            Image(nsImage: img)
                .opacity(usage.isStale ? 0.6 : 1)
        } else {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        }
    }
}

private struct HybridLabel: View {
    let usage: UsageData
    var body: some View {
        HStack(spacing: 4) {
            if let img = MascotImage.render(mood: usage.mood, severity: usage.sessionSeverity, pointSize: 18, monochrome: true) {
                Image(nsImage: img)
            }
            if let p = usage.displaySessionPercent {
                Text("\(p)%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
        }
        .opacity(usage.isStale ? 0.6 : 1)
    }
}
