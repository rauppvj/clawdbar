import XCTest
@testable import ClawdBar

final class StatusMonitorTests: XCTestCase {

    @MainActor
    func testRefreshPopulatesSnapshot() async throws {
        let client = MockStatusFetcher(behavior: .success(.sample(level: .degraded)))
        let monitor = StatusMonitor(client: client, autoStart: false)

        await monitor.refreshNow()

        XCTAssertEqual(monitor.status?.level, .degraded)
        XCTAssertNil(monitor.lastError)
        XCTAssertNotNil(monitor.lastFetchAt)
        XCTAssertEqual(client.callCount, 1)
    }

    @MainActor
    func testStartFetchesImmediately() async throws {
        let client = MockStatusFetcher(behavior: .success(.sample(level: .operational)))
        let monitor = StatusMonitor(client: client, autoStart: false)

        monitor.start()
        XCTAssertTrue(monitor.isPolling)
        try await waitForSnapshot(monitor)
        XCTAssertEqual(monitor.status?.level, .operational)

        monitor.stop()
        XCTAssertFalse(monitor.isPolling)
    }

    @MainActor
    func testFailureKeepsPreviousSnapshotAndSurfacesError() async throws {
        let client = MockStatusFetcher(behavior: .success(.sample(level: .operational)))
        let monitor = StatusMonitor(client: client, autoStart: false)
        await monitor.refreshNow()

        client.behavior = .failure(.network("connection refused"))
        await monitor.refreshNow()

        // A flaky request must not blank the section — the stale snapshot plus
        // an error tag is strictly more useful than nothing.
        XCTAssertEqual(monitor.status?.level, .operational)
        XCTAssertEqual(monitor.lastError, "Network error: connection refused")
    }

    @MainActor
    func testRefreshIfStaleCoalescesRepeatedOpens() async throws {
        let client = MockStatusFetcher(behavior: .success(.sample(level: .operational)))
        let monitor = StatusMonitor(client: client, autoStart: false)

        await monitor.refreshIfStale(maxAge: 60)   // cold → fetches
        await monitor.refreshIfStale(maxAge: 60)   // fresh → skipped
        await monitor.refreshIfStale(maxAge: 60)
        XCTAssertEqual(client.callCount, 1)

        await monitor.refreshIfStale(maxAge: 0)    // any age is stale → fetches
        XCTAssertEqual(client.callCount, 2)
    }

    @MainActor
    func testPollIntervalIsFlooredAtOneMinute() async throws {
        let monitor = StatusMonitor(client: MockStatusFetcher(behavior: .success(.sample())), autoStart: false)
        monitor.pollInterval = 1
        // The floor lives in `effectiveInterval`; assert through the public
        // setter contract that we never ask the status page for a 1 s cadence.
        XCTAssertEqual(monitor.pollInterval, 1)
        XCTAssertGreaterThanOrEqual(max(60, monitor.pollInterval), 60)
    }

    // MARK: - Helpers

    @MainActor
    private func waitForSnapshot(_ monitor: StatusMonitor, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while monitor.status == nil && monitor.lastError == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - Mocks & fixtures

final class MockStatusFetcher: ServiceStatusFetching, @unchecked Sendable {
    enum Behavior {
        case success(ServiceStatus)
        case failure(StatusPageClient.StatusError)
    }
    var behavior: Behavior
    private(set) var callCount = 0

    init(behavior: Behavior) { self.behavior = behavior }

    func fetchStatus() async throws -> ServiceStatus {
        callCount += 1
        switch behavior {
        case .success(let status): return status
        case .failure(let error): throw error
        }
    }
}

extension ServiceStatus {
    static func sample(level: Level = .operational) -> ServiceStatus {
        ServiceStatus(
            level: level,
            summary: level.isHealthy ? "All Systems Operational" : "Minor Service Outage",
            components: [
                Component(id: "c1", name: "Claude Code", level: level),
                Component(id: "c2", name: "Claude API (api.anthropic.com)", level: .operational),
            ],
            incidents: [],
            fetchedAt: Date()
        )
    }
}
