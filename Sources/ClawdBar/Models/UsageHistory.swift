import Foundation
import Observation

/// One observation of usage at a point in time. Persisted as JSON Lines at
/// ~/.clawdbar/history.jsonl. Tiny payload (≈ 50 bytes per line) so a year
/// of 1-minute polls is ~ 26 MB worst case.
struct UsageSample: Codable, Equatable, Sendable {
    let timestamp: Date
    let sessionPercent: Double?
    let weeklyPercent: Double?

    enum CodingKeys: String, CodingKey {
        case timestamp = "t"
        case sessionPercent = "s"
        case weeklyPercent = "w"
    }
}

@MainActor
@Observable
final class UsageHistoryStore {
    private(set) var samples: [UsageSample] = []

    static let storageURL: URL = {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".clawdbar/history.jsonl")
    }()

    init() {
        loadFromDisk()
    }

    func append(_ sample: UsageSample) {
        // Defensive: never log a sample with a corrupt timestamp.
        guard sample.timestamp >= Self.minValidTimestamp else { return }
        samples.append(sample)
        appendToDisk(sample)
    }

    /// Anything before 2024-01-01 is clearly bogus — ClawdBar didn't exist
    /// then. Stale entries with Date.distantPast leaked from earlier dev
    /// builds and made `firstSeen` jump back to year 0001.
    private static let minValidTimestamp = Date(timeIntervalSince1970: 1_704_067_200)

    private func loadFromDisk() {
        let url = Self.storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        var loaded: [UsageSample] = []
        var droppedAny = false
        loaded.reserveCapacity(text.count / 50)
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let sample = try? decoder.decode(UsageSample.self, from: lineData)
            else {
                droppedAny = true
                continue
            }
            if sample.timestamp >= Self.minValidTimestamp {
                loaded.append(sample)
            } else {
                droppedAny = true
            }
        }
        samples = loaded
        // If we dropped bad rows, rewrite the file once so the user's stats
        // page no longer shows year-0 nonsense even before next compute.
        if droppedAny {
            rewriteAll()
        }
    }

    private func rewriteAll() {
        let url = Self.storageURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var blob = Data()
        for sample in samples {
            guard var line = try? encoder.encode(sample) else { continue }
            line.append(0x0A)
            blob.append(line)
        }
        try? blob.write(to: url, options: .atomic)
    }

    private func appendToDisk(_ sample: UsageSample) {
        let url = Self.storageURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard var data = try? encoder.encode(sample) else { return }
        data.append(0x0A) // newline

        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // best-effort: a failed history write should never crash the app
            }
        }
    }
}
