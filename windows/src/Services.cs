using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ClawdBar
{
    // ---------------------------------------------------------------- errors

    internal enum ApiErrorKind { Unauthorized, RateLimited, Server, Network, NonHttpResponse }

    internal sealed class ApiException : Exception
    {
        public readonly ApiErrorKind Kind;
        public readonly int StatusCode;
        public readonly double? RetryAfterSeconds;

        public ApiException(ApiErrorKind kind, string message, int statusCode, double? retryAfter)
            : base(message)
        {
            Kind = kind;
            StatusCode = statusCode;
            RetryAfterSeconds = retryAfter;
        }

        public static ApiException Unauthorized()
        {
            return new ApiException(ApiErrorKind.Unauthorized,
                "401 Unauthorized - Claude Code session expired. Run `claude /login` to re-authenticate.",
                401, null);
        }

        public static ApiException RateLimited(double? retryAfter)
        {
            string message = retryAfter.HasValue
                ? "429 Rate limited - retry after " + ((int)retryAfter.Value).ToString(CultureInfo.InvariantCulture) + "s"
                : "429 Rate limited";
            return new ApiException(ApiErrorKind.RateLimited, message, 429, retryAfter);
        }

        public static ApiException Server(int status, string body)
        {
            string suffix = string.IsNullOrEmpty(body) ? "<no body>" : Truncate(body, 300);
            return new ApiException(ApiErrorKind.Server,
                "Server error " + status.ToString(CultureInfo.InvariantCulture) + ": " + suffix, status, null);
        }

        public static ApiException Network(string message)
        {
            return new ApiException(ApiErrorKind.Network, "Network error: " + message, 0, null);
        }

        private static string Truncate(string s, int max)
        {
            return s.Length <= max ? s : s.Substring(0, max) + "...";
        }
    }

    internal enum CredentialErrorKind { NotFound, AccessDenied, Malformed, FileError }

    internal sealed class CredentialException : Exception
    {
        public readonly CredentialErrorKind Kind;

        public CredentialException(CredentialErrorKind kind, string message) : base(message)
        {
            Kind = kind;
        }
    }

    // ----------------------------------------------------------- credentials

    /// Windows equivalent of the macOS Keychain reader. Claude Code on Windows
    /// writes its OAuth token to %USERPROFILE%\.claude\.credentials.json, so
    /// that file is the primary source; Windows Credential Manager is checked
    /// as a fallback for setups that store it there instead.
    internal sealed class CredentialStore
    {
        public static string DefaultFilePath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    ".claude", ".credentials.json");
            }
        }

        public const string CredentialManagerTarget = "Claude Code-credentials";

        private readonly string _filePath;

        public CredentialStore() : this(DefaultFilePath) { }

        public CredentialStore(string filePath)
        {
            _filePath = filePath;
        }

        public Credentials Load()
        {
            string json = ReadFile();
            if (json != null) return Parse(json, "File: " + _filePath);

            json = ReadCredentialManager();
            if (json != null) return Parse(json, "Windows Credential Manager: " + CredentialManagerTarget);

            throw new CredentialException(CredentialErrorKind.NotFound,
                "No credentials found. Sign in with `claude /login` first.");
        }

        private string ReadFile()
        {
            if (!File.Exists(_filePath)) return null;
            try
            {
                return File.ReadAllText(_filePath, Encoding.UTF8);
            }
            catch (UnauthorizedAccessException ex)
            {
                throw new CredentialException(CredentialErrorKind.AccessDenied,
                    "Access denied reading " + _filePath + ": " + ex.Message);
            }
            catch (Exception ex)
            {
                throw new CredentialException(CredentialErrorKind.FileError,
                    "File error: " + ex.Message);
            }
        }

        public static Credentials Parse(string json, string sourceDescription)
        {
            JsonValue root;
            try
            {
                root = Json.Parse(json);
            }
            catch (Exception ex)
            {
                throw new CredentialException(CredentialErrorKind.Malformed, "invalid JSON: " + ex.Message);
            }
            if (root == null || root.Type != JsonValue.Kind.Object)
                throw new CredentialException(CredentialErrorKind.Malformed, "expected object at root");

            var oauth = root["claudeAiOauth"];
            if (oauth == null || oauth.Type != JsonValue.Kind.Object)
                throw new CredentialException(CredentialErrorKind.Malformed, "missing claudeAiOauth");

            var tokenValue = oauth["accessToken"];
            string accessToken = tokenValue == null ? null : tokenValue.AsString(null);
            if (string.IsNullOrEmpty(accessToken))
                throw new CredentialException(CredentialErrorKind.Malformed, "missing claudeAiOauth.accessToken");

            var credentials = new Credentials();
            credentials.AccessToken = accessToken;

            var refresh = oauth["refreshToken"];
            if (refresh != null)
            {
                string value = refresh.AsString(null);
                if (!string.IsNullOrEmpty(value)) credentials.RefreshToken = value;
            }

            credentials.ExpiresAtUtc = ParseTimestamp(oauth["expiresAt"]);

            var scopes = oauth["scopes"];
            if (scopes != null) credentials.Scopes = scopes.AsStringList();

            var subscription = oauth["subscriptionType"];
            if (subscription != null) credentials.SubscriptionType = subscription.AsString(null);

            var tier = oauth["rateLimitTier"];
            if (tier != null) credentials.RateLimitTier = tier.AsString(null);

            credentials.SourceDescription = sourceDescription;
            return credentials;
        }

        private static DateTime? ParseTimestamp(JsonValue raw)
        {
            if (raw == null) return null;
            double number = raw.AsDouble(double.NaN);
            if (double.IsNaN(number)) return null;
            // Heuristic: >= 10^10 means unix-ms; smaller means unix-s.
            double seconds = number >= 10000000000.0 ? number / 1000.0 : number;
            try
            {
                return Clock.FromUnixSeconds(seconds);
            }
            catch
            {
                return null;
            }
        }

        // --- Windows Credential Manager fallback ---------------------------

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public uint Flags;
            public uint Type;
            public IntPtr TargetName;
            public IntPtr Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            public IntPtr TargetAlias;
            public IntPtr UserName;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "CredReadW", SetLastError = true)]
        private static extern bool CredRead(string target, uint type, uint reservedFlag, out IntPtr credentialPtr);

        [DllImport("advapi32.dll", EntryPoint = "CredFree")]
        private static extern void CredFree(IntPtr buffer);

        private const uint CRED_TYPE_GENERIC = 1;

        private static string ReadCredentialManager()
        {
            IntPtr raw = IntPtr.Zero;
            try
            {
                if (!CredRead(CredentialManagerTarget, CRED_TYPE_GENERIC, 0, out raw)) return null;
                var cred = (CREDENTIAL)Marshal.PtrToStructure(raw, typeof(CREDENTIAL));
                if (cred.CredentialBlobSize == 0 || cred.CredentialBlob == IntPtr.Zero) return null;

                var bytes = new byte[cred.CredentialBlobSize];
                Marshal.Copy(cred.CredentialBlob, bytes, 0, (int)cred.CredentialBlobSize);
                return DecodeBlob(bytes);
            }
            catch
            {
                return null;
            }
            finally
            {
                if (raw != IntPtr.Zero) CredFree(raw);
            }
        }

        /// The blob can be UTF-8 or UTF-16 depending on which tool wrote it.
        /// A UTF-16 payload of ASCII JSON is full of interleaved zero bytes,
        /// which is what we sniff for.
        private static string DecodeBlob(byte[] bytes)
        {
            int zeros = 0;
            int limit = Math.Min(bytes.Length, 64);
            for (int i = 0; i < limit; i++)
            {
                if (bytes[i] == 0) zeros++;
            }
            if (zeros > limit / 4) return Encoding.Unicode.GetString(bytes).TrimEnd('\0');
            return Encoding.UTF8.GetString(bytes).TrimEnd('\0');
        }
    }

    // ------------------------------------------------------------ api client

    internal sealed class AnthropicApiClient
    {
        public string BaseUrl;
        public string Model;
        public string ApiVersion;
        public int TimeoutMilliseconds;

        public AnthropicApiClient() : this(Defaults.ApiBaseUrl, Defaults.ApiModel) { }

        public AnthropicApiClient(string baseUrl, string model)
        {
            BaseUrl = string.IsNullOrEmpty(baseUrl) ? Defaults.ApiBaseUrl : baseUrl.TrimEnd('/');
            Model = string.IsNullOrEmpty(model) ? Defaults.ApiModel : model;
            ApiVersion = "2023-06-01";
            TimeoutMilliseconds = 10000;
        }

        static AnthropicApiClient()
        {
            // .NET Framework's default can still negotiate SSL3/TLS1.0 on older
            // machines; api.anthropic.com requires TLS 1.2+.
            try
            {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            }
            catch
            {
            }
            ServicePointManager.Expect100Continue = false;
        }

        public async Task<UsageData> FetchUsageAsync(Credentials credentials)
        {
            var request = (HttpWebRequest)WebRequest.Create(BaseUrl + "/v1/messages");
            request.Method = "POST";
            request.ContentType = "application/json";
            request.UserAgent = "ClawdBar/0.1 (Windows)";
            request.Headers["Authorization"] = "Bearer " + credentials.AccessToken;
            request.Headers["anthropic-version"] = ApiVersion;
            request.Timeout = TimeoutMilliseconds;
            request.ReadWriteTimeout = TimeoutMilliseconds;
            request.Proxy = WebRequest.DefaultWebProxy;

            byte[] payload = Encoding.UTF8.GetBytes(BuildPayload());
            request.ContentLength = payload.Length;

            try
            {
                using (var stream = await request.GetRequestStreamAsync().ConfigureAwait(false))
                {
                    await stream.WriteAsync(payload, 0, payload.Length).ConfigureAwait(false);
                }

                using (var response = (HttpWebResponse)await WithTimeout(request).ConfigureAwait(false))
                {
                    int status = (int)response.StatusCode;
                    if (status >= 200 && status < 300)
                    {
                        DrainBody(response);
                        return ParseUsage(response.Headers);
                    }
                    throw ApiException.Server(status, ReadBody(response));
                }
            }
            catch (ApiException)
            {
                throw;
            }
            catch (WebException ex)
            {
                var response = ex.Response as HttpWebResponse;
                if (response == null)
                {
                    throw ApiException.Network(ex.Message);
                }
                using (response)
                {
                    int status = (int)response.StatusCode;
                    if (status == 401) throw ApiException.Unauthorized();
                    if (status == 429)
                    {
                        double parsed;
                        string retryRaw = response.Headers["retry-after"];
                        double? retry = null;
                        if (!string.IsNullOrEmpty(retryRaw) &&
                            double.TryParse(retryRaw, NumberStyles.Float, CultureInfo.InvariantCulture, out parsed))
                        {
                            retry = parsed;
                        }
                        throw ApiException.RateLimited(retry);
                    }
                    throw ApiException.Server(status, ReadBody(response));
                }
            }
            catch (Exception ex)
            {
                throw ApiException.Network(ex.Message);
            }
        }

        private string BuildPayload()
        {
            var root = JsonValue.NewObject();
            root["max_tokens"] = JsonValue.From(1);
            var message = JsonValue.NewObject();
            message["content"] = JsonValue.From(".");
            message["role"] = JsonValue.From("user");
            var messages = JsonValue.NewArray();
            messages.Items.Add(message);
            root["messages"] = messages;
            root["model"] = JsonValue.From(Model);
            return root.ToJson();
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
                throw ApiException.Network("timed out after " +
                    (TimeoutMilliseconds / 1000).ToString(CultureInfo.InvariantCulture) + "s");
            }
            return await responseTask.ConfigureAwait(false);
        }

        private static void DrainBody(HttpWebResponse response)
        {
            try
            {
                using (var stream = response.GetResponseStream())
                {
                    if (stream == null) return;
                    var buffer = new byte[4096];
                    while (stream.Read(buffer, 0, buffer.Length) > 0) { }
                }
            }
            catch
            {
            }
        }

        private static string ReadBody(HttpWebResponse response)
        {
            try
            {
                using (var stream = response.GetResponseStream())
                {
                    if (stream == null) return null;
                    using (var reader = new StreamReader(stream, Encoding.UTF8))
                    {
                        return reader.ReadToEnd();
                    }
                }
            }
            catch
            {
                return null;
            }
        }

        public static UsageData ParseUsage(WebHeaderCollection headers)
        {
            var raw = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < headers.Count; i++)
            {
                string key = headers.GetKey(i);
                if (key == null) continue;
                string lower = key.ToLowerInvariant();
                if (!lower.StartsWith("anthropic-", StringComparison.Ordinal)) continue;
                raw[lower] = headers.Get(i);
            }
            return ParseUsage(raw);
        }

        public static UsageData ParseUsage(Dictionary<string, string> raw)
        {
            var usage = new UsageData();
            usage.SessionPercent = ParsePercent(Lookup(raw, "anthropic-ratelimit-unified-5h-utilization"));
            usage.SessionResetAt = ParseReset(Lookup(raw, "anthropic-ratelimit-unified-5h-reset"));
            usage.WeeklyPercent = ParsePercent(Lookup(raw, "anthropic-ratelimit-unified-7d-utilization"));
            usage.WeeklyResetAt = ParseReset(Lookup(raw, "anthropic-ratelimit-unified-7d-reset"));
            usage.LastUpdatedUtc = DateTime.UtcNow;
            usage.IsStale = false;
            usage.RawHeaders = raw;
            return usage;
        }

        private static string Lookup(Dictionary<string, string> raw, string key)
        {
            string value;
            return raw.TryGetValue(key, out value) ? value : null;
        }

        public static double? ParsePercent(string raw)
        {
            if (string.IsNullOrEmpty(raw)) return null;
            double value;
            if (!double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out value)) return null;
            // Headers may report a 0-1 fraction or a 0-100 percent. Normalize.
            return Math.Round(value <= 1.0 ? value * 100 : value, 6);
        }

        public static DateTime? ParseReset(string raw)
        {
            if (string.IsNullOrEmpty(raw)) return null;

            DateTime parsed;
            if (DateTime.TryParse(raw, CultureInfo.InvariantCulture,
                    DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out parsed))
            {
                return DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
            }

            double number;
            if (!double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out number)) return null;
            if (number > 10000000000.0) return Clock.FromUnixSeconds(number / 1000.0);
            if (number > 1000000000.0) return Clock.FromUnixSeconds(number);
            // Small number means "seconds remaining".
            return DateTime.UtcNow.AddSeconds(number);
        }
    }

    // ---------------------------------------------------------------- history

    internal sealed class UsageHistoryStore
    {
        public readonly List<UsageSample> Samples = new List<UsageSample>();

        private readonly string _path;

        public static string DefaultPath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    ".clawdbar", "history.jsonl");
            }
        }

        public string Path_ { get { return _path; } }

        public UsageHistoryStore() : this(DefaultPath) { }

        public UsageHistoryStore(string path)
        {
            _path = path;
            LoadFromDisk();
        }

        public void Append(UsageSample sample)
        {
            if (sample.TimestampUtc < UsageStats.MinValidTimestamp) return;
            Samples.Add(sample);
            AppendToDisk(sample);
        }

        private void LoadFromDisk()
        {
            if (!File.Exists(_path)) return;
            string[] lines;
            try
            {
                lines = File.ReadAllLines(_path, Encoding.UTF8);
            }
            catch
            {
                return;
            }

            bool droppedAny = false;
            for (int i = 0; i < lines.Length; i++)
            {
                string line = lines[i].Trim();
                if (line.Length == 0) continue;
                var sample = UsageSample.FromJsonLine(line);
                if (sample == null || sample.TimestampUtc < UsageStats.MinValidTimestamp)
                {
                    droppedAny = true;
                    continue;
                }
                Samples.Add(sample);
            }

            // If we dropped bad rows, rewrite once so the stats page stops
            // showing year-0 nonsense even before the next compute.
            if (droppedAny) RewriteAll();
        }

        private void RewriteAll()
        {
            try
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(_path));
                var sb = new StringBuilder();
                for (int i = 0; i < Samples.Count; i++)
                {
                    sb.Append(Samples[i].ToJsonLine()).Append('\n');
                }
                File.WriteAllText(_path, sb.ToString(), new UTF8Encoding(false));
            }
            catch
            {
            }
        }

        private void AppendToDisk(UsageSample sample)
        {
            try
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(_path));
                File.AppendAllText(_path, sample.ToJsonLine() + "\n", new UTF8Encoding(false));
            }
            catch
            {
                // Best-effort: a failed history write should never crash a poll.
            }
        }
    }

    // ------------------------------------------------------- launch at login

    /// Windows equivalent of SMAppService: a value under the per-user Run key.
    /// No elevation needed, and uninstalling is just deleting the value.
    internal static class LaunchAtLogin
    {
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string ValueName = "ClawdBar";

        public static bool IsEnabled
        {
            get
            {
                try
                {
                    using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey, false))
                    {
                        if (key == null) return false;
                        var value = key.GetValue(ValueName) as string;
                        return !string.IsNullOrEmpty(value);
                    }
                }
                catch
                {
                    return false;
                }
            }
        }

        public static bool SetEnabled(bool enabled)
        {
            try
            {
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey, true))
                {
                    if (key == null) return false;
                    if (enabled)
                    {
                        string exe = System.Reflection.Assembly.GetExecutingAssembly().Location;
                        key.SetValue(ValueName, "\"" + exe + "\"");
                    }
                    else
                    {
                        if (key.GetValue(ValueName) != null) key.DeleteValue(ValueName, false);
                    }
                }
                return true;
            }
            catch
            {
                return false;
            }
        }
    }

    // --------------------------------------------------------- notifications

    /// Threshold alerts. macOS uses UNUserNotificationCenter; on Windows the
    /// tray icon's balloon tip is the equivalent that needs no AppUserModelID
    /// registration, so a portable single .exe still gets real toasts.
    internal sealed class NotificationManager
    {
        private enum Level { None = 0, Warning = 1, Critical = 2 }

        private Level _lastFiredSession = Level.None;
        private Level _lastFiredWeekly = Level.None;

        private readonly Action<string, string, bool> _deliver;

        public NotificationManager(Action<string, string, bool> deliver)
        {
            _deliver = deliver;
        }

        public void Evaluate(UsageData usage, AppSettings settings)
        {
            if (!settings.NotificationsEnabled) return;

            if (settings.NotifyForSession)
            {
                _lastFiredSession = MaybeFire("5h", usage.SessionPercent, _lastFiredSession, settings);
            }
            if (settings.NotifyForWeekly)
            {
                _lastFiredWeekly = MaybeFire("7d", usage.WeeklyPercent, _lastFiredWeekly, settings);
            }
        }

        private Level MaybeFire(string window, double? percent, Level lastFired, AppSettings settings)
        {
            if (!percent.HasValue) return lastFired;
            double p = percent.Value;

            Level current = Level.None;
            if (p >= settings.CriticalThreshold) current = Level.Critical;
            else if (p >= settings.WarningThreshold) current = Level.Warning;

            if (current > lastFired)
            {
                string title = current == Level.Critical
                    ? "ClawdBar - " + window + " critical"
                    : "ClawdBar - " + window + " approaching limit";
                string body = "Claude Code " + window + " usage at " +
                    ((int)Math.Round(p)).ToString(CultureInfo.InvariantCulture) + "%.";
                if (_deliver != null) _deliver(title, body, settings.NotificationSound);
            }

            // Reset the latch once usage falls back under the warning line, so
            // the next crossing alerts again.
            if (p < settings.WarningThreshold) return Level.None;
            return current > lastFired ? current : lastFired;
        }
    }
}
