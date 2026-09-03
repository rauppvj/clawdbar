import Foundation

/// `ClawdBar --probe-status` — fetches status.claude.com and prints what the
/// UI would render. No credentials, no tokens spent.
enum StatusProbeCommand {
    static let flag = "--probe-status"

    static func run() -> Int32 {
        let client = StatusPageClient()
        print("ClawdBar service-status probe")
        print("=============================")
        print("Endpoint: \(client.configuration.summaryURL)")
        print("")

        switch runBlocking({ try await client.fetchStatus() }) {
        case .success(let status):
            print("Page indicator : \(status.level.rawValue) — \(status.summary)")
            print("Worst level    : \(status.worstLevel.rawValue) (\(status.worstLevel.badge))")
            print("")
            print("Components:")
            for component in status.components {
                let pad = component.shortName.padding(toLength: 12, withPad: " ", startingAt: 0)
                print("  \(pad) \(component.level.badge.padding(toLength: 9, withPad: " ", startingAt: 0)) \(component.name)")
            }
            print("")
            if status.incidents.isEmpty {
                print("Incidents: none unresolved")
            } else {
                print("Incidents:")
                for incident in status.incidents {
                    print("  [\(incident.impact.rawValue)/\(incident.stage)] \(incident.name)")
                    if let body = incident.latestUpdate {
                        print("    \(body.replacingOccurrences(of: "\n", with: " ").prefix(160))")
                    }
                    if let url = incident.url { print("    \(url)") }
                }
            }
            return 0
        case .failure(let error):
            print("Result: FAILED")
            print("Error: \(error)")
            return 1
        }
    }
}
