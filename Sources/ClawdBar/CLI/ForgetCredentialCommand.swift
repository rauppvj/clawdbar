import Foundation

/// Deletes ClawdBar's own keychain item from the terminal, for when the app
/// itself can't be opened (or its saved credential became unreadable after a
/// rebuild changed the binary's code signature).
enum ForgetCredentialCommand {
    static let flag = "--forget-credential"

    static func run() -> Int32 {
        let vault = KeychainTokenVault()
        print("ClawdBar — forget saved credential")
        print("==================================")
        print("Keychain service : \(vault.configuration.service)")
        do {
            try vault.clear()
            print("Removed. ClawdBar will read Claude Code's credentials again on")
            print("the next poll, and macOS may ask you to approve that once.")
            print("")
            print("Your Claude Code login is untouched.")
            return 0
        } catch {
            print("Failed: \(error)")
            return 1
        }
    }
}
