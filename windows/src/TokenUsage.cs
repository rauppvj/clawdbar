using System;
using System.Collections.Generic;
using System.Globalization;

namespace ClawdBar
{
    /// The four token counters Claude Code records for every assistant turn.
    /// A value type so days, models and ranges can be summed with `+`.
    internal struct TokenCounts
    {
        public long Input;
        public long Output;
        public long CacheCreation;
        public long CacheRead;

        /// Everything the request moved, cache reads included - the number
        /// ccusage headlines. Not what claude.ai plots: its chart is Uncached,
        /// and cache reads are 97-99% of the volume on agentic work.
        public long Total { get { return Input + Output + CacheCreation + CacheRead; } }

        /// Tokens that had to be produced or ingested fresh - cache writes
        /// included, since a cache write is new context the model still had to
        /// read. The "real work" figure the probe CLI prints.
        public long Fresh { get { return Input + Output + CacheCreation; } }

        /// Input + output: the two counters that never touched the prompt
        /// cache, and the only two the claude.ai usage chart plots. This is the
        /// headline because it is the number the user can check against
        /// claude.ai - see DailyTokenUsage.RawTotals for the other half of
        /// making those two agree.
        public long Uncached { get { return Input + Output; } }

        public bool IsEmpty { get { return Total == 0; } }

        public static readonly TokenCounts Zero = new TokenCounts();

        public static TokenCounts operator +(TokenCounts a, TokenCounts b)
        {
            var sum = new TokenCounts();
            sum.Input = a.Input + b.Input;
            sum.Output = a.Output + b.Output;
            sum.CacheCreation = a.CacheCreation + b.CacheCreation;
            sum.CacheRead = a.CacheRead + b.CacheRead;
            return sum;
        }

        // Short keys - this is written once per model per day into the on-disk
        // cache, so the shape stays terse. Same spelling as the macOS build.
        public JsonValue ToJson()
        {
            var obj = JsonValue.NewObject();
            obj["i"] = JsonValue.From(Input);
            obj["o"] = JsonValue.From(Output);
            obj["cw"] = JsonValue.From(CacheCreation);
            obj["cr"] = JsonValue.From(CacheRead);
            return obj;
        }

        public static TokenCounts FromJson(JsonValue value)
        {
            var counts = new TokenCounts();
            if (value == null || value.Type != JsonValue.Kind.Object) return counts;
            counts.Input = Field(value, "i");
            counts.Output = Field(value, "o");
            counts.CacheCreation = Field(value, "cw");
            counts.CacheRead = Field(value, "cr");
            return counts;
        }

        private static long Field(JsonValue owner, string key)
        {
            JsonValue member = owner[key];
            return member == null ? 0 : (long)member.AsDouble(0);
        }
    }

    /// One local calendar day of token spend, split by model.
    internal sealed class DailyTokenUsage
    {
        /// Local midnight of the day this row covers.
        public DateTime Day;
        public Dictionary<string, TokenCounts> ByModel;
        public int Messages;

        /// The same day summed over every transcript *record* rather than every
        /// API call - the duplicates TokenUsageScanner drops, left back in.
        ///
        /// Claude Code writes one JSONL line per content block of a response
        /// (thinking, text, tool_use), and every one of those lines repeats the
        /// response's single usage block. The claude.ai usage chart adds them
        /// all up, and its per-model figures match this sum to the token. So
        /// Totals is what was actually generated and this is what the website
        /// will say - the readout shows both rather than picking a side.
        ///
        /// Held per transcript file rather than accumulated per day, so it can
        /// be dropped when a file is re-read from byte zero. The cost is that a
        /// day whose transcripts Claude Code has since deleted keeps its
        /// deduplicated totals but loses this one; every reader therefore
        /// treats a value at or below Totals as "not known" and shows nothing.
        public TokenCounts RawTotals;

        public DailyTokenUsage(DateTime day)
        {
            Day = day;
            ByModel = new Dictionary<string, TokenCounts>(StringComparer.Ordinal);
            Messages = 0;
            RawTotals = TokenCounts.Zero;
        }

        public TokenCounts Totals
        {
            get
            {
                var sum = TokenCounts.Zero;
                foreach (TokenCounts counts in ByModel.Values) sum = sum + counts;
                return sum;
            }
        }

        public static DailyTokenUsage Empty(DateTime day)
        {
            return new DailyTokenUsage(day);
        }
    }

