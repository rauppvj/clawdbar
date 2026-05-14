import Foundation

enum ProbeCommand {
    static let flag = "--probe-credentials"

    static func run() -> Int32 {
        let store = CredentialStore()
        print("ClawdBar credential probe")
        print("=========================")
        print("Keychain service : \(store.configuration.keychainService)")
        print("Keychain account : \(store.configuration.keychainAccount)")
        print("Legacy file path : \(store.configuration.legacyFileURL.path)")
        print("")

        do {
            let cred = try store.load()
            print("Result: OK")
            print("Source           : \(cred.source.displayName)")
            print("accessToken      : present (\(cred.accessToken.count) chars)")
            print("refreshToken     : \(cred.refreshToken.map { "present (\($0.count) chars)" } ?? "missing")")
            if let expires = cred.expiresAt {
                let fmt = ISO8601DateFormatter()
                let delta = expires.timeIntervalSinceNow
                let humanDelta: String
                if delta < 0 {
                    humanDelta = "expired \(Int(-delta))s ago"
                } else if delta < 3600 {
                    humanDelta = "expires in \(Int(delta / 60))m"
                } else if delta < 86_400 {
                    humanDelta = "expires in \(Int(delta / 3600))h"
                } else {
                    humanDelta = "expires in \(Int(delta / 86_400))d"
                }
                print("expiresAt        : \(fmt.string(from: expires)) (\(humanDelta))")
            } else {
                print("expiresAt        : missing")
            }
            print("isExpired        : \(cred.isExpired)")
            print("scopes           : \(cred.scopes.isEmpty ? "[]" : cred.scopes.joined(separator: ", "))")
            print("subscriptionType : \(cred.subscriptionType ?? "missing")")
            print("rateLimitTier    : \(cred.rateLimitTier ?? "missing")")
            print("")
            print("Token values are never printed.")
            return 0
        } catch let err as CredentialStore.LoadError {
            print("Result: FAILED")
            print("Reason: \(err)")
            return 1
        } catch {
            print("Result: FAILED")
            print("Unexpected error: \(error)")
            return 1
        }
    }
}
