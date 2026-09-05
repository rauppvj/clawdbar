import Foundation

/// Turns a plan family plus a rate-limit tier into the pill shown in the
/// popover header.
///
/// Two sources can feed it and they use different vocabularies. The OAuth
/// token's claims are minted at login and are *not* rewritten when the token
/// refreshes, so a Max 5× account can carry a token that still says `pro`
/// months later — which is exactly what it did here. `oauthAccount` in
/// ~/.claude.json tracks the live account instead, so `UsageDaemon` prefers it
/// and falls back to the claims. This type's job is to read whichever it is
/// handed without being fussy about spelling.
enum PlanBadge {
    /// - Parameters:
    ///   - subscriptionType: plan family — `oauthAccount.organizationType`
    ///     ("claude_max") when ~/.claude.json is readable, otherwise
    ///     `claudeAiOauth.subscriptionType` ("pro", "max", "max_5x").
    ///   - rateLimitTier: an opaque id such as "default_claude_ai" or
    ///     "default_claude_max_20x". Carries the multiplier when the family
    ///     doesn't.
    /// - Returns: pill text, or nil when there is nothing to show.
    static func label(subscriptionType: String?, rateLimitTier: String?) -> String? {
        let raw = (subscriptionType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // The two sources spell the family differently: the token claim says
        // "max", ~/.claude.json says "claude_max". Normalise before matching.
        let sub = raw.lowercased().replacingOccurrences(of: "claude_", with: "")
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
        default:           return sub.uppercased()
        }
    }

    /// Tooltip for the pill. Names the source, because the two disagree often
    /// enough to be worth explaining: the token claim is frozen at login while
    /// ~/.claude.json follows the account.
    static let help = """
        Plan as reported by Claude Code in ~/.claude.json. If that file is \
        missing, ClawdBar falls back to the claims inside your OAuth token — \
        those are minted at login and are not rewritten when the token \
        refreshes, so they can name an old plan until you run `claude /login`.
        """
}