    /// One model's slice of a range, for the probe's per-model breakdown.
    internal sealed class ModelSpend
    {
        public string Model;
        public TokenCounts Counts;

        public string DisplayName { get { return TokenUsageFormat.ModelName(Model); } }
    }

    /// Everything the panel needs about local token spend: a day-indexed
    /// series plus the derived slices the UI shows.
    internal sealed class TokenUsageSummary
    {
        /// Ascending by day. Only days that actually had traffic are present -
        /// Window() fills the gaps for charting.
        public List<DailyTokenUsage> Days;
        public DateTime GeneratedAtUtc;

        /// Transcript files the last scan walked. Zero means Claude Code has
        /// never written a transcript here (fresh machine, or a moved home).
        public int FilesSeen;

        public TokenUsageSummary()
        {
            Days = new List<DailyTokenUsage>();
            GeneratedAtUtc = DateTime.MinValue;
            FilesSeen = 0;
        }

        public static TokenUsageSummary Empty()
        {
            return new TokenUsageSummary();
        }

        public bool IsEmpty
        {
            get
            {
                for (int i = 0; i < Days.Count; i++)
                {
                    if (!Days[i].Totals.IsEmpty) return false;
                }
                return true;
            }
        }

        /// The last `count` days ending today, gap-filled with zeroed days so
        /// the bar chart keeps a stable width and idle days read as idle.
        public List<DailyTokenUsage> Window(int count)
        {
            return Window(count, DateTime.Now);
        }

        public List<DailyTokenUsage> Window(int count, DateTime now)
        {
            var indexed = new Dictionary<DateTime, DailyTokenUsage>();
            for (int i = 0; i < Days.Count; i++)
            {
                DailyTokenUsage day = Days[i];
                DateTime key = day.Day.Date;
                DailyTokenUsage existing;
                if (!indexed.TryGetValue(key, out existing))
                {
                    indexed[key] = day;
                    continue;
                }
                indexed[key] = Merge(key, existing, day);
            }

            DateTime today = now.Date;
            var series = new List<DailyTokenUsage>();
            for (int offset = count - 1; offset >= 0; offset--)
            {
                DateTime day = today.AddDays(-offset);
                DailyTokenUsage found;
                series.Add(indexed.TryGetValue(day, out found) ? found : DailyTokenUsage.Empty(day));
            }
            return series;
        }

        /// Two rows for one day: merge rather than letting one of them win.
        private static DailyTokenUsage Merge(DateTime day, DailyTokenUsage a, DailyTokenUsage b)
        {
            var merged = new DailyTokenUsage(day);
            foreach (var pair in a.ByModel) merged.ByModel[pair.Key] = pair.Value;
            foreach (var pair in b.ByModel)
            {
                TokenCounts current;
                merged.ByModel[pair.Key] = merged.ByModel.TryGetValue(pair.Key, out current)
                    ? current + pair.Value
                    : pair.Value;
            }
            merged.Messages = a.Messages + b.Messages;
            merged.RawTotals = a.RawTotals + b.RawTotals;
            return merged;
        }

        /// Totals across the last `count` days, today included.
        public TokenCounts Total(int lastDays)
        {
            var sum = TokenCounts.Zero;
            List<DailyTokenUsage> series = Window(lastDays);
            for (int i = 0; i < series.Count; i++) sum = sum + series[i].Totals;
            return sum;
        }

        /// The same window as Total(), counted the way claude.ai counts it.
        /// See DailyTokenUsage.RawTotals.
        public TokenCounts RawTotal(int lastDays)
        {
            var sum = TokenCounts.Zero;
            List<DailyTokenUsage> series = Window(lastDays);
            for (int i = 0; i < series.Count; i++) sum = sum + series[i].RawTotals;
            return sum;
        }

        public int MessageCount(int lastDays)
        {
            int total = 0;
            List<DailyTokenUsage> series = Window(lastDays);
            for (int i = 0; i < series.Count; i++) total += series[i].Messages;
            return total;
        }

