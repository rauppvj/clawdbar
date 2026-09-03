import Foundation

/// Turns the two plan-ish claims carried by the Claude Code OAuth token into
/// the pill shown in the popover header.
///
/// Both claims are minted by Anthropic's auth server and only change when the
/// token itself is re-issued — a plan upgrade does **not** rewrite the stored
/// token, so the pill can legitimately lag until the user re-runs
/// `claude /login`. Nothing here can fix that; the job is only to read what is
/// there without being fussy about its exact spelling.
enum PlanBadge {
    /// - Parameters:
    ///   - subscriptionType: `claudeAiOauth.subscriptionType` — seen as "pro",
    ///     "max", and (on some accounts) "max_5x" / "max_20x".
    ///   - rateLimitTier: `claudeAiOauth.rateLimitTier` — an opaque id such as
    ///     "default_claude_ai" or "default_claude_max_20x". Carries the
    ///     multiplier when `subscriptionType` doesn't.
    /// - Returns: pill text, or nil when there is nothing to show.
    static func label(subscriptionType: String?, rateLimitTier: String?) -> String? {
        let raw = (subscriptionType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let sub = raw.lowercased()
        let tier = (rateLimitTier ?? "").lowercased()

        // The multiplier can arrive on either claim, so check both before
        // falling back to a bare "MAX".
        if sub.hasPrefix("max") || tier.contains("_max") {
            if sub.contains("20x") || tier.contains("20x") { return "MAX 20×" }
            if sub.contains("5x") || tier.contains("5x") { return "MAX 5×" }
            return "MAX"
        }

        switch sub {
        case "pro":        return "PRO"
        case "team":       return "TEAM"
        case "enterprise": return "ENTERPRISE"
        case "free":       return "FREE"
        // An unknown plan name is still better shown than swallowed.
        default:           return raw.uppercased()
        }
    }

    /// Tooltip for the pill. The label is read from the token, so when it
    /// disagrees with reality the fix is a re-login, not a ClawdBar setting —
    /// say so where the user is already looking.
    static let help = """
        Plan as claimed by your Claude Code OAuth token. It only changes when \
        the token is re-issued — after changing plans, run `claude /login` in a \
        terminal, then hit "Re-read credentials" in Preferences → Data Source.
        """
}
