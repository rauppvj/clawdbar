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
            }
        }
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                // The label goes *above* the number, not under it: "23M" on
                // its own answers nothing, and the first question anyone asks
                // of this panel is "how much did I spend today".
                Text("TOKENS TODAY")
                    .font(Theme.retro(size: 9, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                rangePicker
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(TokenUsageFormat.compact(today.totals.fresh))
                    .font(Theme.retro(size: 26, weight: .heavy))
                    .foregroundStyle(Theme.accentWarm)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                if monitor.isScanning {
                    ProgressView().controlSize(.small).tint(Theme.accentWarm)
                } else if let age = monitor.snapshotAge, monitor.hasScanned {
                    Text("upd \(shortAge(age))")
                        .font(Theme.retro(size: 8))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            // Its own line: at 26 pt the headline leaves no room to sit a
            // second phrase beside it without wrapping mid-caption.
            if !turnsCaption.isEmpty {
                Text(turnsCaption)
                    .font(Theme.retro(size: 8))
                    .tracking(1)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        // On the whole block, not just the number — the hover target for
        // "give me the exact figure" should be the thing you're looking at.
        .contentShape(Rectangle())
        .help(exactTooltip(today))
    }

    /// Cache reads run 97–99 % of the raw total on agentic work: every turn
    /// replays a context that was paid for once. Leading with that number
    /// makes an ordinary day read as tens of millions of tokens, which is
    /// true and useless. So the headline counts what this machine actually
    /// produced or sent, and the replay is named separately rather than
    /// hidden — it is still what fills the rate-limit window.
    private var turnsCaption: String {
        var parts: [String] = []
        if today.messages > 0 {
            parts.append("\(today.messages) TURN\(today.messages == 1 ? "" : "S")")
        }
        if today.totals.cacheRead > 0 {
            parts.append("+\(TokenUsageFormat.compact(today.totals.cacheRead)) CACHED")
        }
        return parts.joined(separator: "  ·  ")
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
        let peak = max(series.map(\.totals.fresh).max() ?? 0, 1)

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
        let fraction = Double(day.totals.fresh) / Double(peak)
        let height = day.totals.fresh == 0 ? 2 : max(3, 44 * fraction)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(barColor(for: day))
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .bottom)
            .help(exactTooltip(day))
    }

    private func barColor(for day: DailyTokenUsage) -> Color {
        if day.totals.fresh == 0 { return Theme.bgRaised }
        return isToday(day) ? Theme.accentWarm : Theme.accentCool.opacity(0.75)
    }

    // MARK: - Range summary + models

    private var rangeCaption: some View {
        let total = monitor.summary.total(lastDays: range.days)
        let average = total.fresh / max(range.days, 1)
        return HStack(spacing: 6) {
            Text("\(range.label) \(TokenUsageFormat.compact(total.fresh))")
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
        .help(rangeTooltip(total))
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

    /// The per-model split used to have its own rows. It answered a question
    /// nobody was asking of a menu-bar popover — one model is ~100 % of the
    /// total for most people — so it moved into the hover text rather than
    /// being thrown away.
    private func rangeTooltip(_ total: TokenCounts) -> String {
        var lines = [
            "Last \(range.days) days — \(TokenUsageFormat.exact(total.fresh)) tokens produced or sent:",
            "  input \(TokenUsageFormat.exact(total.input))",
            "  output \(TokenUsageFormat.exact(total.output))",
            "  cache writes \(TokenUsageFormat.exact(total.cacheCreation))",
            "",
            "Plus \(TokenUsageFormat.exact(total.cacheRead)) cache reads — context replayed on every",
            "turn, paid for once when it was written. Counted apart because it",
            "swamps everything else (\(TokenUsageFormat.exact(total.total)) all in).",
        ]
        let models = monitor.summary.modelBreakdown(lastDays: range.days)
        if !models.isEmpty {
            lines.append("")
            let grand = max(models.reduce(0) { $0 + $1.counts.total }, 1)
            for entry in models.prefix(5) {
                let share = Double(entry.counts.total) / Double(grand) * 100
                let percent = share > 0 && share < 0.5 ? "<1%" : "\(Int(share.rounded()))%"
                lines.append("\(entry.displayName): \(TokenUsageFormat.exact(entry.counts.total)) (\(percent))")
            }
        }
        return lines.joined(separator: "\n")
    }

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
            \(formatter.string(from: day.day)) — \(day.messages) turn\(day.messages == 1 ? "" : "s")

            \(TokenUsageFormat.exact(counts.fresh)) tokens produced or sent
              input \(TokenUsageFormat.exact(counts.input))
              output \(TokenUsageFormat.exact(counts.output))
              cache writes \(TokenUsageFormat.exact(counts.cacheCreation))

            \(TokenUsageFormat.exact(counts.cacheRead)) cache reads — context replayed each turn,
            paid for once when it was written. \(TokenUsageFormat.exact(counts.total)) all in.
            """
    }

    private func shortAge(_ age: TimeInterval) -> String {
        if age < 5 { return "now" }
        if age < 60 { return "\(Int(age))s" }
        if age < 3600 { return "\(Int(age / 60))m" }
        return "\(Int(age / 3600))h"
    }
}
