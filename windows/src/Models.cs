using System;
using System.Collections.Generic;
using System.Globalization;

namespace ClawdBar
{
    internal enum Severity { Ok, Warning, Danger, Critical }

    /// Verb bands shown in the popover / overlay, mirroring Claude Code's own
    /// rotating "Cogitating / Pondering / Brewing..." status text.
    internal enum Mood { Idle, Musing, Focused, Cooking, Sweating, Melting, Toast }

    /// Four-band visual mode for the mascot, derived from current usage.
    internal enum MascotState { Sleep, Chill, Work, Panic }

    internal static class Moods
    {
        public static Mood FromPercent(double? percent)
        {
            if (!percent.HasValue) return Mood.Idle;
            double p = percent.Value;
            if (p < 10) return Mood.Idle;
            if (p < 30) return Mood.Musing;
            if (p < 55) return Mood.Focused;
            if (p < 75) return Mood.Cooking;
            if (p < 88) return Mood.Sweating;
            if (p < 97) return Mood.Melting;
            return Mood.Toast;
        }

        private static readonly Dictionary<Mood, string[]> Variants = BuildVariants();

        private static Dictionary<Mood, string[]> BuildVariants()
        {
            var d = new Dictionary<Mood, string[]>();
            d[Mood.Idle] = new string[] { "Idle", "Resting", "Yawning", "Lounging" };
            d[Mood.Musing] = new string[] { "Musing", "Pondering", "Mulling", "Reflecting" };
            d[Mood.Focused] = new string[] { "Focused", "Cogitating", "Computing", "Thinking", "Crafting" };
            d[Mood.Cooking] = new string[] { "Cooking", "Brewing", "Iterating", "Forging", "Percolating" };
            d[Mood.Sweating] = new string[] { "Sweating", "Grinding", "Stewing", "Chugging", "Smelting" };
            d[Mood.Melting] = new string[] { "Melting", "Frying", "Boiling", "Frazzling", "Singeing" };
            d[Mood.Toast] = new string[] { "Toast", "Cooked", "Maxed", "Crispy", "Burnt" };
            return d;
        }

        /// Picks one variant from a shared 10-second time slot, so the popover
        /// and the overlay always show the same word.
        public static string Label(Mood mood, DateTime nowUtc)
        {
            var variants = Variants[mood];
            long slot = (long)(Clock.ToUnixSeconds(nowUtc) / 10);
            int index = (int)(((slot % variants.Length) + variants.Length) % variants.Length);
            return variants[index];
        }

        public static MascotState StateFromPercent(double? percent)
        {
            if (!percent.HasValue) return MascotState.Sleep;
            double p = percent.Value;
            if (p < 25) return MascotState.Sleep;
            if (p < 60) return MascotState.Chill;
            if (p < 80) return MascotState.Work;
            return MascotState.Panic;
        }
    }

    internal static class Clock
    {
        private static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        public static double ToUnixSeconds(DateTime utc)
        {
            return (utc - Epoch).TotalSeconds;
        }

        public static DateTime FromUnixSeconds(double seconds)
        {
            return Epoch.AddSeconds(seconds);
        }

        /// Monotonic-ish seconds used to drive animations. Wall clock is fine
        /// here — the animations are periodic, so a clock jump just shifts phase.
        public static double AnimationSeconds()
        {
            return Environment.TickCount / 1000.0;
        }
    }

    internal sealed class UsageData
    {
        public double? SessionPercent;
        public DateTime? SessionResetAt;
        public double? WeeklyPercent;
        public DateTime? WeeklyResetAt;
        public DateTime LastUpdatedUtc;
        public bool IsStale;
        public Dictionary<string, string> RawHeaders;

        public UsageData()
        {
            LastUpdatedUtc = DateTime.MinValue;
            IsStale = true;
            RawHeaders = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        }

        public static UsageData Empty()
        {
            return new UsageData();
        }

        public bool HasEverUpdated
        {
            get { return LastUpdatedUtc != DateTime.MinValue; }
        }

        public static Severity SeverityFor(double? percent)
        {
            if (!percent.HasValue) return Severity.Ok;
            double p = percent.Value;
            if (p < 50) return Severity.Ok;
            if (p < 80) return Severity.Warning;
            if (p < 95) return Severity.Danger;
            return Severity.Critical;
        }

        public Severity SessionSeverity { get { return SeverityFor(SessionPercent); } }
        public Severity WeeklySeverity { get { return SeverityFor(WeeklyPercent); } }

        public Severity WorstSeverity
        {
            get
            {
                return (int)SessionSeverity >= (int)WeeklySeverity ? SessionSeverity : WeeklySeverity;
            }
        }

