import XCTest
@testable import ClawdBar

final class TokenUsageSummaryTests: XCTestCase {

    private func day(_ offset: Int, total: Int, model: String = "claude-opus-5", messages: Int = 1) -> DailyTokenUsage {
        let date = Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: Date()))!
        return DailyTokenUsage(day: date, byModel: [model: TokenCounts(input: total)], messages: messages)
    }

    func testWindowFillsIdleDaysAndEndsToday() {
        let summary = TokenUsageSummary(days: [day(4, total: 5), day(0, total: 9)], generatedAt: .now, filesSeen: 1)

        let window = summary.window(days: 5)

        XCTAssertEqual(window.count, 5)
        XCTAssertEqual(window.map(\.totals.total), [5, 0, 0, 0, 9])
        XCTAssertTrue(Calendar.current.isDateInToday(window.last!.day))
    }

    func testWindowExcludesDaysOlderThanTheRange() {
        let summary = TokenUsageSummary(days: [day(10, total: 100), day(1, total: 7)], generatedAt: .now, filesSeen: 1)

        XCTAssertEqual(summary.total(lastDays: 7).total, 7)
        XCTAssertEqual(summary.total(lastDays: 30).total, 107)
    }

    func testModelBreakdownIsSortedBiggestFirst() {
        let today = Calendar.current.startOfDay(for: Date())
        let summary = TokenUsageSummary(
            days: [DailyTokenUsage(
                day: today,
                byModel: [
                    "claude-haiku-4-5-20251001": TokenCounts(input: 5),
                    "claude-opus-5": TokenCounts(input: 500),
                    "claude-sonnet-5": TokenCounts(input: 50),
                ],
                messages: 3
            )],
            generatedAt: .now,
            filesSeen: 1
        )

        let breakdown = summary.modelBreakdown(lastDays: 7)

        XCTAssertEqual(breakdown.map(\.displayName), ["Opus 5", "Sonnet 5", "Haiku 4.5"])
        XCTAssertEqual(breakdown.first?.counts.total, 500)
    }

    func testCountsAddUp() {
        let a = TokenCounts(input: 1, output: 2, cacheCreation: 3, cacheRead: 4)
        let b = TokenCounts(input: 10, output: 20, cacheCreation: 30, cacheRead: 40)
        XCTAssertEqual((a + b).total, 110)
        XCTAssertEqual((a + b).fresh, 66)
        XCTAssertEqual((a + b).uncached, 33)
        XCTAssertTrue(TokenCounts.zero.isEmpty)
    }
}

final class TokenUsageFormatTests: XCTestCase {

    func testCompactScalesAndStaysShort() {
        XCTAssertEqual(TokenUsageFormat.compact(0), "0")
        XCTAssertEqual(TokenUsageFormat.compact(812), "812")
        XCTAssertEqual(TokenUsageFormat.compact(1_200), "1.2K")
        XCTAssertEqual(TokenUsageFormat.compact(45_600), "46K")
        XCTAssertEqual(TokenUsageFormat.compact(3_140_000), "3.1M")
        XCTAssertEqual(TokenUsageFormat.compact(366_000_000), "366M")
        XCTAssertEqual(TokenUsageFormat.compact(2_058_576_110), "2.1B")
        // Every label has to fit under a 30-bar chart in a 340 pt popover.
        for value in [0, 999, 1_000, 999_999, 1_000_000, 12_345_678_901] {
            XCTAssertLessThanOrEqual(TokenUsageFormat.compact(value).count, 5, "\(value)")
        }
    }

    func testModelNamesReadLikeThePlanPage() {
        XCTAssertEqual(TokenUsageFormat.modelName("claude-opus-5"), "Opus 5")
        XCTAssertEqual(TokenUsageFormat.modelName("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(TokenUsageFormat.modelName("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(TokenUsageFormat.modelName("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(TokenUsageFormat.modelName("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(TokenUsageFormat.modelName("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        // An id we've never seen must still be visible, not swallowed.
        XCTAssertEqual(TokenUsageFormat.modelName("some-future-thing"), "Some future.thing")
        XCTAssertEqual(TokenUsageFormat.modelName("12345"), "12345")
    }
}

@MainActor
final class TokenUsageMonitorTests: XCTestCase {

    private struct StubScanner: TokenUsageScanning {
        let result: @Sendable () throws -> TokenUsageSummary
        func scan() throws -> TokenUsageSummary { try result() }
    }

    private nonisolated static func summary(total: Int) -> TokenUsageSummary {
        TokenUsageSummary(
            days: [DailyTokenUsage(
                day: Calendar.current.startOfDay(for: Date()),
                byModel: ["claude-opus-5": TokenCounts(input: total)],
                messages: 1
            )],
            generatedAt: .now,
            filesSeen: 3
        )
    }

    func testRefreshPublishesTheSummary() async {
        let monitor = TokenUsageMonitor(scanner: StubScanner(result: { Self.summary(total: 42) }))

        await monitor.refreshNow()

        XCTAssertEqual(monitor.summary.total(lastDays: 1).total, 42)
        XCTAssertTrue(monitor.hasScanned)
        XCTAssertNil(monitor.lastError)
        XCTAssertNotNil(monitor.lastScanAt)
    }

    func testFailureKeepsTheLastGoodSnapshot() async {
        let shouldFail = LockedFlag()
        let monitor = TokenUsageMonitor(scanner: StubScanner(result: {
            if shouldFail.value { throw TokenUsageScanner.ScanError.projectsDirectoryMissing("/nope") }
            return TokenUsageSummary(
                days: [DailyTokenUsage(
                    day: Calendar.current.startOfDay(for: Date()),
                    byModel: ["claude-opus-5": TokenCounts(input: 7)],
                    messages: 1
                )],
                generatedAt: .now,
                filesSeen: 3
            )
        }))

        await monitor.refreshNow()
        XCTAssertEqual(monitor.summary.total(lastDays: 1).total, 7)

        shouldFail.value = true
        await monitor.refreshNow()

        XCTAssertNotNil(monitor.lastError)
        XCTAssertEqual(monitor.summary.total(lastDays: 1).total, 7, "a failed rescan must not blank the chart")
    }

    func testRefreshIfStaleSkipsAFreshScan() async {
        let calls = Counter()
        let monitor = TokenUsageMonitor(scanner: StubScanner(result: {
            calls.increment()
            return TokenUsageSummary(days: [], generatedAt: .now, filesSeen: 1)
        }))

        await monitor.refreshIfStale(maxAge: 60)
        await monitor.refreshIfStale(maxAge: 60)

        XCTAssertEqual(calls.value, 1)
    }
}

/// Tiny thread-safe boxes — the stub scanner runs on a detached task.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}
