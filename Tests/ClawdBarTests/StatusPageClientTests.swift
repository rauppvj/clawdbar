import XCTest
@testable import ClawdBar

final class StatusPageClientTests: XCTestCase {

    // MARK: - Fixtures

    /// Trimmed real `summary.json` shape, with the awkward cases stitched in:
    /// a group container, both flavours of `only_show_if_degraded`, an
    /// unrecognized status string, and out-of-order positions.
    private let fixture = """
    {
      "page": { "id": "tymt9n04zgry", "name": "Claude", "url": "https://status.claude.com" },
      "components": [
        { "id": "c3", "name": "Claude Code", "status": "partial_outage",
          "position": 3, "group": false, "only_show_if_degraded": false },
        { "id": "c1", "name": "claude.ai", "status": "operational",
          "position": 1, "group": false, "only_show_if_degraded": false },
        { "id": "c2", "name": "Claude API (api.anthropic.com)", "status": "degraded_performance",
          "position": 2, "group": false, "only_show_if_degraded": false },
        { "id": "grp", "name": "Regional endpoints", "status": "operational",
          "position": 4, "group": true, "only_show_if_degraded": false },
        { "id": "hidden", "name": "Batch API", "status": "operational",
          "position": 5, "group": false, "only_show_if_degraded": true },
        { "id": "shown", "name": "Claude Cowork", "status": "major_outage",
          "position": 6, "group": false, "only_show_if_degraded": true },
        { "id": "weird", "name": "Claude for Government", "status": "brand_new_state",
          "position": 7, "group": false, "only_show_if_degraded": false }
      ],
      "incidents": [
        { "id": "i1", "name": "Elevated errors for multiple models", "status": "identified",
          "impact": "critical", "shortlink": "https://stspg.io/abc",
          "created_at": "2026-09-03T13:26:04.201Z", "updated_at": "2026-09-03T13:50:26.925Z",
          "incident_updates": [
            { "body": "An exhaustive list of affected models.", "created_at": "2026-09-03T13:50:26.925Z" },
            { "body": "We are investigating.", "created_at": "2026-09-03T13:26:04.201Z" }
          ] },
        { "id": "i2", "name": "Old news", "status": "resolved", "impact": "minor",
          "shortlink": "https://stspg.io/old", "incident_updates": [] }
      ],
      "scheduled_maintenances": [],
      "status": { "indicator": "minor", "description": "Minor Service Outage" }
    }
    """.data(using: .utf8)!

    private func snapshot(_ json: Data) throws -> ServiceStatus {
        try StatusPageClient.snapshot(from: json, at: Date(timeIntervalSince1970: 1_770_000_000))
    }

    // MARK: - Page level

    func testParsesPageIndicatorAndDescription() throws {
        let status = try snapshot(fixture)
        XCTAssertEqual(status.level, .degraded)          // "minor"
        XCTAssertEqual(status.summary, "Minor Service Outage")
        XCTAssertEqual(status.headline, "MINOR SERVICE OUTAGE")
        XCTAssertFalse(status.isHealthy)
    }

    func testWorstLevelOutranksALaggingPageIndicator() throws {
        // The page still says "All Systems Operational" while a component has
        // already flipped — the pessimistic read is the useful one.
        let json = """
        {
          "components": [
            { "id": "a", "name": "Claude Code", "status": "major_outage", "position": 1 }
          ],
          "status": { "indicator": "none", "description": "All Systems Operational" }
        }
        """.data(using: .utf8)!
        let status = try snapshot(json)
        XCTAssertEqual(status.level, .operational)
        XCTAssertEqual(status.worstLevel, .majorOutage)
        XCTAssertFalse(status.isHealthy)
    }

    func testHealthyPage() throws {
        let json = """
        {
          "components": [
            { "id": "a", "name": "Claude Code", "status": "operational", "position": 1 }
          ],
          "incidents": [],
          "status": { "indicator": "none", "description": "All Systems Operational" }
        }
        """.data(using: .utf8)!
        let status = try snapshot(json)
        XCTAssertTrue(status.isHealthy)
        XCTAssertTrue(status.degradedComponents.isEmpty)
        XCTAssertEqual(status.headline, "ALL SYSTEMS OPERATIONAL")
    }

    // MARK: - Components

    func testComponentsAreFilteredAndSortedByPosition() throws {
        let status = try snapshot(fixture)
        XCTAssertEqual(
            status.components.map(\.id),
            ["c1", "c2", "c3", "shown", "weird"],
            "group containers and healthy only_show_if_degraded rows must be dropped, rest sorted by position"
        )
    }

