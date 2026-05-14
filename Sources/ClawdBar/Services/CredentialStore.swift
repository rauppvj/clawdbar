import Foundation
import Security

protocol CredentialLoading: Sendable {
    func load() throws -> Credentials
}

struct CredentialStore: CredentialLoading, Sendable {
    struct Configuration: Sendable {
        var keychainService: String
        var keychainAccount: String
        var legacyFileURL: URL

        static let `default` = Configuration(
            keychainService: "Claude Code-credentials",
            keychainAccount: NSUserName(),
            legacyFileURL: URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".claude/.credentials.json")
        )
    }

    enum LoadError: Error, Equatable, CustomStringConvertible {
        case notFound
        case accessDenied
        case malformed(String)
        case keychainError(OSStatus)
        case fileError(String)

        var description: String {
            switch self {
            case .notFound:
                return "No credentials found. Sign in to Claude Code first."
            case .accessDenied:
                return "Keychain access denied. Approve the keychain prompt for ClawdBar."
            case .malformed(let detail):
                return "Credentials malformed: \(detail)"
            case .keychainError(let status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error: \(msg)"
            case .fileError(let detail):
                return "File error: \(detail)"
            }
        }
    }

    let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    func load() throws -> Credentials {
        if let data = try readKeychain() {
            return try Self.parse(data: data, source: .keychain)
        }
        if let data = try readLegacyFile() {
            return try Self.parse(data: data, source: .legacyFile(configuration.legacyFileURL))
        }
        throw LoadError.notFound
    }

    private func readKeychain() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.keychainService,
            kSecAttrAccount as String: configuration.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw LoadError.accessDenied
        default:
            throw LoadError.keychainError(status)
        }
    }

    private func readLegacyFile() throws -> Data? {
        let url = configuration.legacyFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw LoadError.fileError(error.localizedDescription)
        }
    }

    static func parse(data: Data, source: Credentials.Source) throws -> Credentials {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LoadError.malformed("invalid JSON: \(error.localizedDescription)")
        }
        guard let dict = root as? [String: Any] else {
            throw LoadError.malformed("expected object at root")
        }
        guard let oauth = dict["claudeAiOauth"] as? [String: Any] else {
            throw LoadError.malformed("missing claudeAiOauth")
        }
        guard let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else {
            throw LoadError.malformed("missing claudeAiOauth.accessToken")
        }

        return Credentials(
            accessToken: accessToken,
            refreshToken: (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: parseTimestamp(oauth["expiresAt"]),
            scopes: (oauth["scopes"] as? [String]) ?? [],
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String,
            source: source
        )
    }

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        let number: Double
        switch raw {
        case let n as NSNumber: number = n.doubleValue
        case let s as String: guard let parsed = Double(s) else { return nil }; number = parsed
        default: return nil
        }
        // Heuristic: > 10^12 means unix-ms; smaller means unix-s.
        let seconds = number >= 10_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }
}
