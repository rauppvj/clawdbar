import XCTest
@testable import ClawdBar

final class CredentialStoreTests: XCTestCase {
    func testParsesFullKeychainPayload() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-fake-access-token-abc123",
            "refreshToken": "sk-ant-fake-refresh-token-xyz789",
            "expiresAt": 1893456000000,
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "max",
            "rateLimitTier": "claude_max_20x_v2"
          },
          "mcpOAuth": {
            "ignored": "we don't care about MCP tokens"
          }
        }
        """
        let data = Data(json.utf8)
        let cred = try CredentialStore.parse(data: data, source: .keychain)

        XCTAssertEqual(cred.accessToken, "sk-ant-fake-access-token-abc123")
        XCTAssertEqual(cred.refreshToken, "sk-ant-fake-refresh-token-xyz789")
        XCTAssertEqual(cred.subscriptionType, "max")
        XCTAssertEqual(cred.rateLimitTier, "claude_max_20x_v2")
        XCTAssertEqual(cred.scopes, ["user:inference", "user:profile"])
        XCTAssertEqual(cred.source, .keychain)
        XCTAssertNotNil(cred.expiresAt)
        // 1893456000000 ms = 2030-01-01 UTC
        XCTAssertEqual(cred.expiresAt?.timeIntervalSince1970 ?? 0, 1_893_456_000, accuracy: 1)
        XCTAssertFalse(cred.isExpired)
    }

    func testParsesMinimalPayload() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok"}}"#
        let cred = try CredentialStore.parse(data: Data(json.utf8), source: .keychain)

        XCTAssertEqual(cred.accessToken, "tok")
        XCTAssertNil(cred.refreshToken)
        XCTAssertNil(cred.expiresAt)
        XCTAssertEqual(cred.scopes, [])
        XCTAssertNil(cred.subscriptionType)
        XCTAssertNil(cred.rateLimitTier)
    }

    func testTreatsLargeTimestampAsMilliseconds() throws {
        let ms = #"{"claudeAiOauth":{"accessToken":"a","expiresAt":1893456000000}}"#
        let credMs = try CredentialStore.parse(data: Data(ms.utf8), source: .keychain)
        XCTAssertEqual(credMs.expiresAt?.timeIntervalSince1970 ?? 0, 1_893_456_000, accuracy: 1)
    }

    func testTreatsSmallTimestampAsSeconds() throws {
        let s = #"{"claudeAiOauth":{"accessToken":"a","expiresAt":1893456000}}"#
        let credS = try CredentialStore.parse(data: Data(s.utf8), source: .keychain)
        XCTAssertEqual(credS.expiresAt?.timeIntervalSince1970 ?? 0, 1_893_456_000, accuracy: 1)
    }

    func testTreatsEmptyRefreshTokenAsNil() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":""}}"#
        let cred = try CredentialStore.parse(data: Data(json.utf8), source: .keychain)
        XCTAssertNil(cred.refreshToken)
    }

    func testMissingAccessTokenThrowsMalformed() {
        let json = #"{"claudeAiOauth":{"refreshToken":"r"}}"#
        XCTAssertThrowsError(
            try CredentialStore.parse(data: Data(json.utf8), source: .keychain)
        ) { error in
            guard case .malformed = (error as? CredentialStore.LoadError) else {
                XCTFail("expected .malformed, got \(error)"); return
            }
        }
    }

    func testEmptyAccessTokenThrowsMalformed() {
        let json = #"{"claudeAiOauth":{"accessToken":""}}"#
        XCTAssertThrowsError(
            try CredentialStore.parse(data: Data(json.utf8), source: .keychain)
        ) { error in
            guard case .malformed = (error as? CredentialStore.LoadError) else {
                XCTFail("expected .malformed, got \(error)"); return
            }
        }
    }

    func testMissingClaudeAiOauthThrowsMalformed() {
        let json = #"{"mcpOAuth":{}}"#
        XCTAssertThrowsError(
            try CredentialStore.parse(data: Data(json.utf8), source: .keychain)
        ) { error in
            guard case .malformed = (error as? CredentialStore.LoadError) else {
                XCTFail("expected .malformed, got \(error)"); return
            }
        }
    }

    func testInvalidJSONThrowsMalformed() {
        let json = "not json"
        XCTAssertThrowsError(
            try CredentialStore.parse(data: Data(json.utf8), source: .keychain)
        ) { error in
            guard case .malformed = (error as? CredentialStore.LoadError) else {
                XCTFail("expected .malformed, got \(error)"); return
            }
        }
    }

    func testSourcePropagates() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"a"}}"#
        let url = URL(fileURLWithPath: "/tmp/fake.json")
        let cred = try CredentialStore.parse(data: Data(json.utf8), source: .legacyFile(url))
        XCTAssertEqual(cred.source, .legacyFile(url))
    }

    func testIsExpiredReturnsTrueForPastDate() {
        var cred = Credentials(
            accessToken: "a", refreshToken: nil,
            expiresAt: Date(timeIntervalSinceNow: -100),
            scopes: [], subscriptionType: nil, rateLimitTier: nil,
            source: .keychain
        )
        XCTAssertTrue(cred.isExpired)
        cred.expiresAt = Date(timeIntervalSinceNow: 100)
        XCTAssertFalse(cred.isExpired)
    }
}