        public int? DisplaySessionPercent
        {
            get { return SessionPercent.HasValue ? (int?)Math.Round(SessionPercent.Value) : null; }
        }

        public int? DisplayWeeklyPercent
        {
            get { return WeeklyPercent.HasValue ? (int?)Math.Round(WeeklyPercent.Value) : null; }
        }

        /// Mood is driven by the higher of session vs weekly utilization, since
        /// hitting either limit is what actually matters.
        public Mood Mood
        {
            get
            {
                double s = SessionPercent.HasValue ? SessionPercent.Value : 0;
                double w = WeeklyPercent.HasValue ? WeeklyPercent.Value : 0;
                return Moods.FromPercent(Math.Max(s, w));
            }
        }

        public MascotState MascotState
        {
            get
            {
                double s = SessionPercent.HasValue ? SessionPercent.Value : 0;
                double w = WeeklyPercent.HasValue ? WeeklyPercent.Value : 0;
                return Moods.StateFromPercent(Math.Max(s, w));
            }
        }

        public UsageData Clone()
        {
            var copy = new UsageData();
            copy.SessionPercent = SessionPercent;
            copy.SessionResetAt = SessionResetAt;
            copy.WeeklyPercent = WeeklyPercent;
            copy.WeeklyResetAt = WeeklyResetAt;
            copy.LastUpdatedUtc = LastUpdatedUtc;
            copy.IsStale = IsStale;
            copy.RawHeaders = new Dictionary<string, string>(RawHeaders, StringComparer.OrdinalIgnoreCase);
            return copy;
        }
    }

    internal sealed class Credentials
    {
        public string AccessToken;
        public string RefreshToken;
        public DateTime? ExpiresAtUtc;
        public List<string> Scopes;
        public string SubscriptionType;
        public string RateLimitTier;
        public string SourceDescription;

        public Credentials()
        {
            Scopes = new List<string>();
        }

        public bool IsExpired
        {
            get { return ExpiresAtUtc.HasValue && DateTime.UtcNow >= ExpiresAtUtc.Value; }
        }

        /// Re-read the token when it is within 5 minutes of expiry, so the next
        /// request gets a fresh one instead of a 401.
        public bool ExpiresSoon
        {
            get { return ExpiresAtUtc.HasValue && (ExpiresAtUtc.Value - DateTime.UtcNow).TotalSeconds < 300; }
        }
    }

    /// One observation of usage at a point in time. Persisted as JSON Lines at
    /// %USERPROFILE%\.clawdbar\history.jsonl — byte-compatible with the macOS
    /// build's file, so a history copied from a Mac keeps working.
    internal sealed class UsageSample
    {
        public DateTime TimestampUtc;
        public double? SessionPercent;
        public double? WeeklyPercent;

        public string ToJsonLine()
        {
            var obj = JsonValue.NewObject();
            obj["t"] = JsonValue.From(Math.Floor(Clock.ToUnixSeconds(TimestampUtc)));
            obj["s"] = SessionPercent.HasValue ? JsonValue.From(SessionPercent.Value) : new JsonValue();
            obj["w"] = WeeklyPercent.HasValue ? JsonValue.From(WeeklyPercent.Value) : new JsonValue();
            return obj.ToJson();
        }

        public static UsageSample FromJsonLine(string line)
        {
            var root = Json.TryParse(line);
            if (root == null || root.Type != JsonValue.Kind.Object) return null;
            var t = root["t"];
            if (t == null || t.Type != JsonValue.Kind.Number) return null;

            var sample = new UsageSample();
            sample.TimestampUtc = Clock.FromUnixSeconds(t.NumberValue);
            var s = root["s"];
            if (s != null && s.Type == JsonValue.Kind.Number) sample.SessionPercent = s.NumberValue;
            var w = root["w"];
            if (w != null && w.Type == JsonValue.Kind.Number) sample.WeeklyPercent = w.NumberValue;
            return sample;
        }
    }

    internal sealed class DailyActivity
    {
        public DateTime Day;
        public double PeakPercent;

        public DailyActivity(DateTime day, double peakPercent)
        {
            Day = day;
            PeakPercent = peakPercent;
        }

        /// 0-4 intensity bucket, GitHub-heatmap style. -1 marks padding cells
        /// for days before tracking started.
        public int Level
        {
            get
            {
                if (PeakPercent < 0) return -1;
                if (PeakPercent == 0) return 0;
                if (PeakPercent < 25) return 1;
                if (PeakPercent < 50) return 2;
                if (PeakPercent < 75) return 3;
                return 4;
            }
        }
    }

