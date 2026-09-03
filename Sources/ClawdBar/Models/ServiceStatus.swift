import Foundation

/// Snapshot of Anthropic's public status page (status.claude.com), decoded
/// into the shape ClawdBar renders. Mirrors what the website shows: one
/// overall indicator, a row per component, plus any unresolved incident.
///
/// Why it exists: a red 429/500 in ClawdBar looks identical whether the user
/// burned through their own limit or Anthropic is having a bad afternoon.
/// This is the second half of that story.
struct ServiceStatus: Equatable, Sendable {
    /// Page-level indicator, e.g. "All Systems Operational".
    var level: Level
    /// The page's own wording for `level` — we show it verbatim, like the site.
    var summary: String
    var components: [Component]
    /// Unresolved incidents only. Empty on a good day.
    var incidents: [Incident]
    var fetchedAt: Date

    /// Where the "open in browser" affordances point.
    static let pageURL = URL(string: "https://status.claude.com")!

    /// Statuspage's component/indicator vocabulary collapsed into one ladder,
    /// so the UI can colour, sort and pick a worst-case from a single enum.
    enum Level: String, Sendable, CaseIterable, Comparable {
        case operational
        case unknown
        case maintenance
        case degraded
        case partialOutage
        case majorOutage
        case critical

        /// Maps a Statuspage *component* `status` value.
        static func component(_ raw: String?) -> Level {
            switch raw {
            case "operational":         return .operational
            case "under_maintenance":   return .maintenance
            case "degraded_performance": return .degraded
            case "partial_outage":      return .partialOutage
            case "major_outage":        return .majorOutage
            default:                    return .unknown
            }
        }

        /// Maps a Statuspage page-level `indicator` or incident `impact` value.
        static func indicator(_ raw: String?) -> Level {
            switch raw {
            case "none":        return .operational
            case "maintenance": return .maintenance
            case "minor":       return .degraded
            case "major":       return .majorOutage
            case "critical":    return .critical
            default:            return .unknown
            }
        }

        var isHealthy: Bool { self == .operational }

        /// Short badge for the retro typeface — 7 characters is all a 200 pt
        /// overlay row can spare.
        var badge: String {
            switch self {
            case .operational:   return "OK"
            case .unknown:       return "?"
            case .maintenance:   return "MAINT"
            case .degraded:      return "DEGRADED"
            case .partialOutage: return "PARTIAL"
            case .majorOutage:   return "OUTAGE"
            case .critical:      return "DOWN"
            }
        }

        /// `unknown` sits just above `operational`: a component we can't read
        /// is worth a muted dot, but must never outrank a real outage when
        /// the UI picks the worst level on the page.
        private var rank: Int {
            switch self {
            case .operational:   return 0
            case .unknown:       return 1
            case .maintenance:   return 2
            case .degraded:      return 3
            case .partialOutage: return 4
            case .majorOutage:   return 5
            case .critical:      return 6
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    struct Component: Identifiable, Equatable, Sendable {
        let id: String
        /// Verbatim page name, e.g. "Claude API (api.anthropic.com)".
        let name: String
        let level: Level

        /// Compact label for the retro typeface: "Claude API
        /// (api.anthropic.com)" → "API". Statuspage names are written for a
        /// web page; we have 200 pt of overlay.
        var shortName: String {
            var trimmed = name
            if let paren = trimmed.firstIndex(of: "(") {
                trimmed = String(trimmed[trimmed.startIndex..<paren])
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            // Every row on this page is a Claude product — the prefix is noise.
            for prefix in ["Claude ", "Anthropic "] where trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                trimmed = String(trimmed.dropFirst(prefix.count))
            }
            if trimmed.lowercased().hasPrefix("for ") {
                trimmed = String(trimmed.dropFirst(4))
            }
            return trimmed.isEmpty ? name.uppercased() : trimmed.uppercased()
        }
    }

    struct Incident: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let impact: Level
        /// Statuspage lifecycle stage: investigating / identified / monitoring.
        let stage: String
        /// Body of the most recent update, if the payload carried one.
        let latestUpdate: String?
        let updatedAt: Date?
        /// Statuspage shortlink for this incident.
        let url: URL?
    }

    /// Worst of the page indicator and every component — the indicator can
    /// lag a component flip by a minute or two, and the pessimistic read is
    /// the useful one when you're staring at a failing request.
    var worstLevel: Level {
        max(level, components.map(\.level).max() ?? .operational)
    }

    var isHealthy: Bool { worstLevel.isHealthy }

    var degradedComponents: [Component] {
        components.filter { !$0.level.isHealthy }
    }

    /// Header line. Uses the page's own description when it has one so the
    /// wording matches status.claude.com.
    var headline: String {
        let cleaned = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { return cleaned.uppercased() }
        return worstLevel.isHealthy ? "ALL SYSTEMS OPERATIONAL" : worstLevel.badge
    }
}
