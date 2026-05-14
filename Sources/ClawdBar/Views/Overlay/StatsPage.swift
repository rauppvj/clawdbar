import SwiftUI

/// Compact stats grid for the floating overlay. Shows derived metrics from
/// the locally-logged usage history.
struct StatsPage: View {
    let stats: UsageStats

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STATS")
                .font(Theme.retro(size: 11, weight: .heavy))
                .tracking(2.5)
                .foregroundStyle(Theme.textPrimary)

            grid

            Spacer(minLength: 0)

            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var grid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 8) {
            cell(label: "STREAK",    value: "\(stats.currentStreak)d", accent: streakColor)
            cell(label: "LONGEST",   value: "\(stats.longestStreak)d", accent: Theme.accentCool)
            cell(label: "PEAK HOUR", value: peakHourValue,             accent: Theme.accentWarm)
            cell(label: "DAYS",      value: "\(stats.daysTracked)",    accent: Theme.textPrimary)
        }
    }

    private func cell(label: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.retro(size: 8))
                .tracking(1.5)
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(Theme.retro(size: 18, weight: .heavy))
                .foregroundStyle(accent)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(Theme.bgPanel)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var streakColor: Color {
        stats.currentStreak == 0 ? Theme.textMuted : Theme.accentWarm
    }

    private var peakHourValue: String {
        guard let hour = stats.peakHour else { return "—" }
        return "\(hour)h"
    }

    @ViewBuilder
    private var footer: some View {
        if let firstSeen = stats.firstSeen {
            Text("Since \(shortDate(firstSeen)) · \(stats.totalSamples) polls")
                .font(Theme.retro(size: 9))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Text("Tracking starts on first poll")
                .font(Theme.retro(size: 9))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func shortDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }
}