    func testComponentStatusMapping() throws {
        let status = try snapshot(fixture)
        let byID = Dictionary(uniqueKeysWithValues: status.components.map { ($0.id, $0.level) })
        XCTAssertEqual(byID["c1"], .operational)
        XCTAssertEqual(byID["c2"], .degraded)
        XCTAssertEqual(byID["c3"], .partialOutage)
        XCTAssertEqual(byID["shown"], .majorOutage)
        XCTAssertEqual(byID["weird"], .unknown, "an unseen status string must degrade, not throw")
    }

    func testDegradedComponentsExcludeHealthyOnes() throws {
        let status = try snapshot(fixture)
        XCTAssertEqual(status.degradedComponents.map(\.id), ["c2", "c3", "shown", "weird"])
    }

    func testShortNameStripsVendorPrefixAndHost() {
        let cases: [(String, String)] = [
            ("claude.ai", "CLAUDE.AI"),
            ("Claude API (api.anthropic.com)", "API"),
            ("Claude Console (platform.claude.com)", "CONSOLE"),
            ("Claude Code", "CODE"),
            ("Claude Cowork", "COWORK"),
            ("Claude for Government", "GOVERNMENT"),
            ("Anthropic Batch API", "BATCH API"),
            ("(weird)", "(WEIRD)"),
        ]
        for (raw, expected) in cases {
            let component = ServiceStatus.Component(id: raw, name: raw, level: .operational)
            XCTAssertEqual(component.shortName, expected, "shortName(\(raw))")
        }
    }

    // MARK: - Incidents

    func testParsesUnresolvedIncidentWithLatestUpdate() throws {
        let status = try snapshot(fixture)
        XCTAssertEqual(status.incidents.count, 1, "resolved incidents must be dropped")
        let incident = try XCTUnwrap(status.incidents.first)
        XCTAssertEqual(incident.id, "i1")
        XCTAssertEqual(incident.name, "Elevated errors for multiple models")
        XCTAssertEqual(incident.impact, .critical)
        XCTAssertEqual(incident.stage, "identified")
        XCTAssertEqual(incident.latestUpdate, "An exhaustive list of affected models.")
        XCTAssertEqual(incident.url?.absoluteString, "https://stspg.io/abc")
        // Fractional-second ISO8601 — plain .iso8601 decoding would fail here.
        XCTAssertEqual(
            incident.updatedAt?.timeIntervalSince1970 ?? 0,
            ISO8601DateFormatter().date(from: "2026-09-03T13:50:26Z")!.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testIncidentDatesFallBackToCreatedAt() throws {
        let json = """
        {
          "incidents": [
            { "id": "i", "name": "N", "status": "investigating", "impact": "major",
              "created_at": "2026-09-03T13:26:04Z", "incident_updates": [] }
          ],
          "status": { "indicator": "major", "description": "Major Outage" }
        }
        """.data(using: .utf8)!
        let status = try snapshot(json)
        let incident = try XCTUnwrap(status.incidents.first)
        XCTAssertNotNil(incident.updatedAt)
        XCTAssertNil(incident.latestUpdate)
        XCTAssertNil(incident.url)
        XCTAssertEqual(incident.impact, .majorOutage)
    }

    // MARK: - Degradation

    func testEmptyObjectYieldsUnknownRatherThanThrowing() throws {
        let status = try snapshot("{}".data(using: .utf8)!)
        XCTAssertEqual(status.level, .unknown)
        XCTAssertTrue(status.components.isEmpty)
        XCTAssertTrue(status.incidents.isEmpty)
        XCTAssertEqual(status.headline, "?", "no description → fall back to the level badge")
    }

    func testMalformedPayloadThrowsTypedError() {
        XCTAssertThrowsError(try snapshot("not json".data(using: .utf8)!)) { error in
            guard case StatusPageClient.StatusError.malformedPayload = error else {
                return XCTFail("expected .malformedPayload, got \(error)")
            }
        }
    }

    func testLevelLadderOrdering() {
        XCTAssertTrue(ServiceStatus.Level.operational < .unknown)
        XCTAssertTrue(ServiceStatus.Level.unknown < .maintenance)
        XCTAssertTrue(ServiceStatus.Level.maintenance < .degraded)
        XCTAssertTrue(ServiceStatus.Level.degraded < .partialOutage)
        XCTAssertTrue(ServiceStatus.Level.partialOutage < .majorOutage)
        XCTAssertTrue(ServiceStatus.Level.majorOutage < .critical)
        XCTAssertEqual([ServiceStatus.Level.degraded, .operational, .partialOutage].max(), .partialOutage)
    }

    func testDefaultEndpointIsTheCanonicalHost() {
        // status.anthropic.com 301s to status.claude.com; following redirects
        // on every poll is waste we can just not do.
        XCTAssertEqual(
            StatusPageClient.Configuration.default.summaryURL.absoluteString,
            "https://status.claude.com/api/v2/summary.json"
        )
    }
}
