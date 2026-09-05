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
        let daemon = UsageDaemon(client: client, credentialStore: creds, vault: InMemoryVault(), history: .temporary(), profileStore: NoProfileStore(), autoStart: false)

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
        let daemon = UsageDaemon(client: client, credentialStore: creds, vault: InMemoryVault(), history: .temporary(), profileStore: NoProfileStore(), autoStart: false)

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
        let daemon = UsageDaemon(client: client, credentialStore: creds, vault: InMemoryVault(), history: .temporary(), profileStore: NoProfileStore(), autoStart: false)

        daemon.start()
        try await waitForError(daemon)
        XCTAssertTrue(daemon.lastError?.contains("401") ?? false)
        daemon.stop()
    }

    @MainActor
    func testCredentialFailureSurfacedAsError() async throws {
        let client = MockUsageFetcher(behavior: .success(.empty))
        let creds = MockCredentialLoader(.failure(.notFound))
        let daemon = UsageDaemon(client: client, credentialStore: creds, vault: InMemoryVault(), history: .temporary(), profileStore: NoProfileStore(), autoStart: false)

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
        let daemon = UsageDaemon(client: client, credentialStore: creds, vault: InMemoryVault(), history: .temporary(), profileStore: NoProfileStore(), autoStart: false)
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
        let daemon = UsageDaemon(client: client, credentialStore: creds, vault: InMemoryVault(), history: .temporary(), profileStore: NoProfileStore(), autoStart: false)
        await daemon.refreshNow()
        await daemon.refreshNow()
        XCTAssertEqual(creds.loadCallCount, 2, "401 should drop the cache; next poll re-reads keychain")
    }

    @MainActor
    func testExplicitInvalidateForcesReload() async throws {
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let client = MockUsageFetcher(behavior: .success(.empty))
        let daemon = UsageDaemon(client: client, credentialStore: creds, vault: InMemoryVault(), history: .temporary(), profileStore: NoProfileStore(), autoStart: false)
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
        let daemon = UsageDaemon(client: client, credentialStore: creds, vault: InMemoryVault(), history: .temporary(), profileStore: NoProfileStore(), autoStart: false)
        await daemon.refreshNow()
        XCTAssertEqual(daemon.usage.sessionPercent, 5)
        XCTAssertGreaterThanOrEqual(client.callCount, 1)
    }


    // MARK: - Saved credential (ClawdBar's own keychain item)

    @MainActor
    func testSuccessfulReadIsMirroredIntoTheVault() async throws {
        let vault = InMemoryVault()
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let daemon = UsageDaemon(client: MockUsageFetcher(behavior: .success(.empty)),
                                 credentialStore: creds, vault: vault,
                                 history: .temporary(), profileStore: NoProfileStore(), autoStart: false)
        await daemon.refreshNow()

        XCTAssertEqual(vault.current?.accessToken, "tok")
        XCTAssertEqual(vault.current?.origin, .mirror)
        XCTAssertEqual(daemon.savedCredentialInfo?.origin, .mirror)
    }

    @MainActor
    func testFreshVaultEntrySkipsTheClaudeCodeKeychainEntirely() async throws {
        // The whole point of the feature: a saved token means zero reads of
        // Claude Code's item, which is the read that can prompt for a password.
        let saved = SavedCredential(
            accessToken: "saved-token", refreshToken: nil,
            expiresAt: Date(timeIntervalSinceNow: 3600), scopes: [],
            subscriptionType: "max", rateLimitTier: "tier",
            origin: .mirror, savedAt: Date()
        )
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let daemon = UsageDaemon(client: MockUsageFetcher(behavior: .success(.empty)),
                                 credentialStore: creds, vault: InMemoryVault(seed: saved),
                                 history: .temporary(), profileStore: NoProfileStore(), autoStart: false)
        await daemon.refreshNow()
        await daemon.refreshNow()

        XCTAssertEqual(creds.loadCallCount, 0, "a live saved token must not trigger a keychain read")
        XCTAssertEqual(daemon.subscriptionType, "max")
    }

    @MainActor
    func testExpiredMirrorIsDroppedAndSourceIsReRead() async throws {
        let stale = SavedCredential(
            accessToken: "stale", refreshToken: nil,
            expiresAt: Date(timeIntervalSinceNow: -60), scopes: [],
            subscriptionType: nil, rateLimitTier: nil,
            origin: .mirror, savedAt: Date(timeIntervalSinceNow: -7200)
        )
        let vault = InMemoryVault(seed: stale)
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let daemon = UsageDaemon(client: MockUsageFetcher(behavior: .success(.empty)),
                                 credentialStore: creds, vault: vault,
                                 history: .temporary(), profileStore: NoProfileStore(), autoStart: false)
        await daemon.refreshNow()

        XCTAssertEqual(creds.loadCallCount, 1)
        XCTAssertEqual(vault.current?.accessToken, "tok", "the stale mirror should have been replaced")
    }

    @MainActor
    func testUnauthorizedDropsTheMirror() async throws {
        let vault = InMemoryVault()
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let daemon = UsageDaemon(client: MockUsageFetcher(behavior: .failure(.unauthorized)),
                                 credentialStore: creds, vault: vault,
                                 history: .temporary(), profileStore: NoProfileStore(), autoStart: false)
        await daemon.refreshNow()

        XCTAssertNil(vault.current, "a rejected mirror is worthless — Claude Code holds a newer token")
        XCTAssertNil(daemon.savedCredentialInfo)
    }

    @MainActor
    func testUnauthorizedKeepsAPastedTokenAndSaysWhatToDo() async throws {
        let vault = InMemoryVault()
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let daemon = UsageDaemon(client: MockUsageFetcher(behavior: .failure(.unauthorized)),
                                 credentialStore: creds, vault: vault,
                                 history: .temporary(), profileStore: NoProfileStore(), autoStart: false)
        try daemon.saveUserToken("  sk-ant-oat01-pasted  ")
        await daemon.refreshNow()

        XCTAssertEqual(vault.current?.accessToken, "sk-ant-oat01-pasted", "trimmed, and not discarded on 401")
        XCTAssertEqual(vault.current?.origin, .pasted)
        XCTAssertTrue(daemon.lastError?.contains("setup-token") ?? false)
        XCTAssertEqual(creds.loadCallCount, 0, "a pasted token never falls back to Claude Code's item")
    }

    @MainActor
    func testPastedTokenSurvivesReReadCredentialsButNotForget() async throws {
        let vault = InMemoryVault()
        let daemon = UsageDaemon(client: MockUsageFetcher(behavior: .success(.empty)),
                                 credentialStore: MockCredentialLoader(.success(MockCredentialLoader.dummy)),
                                 vault: vault, history: .temporary(), profileStore: NoProfileStore(), autoStart: false)
        try daemon.saveUserToken("sk-ant-oat01-pasted")

        daemon.invalidateCredentials()
        XCTAssertEqual(vault.current?.origin, .pasted, "`Re-read credentials` must not delete a deliberate choice")

        daemon.forgetSavedCredential()
        XCTAssertNil(vault.current)
        XCTAssertNil(daemon.savedCredentialInfo)
    }

    @MainActor
    func testEmptyPastedTokenIsRejected() async throws {
        let vault = InMemoryVault()
        let daemon = UsageDaemon(client: MockUsageFetcher(behavior: .success(.empty)),
                                 credentialStore: MockCredentialLoader(.success(MockCredentialLoader.dummy)),
                                 vault: vault, history: .temporary(), profileStore: NoProfileStore(), autoStart: false)
        XCTAssertThrowsError(try daemon.saveUserToken("   "))
        XCTAssertNil(vault.current)
    }

    @MainActor
    func testUnreadableVaultFallsBackToTheSourceAndStopsRetrying() async throws {
        // If the user dismisses the prompt for ClawdBar's own item, retrying
        // it every poll would be a prompt every poll. One failure disables it.
        let vault = InMemoryVault()
        vault.failure = .accessDenied
        let creds = MockCredentialLoader(.success(MockCredentialLoader.dummy))
        let daemon = UsageDaemon(client: MockUsageFetcher(behavior: .success(.empty)),
                                 credentialStore: creds, vault: vault,
                                 history: .temporary(), profileStore: NoProfileStore(), autoStart: false)
        await daemon.refreshNow()
        daemon.invalidateCredentials()
        await daemon.refreshNow()

        XCTAssertEqual(vault.loadCallCount, 1, "the vault is only tried once per session")
        XCTAssertEqual(creds.loadCallCount, 2, "usage keeps working off Claude Code's item")
        XCTAssertNotNil(daemon.vaultError)
        XCTAssertNil(daemon.lastError, "a vault problem must not surface as a usage error")
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

extension UsageHistoryStore {
    /// Scratch store for tests. Without this every daemon built here writes
    /// its fixture samples into the developer's real ~/.clawdbar/history.jsonl.
    static func temporary() -> UsageHistoryStore {
        UsageHistoryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("clawdbar-test-\(UUID().uuidString).jsonl")
        )
    }
}

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

