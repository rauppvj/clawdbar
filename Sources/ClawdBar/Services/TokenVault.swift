import Foundation
import Security

/// The credential ClawdBar keeps for itself, and where it came from.
///
/// This is the payload of ClawdBar's *own* keychain item — the one thing in
/// the app that outlives a launch and is worth protecting. It is stored as
/// JSON inside a generic-password item, which macOS encrypts at rest with the
/// login keychain's key and gates behind an ACL naming ClawdBar. We do not
/// roll our own crypto on top: a second layer would need its own key, that key
/// would have to live in the same keychain, and the weakest link would still
/// be the keychain ACL.
struct SavedCredential: Equatable, Sendable {
    /// Where the token came from. This decides what a 401 means: a mirror can
    /// be replaced silently by re-reading Claude Code's item, while a token
    /// the user pasted can only be replaced by the user.
    enum Origin: String, Codable, Sendable {
        /// Copied out of Claude Code's keychain item after the user approved
        /// the prompt. Short-lived (~5 h) and refreshable from the source.
        case mirror
        /// Long-lived token from `claude setup-token`, pasted in Preferences.
        /// ClawdBar never touches Claude Code's keychain item while one of
        /// these is stored, so it never triggers a keychain prompt.
        case pasted

        var displayName: String {
            switch self {
            case .mirror: return "copy of your Claude Code token"
            case .pasted: return "token you pasted"
            }
        }
    }

    /// Bumped if the stored shape ever changes. A blob we cannot read is not
    /// an error worth surfacing — the next fetch just re-reads the source.
    static let currentVersion = 1

    var version: Int = SavedCredential.currentVersion
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]
    var subscriptionType: String?
    var rateLimitTier: String?
    var origin: Origin
    var savedAt: Date

    /// True when the token is past — or within `margin` of — its stated
    /// expiry. A credential with no `expiresAt` (which is what
    /// `claude setup-token` output looks like) is never considered expired
    /// here; only the API can tell us it went bad.
    func isExpired(margin: TimeInterval = 60, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(margin) >= expiresAt
    }
}

// Codable lives in an extension so the struct keeps its memberwise init.
extension SavedCredential: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, accessToken, refreshToken, expiresAt, scopes
        case subscriptionType, rateLimitTier, origin, savedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
        subscriptionType = try container.decodeIfPresent(String.self, forKey: .subscriptionType)
        rateLimitTier = try container.decodeIfPresent(String.self, forKey: .rateLimitTier)
        origin = try container.decodeIfPresent(Origin.self, forKey: .origin) ?? .mirror
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
    }
}

/// Everything the UI is allowed to know about the saved credential. Carries no
/// secret, so it can safely live in an `@Observable` property that views read.
struct SavedCredentialInfo: Equatable, Sendable {
    var origin: SavedCredential.Origin
    var savedAt: Date
    var expiresAt: Date?

    init(_ credential: SavedCredential) {
        self.origin = credential.origin
        self.savedAt = credential.savedAt
        self.expiresAt = credential.expiresAt
    }
}

protocol CredentialVaulting: Sendable {
    /// Returns the saved credential, or nil when nothing is stored.
    func load() throws -> SavedCredential?
    func save(_ credential: SavedCredential) throws
    func clear() throws
}

/// ClawdBar's own keychain item.
///
/// The whole point of this type is that we own the item. The recurring
/// password prompt users hit comes from reading *Claude Code's* item: the CLI
/// rewrites it on every token refresh, and a rewrite by another process
/// invalidates the ACL entry that "Always Allow" created for us. An item we
/// create and are the only writer of has no such churn — the authorization
/// survives until the app binary's code signature changes.
struct KeychainTokenVault: CredentialVaulting, Sendable {
    struct Configuration: Sendable {
        var service: String
        var account: String

        static let `default` = Configuration(
            service: "com.vinicius.clawdbar.credentials",
            account: NSUserName()
        )
    }

    enum VaultError: Error, Equatable, CustomStringConvertible {
        /// The user dismissed the prompt, or macOS refused us the item. Happens
        /// when the app binary changed identity (a rebuild, or an update of an
        /// ad-hoc signed build) since the item was created.
        case accessDenied
        case keychainError(OSStatus)

        var description: String {
            switch self {
            case .accessDenied:
                return "ClawdBar's saved credential is locked. Approve the keychain prompt, or use Preferences → Data Source → Forget saved credential."
            case .keychainError(let status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error: \(msg)"
            }
        }
    }

    /// Shown in Keychain Access so the item is recognisable — and deletable —
    /// by a user auditing what ClawdBar stored.
    private static let label = "ClawdBar — saved Claude credential"
    private static let comment = """
        Written by ClawdBar so it does not have to re-read Claude Code's \
        keychain item on every launch. Deleting this item is safe: ClawdBar \
        falls back to reading Claude Code's credentials again.
        """

    let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    func load() throws -> SavedCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            // A blob we can't decode is treated as "nothing saved" rather than
            // an error: the caller re-reads the source and overwrites it.
            return try? JSONDecoder().decode(SavedCredential.self, from: data)
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw VaultError.accessDenied
        default:
            throw VaultError.keychainError(status)
        }
    }

    func save(_ credential: SavedCredential) throws {
        let data = try JSONEncoder().encode(credential)

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break // fall through to add
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw VaultError.accessDenied
        default:
            throw VaultError.keychainError(updateStatus)
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = Self.label
        attributes[kSecAttrDescription as String] = "ClawdBar credential"
        attributes[kSecAttrComment as String] = Self.comment
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw VaultError.keychainError(addStatus)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw VaultError.accessDenied
        default:
            throw VaultError.keychainError(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: configuration.account,
        ]
    }
}
