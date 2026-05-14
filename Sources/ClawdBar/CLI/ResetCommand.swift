import Foundation

enum ResetCommand {
    static let flag = "--reset-onboarding"

    static func run() -> Int32 {
        print("ClawdBar — reset to fresh-user state")
        print("====================================")
        let defaults = UserDefaults.standard
        let prefix = "clawdbar."
        let dict = defaults.dictionaryRepresentation()
        var cleared = 0
        for key in dict.keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
            cleared += 1
        }
        defaults.synchronize()
        print("Removed \(cleared) clawdbar.* UserDefaults keys.")
        print("Next launch will re-run onboarding.")
        print("")
        print("Note: this does NOT touch the macOS Keychain or your Claude Code")
        print("login. To force the keychain prompt as well, open Keychain Access,")
        print("search 'Claude Code-credentials', and remove ClawdBar from the")
        print("item's Access Control list.")
        return 0
    }
}
