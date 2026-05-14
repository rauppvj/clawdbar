import Foundation

enum APIProbeCommand {
    static let flag = "--probe-api"

    static func run() -> Int32 {
        print("ClawdBar API probe")
        print("==================")
        print("This will spend ~1 Haiku token against api.anthropic.com.")
        print("")

        let store = CredentialStore()
        let credentials: Credentials
        do {
            credentials = try store.load()
        } catch {
            print("Cannot load credentials: \(error)")
            return 1
        }
        print("Credentials source : \(credentials.source.displayName)")
        print("Subscription       : \(credentials.subscriptionType ?? "?")")
        print("Tier               : \(credentials.rateLimitTier ?? "?")")
        print("Token expires      : \(credentials.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "?")")
        print("")

        let client = AnthropicAPIClient()
        print("Model              : \(client.configuration.model)")
        print("Endpoint           : \(client.configuration.baseURL.appendingPathComponent("v1/messages"))")
        print("")

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<UsageData, Error>!
        Task {
            do {
                let usage = try await client.fetchUsage(using: credentials)
                outcome = .success(usage)
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()

        switch outcome! {
        case .success(let usage):
            print("Result: OK")
            print("Session (5h) : \(usage.displaySessionPercent.map { "\($0)%" } ?? "?")  resets \(usage.sessionResetAt.map(formatReset) ?? "?")")
            print("Weekly  (7d) : \(usage.displayWeeklyPercent.map { "\($0)%" } ?? "?")  resets \(usage.weeklyResetAt.map(formatReset) ?? "?")")
            print("")
            print("All anthropic-* headers:")
            for (k, v) in usage.rawHeaders.sorted(by: { $0.key < $1.key }) {
                print("  \(k): \(v)")
            }
            return 0
        case .failure(let error):
            print("Result: FAILED")
            print("Error: \(error)")
            return 1
        }
    }

    private static func formatReset(_ date: Date) -> String {
        let delta = date.timeIntervalSinceNow
        if delta < 0 { return "(elapsed)" }
        if delta < 3600 { return "in \(Int(delta / 60))m" }
        if delta < 86_400 { return "in \(Int(delta / 3600))h \(Int(delta.truncatingRemainder(dividingBy: 3600) / 60))m" }
        return "in \(Int(delta / 86_400))d \(Int(delta.truncatingRemainder(dividingBy: 86_400) / 3600))h"
    }
}
