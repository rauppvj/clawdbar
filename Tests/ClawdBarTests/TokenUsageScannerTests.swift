import XCTest
@testable import ClawdBar

final class TokenUsageScannerTests: XCTestCase {

    // MARK: - Fixtures

    private var root: URL!
    private var projects: URL!
    private var cache: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdbar-tokens-test-\(UUID().uuidString)")
        projects = root.appendingPathComponent("projects")
        cache = root.appendingPathComponent("tokens.json")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func scanner(retentionDays: Int = 90) -> TokenUsageScanner {
        TokenUsageScanner(configuration: .init(
            projectsDirectory: projects,
            cacheURL: cache,
            retentionDays: retentionDays
        ))
    }

    /// Noon of the local day `offset` days back — formatted as the UTC stamp
    /// Claude Code writes. Anchoring on local noon keeps the expected day
    /// bucket the same in every time zone the tests might run in.
    private func timestamp(daysAgo offset: Int) -> String {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -offset, to: Date())!
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: noon)
    }

    private func line(
        messageID: String,
        requestID: String = "req_1",
        model: String = "claude-opus-5",
        daysAgo: Int = 0,
        input: Int = 10,
        output: Int = 20,
        cacheCreation: Int = 30,
        cacheRead: Int = 40
    ) -> String {
        """
        {"type":"assistant","requestId":"\(requestID)","timestamp":"\(timestamp(daysAgo: daysAgo))",\
        "message":{"id":"\(messageID)","model":"\(model)","usage":{"input_tokens":\(input),\
        "output_tokens":\(output),"cache_creation_input_tokens":\(cacheCreation),\
        "cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    private func write(_ lines: [String], to name: String) throws {
        let url = projects.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to name: String) throws {
        let url = projects.appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - Aggregation

    func testRollsUpTokensPerDayAndModel() throws {
        try write([
            line(messageID: "m1", requestID: "r1"),
            line(messageID: "m2", requestID: "r2", model: "claude-sonnet-5", input: 1, output: 2, cacheCreation: 3, cacheRead: 4),
            line(messageID: "m3", requestID: "r3", daysAgo: 1, input: 100, output: 0, cacheCreation: 0, cacheRead: 0),
        ], to: "proj-a/session.jsonl")

        let summary = try scanner().scan()

        XCTAssertEqual(summary.filesSeen, 1)
        let today = summary.window(days: 2).last!
        XCTAssertEqual(today.totals.total, 100 + 10)      // 10+20+30+40 plus 1+2+3+4
        XCTAssertEqual(today.messages, 2)
        XCTAssertEqual(today.byModel["claude-opus-5"]?.total, 100)
        XCTAssertEqual(today.byModel["claude-sonnet-5"]?.total, 10)
        XCTAssertEqual(summary.window(days: 2).first?.totals.total, 100)
        XCTAssertEqual(summary.total(lastDays: 2).total, 210)
    }

    func testSkipsSyntheticTurns() throws {
        try write([
            line(messageID: "m1", requestID: "r1"),
            line(messageID: "m2", requestID: "r2", model: "<synthetic>", input: 999),
        ], to: "proj-a/session.jsonl")

        let summary = try scanner().scan()

        XCTAssertEqual(summary.total(lastDays: 1).total, 100)
        XCTAssertEqual(summary.window(days: 1).last?.messages, 1)
    }

    func testIgnoresLinesWithoutUsage() throws {
        try write([
            #"{"type":"user","timestamp":"2026-09-01T10:00:00.000Z","message":{"role":"user","content":"talk about usage"}}"#,
            "not json at all",
            line(messageID: "m1", requestID: "r1"),
        ], to: "proj-a/session.jsonl")

        XCTAssertEqual(try scanner().scan().total(lastDays: 1).total, 100)
    }

    // MARK: - Dedup

    func testDropsTurnsReplayedIntoAnotherTranscript() throws {
        // A resumed session copies the earlier turns into its own file.
        try write([line(messageID: "m1", requestID: "r1")], to: "proj-a/first.jsonl")
        try write([
            line(messageID: "m1", requestID: "r1"),
            line(messageID: "m2", requestID: "r2"),
        ], to: "proj-a/resumed.jsonl")

        let summary = try scanner().scan()

        XCTAssertEqual(summary.total(lastDays: 1).total, 200, "the replayed turn must only count once")
        XCTAssertEqual(summary.window(days: 1).last?.messages, 2)
    }

    func testRewrittenFileIsNotDoubleCounted() throws {
        try write([
            line(messageID: "m1", requestID: "r1"),
            line(messageID: "m2", requestID: "r2"),
        ], to: "proj-a/session.jsonl")
        let scanner = scanner()
        XCTAssertEqual(try scanner.scan().total(lastDays: 1).total, 200)

        // Shrinking the file forces a re-read from byte zero.
        try write([line(messageID: "m1", requestID: "r1")], to: "proj-a/session.jsonl")

        XCTAssertEqual(try scanner.scan().total(lastDays: 1).total, 200)
    }

    // MARK: - Incremental reads

    func testAppendedTurnsAreAddedOnTheNextScan() throws {
        try write([line(messageID: "m1", requestID: "r1")], to: "proj-a/session.jsonl")
        let scanner = scanner()
        XCTAssertEqual(try scanner.scan().total(lastDays: 1).total, 100)

        try append(line(messageID: "m2", requestID: "r2") + "\n", to: "proj-a/session.jsonl")

        XCTAssertEqual(try scanner.scan().total(lastDays: 1).total, 200)
    }

    func testHalfWrittenTrailingLineIsPickedUpOnceComplete() throws {
        try write([line(messageID: "m1", requestID: "r1")], to: "proj-a/session.jsonl")
        let scanner = scanner()
        XCTAssertEqual(try scanner.scan().total(lastDays: 1).total, 100)

        // The session that is running right now: a line without its newline.
        let partial = line(messageID: "m2", requestID: "r2")
        let split = partial.index(partial.startIndex, offsetBy: 20)
        try append(String(partial[..<split]), to: "proj-a/session.jsonl")
        XCTAssertEqual(try scanner.scan().total(lastDays: 1).total, 100, "a torn line must not be parsed")

        try append(String(partial[split...]) + "\n", to: "proj-a/session.jsonl")
        XCTAssertEqual(try scanner.scan().total(lastDays: 1).total, 200)
    }

    func testDeletedTranscriptsLeaveTheCache() throws {
        try write([line(messageID: "m1", requestID: "r1")], to: "proj-a/session.jsonl")
        let scanner = scanner()
        _ = try scanner.scan()

        try FileManager.default.removeItem(at: projects.appendingPathComponent("proj-a/session.jsonl"))
        let summary = try scanner.scan()

        XCTAssertEqual(summary.filesSeen, 0)
        // Totals already banked stay — the day record isn't tied to the file.
        XCTAssertEqual(summary.total(lastDays: 1).total, 100)
    }

    // MARK: - Retention

    func testDaysOutsideRetentionAreDropped() throws {
        try write([
            line(messageID: "m1", requestID: "r1", daysAgo: 0),
            line(messageID: "m2", requestID: "r2", daysAgo: 5),
        ], to: "proj-a/session.jsonl")

        let summary = try scanner(retentionDays: 2).scan()

        XCTAssertEqual(summary.total(lastDays: 30).total, 100)
        XCTAssertEqual(summary.days.count, 1)
    }

    // MARK: - Failure

    func testMissingProjectsDirectoryThrows() throws {
        try FileManager.default.removeItem(at: projects)
        XCTAssertThrowsError(try scanner().scan()) { error in
            guard case TokenUsageScanner.ScanError.projectsDirectoryMissing = error else {
                return XCTFail("expected projectsDirectoryMissing, got \(error)")
            }
        }
    }

    // MARK: - Parsing helpers

    func testParsesClaudeCodeTimestamps() throws {
        let parsed = try XCTUnwrap(TokenUsageScanner.parseUTCTimestamp("2026-09-01T13:30:33.952Z"))
        XCTAssertEqual(parsed.timeIntervalSince1970, 1_788_269_433, accuracy: 0.5)
        XCTAssertNil(TokenUsageScanner.parseUTCTimestamp("nope"))
        XCTAssertNil(TokenUsageScanner.parseUTCTimestamp(""))
    }

    func testFingerprintIsStableAndDistinct() {
        let a = TokenUsageScanner.fingerprint(messageID: "msg_1", requestID: "req_1")
        let b = TokenUsageScanner.fingerprint(messageID: "msg_1", requestID: "req_1")
        let c = TokenUsageScanner.fingerprint(messageID: "msg_1", requestID: "req_2")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNil(TokenUsageScanner.fingerprint(messageID: nil, requestID: "req_1"))
    }
}
