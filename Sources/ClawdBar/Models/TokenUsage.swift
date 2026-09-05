import Foundation

/// The four token counters Claude Code records for every assistant turn.
/// Kept as a value type so days, models and ranges can be summed with `+`.
struct TokenCounts: Codable, Equatable, Sendable {
    var input: Int = 0
    var output: Int = 0
    var cacheCreation: Int = 0
    var cacheRead: Int = 0

    /// Everything the request moved, cache reads included. This is the number
    /// ccusage and the Claude web UI headline, and the one that makes days
    /// comparable — cache reads are most of the volume for agentic work.
    var total: Int { input + output + cacheCreation + cacheRead }

    /// Tokens that had to be produced or ingested fresh. Useful as the
    /// secondary figure because it tracks "real work" rather than replay.
    var fresh: Int { input + output + cacheCreation }

    var isEmpty: Bool { total == 0 }

    static let zero = TokenCounts()

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }

    // Short keys — this struct is written once per model per day into the
    // on-disk cache, so the shape stays terse.
    enum CodingKeys: String, CodingKey {
        case input = "i"
        case output = "o"
        case cacheCreation = "cw"
        case cacheRead = "cr"
    }
}

/// One local calendar day of token spend, split by model.
struct DailyTokenUsage: Equatable, Sendable, Identifiable {
    let day: Date
    var byModel: [String: TokenCounts]
    var messages: Int

    var id: Date { day }

    var totals: TokenCounts {
        byModel.values.reduce(.zero, +)
    }

    static func empty(_ day: Date) -> DailyTokenUsage {
        DailyTokenUsage(day: day, byModel: [:], messages: 0)
    }
}

/// Everything the popover needs about local token spend: a day-indexed
/// series plus the derived slices the UI shows.
struct TokenUsageSummary: Equatable, Sendable {
    /// Ascending by day. Only days that actually had traffic are present —
    /// `window(days:)` fills the gaps for charting.
    var days: [DailyTokenUsage]
    var generatedAt: Date
    /// Transcript files the last scan walked. Zero means Claude Code has
    /// never written a transcript here (fresh machine, or a moved home).
    var filesSeen: Int

    static let empty = TokenUsageSummary(days: [], generatedAt: .distantPast, filesSeen: 0)

    var isEmpty: Bool { days.allSatisfy { $0.totals.isEmpty } }

    /// The last `count` days ending today, gap-filled with zeroed days so the
    /// bar chart keeps a stable width and idle days read as idle.
    func window(days count: Int, now: Date = .now, calendar: Calendar = .current) -> [DailyTokenUsage] {
        let today = calendar.startOfDay(for: now)
        let indexed = Dictionary(days.map { (calendar.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { a, b in
            DailyTokenUsage(
                day: a.day,
                byModel: a.byModel.merging(b.byModel, uniquingKeysWith: +),
                messages: a.messages + b.messages
            )
        })
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return indexed[day] ?? .empty(day)
        }
    }

    /// Totals across the last `count` days, today included.
    func total(lastDays count: Int, now: Date = .now, calendar: Calendar = .current) -> TokenCounts {
        window(days: count, now: now, calendar: calendar)
            .reduce(.zero) { $0 + $1.totals }
    }

    func messages(lastDays count: Int, now: Date = .now, calendar: Calendar = .current) -> Int {
        window(days: count, now: now, calendar: calendar)
            .reduce(0) { $0 + $1.messages }
    }

    /// Per-model spend over the last `count` days, biggest first.
    func modelBreakdown(lastDays count: Int, now: Date = .now, calendar: Calendar = .current) -> [ModelSpend] {
        var merged: [String: TokenCounts] = [:]
        for day in window(days: count, now: now, calendar: calendar) {
            for (model, counts) in day.byModel {
                merged[model, default: .zero] += counts
            }
        }
        return merged
            .map { ModelSpend(model: $0.key, counts: $0.value) }
            .filter { !$0.counts.isEmpty }
            .sorted { $0.counts.total > $1.counts.total }
    }

    struct ModelSpend: Equatable, Sendable, Identifiable {
        let model: String
        let counts: TokenCounts
        var id: String { model }
        var displayName: String { TokenUsageFormat.modelName(model) }
    }
}

/// Presentation helpers shared by the popover tab and any future surface.
enum TokenUsageFormat {

    /// Compact token count: 812, 12.4K, 3.1M, 1.24B. Menu-bar sized strings —
    /// full precision belongs in the tooltip, not the pixel-font label.
    static func compact(_ value: Int) -> String {
        let v = Double(value)
        switch abs(v) {
        case ..<1_000:
            return "\(value)"
        case ..<1_000_000:
            return trim(v / 1_000, suffix: "K")
        case ..<1_000_000_000:
            return trim(v / 1_000_000, suffix: "M")
        default:
            return trim(v / 1_000_000_000, suffix: "B")
        }
    }

    /// Grouped full number for tooltips ("1,204,553").
    static func exact(_ value: Int) -> String {
        exactFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let exactFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static func trim(_ scaled: Double, suffix: String) -> String {
        // One decimal below 100, none above — keeps every label ≤ 5 glyphs so
        // 30 of them still fit across a 340 pt popover.
        if scaled < 10 {
            return String(format: "%.1f%@", scaled, suffix)
        }
        if scaled < 100 {
            return String(format: "%.0f%@", scaled, suffix)
        }
        return String(format: "%.0f%@", scaled, suffix)
    }

    /// "claude-opus-4-8" → "Opus 4.8", "claude-3-5-sonnet-20241022" → "Sonnet 3.5".
    /// Anything that doesn't fit the family/version shape is returned as-is:
    /// a new model name should show up verbatim rather than vanish.
    static func modelName(_ raw: String) -> String {
        var parts = raw.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        // Drop the trailing release date ("20241022") that older ids carry.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        guard let familyIndex = parts.firstIndex(where: { $0.contains(where: \.isLetter) }) else {
            return raw
        }
        let family = parts[familyIndex]
        let version = parts.enumerated()
            .filter { $0.offset != familyIndex }
            .map(\.element)
            .joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    /// Single-letter weekday under a bar in the 7-day chart.
    static func axisLabel(for day: Date, compactRange: Bool, calendar: Calendar = .current) -> String {
        if compactRange {
            return "\(calendar.component(.day, from: day))"
        }
        let weekday = calendar.component(.weekday, from: day)
        let symbols = calendar.veryShortWeekdaySymbols
        guard weekday - 1 < symbols.count else { return "" }
        return symbols[weekday - 1].uppercased()
    }

    /// "AUG 7" for the endpoints of the 30-day axis. Kept in English like the
    /// rest of the popover chrome ("TODAY", "AVG", "TURNS"); localized dates
    /// belong in the tooltips, which are prose.
    static func monthDay(_ day: Date?) -> String {
        guard let day else { return "" }
        return monthDayFormatter.string(from: day).uppercased()
    }

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()
}
