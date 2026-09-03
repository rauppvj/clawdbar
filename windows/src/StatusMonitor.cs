using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Cache;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace ClawdBar
{
    internal enum StatusErrorKind { Network, NonHttpResponse, Server, MalformedPayload }

    internal sealed class StatusException : Exception
    {
        public readonly StatusErrorKind Kind;

        public StatusException(StatusErrorKind kind, string message) : base(message)
        {
            Kind = kind;
        }

        public static StatusException Network(string message)
        {
            return new StatusException(StatusErrorKind.Network, "Network error: " + message);
        }

        public static StatusException NonHttp()
        {
            return new StatusException(StatusErrorKind.NonHttpResponse, "Non-HTTP response from status page");
        }

        public static StatusException Server(int status)
        {
            return new StatusException(StatusErrorKind.Server,
                "Status page returned " + status.ToString(CultureInfo.InvariantCulture));
        }

        public static StatusException Malformed(string message)
        {
            return new StatusException(StatusErrorKind.MalformedPayload, "Unreadable status payload: " + message);
        }
    }

    /// Reads Anthropic's public status page feed. `summary.json` is the same
    /// document the website renders: one GET, no credentials, no request body —
    /// nothing about the user leaves the machine on this call.
    ///
    /// The page is an Atlassian Statuspage instance, so the v2 API shape is
    /// stable and documented: `status`, `components`, `incidents`.
    internal sealed class StatusPageClient
    {
        // status.anthropic.com 301s here — use the canonical host directly.
        public const string DefaultSummaryUrl = "https://status.claude.com/api/v2/summary.json";

        public string SummaryUrl;
        public int TimeoutMilliseconds;

        public StatusPageClient() : this(DefaultSummaryUrl) { }

        public StatusPageClient(string summaryUrl)
        {
            SummaryUrl = string.IsNullOrEmpty(summaryUrl) ? DefaultSummaryUrl : summaryUrl;
            TimeoutMilliseconds = 10000;
        }

        static StatusPageClient()
        {
            // Same reason as AnthropicApiClient: .NET Framework's default can
            // still negotiate TLS 1.0, which the CDN in front of Statuspage
            // rejects.
            try
            {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            }
            catch
            {
            }
        }

        public async Task<ServiceStatus> FetchStatusAsync()
        {
            var request = (HttpWebRequest)WebRequest.Create(SummaryUrl);
            request.Method = "GET";
            request.Accept = "application/json";
            request.UserAgent = "ClawdBar/0.1 (Windows)";
            request.Timeout = TimeoutMilliseconds;
            request.ReadWriteTimeout = TimeoutMilliseconds;
            request.Proxy = WebRequest.DefaultWebProxy;
            request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            // We poll on our own cadence and want the live document each time,
            // not whatever WinINET kept from the previous tick.
            try
            {
                request.CachePolicy = new RequestCachePolicy(RequestCacheLevel.NoCacheNoStore);
            }
            catch
            {
            }

            string body;
            try
            {
                using (var response = (HttpWebResponse)await WithTimeout(request).ConfigureAwait(false))
                {
                    int status = (int)response.StatusCode;
                    if (status < 200 || status >= 300) throw StatusException.Server(status);
                    body = ReadBody(response);
                }
            }
            catch (StatusException)
            {
                throw;
            }
            catch (WebException ex)
            {
                var response = ex.Response as HttpWebResponse;
                if (response == null) throw StatusException.Network(ex.Message);
                using (response)
                {
                    throw StatusException.Server((int)response.StatusCode);
                }
            }
            catch (Exception ex)
            {
                throw StatusException.Network(ex.Message);
            }

            if (body == null) throw StatusException.Malformed("empty body");
            return Snapshot(body, DateTime.UtcNow);
        }

        /// Decodes a `summary.json` body. Split out from the request so the
        /// parsing rules can be exercised without a network round trip.
        public static ServiceStatus Snapshot(string body, DateTime fetchedAtUtc)
        {
            JsonValue root;
            try
            {
                root = Json.Parse(body);
            }
            catch (Exception ex)
            {
                throw StatusException.Malformed(ex.Message);
            }
            if (root == null || root.Type != JsonValue.Kind.Object)
                throw StatusException.Malformed("expected object at root");

            var snapshot = new ServiceStatus();
            snapshot.FetchedAtUtc = fetchedAtUtc;

            JsonValue status = root["status"];
            if (status != null && status.Type == JsonValue.Kind.Object)
            {
                snapshot.Level = ServiceLevels.FromIndicator(Str(status, "indicator"));
                snapshot.Summary = Str(status, "description") ?? "";
            }

            snapshot.Components = ParseComponents(root["components"]);
            snapshot.Incidents = ParseIncidents(root["incidents"]);
            return snapshot;
        }

        private static List<ServiceComponent> ParseComponents(JsonValue array)
        {
            var kept = new List<ServiceComponent>();
            var positions = new List<int>();
            if (array == null || array.Type != JsonValue.Kind.Array) return kept;

            for (int i = 0; i < array.Items.Count; i++)
            {
                JsonValue raw = array.Items[i];
                if (raw == null || raw.Type != JsonValue.Kind.Object) continue;

                // `group: true` rows are containers for other rows, not services.
                JsonValue group = raw["group"];
                if (group != null && group.AsBool(false)) continue;

                ServiceLevel level = ServiceLevels.FromComponent(Str(raw, "status"));

                // The page hides these until they break; we do the same.
                JsonValue hidden = raw["only_show_if_degraded"];
                if (hidden != null && hidden.AsBool(false) && ServiceLevels.IsHealthy(level)) continue;

                string id = Str(raw, "id");
                string name = Str(raw, "name");
                if (string.IsNullOrEmpty(name)) continue;

                JsonValue position = raw["position"];
                positions.Add(position == null ? int.MaxValue : (int)position.AsDouble(int.MaxValue));
                kept.Add(new ServiceComponent(id == null ? name : id, name, level));
            }

            // Insertion sort on the parallel position list: the page ships a
            // handful of rows, and this keeps the sort stable without LINQ.
            for (int i = 1; i < kept.Count; i++)
            {
                int position = positions[i];
                ServiceComponent component = kept[i];
                int j = i - 1;
                while (j >= 0 && positions[j] > position)
                {
                    positions[j + 1] = positions[j];
                    kept[j + 1] = kept[j];
                    j--;
                }
                positions[j + 1] = position;
                kept[j + 1] = component;
            }
            return kept;
        }

        private static List<ServiceIncident> ParseIncidents(JsonValue array)
        {
            var incidents = new List<ServiceIncident>();
            if (array == null || array.Type != JsonValue.Kind.Array) return incidents;

            for (int i = 0; i < array.Items.Count; i++)
            {
                JsonValue raw = array.Items[i];
                if (raw == null || raw.Type != JsonValue.Kind.Object) continue;

                string stage = Str(raw, "status");
                // summary.json ships unresolved incidents only, but a resolved
                // one slipping through would read as a live outage in the UI.
                if (stage == "resolved" || stage == "postmortem") continue;

                var incident = new ServiceIncident();
                incident.Id = Str(raw, "id");
                incident.Name = Str(raw, "name");
                if (string.IsNullOrEmpty(incident.Name)) continue;
                incident.Impact = ServiceLevels.FromIndicator(Str(raw, "impact"));
                incident.Stage = stage == null ? "" : stage;
                incident.Url = Str(raw, "shortlink");

                JsonValue updates = raw["incident_updates"];
                if (updates != null && updates.Type == JsonValue.Kind.Array && updates.Items.Count > 0)
                {
                    incident.LatestUpdate = Str(updates.Items[0], "body");
                }

                incident.UpdatedAtUtc = ParseIso8601(Str(raw, "updated_at") ?? Str(raw, "created_at"));
                incidents.Add(incident);
            }
            return incidents;
        }

        private static string Str(JsonValue owner, string key)
        {
            if (owner == null || owner.Type != JsonValue.Kind.Object) return null;
            JsonValue value = owner[key];
            if (value == null || value.Type != JsonValue.Kind.String) return null;
            return value.StringValue;
        }

        /// Statuspage stamps timestamps with fractional seconds and an offset
        /// ("2026-09-03T13:26:04.201-07:00"); DateTime.TryParse handles both
        /// once we ask it to normalise to UTC.
        public static DateTime? ParseIso8601(string raw)
        {
            if (string.IsNullOrEmpty(raw)) return null;
            DateTime parsed;
            if (DateTime.TryParse(raw, CultureInfo.InvariantCulture,
                    DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out parsed))
            {
                return DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
            }
            return null;
        }

        /// HttpWebRequest.Timeout is ignored by the async path, so we race the
        /// response against a timer and abort the request if the timer wins.
        private async Task<WebResponse> WithTimeout(HttpWebRequest request)
        {
            Task<WebResponse> responseTask = request.GetResponseAsync();
            Task finished = await Task.WhenAny(responseTask, Task.Delay(TimeoutMilliseconds)).ConfigureAwait(false);
            if (finished != responseTask)
            {
                try { request.Abort(); } catch { }
                throw StatusException.Network("timed out after " +
                    (TimeoutMilliseconds / 1000).ToString(CultureInfo.InvariantCulture) + "s");
            }
            return await responseTask.ConfigureAwait(false);
        }

        private static string ReadBody(HttpWebResponse response)
        {
            using (Stream stream = response.GetResponseStream())
            {
                if (stream == null) return null;
                using (var reader = new StreamReader(stream, Encoding.UTF8))
                {
                    return reader.ReadToEnd();
                }
            }
        }
    }

    /// Polls the public Claude status page on its own slow cadence, separate
    /// from the usage daemon: it needs no credentials, costs no tokens, and
    /// answers a different question — "is it me or is it them?".
    ///
    /// Like UsageDaemon it lives on the UI thread, so every surface can read
    /// its fields straight from a paint handler without locking.
    internal sealed class StatusMonitor : IDisposable
    {
        public ServiceStatus Status;
        public string LastError;
        public DateTime? LastFetchAtUtc;
        public bool IsFetching;
        public bool IsPolling;
        public bool IsAsleep;

        /// Floored at 60 s. Incidents move on the order of minutes and the page
        /// is a shared CDN document — hammering it buys nothing.
        public double PollInterval;

        /// Raised after every state change so the popup and overlay repaint.
        public event EventHandler Changed;

        private readonly StatusPageClient _client;
        private CancellationTokenSource _cancellation;
        private PowerModeChangedEventHandler _powerHandler;

        public StatusMonitor() : this(new StatusPageClient()) { }

        public StatusMonitor(StatusPageClient client)
        {
            _client = client;
            PollInterval = 120;
            RegisterSystemObservers();
        }

        public void Start()
        {
            if (_cancellation != null) return;
            _cancellation = new CancellationTokenSource();
            IsPolling = true;
            RunLoop(_cancellation.Token);
        }

        public void Stop()
        {
            if (_cancellation == null) return;
            _cancellation.Cancel();
            _cancellation = null;
            IsPolling = false;
            RaiseChanged();
        }

        public Task RefreshNowAsync()
        {
            return FetchOnceAsync();
        }

        /// Top-up for UI surfaces that just appeared (the tray panel, the
        /// overlay). Skips the request when the snapshot is younger than
        /// `maxAgeSeconds`, so opening the panel ten times in a row still costs
        /// one request.
        public Task RefreshIfStaleAsync(double maxAgeSeconds)
        {
            if (Status != null && LastFetchAtUtc.HasValue &&
                (DateTime.UtcNow - LastFetchAtUtc.Value).TotalSeconds < maxAgeSeconds)
            {
                return Task.FromResult<object>(null);
            }
            return FetchOnceAsync();
        }

        /// Age of the current snapshot in seconds, for the "upd 2m" captions.
        public double? SnapshotAgeSeconds
        {
            get
            {
                if (!LastFetchAtUtc.HasValue) return null;
                return (DateTime.UtcNow - LastFetchAtUtc.Value).TotalSeconds;
            }
        }

        private async void RunLoop(CancellationToken token)
        {
            await FetchOnceAsync().ConfigureAwait(true);

            while (!token.IsCancellationRequested)
            {
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(EffectiveInterval), token).ConfigureAwait(true);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                if (token.IsCancellationRequested) return;
                if (IsAsleep) continue;
                await FetchOnceAsync().ConfigureAwait(true);
            }
        }

        /// Same battery back-off as the usage daemon: on battery and low, poll
        /// five times less often.
        private double EffectiveInterval
        {
            get
            {
                double baseInterval = Math.Max(60, PollInterval);
                try
                {
                    var power = System.Windows.Forms.SystemInformation.PowerStatus;
                    bool onBattery = power.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Offline;
                    bool saving = (power.BatteryChargeStatus & System.Windows.Forms.BatteryChargeStatus.Low) != 0;
                    if (onBattery && saving) return baseInterval * 5;
                }
                catch
                {
                }
                return baseInterval;
            }
        }

        private async Task FetchOnceAsync()
        {
            IsFetching = true;
            RaiseChanged();
            try
            {
                ServiceStatus fresh = await _client.FetchStatusAsync().ConfigureAwait(true);
                Status = fresh;
                LastError = null;
                LastFetchAtUtc = fresh.FetchedAtUtc;
            }
            catch (Exception ex)
            {
                // Keep the previous snapshot on screen — a stale "all good" plus
                // a STALE tag beats blanking the section on one flaky request.
                LastError = ex.Message;
            }
            finally
            {
                IsFetching = false;
                RaiseChanged();
            }
        }

        private void RaiseChanged()
        {
            var handler = Changed;
            if (handler != null) handler(this, EventArgs.Empty);
        }

        private void RegisterSystemObservers()
        {
            _powerHandler = new PowerModeChangedEventHandler(OnPowerModeChanged);
            try
            {
                SystemEvents.PowerModeChanged += _powerHandler;
            }
            catch
            {
            }
        }

        private async void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
        {
            if (e.Mode == PowerModes.Suspend)
            {
                IsAsleep = true;
            }
            else if (e.Mode == PowerModes.Resume)
            {
                IsAsleep = false;
                if (_cancellation != null) await FetchOnceAsync().ConfigureAwait(true);
            }
        }

        public void Dispose()
        {
            Stop();
            if (_powerHandler != null)
            {
                try { SystemEvents.PowerModeChanged -= _powerHandler; } catch { }
                _powerHandler = null;
            }
        }
    }
}
