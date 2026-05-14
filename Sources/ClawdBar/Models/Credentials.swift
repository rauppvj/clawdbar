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

        var displayName: String {
            switch self {
            case .keychain: return "macOS Keychain"
            case .legacyFile(let url): return "Legacy file: \(url.path)"
            }
        }
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    var expiresSoon: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 300
    }
}
