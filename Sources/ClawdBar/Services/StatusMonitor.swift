import Foundation
import Observation
import AppKit

/// Polls the public Claude status page on its own slow cadence, separate from
/// the usage daemon: it needs no credentials, costs no tokens, and answers a
/// different question — "is it me or is it them?".
@MainActor
@Observable
final class StatusMonitor {
    private(set) var status: ServiceStatus?
    private(set) var lastError: String?
    private(set) var lastFetchAt: Date?
    private(set) var isFetching: Bool = false
    private(set) var isPolling: Bool = false

    /// Floored at 60 s. Incidents move on the order of minutes and the page is
    /// a shared CDN document — hammering it buys nothing.
    var pollInterval: TimeInterval = 120

    private let client: ServiceStatusFetching
    private var pollTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var isAsleep = false

    init(client: ServiceStatusFetching = StatusPageClient(), autoStart: Bool = false) {
        self.client = client
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
        await fetchOnce()
    }

    /// Top-up for UI surfaces that just appeared (popover, overlay). Skips the
    /// request when the snapshot is younger than `maxAge`, so opening the menu
    /// bar ten times in a row still costs one request.
    func refreshIfStale(maxAge: TimeInterval = 60) async {
        if let lastFetchAt, -lastFetchAt.timeIntervalSinceNow < maxAge, status != nil {
            return
        }
        await fetchOnce()
    }

    /// Age of the current snapshot, for the "upd 2m" captions.
    var snapshotAge: TimeInterval? {
        guard let lastFetchAt else { return nil }
        return -lastFetchAt.timeIntervalSinceNow
    }

    private func pollLoop() async {
        await fetchOnce()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(effectiveInterval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if isAsleep { continue }
            await fetchOnce()
        }
    }

    private var effectiveInterval: TimeInterval {
        let base = max(60, pollInterval)
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? base * 5 : base
    }

    private func fetchOnce() async {
        isFetching = true
        defer { isFetching = false }
        do {
            let fresh = try await client.fetchStatus()
            status = fresh
            lastError = nil
            lastFetchAt = fresh.fetchedAt
        } catch let error as StatusPageClient.StatusError {
            // Keep the previous snapshot on screen — a stale "all good" plus
            // an error tag beats blanking the section on one flaky request.
            lastError = "\(error)"
        } catch {
            lastError = error.localizedDescription
        }
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
                guard self?.isPolling == true else { return }
                await self?.fetchOnce()
            }
        })
    }
}
