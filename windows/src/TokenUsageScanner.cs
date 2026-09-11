using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace ClawdBar
{
    /// Maps timestamps to "yyyy-MM-dd" keys in the user's own time zone,
    /// caching the current day's bounds. Transcript lines arrive in order, so
    /// nearly every lookup is an interval check instead of a conversion.
    ///
    /// A class rather than a struct: it carries mutable cache state, and a
    /// struct copied into a helper would silently lose it.
    internal sealed class DayBucketer
    {
        private DateTime _startUtc;
        private DateTime _endUtc;
        private string _key;
        private bool _valid;

        public string Key(DateTime utc)
        {
            if (_valid && utc >= _startUtc && utc < _endUtc) return _key;

            DateTime startLocal = utc.ToLocalTime().Date;
            DateTime endLocal = startLocal.AddDays(1);
            _startUtc = startLocal.ToUniversalTime();
            _endUtc = endLocal.ToUniversalTime();
            _key = Format(startLocal);
            _valid = true;
            return _key;
        }

        public static string Format(DateTime localDay)
        {
            return localDay.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        }

        /// Local midnight for a key, or null when the key is not a date.
        public static DateTime? DateFromKey(string key)
        {
            DateTime parsed;
            if (!DateTime.TryParseExact(key, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                    DateTimeStyles.None, out parsed))
            {
                return null;
            }
            return parsed.Date;
        }
    }

    /// Reads Claude Code's local transcripts (%USERPROFILE%\.claude\projects,
    /// recursively, *.jsonl) and rolls the per-turn message.usage blocks up
    /// into daily token totals.
    ///
    /// Three things make this cheap enough to run every time the panel opens:
    ///
    /// 1. Byte cursors. Transcripts are append-only, so each file is
    ///    remembered by (size, mtime, offset) and only the bytes past the
    ///    offset are read on the next pass. A pass where nothing changed is a
    ///    hundred-odd stat calls.
    /// 2. Retention skip. A file whose mtime predates the retention window
    ///    cannot contain a day we still show, so it is marked consumed unread.
    ///    That keeps the very first scan off the hundreds of megabytes of
    ///    transcripts a heavy user accumulates.
    /// 3. Dedup by (message id, request id). One API response is written as
    ///    several lines - one per content block (thinking, text, tool_use) -
    ///    and every one of them repeats the response's single usage block.
    ///    Resumed and forked sessions then replay those lines into the new
    ///    file. Counting raw lines therefore inflates every number ~2x, so
    ///    fingerprints are kept per day and pruned along with the day.
    ///
    /// Both counts are kept. DayRecord.Models holds the deduplicated one - the
    /// tokens that were really generated - and FileCursor.Raw holds the naive
    /// per-line sum, because that is precisely what the claude.ai usage chart
    /// plots, and the panel shows the two side by side rather than leaving the
    /// user to wonder which of the app and the website is lying.
    internal sealed class TokenUsageScanner
    {
        /// How many days of history to keep. The UI shows 30; the extra
        /// headroom means a month-long view survives a few idle weeks.
        public const int DefaultRetentionDays = 90;

        public readonly string ProjectsDirectory;
        public readonly string CachePath;
        public readonly int RetentionDays;

        public TokenUsageScanner()
            : this(DefaultProjectsDirectory, DefaultCachePath, DefaultRetentionDays)
        {
        }

        public TokenUsageScanner(string projectsDirectory, string cachePath, int retentionDays)
        {
            ProjectsDirectory = projectsDirectory;
            CachePath = cachePath;
            RetentionDays = retentionDays;
        }

        public static string DefaultProjectsDirectory
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    ".claude", "projects");
            }
        }

        public static string DefaultCachePath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    ".clawdbar", "tokens.json");
            }
        }

        // ------------------------------------------------------ entry point

        /// Walks whatever is new since the last call and returns the rolled-up
        /// summary. Does no UI work, so it is safe to run on a worker thread.
        /// Throws TokenScanException when there are no transcripts at all.
        public TokenUsageSummary Scan()
        {
            return Scan(DateTime.UtcNow);
        }

        public TokenUsageSummary Scan(DateTime nowUtc)
        {
            if (!Directory.Exists(ProjectsDirectory))
            {
                throw new TokenScanException("No Claude Code transcripts at " + ProjectsDirectory);
            }

            Cache cache = LoadCache();
            DateTime cutoffUtc = nowUtc.ToLocalTime().Date.AddDays(-RetentionDays).ToUniversalTime();
            double cutoffUnix = Clock.ToUnixSeconds(cutoffUtc);

            List<TranscriptFile> files = TranscriptFiles();
            var bucket = new DayBucketer();

            for (int i = 0; i < files.Count; i++)
            {
                TranscriptFile file = files[i];
                FileCursor previous;
                bool known = cache.Files.TryGetValue(file.Path, out previous);

                // Untouched since the last pass - nothing to read.
                if (known && previous.Size == file.Size && previous.Modified == file.Modified) continue;

                // Older than anything we still display. Mark it consumed so the
                // next pass skips it without another look.
                if (!known && file.Modified < cutoffUnix)
                {
                    var skipped = new FileCursor();
                    skipped.Offset = file.Size;
                    skipped.Size = file.Size;
                    skipped.Modified = file.Modified;
                    cache.Files[file.Path] = skipped;
                    continue;
                }

                // A file that shrank was rewritten, not appended to - start
                // over. Dedup makes the re-read idempotent for the deduplicated
                // totals; the raw tally has no such protection, which is
                // exactly why it is held per file and thrown away with the
                // offset.
                long offset = known ? previous.Offset : 0;
                Dictionary<string, TokenCounts> raw = known
                    ? previous.Raw
                    : new Dictionary<string, TokenCounts>(StringComparer.Ordinal);
                if (offset > file.Size)
                {
                    offset = 0;
                    raw = new Dictionary<string, TokenCounts>(StringComparer.Ordinal);
                }

                Dictionary<string, TokenCounts> rawForFile = raw;
                long consumed = ReadEntries(file.Path, offset, delegate(JsonValue entry)
                {
                    Absorb(entry, cache, rawForFile, bucket, cutoffUtc);
                });

                var cursor = new FileCursor();
                cursor.Offset = consumed;
                cursor.Size = file.Size;
                cursor.Modified = file.Modified;
                cursor.Raw = rawForFile;
                cache.Files[file.Path] = cursor;
            }

            // Forget files that no longer exist so the cache cannot grow
            // forever.
            var live = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < files.Count; i++) live.Add(files[i].Path);
            var dead = new List<string>();
            foreach (var pair in cache.Files)
            {
                if (!live.Contains(pair.Key)) dead.Add(pair.Key);
            }
            for (int i = 0; i < dead.Count; i++) cache.Files.Remove(dead[i]);

            Prune(cache, cutoffUtc);
            SaveCache(cache);

            return Summarize(cache, files.Count);
        }

        // -------------------------------------------------- absorbing a line

        private void Absorb(JsonValue entry, Cache cache, Dictionary<string, TokenCounts> raw,
            DayBucketer bucket, DateTime cutoffUtc)
        {
            JsonValue message = entry["message"];
            if (message == null) return;
            JsonValue usage = message["usage"];
            if (usage == null) return;

            JsonValue modelValue = message["model"];
            if (modelValue == null || modelValue.Type != JsonValue.Kind.String) return;
            string model = modelValue.StringValue;
            // Synthetic turns (local errors, interrupts) never hit the API.
            if (model.Length == 0 || model == "<synthetic>") return;

            JsonValue stamp = entry["timestamp"];
            if (stamp == null || stamp.Type != JsonValue.Kind.String) return;
            DateTime? when = ParseUtcTimestamp(stamp.StringValue);
            if (!when.HasValue || when.Value < cutoffUtc) return;

            var counts = new TokenCounts();
            counts.Input = Number(usage, "input_tokens");
            counts.Output = Number(usage, "output_tokens");
            counts.CacheCreation = Number(usage, "cache_creation_input_tokens");
            counts.CacheRead = Number(usage, "cache_read_input_tokens");
            if (counts.IsEmpty) return;

            string dayKey = bucket.Key(when.Value);

            // Every record counts here, duplicates and replays included: this
            // is the claude.ai-equivalent tally.
            TokenCounts currentRaw;
            raw[dayKey] = raw.TryGetValue(dayKey, out currentRaw) ? currentRaw + counts : counts;

            // Another block of a response we already counted, or a turn
            // replayed into this file by a resumed or forked session.
            JsonValue idValue = message["id"];
            string messageId = idValue != null && idValue.Type == JsonValue.Kind.String ? idValue.StringValue : null;
            JsonValue requestValue = entry["requestId"];
            string requestId = requestValue != null && requestValue.Type == JsonValue.Kind.String
                ? requestValue.StringValue
                : null;

            if (!string.IsNullOrEmpty(messageId))
            {
                long fingerprint = Fingerprint(messageId, requestId);
                HashSet<long> seen;
                if (!cache.Keys.TryGetValue(dayKey, out seen))
                {
                    seen = new HashSet<long>();
                    cache.Keys[dayKey] = seen;
                }
                if (!seen.Add(fingerprint)) return;
            }

            DayRecord record;
            if (!cache.Days.TryGetValue(dayKey, out record))
            {
                record = new DayRecord();
                cache.Days[dayKey] = record;
            }
            TokenCounts current;
            record.Models[model] = record.Models.TryGetValue(model, out current) ? current + counts : counts;
            record.Messages++;
        }

        private static long Number(JsonValue owner, string key)
        {
            JsonValue member = owner[key];
            return member == null ? 0 : (long)member.AsDouble(0);
        }

        // ------------------------------------------------------------ files

        private struct TranscriptFile
        {
            public string Path;
            public long Size;
            public double Modified;
        }

        /// Manual recursion rather than SearchOption.AllDirectories: one
        /// unreadable project folder would otherwise abort the whole walk.
        private List<TranscriptFile> TranscriptFiles()
        {
            var found = new List<TranscriptFile>();
            var pending = new Stack<string>();
            pending.Push(ProjectsDirectory);

            while (pending.Count > 0)
            {
                string directory = pending.Pop();

                string[] children;
                try { children = Directory.GetDirectories(directory); }
                catch { children = new string[0]; }
                for (int i = 0; i < children.Length; i++) pending.Push(children[i]);

                string[] entries;
                try { entries = Directory.GetFiles(directory, "*.jsonl"); }
                catch { continue; }

                for (int i = 0; i < entries.Length; i++)
                {
                    try
                    {
                        var info = new FileInfo(entries[i]);
                        if (!info.Exists) continue;
                        var file = new TranscriptFile();
                        file.Path = info.FullName;
                        file.Size = info.Length;
                        file.Modified = Clock.ToUnixSeconds(info.LastWriteTimeUtc);
                        found.Add(file);
                    }
                    catch
                    {
                    }
                }
            }
            return found;
        }

        private static readonly byte[] UsageMarker = Encoding.ASCII.GetBytes("\"usage\"");

        /// Streams whole lines from `offset` and returns the offset just past
        /// the last complete line. A half-written trailing line (the session
        /// that is running right now) is left for the next pass.
        private long ReadEntries(string path, long offset, Action<JsonValue> body)
        {
            long consumed = offset;
            try
            {
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                           FileShare.ReadWrite | FileShare.Delete, 1 << 16))
                {
                    if (offset > 0)
                    {
                        if (offset > stream.Length) return offset;
                        stream.Seek(offset, SeekOrigin.Begin);
                    }

                    var chunk = new byte[1 << 20];
                    byte[] leftover = new byte[0];

                    while (true)
                    {
                        int read = stream.Read(chunk, 0, chunk.Length);
                        if (read <= 0) break;

                        int start = 0;
                        for (int i = 0; i < read; i++)
                        {
                            if (chunk[i] != (byte)'\n') continue;

                            byte[] line = Join(leftover, chunk, start, i - start);
                            leftover = new byte[0];
                            consumed += line.Length + 1;
                            start = i + 1;
                            HandleLine(line, body);
                        }

                        int tail = read - start;
                        if (tail > 0) leftover = Join(leftover, chunk, start, tail);
                    }
                }
            }
            catch
            {
                // An unreadable transcript is a gap in the chart, never a
                // failed scan: keep whatever the other files produced.
                return consumed;
            }
            return consumed;
        }

        private static byte[] Join(byte[] head, byte[] buffer, int start, int length)
        {
            if (head.Length == 0)
            {
                var only = new byte[length];
                Buffer.BlockCopy(buffer, start, only, 0, length);
                return only;
            }
            var joined = new byte[head.Length + length];
            Buffer.BlockCopy(head, 0, joined, 0, head.Length);
            Buffer.BlockCopy(buffer, start, joined, head.Length, length);
            return joined;
        }

        private static void HandleLine(byte[] line, Action<JsonValue> body)
        {
            // Cheap prefilter: only about a third of transcript lines are
            // assistant turns, and the JSON parse is the expensive part.
            if (line.Length <= 2 || !Contains(line, UsageMarker)) return;

            JsonValue entry;
            try { entry = Json.TryParse(Encoding.UTF8.GetString(line)); }
            catch { return; }
            if (entry == null || entry.Type != JsonValue.Kind.Object) return;
            body(entry);
        }

        private static bool Contains(byte[] haystack, byte[] needle)
        {
            int limit = haystack.Length - needle.Length;
            for (int i = 0; i <= limit; i++)
            {
                int j = 0;
                while (j < needle.Length && haystack[i + j] == needle[j]) j++;
                if (j == needle.Length) return true;
            }
            return false;
        }

        // ------------------------------------------------------------ cache

        private sealed class Cache
        {
            // 2: file cursors carry the per-day raw tally.
            public const int Current = 2;

            public Dictionary<string, FileCursor> Files =
                new Dictionary<string, FileCursor>(StringComparer.OrdinalIgnoreCase);
            public Dictionary<string, DayRecord> Days =
                new Dictionary<string, DayRecord>(StringComparer.Ordinal);
            /// Day key to the fingerprints already counted for that day.
            public Dictionary<string, HashSet<long>> Keys =
                new Dictionary<string, HashSet<long>>(StringComparer.Ordinal);
        }

        private sealed class FileCursor
        {
            public long Offset;
            public long Size;
            public double Modified;
            /// Day key to every usage record this file carries for that day,
            /// duplicates included. Per file rather than per day because a
            /// rewritten file is re-read from byte zero, and an undeduplicated
            /// counter has to be able to drop its old contribution.
            public Dictionary<string, TokenCounts> Raw =
                new Dictionary<string, TokenCounts>(StringComparer.Ordinal);
        }

        private sealed class DayRecord
        {
            public Dictionary<string, TokenCounts> Models =
                new Dictionary<string, TokenCounts>(StringComparer.Ordinal);
            public int Messages;
        }

        private Cache LoadCache()
        {
            var cache = new Cache();
            JsonValue root;
            try
            {
                if (!File.Exists(CachePath)) return cache;
                root = Json.TryParse(File.ReadAllText(CachePath, Encoding.UTF8));
            }
            catch
            {
                return cache;
            }
            if (root == null || root.Type != JsonValue.Kind.Object) return cache;

            JsonValue version = root["version"];
            if (version == null || (int)version.AsDouble(0) != Cache.Current) return cache;

            JsonValue files = root["files"];
            if (files != null && files.Type == JsonValue.Kind.Object)
            {
                foreach (var pair in files.Members)
                {
                    JsonValue value = pair.Value;
                    if (value == null || value.Type != JsonValue.Kind.Object) continue;
                    var cursor = new FileCursor();
                    cursor.Offset = (long)Read(value, "off");
                    cursor.Size = (long)Read(value, "sz");
                    cursor.Modified = Read(value, "mt");
                    cursor.Raw = ReadCounts(value["raw"]);
                    cache.Files[pair.Key] = cursor;
                }
            }

            JsonValue days = root["days"];
            if (days != null && days.Type == JsonValue.Kind.Object)
            {
                foreach (var pair in days.Members)
                {
                    JsonValue value = pair.Value;
                    if (value == null || value.Type != JsonValue.Kind.Object) continue;
                    var record = new DayRecord();
                    record.Models = ReadCounts(value["models"]);
                    record.Messages = (int)Read(value, "messages");
                    cache.Days[pair.Key] = record;
                }
            }

            JsonValue keys = root["keys"];
            if (keys != null && keys.Type == JsonValue.Kind.Object)
            {
                foreach (var pair in keys.Members)
                {
                    JsonValue list = pair.Value;
                    if (list == null || list.Type != JsonValue.Kind.Array) continue;
                    var set = new HashSet<long>();
                    for (int i = 0; i < list.Items.Count; i++)
                    {
                        set.Add((long)list.Items[i].AsDouble(0));
                    }
                    cache.Keys[pair.Key] = set;
                }
            }
            return cache;
        }

        private static double Read(JsonValue owner, string key)
        {
            JsonValue member = owner[key];
            return member == null ? 0 : member.AsDouble(0);
        }

        private static Dictionary<string, TokenCounts> ReadCounts(JsonValue value)
        {
            var map = new Dictionary<string, TokenCounts>(StringComparer.Ordinal);
            if (value == null || value.Type != JsonValue.Kind.Object) return map;
            foreach (var pair in value.Members)
            {
                map[pair.Key] = TokenCounts.FromJson(pair.Value);
            }
            return map;
        }

        private void SaveCache(Cache cache)
        {
            var root = JsonValue.NewObject();
            root["version"] = JsonValue.From(Cache.Current);

            var files = JsonValue.NewObject();
            foreach (var pair in cache.Files)
            {
                var cursor = JsonValue.NewObject();
                cursor["off"] = JsonValue.From(pair.Value.Offset);
                cursor["sz"] = JsonValue.From(pair.Value.Size);
                cursor["mt"] = JsonValue.From(pair.Value.Modified);
                cursor["raw"] = WriteCounts(pair.Value.Raw);
                files[pair.Key] = cursor;
            }
            root["files"] = files;

            var days = JsonValue.NewObject();
            foreach (var pair in cache.Days)
            {
                var record = JsonValue.NewObject();
                record["models"] = WriteCounts(pair.Value.Models);
                record["messages"] = JsonValue.From(pair.Value.Messages);
                days[pair.Key] = record;
            }
            root["days"] = days;

            var keys = JsonValue.NewObject();
            foreach (var pair in cache.Keys)
            {
                var list = JsonValue.NewArray();
                foreach (long fingerprint in pair.Value)
                {
                    list.Items.Add(JsonValue.From(fingerprint));
                }
                keys[pair.Key] = list;
            }
            root["keys"] = keys;

            try
            {
                string directory = Path.GetDirectoryName(CachePath);
                if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory))
                {
                    Directory.CreateDirectory(directory);
                }
                // Write beside the target and move into place, so a crash
                // mid-write leaves the previous cache intact rather than a
                // truncated file the next launch has to throw away.
                string temporary = CachePath + ".tmp";
                File.WriteAllText(temporary, root.ToJson(), new UTF8Encoding(false));
                if (File.Exists(CachePath)) File.Delete(CachePath);
                File.Move(temporary, CachePath);
            }
            catch
            {
                // A cache we cannot write only costs the next scan its
                // incremental head start.
            }
        }

        private static JsonValue WriteCounts(Dictionary<string, TokenCounts> map)
        {
            var obj = JsonValue.NewObject();
            foreach (var pair in map) obj[pair.Key] = pair.Value.ToJson();
            return obj;
        }

        private void Prune(Cache cache, DateTime cutoffUtc)
        {
            // Keys are "yyyy-MM-dd", so a lexicographic compare is a date
            // compare.
            string cutoffKey = DayBucketer.Format(cutoffUtc.ToLocalTime().Date);

            var staleDays = new List<string>();
            foreach (var pair in cache.Days)
            {
                if (string.CompareOrdinal(pair.Key, cutoffKey) < 0) staleDays.Add(pair.Key);
            }
            for (int i = 0; i < staleDays.Count; i++) cache.Days.Remove(staleDays[i]);

            var staleKeys = new List<string>();
            foreach (var pair in cache.Keys)
            {
                if (string.CompareOrdinal(pair.Key, cutoffKey) < 0) staleKeys.Add(pair.Key);
            }
            for (int i = 0; i < staleKeys.Count; i++) cache.Keys.Remove(staleKeys[i]);

            foreach (var pair in cache.Files)
            {
                var drop = new List<string>();
                foreach (var day in pair.Value.Raw)
                {
                    if (string.CompareOrdinal(day.Key, cutoffKey) < 0) drop.Add(day.Key);
                }
                for (int i = 0; i < drop.Count; i++) pair.Value.Raw.Remove(drop[i]);
            }
        }

        private TokenUsageSummary Summarize(Cache cache, int filesSeen)
        {
            var raw = new Dictionary<string, TokenCounts>(StringComparer.Ordinal);
            foreach (var file in cache.Files)
            {
                foreach (var day in file.Value.Raw)
                {
                    TokenCounts current;
                    raw[day.Key] = raw.TryGetValue(day.Key, out current)
                        ? current + day.Value
                        : day.Value;
                }
            }

            var summary = new TokenUsageSummary();
            foreach (var pair in cache.Days)
            {
                DateTime? day = DayBucketer.DateFromKey(pair.Key);
                if (!day.HasValue) continue;

                var entry = new DailyTokenUsage(day.Value);
                entry.ByModel = pair.Value.Models;
                entry.Messages = pair.Value.Messages;
                TokenCounts mirrored;
                if (raw.TryGetValue(pair.Key, out mirrored)) entry.RawTotals = mirrored;
                summary.Days.Add(entry);
            }
            summary.Days.Sort(delegate(DailyTokenUsage a, DailyTokenUsage b)
            {
                return a.Day.CompareTo(b.Day);
            });
            summary.GeneratedAtUtc = DateTime.UtcNow;
            summary.FilesSeen = filesSeen;
            return summary;
        }

        // --------------------------------------------------------- decoding

        /// FNV-1a over "<message id>|<request id>", folded into 53 bits.
        ///
        /// The fold is the one deliberate difference from the macOS build: the
        /// cache goes through this port's own JSON reader, whose numbers are
        /// doubles, and a full 64-bit hash would not survive the round trip.
        /// 53 bits still puts a collision across a day's ~30 k turns at around
        /// one in 20 billion, and the two caches are per-platform anyway.
        public static long Fingerprint(string messageId, string requestId)
        {
            ulong hash = 0xcbf29ce484222325UL;
            hash = Mix(hash, messageId);
            hash = Mix(hash, "|");
            hash = Mix(hash, requestId == null ? "" : requestId);
            return (long)(hash & 0x1FFFFFFFFFFFFFUL);
        }

        private static ulong Mix(ulong hash, string text)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(text);
            for (int i = 0; i < bytes.Length; i++)
            {
                hash ^= bytes[i];
                hash *= 0x100000001B3UL;
            }
            return hash;
        }

        /// Parses the fixed-shape UTC stamps Claude Code writes
        /// ("2026-09-01T13:30:33.952Z"). Hand-rolled because DateTime.Parse
        /// costs more than the JSON decode it follows.
        public static DateTime? ParseUtcTimestamp(string raw)
        {
            if (raw == null || raw.Length < 19) return null;

            int year, month, day, hour, minute, second;
            if (!Digits(raw, 0, 4, out year)) return null;
            if (!Digits(raw, 5, 2, out month)) return null;
            if (!Digits(raw, 8, 2, out day)) return null;
            if (!Digits(raw, 11, 2, out hour)) return null;
            if (!Digits(raw, 14, 2, out minute)) return null;
            if (!Digits(raw, 17, 2, out second)) return null;
            if (month < 1 || month > 12 || day < 1 || day > 31) return null;
            if (hour > 23 || minute > 59 || second > 60) return null;

            try
            {
                return new DateTime(year, month, day, hour, minute, Math.Min(second, 59),
                    DateTimeKind.Utc);
            }
            catch (ArgumentOutOfRangeException)
            {
                // 31 April and friends: a malformed stamp is a dropped record,
                // not a failed scan.
                return null;
            }
        }

        private static bool Digits(string text, int start, int length, out int value)
        {
            value = 0;
            if (start + length > text.Length) return false;
            for (int i = start; i < start + length; i++)
            {
                char c = text[i];
                if (c < '0' || c > '9') return false;
                value = value * 10 + (c - '0');
            }
            return true;
        }
    }

    /// Raised when there is nothing to scan at all - a fresh machine, or a
    /// home directory that moved. Distinct from a transcript we failed to
    /// read, which is silently skipped.
    internal sealed class TokenScanException : Exception
    {
        public TokenScanException(string message) : base(message) { }
    }

    /// Owns the token-spend snapshot shown in the tray panel.
    ///
    /// Unlike UsageDaemon this talks to no network and needs no credentials -
    /// everything comes from transcripts already on disk - so it refreshes
    /// when a surface appears rather than on a timer. The walk itself runs on
    /// a worker thread; only the finished summary crosses back to the UI.
    internal sealed class TokenUsageMonitor
    {
        public TokenUsageSummary Summary;
        public bool IsScanning;
        public string LastError;
        public DateTime? LastScanAtUtc;

        /// True once the first scan has settled, so the UI can tell "nothing
        /// yet" apart from "genuinely zero tokens today".
        public bool HasScanned;

        /// Raised after every state change so the panel can repaint. Always
        /// fires on the thread that started the scan - the UI thread, for
        /// every caller inside the app.
        public event EventHandler Changed;

        private readonly TokenUsageScanner _scanner;
        private Task _inFlight;

        public TokenUsageMonitor() : this(new TokenUsageScanner()) { }

        public TokenUsageMonitor(TokenUsageScanner scanner)
        {
            _scanner = scanner;
            Summary = TokenUsageSummary.Empty();
        }

        public string ProjectsDirectory { get { return _scanner.ProjectsDirectory; } }

        /// Rescan unconditionally. Coalesces with any scan already running
        /// rather than walking the transcripts twice.
        public Task RefreshNowAsync()
        {
            if (_inFlight != null) return _inFlight;
            _inFlight = PerformScanAsync();
            return _inFlight;
        }

        /// Top-up for a surface that just appeared. An unchanged pass is only
        /// a stat per transcript, but opening the panel ten times in a row
        /// still should not do it ten times.
        public Task RefreshIfStaleAsync(double maxAgeSeconds)
        {
            if (HasScanned && LastScanAtUtc.HasValue &&
                (DateTime.UtcNow - LastScanAtUtc.Value).TotalSeconds < maxAgeSeconds)
            {
                return Task.FromResult<object>(null);
            }
            return RefreshNowAsync();
        }

        /// Age of the current snapshot in seconds, for the "upd 2m" caption.
        public double? SnapshotAgeSeconds
        {
            get
            {
                if (!LastScanAtUtc.HasValue) return null;
                return (DateTime.UtcNow - LastScanAtUtc.Value).TotalSeconds;
            }
        }

        private async Task PerformScanAsync()
        {
            IsScanning = true;
            RaiseChanged();
            try
            {
                TokenUsageScanner scanner = _scanner;
                TokenUsageSummary fresh = null;
                string failure = null;

                await Task.Run(delegate
                {
                    try { fresh = scanner.Scan(); }
                    catch (Exception ex) { failure = ex.Message; }
                }).ConfigureAwait(true);

                HasScanned = true;
                LastScanAtUtc = DateTime.UtcNow;
                if (fresh != null)
                {
                    Summary = fresh;
                    LastError = null;
                }
                else
                {
                    // Keep the previous snapshot on screen - a transient read
                    // failure should not blank out yesterday's numbers.
                    LastError = failure;
                }
            }
            finally
            {
                IsScanning = false;
                _inFlight = null;
                RaiseChanged();
            }
        }

        private void RaiseChanged()
        {
            var handler = Changed;
            if (handler != null) handler(this, EventArgs.Empty);
        }
    }
}
