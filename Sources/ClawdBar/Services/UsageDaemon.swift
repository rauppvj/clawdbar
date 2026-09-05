import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class UsageDaemon {
    private(set) var usage: UsageData = .empty
    private(set) var lastError: String?
    private(set) var lastFetchAt: Date?
    private(set) var isPolling: Bool = false
    private(set) var isAsleep: Bool = false
    private(set) var isFetching: Bool = false

    /// What ClawdBar has stored in its own keychain item, minus the secret.
    /// nil means nothing is saved and the next fetch reads Claude Code's item.
    private(set) var savedCredentialInfo: SavedCredentialInfo?
    /// Set when the vault turned out to be unreadable this session (the user
    /// dismissed its prompt, or the app binary changed identity). We stop
    /// touching it rather than re-prompting on every poll.
    private(set) var vaultError: String?

    /// What Claude Code currently believes about the account, read from
    /// ~/.claude.json. Preferred over the token claims because a refreshed
    /// token keeps whatever plan it was minted with.
    private(set) var accountProfile: AccountProfile?

    /// Best-effort plan family (e.g. "claude_max", "max", "pro"). nil until we
    /// have either a profile or credentials.
    var subscriptionType: String? {
        accountProfile?.organizationType ?? cachedCredentials?.subscriptionType
    }
    /// Internal tier identifier (e.g. "default_claude_max_5x"). Opaque, used for diagnostics.
    var rateLimitTier: String? {
        accountProfile?.tier ?? cachedCredentials?.rateLimitTier
    }
    /// Where the plan pill's text came from, for the Preferences diagnostics.
    var planSource: String {
        accountProfile != nil ? "~/.claude.json" : "OAuth token claims"
    }

    /// Configurable poll interval. Floored at 30s per spec.
    var pollInterval: TimeInterval = 60

    private let client: UsageFetching
    private let credentialStore: CredentialLoading
    private let vault: CredentialVaulting
    private var pollTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var cachedCredentials: Credentials?
    private let profileStore: AccountProfileLoading
    private var profileModifiedAt: Date?
    private var hasCheckedProfile = false
    private var vaultAvailable = true
    let history: UsageHistoryStore

    init(
        client: UsageFetching = AnthropicAPIClient(),
        credentialStore: CredentialLoading = CredentialStore(),
        vault: CredentialVaulting = KeychainTokenVault(),
        history: UsageHistoryStore = UsageHistoryStore(),
        profileStore: AccountProfileLoading = AccountProfileStore(),
        autoStart: Bool = true
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.vault = vault
        self.history = history
        self.profileStore = profileStore
        // Seed from our own keychain item before anything else runs. When it
        // holds a live token the whole session can go by without ever touching
        // Claude Code's item — which is the only read that can prompt.
        cachedCredentials = usableSavedCredential().map(Credentials.init(saved:))
        refreshAccountProfile()
        registerSystemObservers()
        if autoStart {
            start()
        }
    }

    func start() {
        guard pollTask == nil else { return }
        isPolling = true
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    func refreshNow() async {
        await fetchOnce(reason: .manual)
    }

    /// Drops the cached token so the next fetch re-reads Claude Code's item.
    /// Use after the user runs `claude /login`. A token the user pasted is
    /// deliberately kept — that one is not a cache, it is their choice of
    /// credential; `forgetSavedCredential()` is the button that removes it.
    func invalidateCredentials() {
        cachedCredentials = nil
        if savedCredentialInfo?.origin != .pasted {
            discardSavedCredential()
        }
    }

    /// Removes ClawdBar's own keychain item entirely. The next fetch falls
    /// back to reading Claude Code's credentials, prompt and all.
    func forgetSavedCredential() {
        cachedCredentials = nil
        discardSavedCredential()
    }

    /// Stores a long-lived token from `claude setup-token` as ClawdBar's
    /// credential. While one is saved ClawdBar never reads Claude Code's
    /// keychain item, so macOS never has a reason to ask for the password.
    /// - Returns: the credential now in use.
    @discardableResult
    func saveUserToken(_ rawToken: String) throws -> Credentials {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw CredentialStore.LoadError.malformed("the token is empty")
        }
        // Carry the plan claims over from whatever we had, so the popover's
        // plan pill survives the switch — a pasted token has no JSON envelope
        // to read them from.
        let previous = try? vault.load()
        let saved = SavedCredential(
            accessToken: token,
            refreshToken: nil,
            expiresAt: nil,
            scopes: [],
            subscriptionType: previous?.subscriptionType ?? cachedCredentials?.subscriptionType,
            rateLimitTier: previous?.rateLimitTier ?? cachedCredentials?.rateLimitTier,
            origin: .pasted,
            savedAt: Date()
        )
        vaultAvailable = true
        vaultError = nil
        try vault.save(saved)
        savedCredentialInfo = SavedCredentialInfo(saved)
        let credentials = Credentials(saved: saved)
        cachedCredentials = credentials
        return credentials
    }

    /// Loads credentials into the in-memory cache, reading Claude Code's
    /// keychain item only when neither memory nor the saved copy can answer.
    /// Other call sites (onboarding, the poll loop) should funnel through this
    /// so we never fire concurrent `SecItemCopyMatching` calls — otherwise the
    /// user sees multiple keychain prompts even though their answer to the
    /// first would have covered all.
    @discardableResult
    func loadCredentials() throws -> Credentials {
        try loadCachedCredentials()
    }

    private enum FetchReason { case scheduled, manual, wake }

    private func pollLoop() async {
        // Initial immediate fetch so users see data within ~5s of launch.
        await fetchOnce(reason: .scheduled)
        while !Task.isCancelled {
            let interval = effectiveInterval
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if isAsleep { continue }
            await fetchOnce(reason: .scheduled)
        }
    }

    /// Re-parses ~/.claude.json only when its mtime has moved — the file is a
    /// few hundred KB of unrelated Claude Code state and this runs on every
    /// poll. The `hasCheckedProfile` flag is what makes the *first* look
    /// happen: on a machine with no such file both mtimes are nil, and gating
    /// on them alone would either skip forever or re-parse forever.
    ///
    /// A plan change rewrites this file without any token being re-issued, so
    /// this is the path that keeps the pill honest when the user upgrades.
    private func refreshAccountProfile() {
        let modified = profileStore.modifiedAt()
        if hasCheckedProfile, modified == profileModifiedAt { return }
        hasCheckedProfile = true
        profileModifiedAt = modified

        let loaded = profileStore.load()
        if loaded != nil || modified != nil {
            // A readable file that no longer names an account means a sign-out.
            // Fall back to the token claims rather than pinning a stale plan.
            accountProfile = loaded
        }
        // File gone entirely (moved home, deleted): keep what we had — the
        // account didn't change, our view of the disk did.
    }

    private var effectiveInterval: TimeInterval {
        let base = max(30, pollInterval)
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? base * 5 : base
    }

    private func fetchOnce(reason: FetchReason) async {
        isFetching = true
        defer { isFetching = false }
        // A plan change lands in ~/.claude.json without any token being
        // re-issued, so re-read it whenever the file has moved.
        refreshAccountProfile()
        do {
            let credentials = try loadCachedCredentials()
            let fresh = try await client.fetchUsage(using: credentials)
            self.usage = fresh
            self.lastError = nil
            self.lastFetchAt = Date()
            history.append(UsageSample(
                timestamp: fresh.lastUpdated,
                sessionPercent: fresh.sessionPercent,
                weeklyPercent: fresh.weeklyPercent
            ))
        } catch AnthropicAPIClient.APIError.unauthorized {
            self.usage.isStale = true
            self.lastError = handleUnauthorized()
        } catch let error as AnthropicAPIClient.APIError {
            self.usage.isStale = true
            self.lastError = "\(error)"
        } catch let error as CredentialStore.LoadError {
            self.usage.isStale = true
            self.lastError = "\(error)"
        } catch {
            self.usage.isStale = true
            self.lastError = error.localizedDescription
        }
    }

    /// Resolves a token, cheapest source first: memory, then ClawdBar's own
    /// keychain item, then — only if both come up empty — Claude Code's item.
    ///
    /// That last read is the one that can pop a password prompt. The macOS
    /// keychain ACL has an integrity entry bound to the item's data hash, and
    /// Claude Code rewrites its item on every OAuth refresh (~every 5 h). The
    /// rewrite changes the hash, which silently revokes the "Always Allow"
    /// authorization the user granted us, so the next `SecItemCopyMatching`
    /// becomes a password prompt. Nothing we can do keeps access to an item
    /// another process keeps rewriting — so the fix is to need it less often:
    /// mirror what we read into an item we own, and hold the in-memory copy
    /// until the API itself says 401.
    private func loadCachedCredentials() throws -> Credentials {
        if let cached = cachedCredentials {
            return cached
        }
        if let saved = usableSavedCredential() {
            let credentials = Credentials(saved: saved)
            cachedCredentials = credentials
            return credentials
        }
        let fresh = try credentialStore.load()
        cachedCredentials = fresh
        persistSavedCredential(fresh, origin: .mirror)
        return fresh
    }

    /// Reads the vault, refreshes the published summary, and drops a mirror
    /// that has aged out. Never throws: a vault we cannot use is a missed
    /// optimisation, not a failure — the caller falls back to the source.
    private func usableSavedCredential() -> SavedCredential? {
        guard vaultAvailable else { return nil }
        do {
            guard let saved = try vault.load() else {
                savedCredentialInfo = nil
                return nil
            }
            savedCredentialInfo = SavedCredentialInfo(saved)
            guard !saved.isExpired() else {
                // A stale mirror is worthless — Claude Code's item already
                // holds a newer token. A pasted token has no expiry to age out.
                if saved.origin == .mirror { discardSavedCredential() }
                return nil
            }
            return saved
        } catch {
            markVaultUnavailable(error)
            return nil
        }
    }

    private func persistSavedCredential(_ credentials: Credentials, origin: SavedCredential.Origin) {
        guard vaultAvailable else { return }
        let saved = credentials.asSaved(origin: origin)
        do {
            try vault.save(saved)
            savedCredentialInfo = SavedCredentialInfo(saved)
        } catch {
            markVaultUnavailable(error)
        }
    }

    private func discardSavedCredential() {
        savedCredentialInfo = nil
        guard vaultAvailable else { return }
        do {
            try vault.clear()
        } catch {
            markVaultUnavailable(error)
        }
    }

    /// One failed vault operation disables it for the session. Retrying would
    /// mean a keychain prompt per poll, which is exactly what this feature
    /// exists to avoid.
    private func markVaultUnavailable(_ error: any Error) {
        vaultAvailable = false
        vaultError = "\(error)"
    }

    /// A 401 means the token in hand is dead. Which copy to throw away depends
    /// on where it came from: a mirror can be replaced by re-reading Claude
    /// Code's item, but only the user can replace a token they pasted.
    private func handleUnauthorized() -> String {
        cachedCredentials = nil
        if savedCredentialInfo?.origin == .pasted {
            return "401 Unauthorized — the token saved in ClawdBar was rejected. Run `claude setup-token` again and paste the new one in Preferences → Data Source."
        }
        discardSavedCredential()
        return "\(AnthropicAPIClient.APIError.unauthorized)"
    }

    private func registerSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter

        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isAsleep = true }
        })

        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isAsleep = false
                await self?.fetchOnce(reason: .wake)
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { _ in
            // No-op — the next loop iteration re-evaluates effectiveInterval.
        })
    }
}
