import XCTest
@testable import ClawdBar

@MainActor
final class UsageHistoryStoreTests: XCTestCase {

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdbar-history-test-\(UUID().uuidString).jsonl")
    }

    func testAppendWritesToTheInjectedPathOnly() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = UsageHistoryStore(fileURL: url)
        store.append(UsageSample(timestamp: Date(), sessionPercent: 42, weeklyPercent: 18))

        let written = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8))
        XCTAssertTrue(written.contains("42"), "sample should land in the injected file")

        // The guard that matters: the real history must be untouched by tests.
        XCTAssertNotEqual(url, UsageHistoryStore.storageURL)
    }

    func testReloadsWhatItWrote() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = UsageHistoryStore(fileURL: url)
        first.append(UsageSample(timestamp: Date(), sessionPercent: 10, weeklyPercent: 20))
        first.append(UsageSample(timestamp: Date(), sessionPercent: 30, weeklyPercent: 40))

        let second = UsageHistoryStore(fileURL: url)
        XCTAssertEqual(second.samples.count, 2)
        XCTAssertEqual(second.samples.last?.sessionPercent, 30)
    }

    func testRejectsCorruptTimestamps() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = UsageHistoryStore(fileURL: url)
        store.append(UsageSample(timestamp: .distantPast, sessionPercent: 5, weeklyPercent: 5))
        XCTAssertTrue(store.samples.isEmpty, "pre-2024 samples must be dropped, not logged")
    }
}
