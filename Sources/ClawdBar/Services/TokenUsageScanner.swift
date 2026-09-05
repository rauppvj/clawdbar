import Foundation

/// Reads Claude Code's local transcripts (`~/.claude/projects/**/*.jsonl`) and
/// rolls the per-turn `message.usage` blocks up into daily token totals.
///
/// Three things make this cheap enough to run every time the popover opens:
///
/// 1. **Byte cursors.** Transcripts are append-only, so each file is
///    remembered by (size, mtime, offset) and only the bytes past the offset
///    are read on the next pass. A pass where nothing changed is 100-odd
///    `stat` calls.
/// 2. **Retention skip.** A file whose mtime predates the retention window
///    cannot contain a day we still show, so it is marked consumed unread.
///    That keeps the very first scan off the hundreds of megabytes of
///    transcripts a heavy user accumulates.
/// 3. **Dedup by (message id, request id).** Resumed and forked sessions
///    replay earlier turns into the new file — on this machine that is ~47 %
///    of all usage records — so counting raw lines would inflate every number.
///    Hashes are kept per day and pruned along with the day.
struct TokenUsageScanner: Sendable {

    struct Configuration: Sendable {
        var projectsDirectory: URL
        var cacheURL: URL
        /// How many days of history to keep. The UI shows 30; the extra
        /// headroom means a month-long view survives a few idle weeks.
        var retentionDays: Int

