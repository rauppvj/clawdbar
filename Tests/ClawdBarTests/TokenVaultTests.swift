import XCTest
@testable import ClawdBar

/// Covers the payload ClawdBar writes into its own keychain item. The keychain
/// itself is not exercised here on purpose — a test that called SecItemAdd
/// would create a real item on whoever's Mac ran the suite.
final class TokenVaultTests: XCTestCase {

    private let sample = SavedCredential(
        accessToken: "sk-ant-fake-token",
        refreshToken: "sk-ant-fake-refresh",
        expiresAt: Date(timeIntervalSince1970: 1_893_456_000),
        scopes: ["user:inference"],
        subscriptionType: "max",
        rateLimitTier: "claude_max_20x_v2",
        origin: .mirror,
        savedAt: Date(timeIntervalSince1970: 1_893_452_400)
    )

    func testRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(SavedCredential.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertEqual(decoded.version, SavedCredential.currentVersion)
    }

    func testDecodesABlobWrittenBeforeTheOptionalFieldsExisted() throws {
        // Forward compatibility guard: a stored blob missing everything but the
        // token must still load, so an app update never strands a saved login.
        let json = #"{"accessToken":"tok"}"#
        let decoded = try JSONDecoder().decode(SavedCredential.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.accessToken, "tok")
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.origin, .mirror)
        XCTAssertEqual(decoded.scopes, [])
        XCTAssertNil(decoded.expiresAt)
    }

    func testRejectsABlobWithNoToken() {
        let json = #"{"origin":"pasted"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(SavedCredential.self, from: Data(json.utf8)))
    }

    func testExpiryUsesTheMarginSoWeNeverSendADyingToken() {
        var credential = sample
        let now = Date()
        credential.expiresAt = now.addingTimeInterval(30)
        XCTAssertTrue(credential.isExpired(margin: 60, now: now))
        credential.expiresAt = now.addingTimeInterval(300)
        XCTAssertFalse(credential.isExpired(margin: 60, now: now))
    }

    func testATokenWithoutAnExpiryNeverAgesOut() {
        // `claude setup-token` output carries no expiry we can read. Only the
        // API can tell us it went bad, so we must not guess.
        var credential = sample
        credential.origin = .pasted
        credential.expiresAt = nil
        XCTAssertFalse(credential.isExpired())
    }

    func testConvertsToAndFromTheCredentialsTheAPIClientUses() {
        let credentials = Credentials(saved: sample)
        XCTAssertEqual(credentials.accessToken, sample.accessToken)
        XCTAssertEqual(credentials.subscriptionType, "max")
        XCTAssertEqual(credentials.source, .saved(.mirror))
        XCTAssertTrue(credentials.source.displayName.contains("ClawdBar"))

        let back = credentials.asSaved(origin: .pasted, savedAt: sample.savedAt)
        XCTAssertEqual(back.origin, .pasted)
        XCTAssertEqual(back.accessToken, sample.accessToken)
        XCTAssertEqual(back.expiresAt, sample.expiresAt)
    }

    func testVaultConfigurationTargetsAnItemClawdBarOwns() {
        // Reading Claude Code's item is what prompts; ours must be a separate
        // service name so the two can never collide.
        let vault = KeychainTokenVault()
        XCTAssertEqual(vault.configuration.service, "com.vinicius.clawdbar.credentials")
        XCTAssertNotEqual(vault.configuration.service, CredentialStore.Configuration.default.keychainService)
    }
}
