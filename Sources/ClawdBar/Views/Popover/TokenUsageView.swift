import SwiftUI

/// Daily token spend, read from Claude Code's own transcripts. Answers the
/// question the rate-limit bars can't: not "how close am I to the ceiling"
/// but "how much did I actually burn today, and how does that compare to the
/// last week or month".
struct TokenUsageView: View {
    @Bindable var monitor: TokenUsageMonitor

    /// Persisted so the tab reopens on the range the user last looked at.
    @AppStorage("clawdbar.tokens.range") private var storedRange: String = Range.week.rawValue

    enum Range: String, CaseIterable, Identifiable {
        case week, month

        var id: String { rawValue }
        var days: Int { self == .week ? 7 : 30 }
        var label: String { self == .week ? "7D" : "30D" }
    }

    private var range: Range {
        Range(rawValue: storedRange) ?? .week
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            if monitor.summary.filesSeen == 0 && monitor.hasScanned {
                emptyState
            } else {
                chart
                rangeCaption
                breakdown
            }
        }
    }

    // MARK: - Headline

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(TokenUsageFormat.compact(today.totals.total))
                    .font(Theme.retro(size: 26, weight: .heavy))
                    .foregroundStyle(Theme.accentWarm)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .help(exactTooltip(today))
                Text(todayCaption)
                    .font(Theme.retro(size: 8))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 5) {
                rangePicker
                if monitor.isScanning {
                    ProgressView().controlSize(.small).tint(Theme.accentWarm)
                } else if let age = monitor.snapshotAge, monitor.hasScanned {
                    Text("upd \(shortAge(age))")
                        .font(Theme.retro(size: 8))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    private var todayCaption: String {
        let turns = today.messages
        guard turns > 0 else { return "TODAY" }
        return "TODAY  ·  \(turns) TURN\(turns == 1 ? "" : "S")"
    }

    private var rangePicker: some View {
        HStack(spacing: 3) {
            ForEach(Range.allCases) { option in
                Button {
                    storedRange = option.rawValue
                } label: {
                    Text(option.label)
                        .font(Theme.retro(size: 8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(option == range ? Theme.accentWarm.opacity(0.18) : Theme.bgPanel)
                        .foregroundStyle(option == range ? Theme.accentWarm : Theme.textMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show the last \(option.days) days")
            }
        }
    }

    // MARK: - Chart

    private var chart: some View {
        let series = window
        let peak = max(series.map(\.totals.total).max() ?? 0, 1)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(series) { day in
                    bar(for: day, peak: peak)
                }
            }
            .frame(height: 44)
            .animation(.easeInOut(duration: 0.2), value: storedRange)

            axis(for: series)
        }
    }

    /// A weekday letter per bar reads fine across seven columns; across thirty
    /// the columns are ~8 pt wide and a two-digit date renders as an ellipsis,
    /// so the month view gets endpoints instead.
    @ViewBuilder
    private func axis(for series: [DailyTokenUsage]) -> some View {
        if range == .week {
            HStack(spacing: barSpacing) {
                ForEach(series) { day in
                    Text(TokenUsageFormat.axisLabel(for: day.day, compactRange: false))
                        .font(Theme.retro(size: 7))
                        .foregroundStyle(isToday(day) ? Theme.accentWarm : Theme.textMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            HStack(spacing: 0) {
                Text(TokenUsageFormat.monthDay(series.first?.day))
                    .font(Theme.retro(size: 7))
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 0)
                Text(TokenUsageFormat.monthDay(midpoint(of: series)))
                    .font(Theme.retro(size: 7))
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 0)
                Text("TODAY")
                    .font(Theme.retro(size: 7))
                    .foregroundStyle(Theme.accentWarm)
            }
        }
    }

    private var barSpacing: CGFloat { range == .week ? 5 : 2 }

    private func bar(for day: DailyTokenUsage, peak: Int) -> some View {
        // Empty days still get a 2 pt stub so the baseline stays readable and
        // an idle day is visibly different from a missing one.
        let fraction = Double(day.totals.total) / Double(peak)
        let height = day.totals.isEmpty ? 2 : max(3, 44 * fraction)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(barColor(for: day))
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .bottom)
            .help(exactTooltip(day))
    }

    private func barColor(for day: DailyTokenUsage) -> Color {
        if day.totals.isEmpty { return Theme.bgRaised }
        return isToday(day) ? Theme.accentWarm : Theme.accentCool.opacity(0.75)
    }

    // MARK: - Range summary + models

    private var rangeCaption: some View {
        let total = monitor.summary.total(lastDays: range.days)
        let average = total.total / max(range.days, 1)
        return HStack(spacing: 6) {
            Text("\(range.label) \(TokenUsageFormat.compact(total.total))")
                .font(Theme.retro(size: 9, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("·")
                .font(Theme.retro(size: 9))
                .foregroundStyle(Theme.textMuted)
            Text("AVG \(TokenUsageFormat.compact(average))/DAY")
                .font(Theme.retro(size: 9))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .help("""
            \(TokenUsageFormat.exact(total.total)) tokens over the last \(range.days) days.
            Input \(TokenUsageFormat.exact(total.input)) · output \(TokenUsageFormat.exact(total.output))
            Cache write \(TokenUsageFormat.exact(total.cacheCreation)) · cache read \(TokenUsageFormat.exact(total.cacheRead))
            """)
    }

    @ViewBuilder
    private var breakdown: some View {
        let models = monitor.summary.modelBreakdown(lastDays: range.days)
        if models.isEmpty {
            Text(monitor.hasScanned ? "NO TOKENS IN THIS RANGE" : "SCANNING TRANSCRIPTS…")
                .font(Theme.retro(size: 8))
                .foregroundStyle(Theme.textMuted)
        } else {
            let total = max(models.reduce(0) { $0 + $1.counts.total }, 1)
            VStack(spacing: 5) {
                ForEach(Array(models.prefix(3).enumerated()), id: \.element.id) { index, entry in
                    modelRow(entry, share: Double(entry.counts.total) / Double(total), index: index)
                }
                if models.count > 3 {
                    HStack {
                        Text("+\(models.count - 3) more model\(models.count == 4 ? "" : "s")")
                            .font(Theme.retro(size: 7))
                            .foregroundStyle(Theme.textMuted)
                        Spacer()
                    }
                }
            }
        }
    }

    private func modelRow(_ entry: TokenUsageSummary.ModelSpend, share: Double, index: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(modelColor(index))
                .frame(width: 5, height: 5)
            Text(entry.displayName)
                .font(Theme.retro(size: 8))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(TokenUsageFormat.compact(entry.counts.total))
                .font(Theme.retro(size: 8))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
            shareBar(share: share, color: modelColor(index))
            Text(sharePercent(share))
                .font(Theme.retro(size: 7))
                .foregroundStyle(Theme.textMuted)
                .monospacedDigit()
                .frame(width: 26, alignment: .trailing)
        }
        .help("""
            \(entry.displayName) — \(TokenUsageFormat.exact(entry.counts.total)) tokens
            Input \(TokenUsageFormat.exact(entry.counts.input)) · output \(TokenUsageFormat.exact(entry.counts.output))
            Cache write \(TokenUsageFormat.exact(entry.counts.cacheCreation)) · cache read \(TokenUsageFormat.exact(entry.counts.cacheRead))
            """)
    }

    /// A model that ran once in a month is a rounding error against a billion
    /// cache-read tokens — "<1%" says "present but negligible", "0%" reads as
    /// a bug.
    private func sharePercent(_ share: Double) -> String {
        let percent = share * 100
        if percent > 0 && percent < 0.5 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }

    private func shareBar(share: Double, color: Color) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.bgRaised)
            GeometryReader { proxy in
                Capsule()
                    .fill(color)
                    .frame(width: max(2, proxy.size.width * min(max(share, 0), 1)))
            }
        }
        .frame(width: 54, height: 4)
    }

    private func modelColor(_ index: Int) -> Color {
        switch index {
        case 0: return Theme.accentWarm
        case 1: return Theme.accentCool
        default: return Theme.textSecondary
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NO TRANSCRIPTS FOUND")
                .font(Theme.retro(size: 9, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
            Text("Token spend is read from ~/.claude/projects. Run Claude Code once and it will show up here.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func midpoint(of series: [DailyTokenUsage]) -> Date? {
        let index = series.count / 2
        return series.indices.contains(index) ? series[index].day : nil
    }

    private var window: [DailyTokenUsage] {
        monitor.summary.window(days: range.days)
    }

    private var today: DailyTokenUsage {
        window.last ?? .empty(Calendar.current.startOfDay(for: .now))
    }

    private func isToday(_ day: DailyTokenUsage) -> Bool {
        Calendar.current.isDateInToday(day.day)
    }

    private func exactTooltip(_ day: DailyTokenUsage) -> String {
        let counts = day.totals
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        guard !counts.isEmpty else {
            return "\(formatter.string(from: day.day)) — no tokens"
        }
        return """
            \(formatter.string(from: day.day)) — \(TokenUsageFormat.exact(counts.total)) tokens · \(day.messages) turns
            Input \(TokenUsageFormat.exact(counts.input)) · output \(TokenUsageFormat.exact(counts.output))
            Cache write \(TokenUsageFormat.exact(counts.cacheCreation)) · cache read \(TokenUsageFormat.exact(counts.cacheRead))
            """
    }

    private func shortAge(_ age: TimeInterval) -> String {
        if age < 5 { return "now" }
        if age < 60 { return "\(Int(age))s" }
        if age < 3600 { return "\(Int(age / 60))m" }
        return "\(Int(age / 3600))h"
    }
}