    /// Derived metrics computed from the history store. Pure: Compute() takes
    /// samples and produces a snapshot.
    internal sealed class UsageStats
    {
        public DateTime? FirstSeen;
        public DateTime? LastSeen;
        public int TotalSamples;
        public int DaysTracked;
        public int CurrentStreak;
        public int LongestStreak;
        public int? PeakHour;
        public List<DailyActivity> ActivityByDay;

        public UsageStats()
        {
            ActivityByDay = new List<DailyActivity>();
        }

        /// Anything before 2024-01-01 is clearly bogus — ClawdBar did not exist
        /// then, and a stale DateTime.MinValue would blow the "since" math up.
        public static readonly DateTime MinValidTimestamp = new DateTime(2024, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        public static UsageStats Compute(List<UsageSample> input, int windowDays, DateTime nowUtc)
        {
            var stats = new UsageStats();
            var samples = new List<UsageSample>();
            for (int i = 0; i < input.Count; i++)
            {
                if (input[i].TimestampUtc >= MinValidTimestamp) samples.Add(input[i]);
            }

            DateTime todayLocal = nowUtc.ToLocalTime().Date;
            if (samples.Count == 0)
            {
                for (int offset = windowDays - 1; offset >= 0; offset--)
                {
                    stats.ActivityByDay.Add(new DailyActivity(todayLocal.AddDays(-offset), 0));
                }
                return stats;
            }

            // Bucket by local calendar day -> peak session %, and by hour for
            // the "peak hour" stat.
            var peakByDay = new Dictionary<DateTime, double>();
            var hourSum = new Dictionary<int, double>();
            var hourCount = new Dictionary<int, int>();
            DateTime min = DateTime.MaxValue;
            DateTime max = DateTime.MinValue;

            for (int i = 0; i < samples.Count; i++)
            {
                var sample = samples[i];
                DateTime local = sample.TimestampUtc.ToLocalTime();
                DateTime day = local.Date;
                double s = sample.SessionPercent.HasValue ? sample.SessionPercent.Value : 0;

                double existing;
                if (!peakByDay.TryGetValue(day, out existing) || existing < s) peakByDay[day] = s;

                int hour = local.Hour;
                double sum;
                hourSum[hour] = hourSum.TryGetValue(hour, out sum) ? sum + s : s;
                int count;
                hourCount[hour] = hourCount.TryGetValue(hour, out count) ? count + 1 : 1;

                if (sample.TimestampUtc < min) min = sample.TimestampUtc;
                if (sample.TimestampUtc > max) max = sample.TimestampUtc;
            }

            for (int offset = windowDays - 1; offset >= 0; offset--)
            {
                DateTime day = todayLocal.AddDays(-offset);
                double peak;
                if (!peakByDay.TryGetValue(day, out peak)) peak = 0;
                stats.ActivityByDay.Add(new DailyActivity(day, peak));
            }

            var activeDays = new List<DateTime>(peakByDay.Keys);
            activeDays.Sort();

            stats.FirstSeen = min;
            stats.LastSeen = max;
            stats.TotalSamples = samples.Count;
            stats.DaysTracked = activeDays.Count;
            stats.LongestStreak = LongestRun(activeDays);
            stats.CurrentStreak = CurrentRun(peakByDay, todayLocal);
            stats.PeakHour = BestHour(hourSum, hourCount);
            return stats;
        }

        private static int LongestRun(List<DateTime> sortedDays)
        {
            if (sortedDays.Count == 0) return 0;
            int longest = 1;
            int current = 1;
            for (int i = 1; i < sortedDays.Count; i++)
            {
                if (sortedDays[i - 1].AddDays(1) == sortedDays[i])
                {
                    current++;
                    if (current > longest) longest = current;
                }
                else
                {
                    current = 1;
                }
            }
            return longest;
        }

        private static int CurrentRun(Dictionary<DateTime, double> activeDays, DateTime today)
        {
            int streak = 0;
            DateTime cursor = today;
            while (activeDays.ContainsKey(cursor))
            {
                streak++;
                cursor = cursor.AddDays(-1);
            }
            return streak;
        }

        private static int? BestHour(Dictionary<int, double> sums, Dictionary<int, int> counts)
        {
            int? best = null;
            double bestAvg = double.MinValue;
            foreach (var kv in sums)
            {
                int count;
                if (!counts.TryGetValue(kv.Key, out count) || count == 0) continue;
                double avg = kv.Value / count;
                if (avg > bestAvg)
                {
                    bestAvg = avg;
                    best = kv.Key;
                }
            }
            return best;
        }
    }
}
