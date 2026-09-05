import Foundation

/// The account facts Claude Code keeps in `~/.claude.json` under `oauthAccount`.
///
/// This matters because the OAuth token's own `subscriptionType` /
/// `rateLimitTier` claims are minted at login and are **not** rewritten when
/// the token is refreshed — a Max 5× account can carry a token that still says
/// `pro` / `default_claude_ai` months later. The JSON file is rewritten by
/// Claude Code as the account changes, so it is the fresher of the two.
struct AccountProfile: Equatable, Sendable, Codable {
    /// e.g. "claude_max", "claude_pro".
    var organizationType: String?
    /// e.g. "default_claude_max_5x" — carries the multiplier.
    var organizationRateLimitTier: String?
    /// Set instead of the org tier on seat-based plans.
    var userRateLimitTier: String?
    var seatTier: String?
    var organizationName: String?

    enum CodingKeys: String, CodingKey {
        case organizationType
        case organizationRateLimitTier
        case userRateLimitTier
        case seatTier
        case organizationName
    }

    /// A per-user seat tier wins over the organization's, which is what a
    /// team member on a shared org would be billed against.
    var tier: String? {
        userRateLimitTier ?? organizationRateLimitTier
    }

    /// Nothing worth showing — treat as absent so the token claims are used.
    var isEmpty: Bool {
        organizationType == nil && tier == nil && seatTier == nil
    }
}