        /// Per-model spend over the last `count` days, biggest first.
        public List<ModelSpend> ModelBreakdown(int lastDays)
        {
            var merged = new Dictionary<string, TokenCounts>(StringComparer.Ordinal);
            List<DailyTokenUsage> series = Window(lastDays);
            for (int i = 0; i < series.Count; i++)
            {
                foreach (var pair in series[i].ByModel)
                {
                    TokenCounts current;
                    merged[pair.Key] = merged.TryGetValue(pair.Key, out current)
                        ? current + pair.Value
                        : pair.Value;
                }
            }

            var list = new List<ModelSpend>();
            foreach (var pair in merged)
            {
                if (pair.Value.IsEmpty) continue;
                var spend = new ModelSpend();
                spend.Model = pair.Key;
                spend.Counts = pair.Value;
                list.Add(spend);
            }
            // Insertion sort, matching the rest of the port: the list is a
            // handful of models and this keeps LINQ out of the build.
            for (int i = 1; i < list.Count; i++)
            {
                ModelSpend item = list[i];
                int j = i - 1;
                while (j >= 0 && list[j].Counts.Total < item.Counts.Total)
                {
                    list[j + 1] = list[j];
                    j--;
                }
                list[j + 1] = item;
            }
            return list;
        }
    }

    /// Presentation helpers shared by the tray panel and the CLI probe.
    internal static class TokenUsageFormat
    {
        /// Compact token count: 812, 12.4K, 3.1M, 1.24B. Panel-sized strings -
        /// full precision belongs in the readout line, not on a bar.
        public static string Compact(long value)
        {
            double magnitude = Math.Abs((double)value);
            if (magnitude < 1000) return value.ToString(CultureInfo.InvariantCulture);
            if (magnitude < 1000000) return Trim(value / 1000.0, "K");
            if (magnitude < 1000000000) return Trim(value / 1000000.0, "M");
            return Trim(value / 1000000000.0, "B");
        }

        /// Grouped full number for the probe output ("1,204,553").
        public static string Exact(long value)
        {
            return value.ToString("#,0", CultureInfo.InvariantCulture);
        }

        private static string Trim(double scaled, string suffix)
        {
            // One decimal below 10, none above - keeps every label short
            // enough that 30 of them still fit across a 340 px panel.
            string format = Math.Abs(scaled) < 10 ? "0.0" : "0";
            return scaled.ToString(format, CultureInfo.InvariantCulture) + suffix;
        }

        /// "claude-opus-4-8" becomes "Opus 4.8", "claude-3-5-sonnet-20241022"
        /// becomes "Sonnet 3.5". Anything that does not fit the family/version
        /// shape is returned as-is: a new model name should show up verbatim
        /// rather than vanish.
        public static string ModelName(string raw)
        {
            if (string.IsNullOrEmpty(raw)) return raw;
            var parts = new List<string>(raw.Split('-'));
            if (parts.Count > 0 && parts[0] == "claude") parts.RemoveAt(0);

            // Drop the trailing release date ("20241022") that older ids carry.
            if (parts.Count > 0 && parts[parts.Count - 1].Length == 8 && AllDigits(parts[parts.Count - 1]))
            {
                parts.RemoveAt(parts.Count - 1);
            }

            int familyIndex = -1;
            for (int i = 0; i < parts.Count; i++)
            {
                if (HasLetter(parts[i])) { familyIndex = i; break; }
            }
            if (familyIndex < 0) return raw;

            string family = parts[familyIndex];
            var version = new List<string>();
            for (int i = 0; i < parts.Count; i++)
            {
                if (i != familyIndex) version.Add(parts[i]);
            }

            string name = family.Substring(0, 1).ToUpperInvariant() + family.Substring(1);
            return version.Count == 0 ? name : name + " " + string.Join(".", version.ToArray());
        }

        private static bool AllDigits(string text)
        {
            if (text.Length == 0) return false;
            for (int i = 0; i < text.Length; i++)
            {
                if (!char.IsDigit(text[i])) return false;
            }
            return true;
        }

        private static bool HasLetter(string text)
        {
            for (int i = 0; i < text.Length; i++)
            {
                if (char.IsLetter(text[i])) return true;
            }
            return false;
        }

        /// Single-letter weekday under a bar in the 7-day chart.
        public static string AxisLabel(DateTime day, bool compactRange)
        {
            if (compactRange) return day.Day.ToString(CultureInfo.InvariantCulture);
            string[] symbols = DateTimeFormatInfo.CurrentInfo.ShortestDayNames;
            int index = (int)day.DayOfWeek;
            if (index < 0 || index >= symbols.Length) return "";
            return symbols[index].ToUpperInvariant();
        }

        /// "AUG 7" for the endpoints of the 30-day axis. Kept in English like
        /// the rest of the panel chrome ("TODAY", "AVG", "TURNS").
        public static string MonthDay(DateTime day)
        {
            return day.ToString("MMM d", CultureInfo.InvariantCulture).ToUpperInvariant();
        }
    }
}
