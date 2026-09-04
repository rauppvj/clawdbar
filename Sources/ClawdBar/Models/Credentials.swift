import Foundation

struct Credentials: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]
    var subscriptionType: String?
    var rateLimitTier: String?
    var source: Source

    enum Source: Equatable, Sendable {
        case keychain
        case legacyFile(URL)
        /// Read back from ClawdBar's own keychain item — no prompt, because
        /// ClawdBar owns that item. See `KeychainTokenVault`.
        case saved(SavedCredential.Origin)

        var displayName: String {
            switch self {
            case .keychain: return "macOS Keychain"
            case .legacyFile(let url): return "Legacy file: \(url.path)"
            case .saved(let origin): return "ClawdBar keychain item (\(origin.displayName))"
            }
        }
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

extension Credentials {
    init(saved: SavedCredential) {
        self.init(
            accessToken: saved.accessToken,
            refreshToken: saved.refreshToken,
            expiresAt: saved.expiresAt,
            scopes: saved.scopes,
            subscriptionType: saved.subscriptionType,
            rateLimitTier: saved.rateLimitTier,
            source: .saved(saved.origin)
        )
    }

    func asSaved(origin: SavedCredential.Origin, savedAt: Date = Date()) -> SavedCredential {
        SavedCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: scopes,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier,
            origin: origin,
            savedAt: savedAt
        )
    }
}
