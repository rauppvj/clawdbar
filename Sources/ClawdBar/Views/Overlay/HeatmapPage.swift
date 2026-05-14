import SwiftUI

/// GitHub-style activity heatmap rendered into the floating overlay. Columns
/// are weeks (most recent on the right); rows are weekdays. Cell intensity
/// reflects the peak session % observed that day.
struct HeatmapPage: View {
    let stats: UsageStats

    private let cellSize: CGFloat = 13
    private let spacing: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACTIVITY")
                .font(Theme.retro(size: 11, weight: .heavy))
                .tracking(2.5)
                .foregroundStyle(Theme.textPrimary)

            heatmap
                .frame(maxWidth: .infinity, alignment: .center)

            footer
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var heatmap: some View {
        let cells = stats.activityByDay
        let columnsCount = 8
        let perColumn = 7
        let totalDesired = columnsCount * perColumn

        // Pad left with empty cells when we have less than 56 days of history.
        let padCount = max(0, totalDesired - cells.count)
        let padding = Array(
            repeating: UsageStats.DailyActivity(day: .distantPast, peakPercent: -1),
            count: padCount
        )
        let full = padding + cells.suffix(totalDesired)

        return HStack(spacing: spacing) {
            ForEach(0..<columnsCount, id: \.self) { col in
                VStack(spacing: spacing) {
                    ForEach(0..<perColumn, id: \.self) { row in
                        let idx = col * perColumn + row
                        cell(for: idx < full.count ? full[idx] : nil)
                    }
                }
            }
        }
    }

    private func cell(for activity: UsageStats.DailyActivity?) -> some View {
        let activity = activity ?? UsageStats.DailyActivity(day: .distantPast, peakPercent: -1)
        let isPadding = activity.peakPercent < 0
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(color(for: activity, isPadding: isPadding))
            .frame(width: cellSize, height: cellSize)
            .help(tooltip(for: activity, isPadding: isPadding))
    }

    private func color(for activity: UsageStats.DailyActivity, isPadding: Bool) -> Color {
        if isPadding {
            return Theme.bgRaised.opacity(0.4)
        }
        switch activity.level {
        case 0: return Theme.bgRaised
        case 1: return Theme.accentCool.opacity(0.35)
        case 2: return Theme.accentCool.opacity(0.55)
        case 3: return Theme.accentCool.opacity(0.8)
        default: return Theme.accentCool
        }
    }

    private func tooltip(for activity: UsageStats.DailyActivity, isPadding: Bool) -> String {
        if isPadding { return "Before tracking started" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        return "\(fmt.string(from: activity.day)) — peak \(Int(activity.peakPercent.rounded()))%"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // Replaces the cryptic "2D" badge from before — explicit count,
            // explicit unit, only shown when tracking has produced data.
            if stats.daysTracked > 0 {
                Text("\(stats.daysTracked) \(stats.daysTracked == 1 ? "day" : "days") tracked")
                    .font(Theme.retro(size: 8))
                    .foregroundStyle(Theme.accentWarm)
            } else {
                Text("Tracking…")
                    .font(Theme.retro(size: 8))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            HStack(spacing: 3) {
                Text("less")
                    .font(Theme.retro(size: 7))
                    .foregroundStyle(Theme.textMuted)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(legendColor(level: level))
                        .frame(width: 8, height: 8)
                }
                Text("more")
                    .font(Theme.retro(size: 7))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    private func legendColor(level: Int) -> Color {
        switch level {
        case 0: return Theme.bgRaised
        case 1: return Theme.accentCool.opacity(0.35)
        case 2: return Theme.accentCool.opacity(0.55)
        case 3: return Theme.accentCool.opacity(0.8)
        default: return Theme.accentCool
        }
    }
}
