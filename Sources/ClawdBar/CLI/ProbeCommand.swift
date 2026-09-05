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
        printSavedCredential()
        print("")
        printAccountProfile()
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

    /// Reports what Claude Code records about the account. This is where the
    /// plan pill gets its text; the token claims below are only the fallback,
    /// and the two routinely disagree.
    private static func printAccountProfile() {
        let store = AccountProfileStore()
        print("Account profile")
        print("---------------")
        print("File             : \(store.fileURL.path)")
        guard let profile = store.load() else {
            print("Result           : not readable — the plan pill will use the token claims")
            return
        }
        print("organizationType : \(profile.organizationType ?? "missing")")
        print("org tier         : \(profile.organizationRateLimitTier ?? "missing")")
        print("user tier        : \(profile.userRateLimitTier ?? "missing")")
        print("seat tier        : \(profile.seatTier ?? "missing")")
        print("Plan pill        : \(PlanBadge.label(subscriptionType: profile.organizationType, rateLimitTier: profile.tier) ?? "hidden")")
    }

    /// Reports ClawdBar's own keychain item — the copy that keeps the app from
    /// re-reading Claude Code's item (and re-prompting) on every launch.
    private static func printSavedCredential() {
        let vault = KeychainTokenVault()
        print("ClawdBar's own item")
        print("-------------------")
        print("Keychain service : \(vault.configuration.service)")
        do {
            guard let saved = try vault.load() else {
                print("Saved            : nothing yet")
                return
            }
            let fmt = ISO8601DateFormatter()
            print("Saved            : yes (\(saved.origin.rawValue))")
            print("accessToken      : present (\(saved.accessToken.count) chars)")
            print("savedAt          : \(fmt.string(from: saved.savedAt))")
            print("expiresAt        : \(saved.expiresAt.map { fmt.string(from: $0) } ?? "none")")
            print("usable now       : \(saved.isExpired() ? "no — expired" : "yes")")
        } catch {
            print("Saved            : unreadable — \(error)")
        }
    }
}
