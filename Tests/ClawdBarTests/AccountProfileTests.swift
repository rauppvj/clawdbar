import XCTest
@testable import ClawdBar

final class AccountProfileStoreTests: XCTestCase {

    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdbar-profile-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testReadsTheAccountBlockAndIgnoresTheRest() throws {
        let url = try write("""
            {"numStartups":41,
             "oauthAccount":{"accountUuid":"abc","organizationType":"claude_max",
                             "organizationRateLimitTier":"default_claude_max_5x",
                             "seatTier":null,"userRateLimitTier":null,
                             "organizationName":"someone's Organization"},
             "tipsHistory":{"plan-mode":41}}
            """)
        defer { try? FileManager.default.removeItem(at: url) }

        let profile = try XCTUnwrap(AccountProfileStore(fileURL: url).load())

        XCTAssertEqual(profile.organizationType, "claude_max")
        XCTAssertEqual(profile.tier, "default_claude_max_5x")
        XCTAssertEqual(PlanBadge.label(subscriptionType: profile.organizationType, rateLimitTier: profile.tier), "MAX 5×")
    }

    func testSeatTierWinsOverTheOrganizationTier() throws {
        let url = try write("""
            {"oauthAccount":{"organizationType":"claude_max",
                             "organizationRateLimitTier":"default_claude_max_20x",
                             "userRateLimitTier":"default_claude_max_5x"}}
            """)
        defer { try? FileManager.default.removeItem(at: url) }

        let profile = try XCTUnwrap(AccountProfileStore(fileURL: url).load())
        XCTAssertEqual(profile.tier, "default_claude_max_5x", "a per-user seat is what the user is actually billed against")
    }

    func testMissingOrEmptyFilesFallBackToNil() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdbar-profile-absent-\(UUID().uuidString).json")
        XCTAssertNil(AccountProfileStore(fileURL: missing).load())
        XCTAssertNil(AccountProfileStore(fileURL: missing).modifiedAt())

        let garbage = try write("not json")
        defer { try? FileManager.default.removeItem(at: garbage) }
        XCTAssertNil(AccountProfileStore(fileURL: garbage).load())

        // Present but with nothing worth showing — the token claims should win.
        let hollow = try write(#"{"oauthAccount":{"accountUuid":"abc"}}"#)
        defer { try? FileManager.default.removeItem(at: hollow) }
        XCTAssertNil(AccountProfileStore(fileURL: hollow).load())
    }

    func testModifiedAtTracksTheFile() throws {
        let url = try write(#"{"oauthAccount":{"organizationType":"claude_pro"}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotNil(AccountProfileStore(fileURL: url).modifiedAt())
    }
}

@MainActor
final class DaemonPlanSourceTests: XCTestCase {

    private struct StubProfileStore: AccountProfileLoading {
        let profile: AccountProfile?
        func load() -> AccountProfile? { profile }
        func modifiedAt() -> Date? { profile == nil ? nil : Date(timeIntervalSince1970: 1) }
    }

    private func daemon(profile: AccountProfile?) -> UsageDaemon {
        UsageDaemon(
            client: MockUsageFetcher(behavior: .success(.empty)),
            credentialStore: MockCredentialLoader(.success(Credentials(
                accessToken: "tok", refreshToken: nil, expiresAt: nil, scopes: [],
                subscriptionType: "pro", rateLimitTier: "default_claude_ai",
                source: .keychain))),
            vault: InMemoryVault(),
            history: .temporary(),
            profileStore: StubProfileStore(profile: profile),
            autoStart: false
        )
    }

    func testProfilePlanBeatsTheTokenClaim() async {
        // The regression this exists for: a Max 5× account whose OAuth token
        // was minted while it was still Pro, and stayed that way through every
        // refresh.
        let daemon = daemon(profile: AccountProfile(
            organizationType: "claude_max",
            organizationRateLimitTier: "default_claude_max_5x"
        ))

        XCTAssertEqual(daemon.subscriptionType, "claude_max")
        XCTAssertEqual(daemon.rateLimitTier, "default_claude_max_5x")
        XCTAssertEqual(daemon.planSource, "~/.claude.json")
        XCTAssertEqual(
            PlanBadge.label(subscriptionType: daemon.subscriptionType, rateLimitTier: daemon.rateLimitTier),
            "MAX 5×"
        )
    }

    func testTokenClaimsAreUsedWhenTheProfileIsUnreadable() async throws {
        let daemon = daemon(profile: nil)
        _ = try daemon.loadCredentials()

        XCTAssertEqual(daemon.subscriptionType, "pro")
        XCTAssertEqual(daemon.rateLimitTier, "default_claude_ai")
        XCTAssertEqual(daemon.planSource, "OAuth token claims")
    }
}