        static let `default` = Configuration(
            projectsDirectory: FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects"),
            cacheURL: FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".clawdbar/tokens.json"),
            retentionDays: 90
        )
    }

    enum ScanError: Error, Equatable, CustomStringConvertible {
        case projectsDirectoryMissing(String)

        var description: String {
            switch self {
            case .projectsDirectoryMissing(let path):
                return "No Claude Code transcripts at \(path)"
            }
        }
    }

    let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Entry point

    /// Walks whatever is new since the last call and returns the rolled-up
    /// summary. Safe to call from any thread; does no UI work.
    func scan(now: Date = .now, calendar: Calendar = .current) throws -> TokenUsageSummary {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: configuration.projectsDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScanError.projectsDirectoryMissing(configuration.projectsDirectory.path)
        }

        var cache = loadCache()
        let cutoff = calendar.date(byAdding: .day, value: -configuration.retentionDays, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(-Double(configuration.retentionDays) * 86_400)

        let files = transcriptFiles()
        var bucket = DayBucketer(calendar: calendar)

        for file in files {
            let key = file.url.path
            let previous = cache.files[key]

            // Untouched since the last pass — nothing to read.
            if let previous, previous.size == file.size, previous.modified == file.modified {
                continue
            }
            // Older than anything we still display. Mark it consumed so the
            // next pass skips it without another look.
            if file.modified < cutoff.timeIntervalSince1970, previous == nil {
                cache.files[key] = FileCursor(offset: file.size, size: file.size, modified: file.modified)
                continue
            }

            // A file that shrank was rewritten, not appended to — start over.
            // Dedup makes the re-read idempotent.
            var offset = previous?.offset ?? 0
            if offset > file.size { offset = 0 }

            let consumed = readEntries(at: file.url, from: offset) { entry in
                absorb(entry, into: &cache, bucket: &bucket, cutoff: cutoff)
            }
            cache.files[key] = FileCursor(offset: consumed, size: file.size, modified: file.modified)
        }

        // Forget files that no longer exist so the cache can't grow forever.
        let livePaths = Set(files.map(\.url.path))
        cache.files = cache.files.filter { livePaths.contains($0.key) }

        prune(&cache, cutoff: cutoff, calendar: calendar)
        saveCache(cache)

        return summary(from: cache, calendar: calendar, filesSeen: files.count)
    }

    // MARK: - Absorbing one record

    private func absorb(
        _ entry: TranscriptEntry,
        into cache: inout Cache,
        bucket: inout DayBucketer,
        cutoff: Date
    ) {
        guard let message = entry.message,
              let usage = message.usage,
              let model = message.model,
              // Synthetic turns (local errors, interrupts) never hit the API.
              model != "<synthetic>",
              let stamp = entry.timestamp,
              let date = Self.parseUTCTimestamp(stamp),
              date >= cutoff
        else { return }

        let dayKey = bucket.key(for: date)

        // Replay of a turn we already counted, from a resumed or forked session.
        let hash = Self.fingerprint(messageID: message.id, requestID: entry.requestId)
        if let hash {
            if cache.keys[dayKey]?.contains(hash) == true { return }
            cache.keys[dayKey, default: []].append(hash)
        }

        let counts = TokenCounts(
            input: usage.inputTokens ?? 0,
            output: usage.outputTokens ?? 0,
            cacheCreation: usage.cacheCreationInputTokens ?? 0,
            cacheRead: usage.cacheReadInputTokens ?? 0
        )
        guard !counts.isEmpty else { return }

        var record = cache.days[dayKey] ?? DayRecord(models: [:], messages: 0)
        record.models[model, default: .zero] += counts
        record.messages += 1
        cache.days[dayKey] = record
    }

    // MARK: - Reading

    private struct TranscriptFile {
        let url: URL
        let size: UInt64
        let modified: TimeInterval
    }

    private func transcriptFiles() -> [TranscriptFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: configuration.projectsDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [TranscriptFile] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modified = values.contentModificationDate
            else { continue }
            found.append(TranscriptFile(url: url, size: UInt64(size), modified: modified.timeIntervalSince1970))
        }
        return found
    }

    /// Streams whole lines from `offset` and returns the offset just past the
    /// last complete line. A half-written trailing line (the session that is
    /// running right now) is left for the next pass.
    private func readEntries(
        at url: URL,
        from offset: UInt64,
        handle body: (TranscriptEntry) -> Void
    ) -> UInt64 {
        guard let file = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? file.close() }
        if offset > 0 {
            do { try file.seek(toOffset: offset) } catch { return offset }
        }

        let decoder = JSONDecoder()
        var consumed = offset
        var pending = Data()

        while true {
            let chunk: Data?
            do { chunk = try file.read(upToCount: 1 << 20) } catch { break }
            guard let chunk, !chunk.isEmpty else { break }
            pending.append(chunk)

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                consumed += UInt64(line.count + 1)
                pending = pending[pending.index(after: newline)...]
                // Cheap prefilter: only ~a third of transcript lines are
                // assistant turns, and JSON decoding is the expensive part.
                guard line.count > 2, line.range(of: Self.usageMarker) != nil else { continue }
                guard let entry = try? decoder.decode(TranscriptEntry.self, from: Data(line)) else { continue }
                body(entry)
            }
            pending = Data(pending)
        }
        return consumed
    }

    private static let usageMarker = Data("\"usage\"".utf8)

    // MARK: - Cache

    private struct Cache: Codable {
        var version: Int
        var files: [String: FileCursor]
        var days: [String: DayRecord]
        /// Day key → fingerprints already counted for that day.
        var keys: [String: [UInt64]]

        static let current = 1
        static let empty = Cache(version: Cache.current, files: [:], days: [:], keys: [:])
    }

    private struct FileCursor: Codable, Equatable {
        var offset: UInt64
        var size: UInt64
        var modified: TimeInterval
    }

    private struct DayRecord: Codable {
        var models: [String: TokenCounts]
        var messages: Int
    }

    private func loadCache() -> Cache {
        guard let data = try? Data(contentsOf: configuration.cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == Cache.current
        else { return .empty }
        return cache
    }

    private func saveCache(_ cache: Cache) {
        let directory = configuration.cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: configuration.cacheURL, options: .atomic)
    }

    private func prune(_ cache: inout Cache, cutoff: Date, calendar: Calendar) {
        var bucket = DayBucketer(calendar: calendar)
        let cutoffKey = bucket.key(for: cutoff)
        // Keys are "yyyy-MM-dd", so a lexicographic compare is a date compare.
        cache.days = cache.days.filter { $0.key >= cutoffKey }
        cache.keys = cache.keys.filter { $0.key >= cutoffKey }
    }

    private func summary(from cache: Cache, calendar: Calendar, filesSeen: Int) -> TokenUsageSummary {
        let bucket = DayBucketer(calendar: calendar)
        let days: [DailyTokenUsage] = cache.days.compactMap { key, record in
            guard let day = bucket.date(fromKey: key) else { return nil }
            return DailyTokenUsage(day: day, byModel: record.models, messages: record.messages)
        }
        .sorted { $0.day < $1.day }

        return TokenUsageSummary(days: days, generatedAt: .now, filesSeen: filesSeen)
    }

    // MARK: - Decoding

    private struct TranscriptEntry: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                let inputTokens: Int?
                let outputTokens: Int?
                let cacheCreationInputTokens: Int?
                let cacheReadInputTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case outputTokens = "output_tokens"
                    case cacheCreationInputTokens = "cache_creation_input_tokens"
                    case cacheReadInputTokens = "cache_read_input_tokens"
                }
            }
            let id: String?
            let model: String?
            let usage: Usage?
        }
        let timestamp: String?
        let requestId: String?
        let message: Message?
    }

    /// FNV-1a over "<message id>|<request id>". `Hasher` is seeded per process,
    /// so it can't be used for a fingerprint that has to survive a relaunch.
    static func fingerprint(messageID: String?, requestID: String?) -> UInt64? {
        guard let messageID, !messageID.isEmpty else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01B3
            }
        }
        mix(messageID)
        mix("|")
        mix(requestID ?? "")
        return hash
    }

    /// Parses the fixed-shape UTC stamps Claude Code writes
    /// ("2026-09-01T13:30:33.952Z"). Hand-rolled because `ISO8601DateFormatter`
    /// costs more than the JSON decode it follows.
    static func parseUTCTimestamp(_ raw: String) -> Date? {
        let digits = Array(raw.utf8)
        guard digits.count >= 19 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = digits[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard let year = number(0..<4),
              let month = number(5..<7),
              let day = number(8..<10),
              let hour = number(11..<13),
              let minute = number(14..<16),
              let second = number(17..<19),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        let seconds = Double(daysFromCivil(year: year, month: month, day: day)) * 86_400
            + Double(hour * 3_600 + minute * 60 + second)
        return Date(timeIntervalSince1970: seconds)
    }

    /// Howard Hinnant's days-from-civil: calendar arithmetic without a
    /// `Calendar` round trip.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

/// Maps timestamps to "yyyy-MM-dd" keys in the user's own time zone, caching
/// the current day's bounds. Transcript lines arrive in order, so nearly every
/// lookup is an interval check instead of a calendar computation.
struct DayBucketer {
    private let calendar: Calendar
    private var cachedRange: Range<Date>?
    private var cachedKey: String = ""

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    mutating func key(for date: Date) -> String {
        if let cachedRange, cachedRange.contains(date) { return cachedKey }
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        cachedRange = start..<end
        cachedKey = Self.format(start, calendar: calendar)
        return cachedKey
    }

    func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    private static func format(_ startOfDay: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: startOfDay)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