/// Stands in for `AccountProfileStore`. Without it these daemons read the
/// developer's real `~/.claude.json`, and assertions about the plan claims
/// would pass or fail depending on whose machine ran them — green on CI, red
/// locally, which is the worst way round.
struct NoProfileStore: AccountProfileLoading {
    func load() -> AccountProfile? { nil }
    func modifiedAt() -> Date? { nil }
}

/// Stands in for `KeychainTokenVault`. Without it every daemon built here
/// would create — and rewrite — a real keychain item on the developer's Mac.
final class InMemoryVault: CredentialVaulting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SavedCredential?
    private(set) var loadCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var clearCallCount = 0
    /// When set, every operation throws it — models a vault we lost access to.
    var failure: KeychainTokenVault.VaultError?

    init(seed: SavedCredential? = nil) { stored = seed }

    var current: SavedCredential? { lock.withLock { stored } }

    func load() throws -> SavedCredential? {
        try lock.withLock {
            loadCallCount += 1
            if let failure { throw failure }
            return stored
        }
    }

    func save(_ credential: SavedCredential) throws {
        try lock.withLock {
            saveCallCount += 1
            if let failure { throw failure }
            stored = credential
        }
    }

    func clear() throws {
        try lock.withLock {
            clearCallCount += 1
            if let failure { throw failure }
            stored = nil
        }
    }
}
