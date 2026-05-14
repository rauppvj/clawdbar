import Foundation

struct UsageData: Equatable, Sendable {
    var sessionPercent: Double?
    var sessionResetAt: Date?
    var weeklyPercent: Double?
    var weeklyResetAt: Date?
    var lastUpdated: Date
    var isStale: Bool
    var rawHeaders: [String: String]

    static let empty = UsageData(
        sessionPercent: nil, sessionResetAt: nil,
        weeklyPercent: nil, weeklyResetAt: nil,
        lastUpdated: .distantPast, isStale: true, rawHeaders: [:]
    )

    enum Severity {
        case ok, warning, danger, critical

        var systemColorName: String {
            switch self {
            case .ok: return "systemGreen"
            case .warning: return "systemYellow"
            case .danger: return "systemOrange"
            case .critical: return "systemRed"
            }
        }
    }

    static func severity(for percent: Double?) -> Severity {
        guard let p = percent else { return .ok }
        switch p {
        case ..<50: return .ok
        case ..<80: return .warning
        case ..<95: return .danger
        default: return .critical
        }
    }

    var sessionSeverity: Severity { Self.severity(for: sessionPercent) }
    var weeklySeverity: Severity { Self.severity(for: weeklyPercent) }

    var displaySessionPercent: Int? { sessionPercent.map { Int($0.rounded()) } }
    var displayWeeklyPercent: Int? { weeklyPercent.map { Int($0.rounded()) } }
}
