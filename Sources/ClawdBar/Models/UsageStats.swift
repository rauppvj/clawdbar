import Foundation

/// Derived metrics computed from the UsageHistoryStore. Pure function-style:
/// `compute(from:)` takes samples and produces a snapshot of stats.
struct UsageStats: Equatable, Sendable {
    var firstSeen: Date?
    var lastSeen: Date?
    var totalSamples: Int = 0
    var daysTracked: Int = 0
    var currentStreak: Int = 0
    var longestStreak: Int = 0
    var peakHour: Int?
    /// Last N days, oldest first. Each entry is (day midnight, peak session %).
    var activityByDay: [DailyActivity] = []

    struct DailyActivity: Equatable, Sendable, Identifiable {
        let day: Date
        let peakPercent: Double
        var id: Date { day }

        /// 0…4 intensity bucket à la GitHub heatmap.
        var level: Int {
            switch peakPercent {
            case 0:        return 0
            case ..<25:    return 1
            case ..<50:    return 2
            case ..<75:    return 3
            default:       return 4
            }
        }
    }

    static let empty = UsageStats()

    static func compute(from samples: [UsageSample], windowDays: Int = 56, now: Date = Date()) -> UsageStats {
        // Defensive filter: ignore samples with timestamps before 2024.
        // ClawdBar didn't exist before that; any earlier timestamp is a
        // corrupted entry (e.g. a stale Date.distantPast left over from
        // earlier dev builds), which would otherwise blow up the "since"
        // calendar math into 700,000+ days.
        let cutoff = Date(timeIntervalSince1970: 1_704_067_200)   // 2024-01-01 UTC
        let samples = samples.filter { $0.timestamp >= cutoff }
        guard !samples.isEmpty else { return .empty }

        let calendar = Calendar.current

        // Bucket samples by day -> peak session %.
        var peakByDay: [Date: Double] = [:]
        var hourSum: [Int: Double] = [:]
        var hourCount: [Int: Int] = [:]
        for sample in samples {
            let day = calendar.startOfDay(for: sample.timestamp)
            let s = sample.sessionPercent ?? 0
            if peakByDay[day] == nil || (peakByDay[day] ?? 0) < s {
                peakByDay[day] = s
            }
            let hour = calendar.component(.hour, from: sample.timestamp)
            hourSum[hour, default: 0] += s
            hourCount[hour, default: 0] += 1
        }

        // Build the windowed activity array (most recent N days, oldest first).
        let today = calendar.startOfDay(for: now)
        var activity: [DailyActivity] = []
        activity.reserveCapacity(windowDays)
        for offset in (0..<windowDays).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let peak = peakByDay[day] ?? 0
            activity.append(DailyActivity(day: day, peakPercent: peak))
        }

        // Streaks: an "active" day is any day with at least one sample logged.
        let allActiveDays = Set(peakByDay.keys)
        let longestStreak = longestRun(of: allActiveDays, calendar: calendar)
        let currentStreak = currentRun(of: allActiveDays, ending: today, calendar: calendar)

        // Peak hour: hour-of-day where average session % is highest.
        let peakHour = hourSum
            .compactMap { (hour, sum) -> (Int, Double)? in
                guard let count = hourCount[hour], count > 0 else { return nil }
                return (hour, sum / Double(count))
            }
            .max(by: { $0.1 < $1.1 })?.0

        let timestamps = samples.map(\.timestamp)
        return UsageStats(
            firstSeen: timestamps.min(),
            lastSeen: timestamps.max(),
            totalSamples: samples.count,
            daysTracked: allActiveDays.count,
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            peakHour: peakHour,
            activityByDay: activity
        )
    }

    private static func longestRun(of activeDays: Set<Date>, calendar: Calendar) -> Int {
        let sorted = activeDays.sorted()
        guard !sorted.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for i in 1..<sorted.count {
            if let prev = calendar.date(byAdding: .day, value: 1, to: sorted[i - 1]),
               calendar.isDate(prev, inSameDayAs: sorted[i]) {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }
        return longest
    }

    private static func currentRun(of activeDays: Set<Date>, ending today: Date, calendar: Calendar) -> Int {
        var streak = 0
        var cursor = today
        while activeDays.contains(cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }
}
