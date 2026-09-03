import Foundation

protocol ServiceStatusFetching: Sendable {
    func fetchStatus() async throws -> ServiceStatus
}

/// Reads Anthropic's public status page feed. `summary.json` is the same
/// document the website renders: one GET, no credentials, no request body —
/// nothing about the user leaves the machine on this call.
///
/// The page is an Atlassian Statuspage instance, so the v2 API shape is
/// stable and documented: `status`, `components`, `incidents`.
struct StatusPageClient: ServiceStatusFetching, Sendable {
    struct Configuration: Sendable {
        var summaryURL: URL
        var timeout: TimeInterval

        static let `default` = Configuration(
            // status.anthropic.com 301s here — use the canonical host directly.
            summaryURL: URL(string: "https://status.claude.com/api/v2/summary.json")!,
            timeout: 10
        )
    }

    enum StatusError: Error, Equatable, CustomStringConvertible {
        case network(String)
        case nonHTTPResponse
        case server(status: Int)
        case malformedPayload(String)

        var description: String {
            switch self {
            case .network(let message):
                return "Network error: \(message)"
            case .nonHTTPResponse:
                return "Non-HTTP response from status page"
            case .server(let status):
                return "Status page returned \(status)"
            case .malformedPayload(let message):
                return "Unreadable status payload: \(message)"
            }
        }
    }

    let configuration: Configuration
    let session: URLSession

    init(configuration: Configuration = .default, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func fetchStatus() async throws -> ServiceStatus {
        var request = URLRequest(url: configuration.summaryURL)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClawdBar/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        // We poll on our own cadence and want the live document each time,
        // not whatever the URL cache kept from the previous tick.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw StatusError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw StatusError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StatusError.server(status: http.statusCode)
        }
        return try Self.snapshot(from: data, at: Date())
    }

    /// Decodes a `summary.json` body. Split out from the request so tests can
    /// feed fixtures without a network stub.
    static func snapshot(from data: Data, at date: Date) throws -> ServiceStatus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            throw StatusError.malformedPayload(error.localizedDescription)
        }

        let components = (payload.components ?? [])
            // `group: true` rows are containers for other rows, not services.
            .filter { $0.group != true }
            .map { raw -> (Payload.Component, ServiceStatus.Level) in
                (raw, .component(raw.status))
            }
            // The page hides these until they break; we do the same.
            .filter { $0.0.onlyShowIfDegraded != true || !$0.1.isHealthy }
            .sorted { ($0.0.position ?? .max) < ($1.0.position ?? .max) }
            .map { raw, level in
                ServiceStatus.Component(id: raw.id, name: raw.name, level: level)
            }

        let incidents = (payload.incidents ?? [])
            // summary.json ships unresolved incidents only, but a resolved one
            // slipping through would read as a live outage in the UI.
            .filter { $0.status != "resolved" && $0.status != "postmortem" }
            .map { raw in
                ServiceStatus.Incident(
                    id: raw.id,
                    name: raw.name,
                    impact: .indicator(raw.impact),
                    stage: raw.status ?? "",
                    latestUpdate: raw.incidentUpdates?.first?.body,
                    updatedAt: parseISO8601(raw.updatedAt ?? raw.createdAt),
                    url: raw.shortlink.flatMap(URL.init(string:))
                )
            }

        return ServiceStatus(
            level: .indicator(payload.status?.indicator),
            summary: payload.status?.description ?? "",
            components: components,
            incidents: incidents,
            fetchedAt: date
        )
    }

    // MARK: - Wire format

    /// Every field optional on purpose: a status page that drops a key must
    /// degrade to a muted dot, never to a thrown error on the UI path.
    private struct Payload: Decodable {
        let status: Status?
        let components: [Component]?
        let incidents: [Incident]?

        struct Status: Decodable {
            let indicator: String?
            let description: String?
        }

        struct Component: Decodable {
            let id: String
            let name: String
            let status: String?
            let position: Int?
            let group: Bool?
            let onlyShowIfDegraded: Bool?
        }

        struct Incident: Decodable {
            let id: String
            let name: String
            let status: String?
            let impact: String?
            let shortlink: String?
            let createdAt: String?
            let updatedAt: String?
            let incidentUpdates: [Update]?

            struct Update: Decodable {
                let body: String?
                let createdAt: String?
            }
        }
    }

    /// Statuspage stamps timestamps with fractional seconds
    /// ("2026-09-03T13:26:04.201Z"); plain `.iso8601` decoding chokes on those,
    /// so dates arrive as strings and get parsed here.
    static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
