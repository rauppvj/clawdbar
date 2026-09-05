import Foundation
import Observation

/// Anything that can produce a token summary. Lets tests drive the views
/// without laying down transcript fixtures.
protocol TokenUsageScanning: Sendable {
    func scan() throws -> TokenUsageSummary
}

extension TokenUsageScanner: TokenUsageScanning {
    // Protocol requirements can't be met by defaulted parameters.
    func scan() throws -> TokenUsageSummary {
        try scan(now: .now, calendar: .current)
    }
}

/// Owns the token-spend snapshot shown in the popover.
///
/// Unlike `UsageDaemon` this talks to no network and needs no credentials —
/// everything comes from transcripts already on disk — so it refreshes when a
/// surface appears rather than on a timer. Scanning happens off the main actor;
/// only the finished summary crosses back.
@MainActor
@Observable
final class TokenUsageMonitor {
    private(set) var summary: TokenUsageSummary = .empty
    private(set) var isScanning: Bool = false
    private(set) var lastError: String?
    private(set) var lastScanAt: Date?

    /// True until the first scan settles, so the UI can tell "nothing yet"
    /// apart from "genuinely zero tokens today".
    private(set) var hasScanned: Bool = false

    private let scanner: TokenUsageScanning
    private var inFlight: Task<Void, Never>?

    init(scanner: TokenUsageScanning = TokenUsageScanner(), autoStart: Bool = false) {
        self.scanner = scanner
        if autoStart {
            Task { await refreshNow() }
        }
    }

    /// Seeds a monitor with a summary already in hand, for surfaces that have
    /// no reason to scan again — SwiftUI previews and `--render-tokens`.
    init(seeded summary: TokenUsageSummary) {
        self.scanner = TokenUsageScanner()
        self.summary = summary
        self.hasScanned = true
        self.lastScanAt = .now
    }

    /// Rescan unconditionally. Coalesces with any scan already running rather
    /// than walking the transcripts twice.
    func refreshNow() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await performScan() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Top-up for a surface that just appeared. An unchanged pass is only a
    /// stat per transcript, but opening the popover ten times in a row still
    /// shouldn't do it ten times.
    func refreshIfStale(maxAge: TimeInterval = 30) async {
        if let lastScanAt, -lastScanAt.timeIntervalSinceNow < maxAge, hasScanned {
            return
        }
        await refreshNow()
    }

    var snapshotAge: TimeInterval? {
        guard let lastScanAt else { return nil }
        return -lastScanAt.timeIntervalSinceNow
    }

    private func performScan() async {
        isScanning = true
        defer { isScanning = false }

        let scanner = self.scanner
        let result: Result<TokenUsageSummary, Error> = await Task.detached(priority: .utility) {
            do {
                return .success(try scanner.scan())
            } catch {
                return .failure(error)
            }
        }.value

        hasScanned = true
        lastScanAt = .now
        switch result {
        case .success(let summary):
            self.summary = summary
            lastError = nil
        case .failure(let error):
            // Keep the previous snapshot on screen — a transient read failure
            // shouldn't blank out yesterday's numbers.
            lastError = String(describing: error)
        }
    }
}
