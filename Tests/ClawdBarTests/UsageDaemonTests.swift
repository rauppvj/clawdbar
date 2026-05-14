import XCTest
@testable import ClawdBar

final class UsageDaemonTests: XCTestCase {

    @MainActor
    func testInitialFetchPopulatesUsage() async throws {
        let usage = UsageData(
            sessionPercent: 42, sessionResetAt: Date(timeIntervalSinceNow: 3600),
            weeklyPercent: 18, weeklyResetAt: Date(timeIntervalSinceNow: 86_400),
            lastUpdated: .now, isStale: false, rawHeaders: ["anthropic-x": "y"]
        )
        let client = MockUsageFetcher(behavior: .success(usage))
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let daemon = UsageDaemon(client: client, credentialStore: creds, autoStart: false)

        daemon.start()
        try await waitForUsage(daemon)
        XCTAssertEqual(daemon.usage.sessionPercent, 42)
        XCTAssertEqual(daemon.usage.weeklyPercent, 18)
        XCTAssertNil(daemon.lastError)
        XCTAssertFalse(daemon.usage.isStale)
        daemon.stop()
    }

    @MainActor
    func testNetworkErrorMarksStaleAndSurfacesMessage() async throws {
        let client = MockUsageFetcher(behavior: .failure(.network("connection refused")))
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let daemon = UsageDaemon(client: client, credentialStore: creds, autoStart: false)

        daemon.start()
        try await waitForError(daemon)
        XCTAssertNotNil(daemon.lastError)
        XCTAssertTrue(daemon.lastError?.contains("Network error") ?? false)
        XCTAssertTrue(daemon.usage.isStale)
        daemon.stop()
    }

    @MainActor
    func testUnauthorizedSurfacesAuthError() async throws {
        let client = MockUsageFetcher(behavior: .failure(.unauthorized))
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let daemon = UsageDaemon(client: client, credentialStore: creds, autoStart: false)

        daemon.start()
        try await waitForError(daemon)
        XCTAssertTrue(daemon.lastError?.contains("401") ?? false)
        daemon.stop()
    }

    @MainActor
    func testCredentialFailureSurfacedAsError() async throws {
        let client = MockUsageFetcher(behavior: .success(.empty))
        let creds = MockCredentialLoader(.failure(.notFound))
        let daemon = UsageDaemon(client: client, credentialStore: creds, autoStart: false)

        daemon.start()
        try await waitForError(daemon)
        XCTAssertTrue(daemon.lastError?.localizedCaseInsensitiveContains("no credentials") ?? false)
        daemon.stop()
    }

    @MainActor
    func testCredentialsCachedAcrossFetches() async throws {
        // Two successful polls should read the keychain exactly once.
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let client = MockUsageFetcher(behavior: .success(
            UsageData(sessionPercent: 1, sessionResetAt: nil, weeklyPercent: 1,
                     weeklyResetAt: nil, lastUpdated: .now, isStale: false, rawHeaders: [:])
        ))
        let daemon = UsageDaemon(client: client, credentialStore: creds, autoStart: false)
        await daemon.refreshNow()
        await daemon.refreshNow()
        await daemon.refreshNow()
        XCTAssertEqual(creds.loadCallCount, 1, "credentialStore.load() should only fire on first fetch")
        XCTAssertEqual(client.callCount, 3)
    }

    @MainActor
    func testUnauthorizedInvalidatesCredentialCache() async throws {
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let client = MockUsageFetcher(behavior: .failure(.unauthorized))
        let daemon = UsageDaemon(client: client, credentialStore: creds, autoStart: false)
        await daemon.refreshNow()
        await daemon.refreshNow()
        XCTAssertEqual(creds.loadCallCount, 2, "401 should drop the cache; next poll re-reads keychain")
    }

    @MainActor
    func testExplicitInvalidateForcesReload() async throws {
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let client = MockUsageFetcher(behavior: .success(.empty))
        let daemon = UsageDaemon(client: client, credentialStore: creds, autoStart: false)
        await daemon.refreshNow()
        XCTAssertEqual(creds.loadCallCount, 1)
        daemon.invalidateCredentials()
        await daemon.refreshNow()
        XCTAssertEqual(creds.loadCallCount, 2)
    }

    @MainActor
    func testManualRefreshTriggersFetch() async throws {
        let client = MockUsageFetcher(behavior: .success(
            UsageData(sessionPercent: 5, sessionResetAt: nil, weeklyPercent: 3,
                     weeklyResetAt: nil, lastUpdated: .now, isStale: false, rawHeaders: [:])
        ))
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let daemon = UsageDaemon(client: client, credentialStore: creds, autoStart: false)
        await daemon.refreshNow()
        XCTAssertEqual(daemon.usage.sessionPercent, 5)
        XCTAssertGreaterThanOrEqual(client.callCount, 1)
    }

    // MARK: - Helpers

    @MainActor
    private func waitForUsage(_ daemon: UsageDaemon, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while daemon.usage.sessionPercent == nil && daemon.lastError == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private func waitForError(_ daemon: UsageDaemon, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while daemon.lastError == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - Mocks

final class MockUsageFetcher: UsageFetching, @unchecked Sendable {
    enum Behavior {
        case success(UsageData)
        case failure(AnthropicAPIClient.APIError)
    }
    var behavior: Behavior
    private(set) var callCount: Int = 0

    init(behavior: Behavior) { self.behavior = behavior }

    func fetchUsage(using credentials: Credentials) async throws -> UsageData {
        callCount += 1
        switch behavior {
        case .success(let u): return u
        case .failure(let e): throw e
        }
    }
}

final class MockCredentialLoader: CredentialLoading, @unchecked Sendable {
    enum Outcome {
        case success(Credentials)
        case failure(CredentialStore.LoadError)
    }
    let outcome: Outcome
    private(set) var loadCallCount: Int = 0
    init(_ outcome: Outcome) { self.outcome = outcome }

    static let dummy = Credentials(
        accessToken: "tok", refreshToken: nil, expiresAt: nil,
        scopes: [], subscriptionType: "max", rateLimitTier: "tier",
        source: .keychain
    )

    func load() throws -> Credentials {
        loadCallCount += 1
        switch outcome {
        case .success(let c): return c
        case .failure(let e): throw e
        }
    }
}
