import Foundation

protocol UsageFetching: Sendable {
    func fetchUsage(using credentials: Credentials) async throws -> UsageData
}

struct AnthropicAPIClient: UsageFetching, Sendable {
    struct Configuration: Sendable {
        var baseURL: URL
        var model: String
        var apiVersion: String
        var timeout: TimeInterval

        static let `default` = Configuration(
            baseURL: URL(string: "https://api.anthropic.com")!,
            model: "claude-haiku-4-5-20251001",
            apiVersion: "2023-06-01",
            timeout: 10
        )
    }

    enum APIError: Error, Equatable, CustomStringConvertible {
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case server(status: Int, body: String?)
        case network(String)
        case nonHTTPResponse

        var description: String {
            switch self {
            case .unauthorized:
                return "401 Unauthorized — Claude Code session expired. Run `claude /login` to re-authenticate."
            case .rateLimited(let retry):
                if let retry { return "429 Rate limited — retry after \(Int(retry))s" }
                return "429 Rate limited"
            case .server(let status, let body):
                return "Server error \(status): \(body ?? "<no body>")"
            case .network(let message):
                return "Network error: \(message)"
            case .nonHTTPResponse:
                return "Non-HTTP response from API"
            }
        }
    }

    let configuration: Configuration
    let session: URLSession

    init(configuration: Configuration = .default, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func fetchUsage(using credentials: Credentials) async throws -> UsageData {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClawdBar/0.1 (macOS)", forHTTPHeaderField: "User-Agent")

        let payload: [String: Any] = [
            "model": configuration.model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.nonHTTPResponse
        }

        switch http.statusCode {
        case 200..<300:
            return Self.parseUsage(headers: http.allHeaderFields)
        case 401:
            throw APIError.unauthorized
        case 429:
            let raw = http.value(forHTTPHeaderField: "retry-after")
            let retry = raw.flatMap(TimeInterval.init)
            throw APIError.rateLimited(retryAfter: retry)
        default:
            let body = String(data: data, encoding: .utf8)
            throw APIError.server(status: http.statusCode, body: body)
        }
    }

    static func parseUsage(headers: [AnyHashable: Any]) -> UsageData {
        var raw: [String: String] = [:]
        for (key, value) in headers {
            guard let keyStr = key as? String else { continue }
            let lower = keyStr.lowercased()
            guard lower.hasPrefix("anthropic-") else { continue }
            raw[lower] = "\(value)"
        }

        return UsageData(
            sessionPercent: parsePercent(raw["anthropic-ratelimit-unified-5h-utilization"]),
            sessionResetAt: parseReset(raw["anthropic-ratelimit-unified-5h-reset"]),
            weeklyPercent: parsePercent(raw["anthropic-ratelimit-unified-7d-utilization"]),
            weeklyResetAt: parseReset(raw["anthropic-ratelimit-unified-7d-reset"]),
            lastUpdated: Date(),
            isStale: false,
            rawHeaders: raw
        )
    }

    static func parsePercent(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw) else { return nil }
        // Headers may report 0-1 fraction or 0-100 percent. Normalize to 0-100.
        return value <= 1.0 ? value * 100 : value
    }

    static func parseReset(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = parseISO8601(raw) { return date }
        guard let number = Double(raw) else { return nil }
        if number > 10_000_000_000 {
            return Date(timeIntervalSince1970: number / 1000)
        }
        if number > 1_000_000_000 {
            return Date(timeIntervalSince1970: number)
        }
        // Small number → seconds remaining.
        return Date(timeIntervalSinceNow: number)
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
