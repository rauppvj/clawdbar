import XCTest
@testable import ClawdBar

final class AnthropicAPIClientTests: XCTestCase {

    // MARK: - Header parsing (pure)

    func testParseUsageWithUnifiedHeaders() {
        let headers: [AnyHashable: Any] = [
            "anthropic-ratelimit-unified-5h-utilization": "47",
            "anthropic-ratelimit-unified-5h-reset": "2030-01-01T00:00:00Z",
            "anthropic-ratelimit-unified-7d-utilization": "18",
            "anthropic-ratelimit-unified-7d-reset": "2030-01-07T00:00:00Z",
            "anthropic-request-id": "req_abc",
            "x-unrelated": "should be ignored",
        ]
        let u = AnthropicAPIClient.parseUsage(headers: headers)
        XCTAssertEqual(u.sessionPercent, 47)
        XCTAssertEqual(u.weeklyPercent, 18)
        XCTAssertEqual(u.displaySessionPercent, 47)
        XCTAssertEqual(u.displayWeeklyPercent, 18)
        XCTAssertNotNil(u.sessionResetAt)
        XCTAssertNotNil(u.weeklyResetAt)
        XCTAssertEqual(u.rawHeaders["anthropic-request-id"], "req_abc")
        XCTAssertNil(u.rawHeaders["x-unrelated"])
        XCTAssertFalse(u.isStale)
    }

    func testParsePercentNormalizesFraction() {
        XCTAssertEqual(AnthropicAPIClient.parsePercent("0.47") ?? -1, 47, accuracy: 0.0001)
        XCTAssertEqual(AnthropicAPIClient.parsePercent("47"), 47)
        XCTAssertEqual(AnthropicAPIClient.parsePercent("100"), 100)
        XCTAssertEqual(AnthropicAPIClient.parsePercent("1") ?? -1, 100, accuracy: 0.0001)
        XCTAssertNil(AnthropicAPIClient.parsePercent(nil))
        XCTAssertNil(AnthropicAPIClient.parsePercent("garbage"))
    }

    func testParseResetISO8601() {
        let date = AnthropicAPIClient.parseReset("2030-01-01T00:00:00Z")
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_893_456_000, accuracy: 1)
    }

    func testParseResetUnixSeconds() {
        let date = AnthropicAPIClient.parseReset("1893456000")
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_893_456_000, accuracy: 1)
    }

    func testParseResetUnixMillis() {
        let date = AnthropicAPIClient.parseReset("1893456000000")
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_893_456_000, accuracy: 1)
    }

    func testParseResetSecondsRemaining() {
        let date = AnthropicAPIClient.parseReset("3600")
        let delta = (date?.timeIntervalSinceNow ?? 0)
        XCTAssertEqual(delta, 3600, accuracy: 2)
    }

    func testParseResetReturnsNilForGarbage() {
        XCTAssertNil(AnthropicAPIClient.parseReset(nil))
        XCTAssertNil(AnthropicAPIClient.parseReset("not a date"))
    }

    func testSeverityBuckets() {
        XCTAssertEqual(UsageData.severity(for: 0), .ok)
        XCTAssertEqual(UsageData.severity(for: 49), .ok)
        XCTAssertEqual(UsageData.severity(for: 50), .warning)
        XCTAssertEqual(UsageData.severity(for: 79), .warning)
        XCTAssertEqual(UsageData.severity(for: 80), .danger)
        XCTAssertEqual(UsageData.severity(for: 94), .danger)
        XCTAssertEqual(UsageData.severity(for: 95), .critical)
        XCTAssertEqual(UsageData.severity(for: 100), .critical)
        XCTAssertEqual(UsageData.severity(for: nil), .ok)
    }

    // MARK: - End-to-end through URLProtocol mock

    func testSuccessfulFetchParsesHeaders() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/v1/messages")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "anthropic-ratelimit-unified-5h-utilization": "42",
                    "anthropic-ratelimit-unified-5h-reset": "300",
                    "anthropic-ratelimit-unified-7d-utilization": "12",
                    "anthropic-ratelimit-unified-7d-reset": "604800",
                ]
            )!
            return (response, Data("{}".utf8))
        }
        let client = makeClient()
        let usage = try await client.fetchUsage(using: makeCredentials())
        XCTAssertEqual(usage.sessionPercent, 42)
        XCTAssertEqual(usage.weeklyPercent, 12)
        XCTAssertNotNil(usage.sessionResetAt)
        XCTAssertNotNil(usage.weeklyResetAt)
    }

    func testUnauthorizedThrows() async {
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (response, Data())
        }
        do {
            _ = try await makeClient().fetchUsage(using: makeCredentials())
            XCTFail("expected throw")
        } catch let err as AnthropicAPIClient.APIError {
            XCTAssertEqual(err, .unauthorized)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testRateLimitedExtractsRetryAfter() async {
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(
                url: req.url!, statusCode: 429, httpVersion: "HTTP/1.1",
                headerFields: ["retry-after": "30"]
            )!
            return (response, Data())
        }
        do {
            _ = try await makeClient().fetchUsage(using: makeCredentials())
            XCTFail("expected throw")
        } catch let err as AnthropicAPIClient.APIError {
            XCTAssertEqual(err, .rateLimited(retryAfter: 30))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testServerErrorIncludesBody() async {
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (response, Data("{\"error\":\"boom\"}".utf8))
        }
        do {
            _ = try await makeClient().fetchUsage(using: makeCredentials())
            XCTFail("expected throw")
        } catch let err as AnthropicAPIClient.APIError {
            guard case .server(let status, let body) = err else { XCTFail("wrong case: \(err)"); return }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, "{\"error\":\"boom\"}")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Helpers

    private func makeClient() -> AnthropicAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return AnthropicAPIClient(
            configuration: .init(
                baseURL: URL(string: "https://test.local")!,
                model: "test-model",
                apiVersion: "2023-06-01",
                timeout: 5
            ),
            session: session
        )
    }

    private func makeCredentials() -> Credentials {
        Credentials(
            accessToken: "test-token", refreshToken: nil, expiresAt: nil,
            scopes: [], subscriptionType: "max", rateLimitTier: "test",
            source: .keychain
        )
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
