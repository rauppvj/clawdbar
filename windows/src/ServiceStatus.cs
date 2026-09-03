using System;
using System.Collections.Generic;

namespace ClawdBar
{
    /// Statuspage's component/indicator vocabulary collapsed into one ladder,
    /// so the UI can colour, sort and pick a worst-case from a single enum.
    /// Declared in severity order: Unknown sits just above Operational, because
    /// a component we cannot read is worth a muted dot but must never outrank a
    /// real outage when the UI picks the worst level on the page.
    internal enum ServiceLevel
    {
        Operational = 0,
        Unknown = 1,
        Maintenance = 2,
        Degraded = 3,
        PartialOutage = 4,
        MajorOutage = 5,
        Critical = 6
    }

    internal static class ServiceLevels
    {
        /// Maps a Statuspage *component* `status` value.
        public static ServiceLevel FromComponent(string raw)
        {
            switch (raw)
            {
                case "operational": return ServiceLevel.Operational;
                case "under_maintenance": return ServiceLevel.Maintenance;
                case "degraded_performance": return ServiceLevel.Degraded;
                case "partial_outage": return ServiceLevel.PartialOutage;
                case "major_outage": return ServiceLevel.MajorOutage;
                default: return ServiceLevel.Unknown;
            }
        }

        /// Maps a Statuspage page-level `indicator` or incident `impact` value.
        public static ServiceLevel FromIndicator(string raw)
        {
            switch (raw)
            {
                case "none": return ServiceLevel.Operational;
                case "maintenance": return ServiceLevel.Maintenance;
                case "minor": return ServiceLevel.Degraded;
                case "major": return ServiceLevel.MajorOutage;
                case "critical": return ServiceLevel.Critical;
                default: return ServiceLevel.Unknown;
            }
        }

        public static bool IsHealthy(ServiceLevel level)
        {
            return level == ServiceLevel.Operational;
        }

        /// Short badge for the retro typeface — 8 characters is all a 200 px
        /// overlay row can spare.
        public static string Badge(ServiceLevel level)
        {
            switch (level)
            {
                case ServiceLevel.Operational: return "OK";
                case ServiceLevel.Maintenance: return "MAINT";
                case ServiceLevel.Degraded: return "DEGRADED";
                case ServiceLevel.PartialOutage: return "PARTIAL";
                case ServiceLevel.MajorOutage: return "OUTAGE";
                case ServiceLevel.Critical: return "DOWN";
                default: return "?";
            }
        }

        /// Lowercase wire-ish name, used by --probe-status output.
        public static string Name(ServiceLevel level)
        {
            switch (level)
            {
                case ServiceLevel.Operational: return "operational";
                case ServiceLevel.Maintenance: return "maintenance";
                case ServiceLevel.Degraded: return "degraded";
                case ServiceLevel.PartialOutage: return "partialOutage";
                case ServiceLevel.MajorOutage: return "majorOutage";
                case ServiceLevel.Critical: return "critical";
                default: return "unknown";
            }
        }

        public static ServiceLevel Worse(ServiceLevel a, ServiceLevel b)
        {
            return (int)a >= (int)b ? a : b;
        }
    }

    internal sealed class ServiceComponent
    {
        public string Id;
        /// Verbatim page name, e.g. "Claude API (api.anthropic.com)".
        public string Name;
        public ServiceLevel Level;

        public ServiceComponent(string id, string name, ServiceLevel level)
        {
            Id = id;
            Name = name;
            Level = level;
        }

        public bool IsHealthy
        {
            get { return ServiceLevels.IsHealthy(Level); }
        }

        /// Compact label for the retro typeface: "Claude API
        /// (api.anthropic.com)" → "API". Statuspage names are written for a web
        /// page; we have 200 px of overlay.
        public string ShortName
        {
            get
            {
                string trimmed = Name == null ? "" : Name;
                int paren = trimmed.IndexOf('(');
                if (paren >= 0) trimmed = trimmed.Substring(0, paren);
                trimmed = trimmed.Trim();

                // Every row on this page is a Claude product — the prefix is noise.
                string[] prefixes = { "Claude ", "Anthropic " };
                for (int i = 0; i < prefixes.Length; i++)
                {
                    if (trimmed.StartsWith(prefixes[i], StringComparison.OrdinalIgnoreCase))
                    {
                        trimmed = trimmed.Substring(prefixes[i].Length);
                    }
                }
                if (trimmed.StartsWith("for ", StringComparison.OrdinalIgnoreCase))
                {
                    trimmed = trimmed.Substring(4);
                }
                return trimmed.Length == 0
                    ? (Name == null ? "" : Name.ToUpperInvariant())
                    : trimmed.ToUpperInvariant();
            }
        }
    }

    internal sealed class ServiceIncident
    {
        public string Id;
        public string Name;
        public ServiceLevel Impact;
        /// Statuspage lifecycle stage: investigating / identified / monitoring.
        public string Stage;
        /// Body of the most recent update, if the payload carried one.
        public string LatestUpdate;
        public DateTime? UpdatedAtUtc;
        /// Statuspage shortlink for this incident.
        public string Url;

        public ServiceIncident()
        {
            Stage = "";
        }
    }

    /// Snapshot of Anthropic's public status page (status.claude.com), decoded
    /// into the shape ClawdBar renders. Mirrors what the website shows: one
    /// overall indicator, a row per component, plus any unresolved incident.
    ///
    /// Why it exists: a red 429/500 in ClawdBar looks identical whether the user
    /// burned through their own limit or Anthropic is having a bad afternoon.
    /// This is the second half of that story.
    internal sealed class ServiceStatus
    {
        /// Page-level indicator, e.g. "All Systems Operational".
        public ServiceLevel Level;
        /// The page's own wording for `Level` — we show it verbatim, like the site.
        public string Summary;
        public List<ServiceComponent> Components;
        /// Unresolved incidents only. Empty on a good day.
        public List<ServiceIncident> Incidents;
        public DateTime FetchedAtUtc;

        /// Where the "open in browser" affordances point.
        public const string PageUrl = "https://status.claude.com";

        public ServiceStatus()
        {
            Level = ServiceLevel.Unknown;
            Summary = "";
            Components = new List<ServiceComponent>();
            Incidents = new List<ServiceIncident>();
        }

        /// Worst of the page indicator and every component — the indicator can
        /// lag a component flip by a minute or two, and the pessimistic read is
        /// the useful one when you're staring at a failing request.
        public ServiceLevel WorstLevel
        {
            get
            {
                ServiceLevel worst = Level;
                for (int i = 0; i < Components.Count; i++)
                {
                    worst = ServiceLevels.Worse(worst, Components[i].Level);
                }
                return worst;
            }
        }

        public bool IsHealthy
        {
            get { return ServiceLevels.IsHealthy(WorstLevel); }
        }

        public List<ServiceComponent> DegradedComponents
        {
            get
            {
                var list = new List<ServiceComponent>();
                for (int i = 0; i < Components.Count; i++)
                {
                    if (!Components[i].IsHealthy) list.Add(Components[i]);
                }
                return list;
            }
        }

        /// Header line. Uses the page's own description when it has one so the
        /// wording matches status.claude.com.
        public string Headline
        {
            get
            {
                string cleaned = Summary == null ? "" : Summary.Trim();
                if (cleaned.Length > 0) return cleaned.ToUpperInvariant();
                return IsHealthy ? "ALL SYSTEMS OPERATIONAL" : ServiceLevels.Badge(WorstLevel);
            }
        }
    }
}
