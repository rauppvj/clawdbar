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

    /// The bar (or the headline) the pointer is over. Drives the readout line
    /// under the chart — see `readout` for why this replaced `.help()`.
    @State private var hovered: Date?

    init(monitor: TokenUsageMonitor, previewHover: Date? = nil) {
        self.monitor = monitor
        // `--render-tokens` seeds this so the hover state can be reviewed in a
        // PNG. A pointer is the one thing an ImageRenderer cannot supply.
        _hovered = State(initialValue: previewHover)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            if monitor.summary.filesSeen == 0 && monitor.hasScanned {
                emptyState
            } else {
                chart
                readout
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
        .contentShape(Rectangle())
        .onHover { inside in hover(today.day, inside) }
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
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(barColor(for: day))
                .frame(height: height)
        }
        // The hover target is the whole column, not the drawn bar: on a quiet
        // day that bar is a 3 pt sliver and would be nearly unhittable.
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in hover(day.day, inside) }
    }

    private func hover(_ day: Date, _ inside: Bool) {
        if inside {
            hovered = day
        } else if hovered == day {
            hovered = nil
        }
    }

    private func barColor(for day: DailyTokenUsage) -> Color {
        let isHovered = hovered == day.day
        if day.totals.fresh == 0 {
            return isHovered ? Theme.textMuted.opacity(0.45) : Theme.bgRaised
        }
        if isToday(day) { return Theme.accentWarm }
        return Theme.accentCool.opacity(isHovered ? 1 : 0.7)
    }

    // MARK: - Range summary + models

    /// One line under the chart, and the only place exact figures live.
    ///
    /// This used to be `.help()` tooltips. They were the wrong tool three ways
    /// over: macOS fixes the delay at ~2 s, paints them in the system's light
    /// chrome no matter what the app looks like, and gives no control over
    /// layout — so a four-line breakdown arrived as a white slab bolted onto a
    /// black pixel-art popover. A readout that swaps in place is instant, uses
    /// the app's own type, and can't be styled by anyone but us.
    private var readout: some View {
        Group {
            if let day = hoveredDay {
                Text(dayReadout(day))
                    .foregroundStyle(Theme.textPrimary)
            } else {
                rangeReadout
            }
        }
        .font(Theme.retro(size: 9))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        // Pinned height: the two branches build different view trees and
        // measured 2 pt apart, which would bounce the whole popover every time
        // the pointer crossed a bar.
        .frame(maxWidth: .infinity, minHeight: 15, maxHeight: 15, alignment: .leading)
        .animation(.easeInOut(duration: 0.12), value: hovered)
    }

    private var hoveredDay: DailyTokenUsage? {
        guard let hovered else { return nil }
        return window.first { $0.day == hovered }
    }

    /// "31 AUG · 5.4M · 1504 TURNS · +582M CACHED"
    private func dayReadout(_ day: DailyTokenUsage) -> String {
        let counts = day.totals
        var parts = [TokenUsageFormat.monthDay(day.day)]
        guard !counts.isEmpty else {
            parts.append("IDLE")
            return parts.joined(separator: "  ·  ")
        }
        parts.append(TokenUsageFormat.compact(counts.fresh))
        if day.messages > 0 {
            parts.append("\(day.messages) TURN\(day.messages == 1 ? "" : "S")")
        }
        if counts.cacheRead > 0 {
            parts.append("+\(TokenUsageFormat.compact(counts.cacheRead)) CACHED")
        }
        return parts.joined(separator: "  ·  ")
    }

    private var rangeReadout: some View {
        let total = monitor.summary.total(lastDays: range.days)
        let average = total.fresh / max(range.days, 1)
        return HStack(spacing: 6) {
            Text("\(range.label) \(TokenUsageFormat.compact(total.fresh))")
                .fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)
            Text("·")
                .foregroundStyle(Theme.textMuted)
            Text("AVG \(TokenUsageFormat.compact(average))/DAY")
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
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

    private func shortAge(_ age: TimeInterval) -> String {
        if age < 5 { return "now" }
        if age < 60 { return "\(Int(age))s" }
        if age < 3600 { return "\(Int(age / 60))m" }
        return "\(Int(age / 3600))h"
    }
}
