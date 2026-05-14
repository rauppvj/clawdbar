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

    /// Best-effort subscription type from the OAuth token (e.g. "max", "pro").
    /// nil if we haven't fetched credentials yet or the value isn't present.
    var subscriptionType: String? { cachedCredentials?.subscriptionType }
    /// Internal tier identifier (e.g. "default_claude_max_5x"). Opaque, used for diagnostics.
    var rateLimitTier: String? { cachedCredentials?.rateLimitTier }

    /// Configurable poll interval. Floored at 30s per spec.
    var pollInterval: TimeInterval = 60

    private let client: UsageFetching
    private let credentialStore: CredentialLoading
    private var pollTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var cachedCredentials: Credentials?
    let history: UsageHistoryStore

    init(
        client: UsageFetching = AnthropicAPIClient(),
        credentialStore: CredentialLoading = CredentialStore(),
        history: UsageHistoryStore = UsageHistoryStore(),
        autoStart: Bool = true
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.history = history
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

    /// Drops the in-memory token cache so the next fetch re-reads the keychain.
    /// Use after the user runs `claude /login` or when the API returned 401.
    func invalidateCredentials() {
        cachedCredentials = nil
    }

    /// Loads credentials into the in-memory cache. Re-reads the keychain only
    /// when the cache is empty or near expiry. Other call sites (onboarding,
    /// the poll loop) should funnel through this so we never fire concurrent
    /// `SecItemCopyMatching` calls — otherwise the user sees multiple keychain
    /// prompts even though their answer to the first would have covered all.
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

    private var effectiveInterval: TimeInterval {
        let base = max(30, pollInterval)
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? base * 5 : base
    }

    private func fetchOnce(reason: FetchReason) async {
        isFetching = true
        defer { isFetching = false }
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
            // Token was rejected — invalidate cache so the next poll re-reads
            // the keychain (the user may have just run `claude /login`).
            cachedCredentials = nil
            self.usage.isStale = true
            self.lastError = "\(AnthropicAPIClient.APIError.unauthorized)"
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

    /// Reads the keychain at most once per token-lifetime. If the cached
    /// credential is within 60s of its `expiresAt` we re-read so the next
    /// request gets a fresh token before the API rejects it.
    private func loadCachedCredentials() throws -> Credentials {
        if let cached = cachedCredentials, !cached.expiresSoon {
            return cached
        }
        let fresh = try credentialStore.load()
        cachedCredentials = fresh
        return fresh
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
