using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ClawdBar
{
    /// Owns the poll loop, the in-memory credential cache and the history
    /// store. Runs entirely on the UI thread: every await resumes on the
    /// WinForms synchronization context, so views can read state directly
    /// without locking.
    internal sealed class UsageDaemon : IDisposable
    {
        public UsageData Usage;
        public string LastError;
        public DateTime? LastFetchAtUtc;
        public bool IsPolling;
        public bool IsAsleep;
        public bool IsFetching;

        public readonly UsageHistoryStore History;

        /// Raised after every state change so the tray icon, popup and overlay
        /// can repaint. Always fires on the UI thread.
        public event EventHandler Changed;

        /// Raised only when a fetch produced fresh usage, so notification
        /// evaluation does not re-run on error ticks.
        public event EventHandler<UsageData> UsageFetched;

        public double PollInterval;

        private readonly AnthropicApiClient _client;
        private readonly CredentialStore _credentialStore;
        private readonly AccountProfileStore _profileStore;
        private Credentials _cachedCredentials;
        private AccountProfile _accountProfile;
        private DateTime? _profileModifiedUtc;
        private bool _hasCheckedProfile;
        private CancellationTokenSource _cancellation;
        private PowerModeChangedEventHandler _powerHandler;

        public UsageDaemon(AnthropicApiClient client, CredentialStore credentialStore, UsageHistoryStore history)
            : this(client, credentialStore, history, new AccountProfileStore())
        {
        }

        public UsageDaemon(AnthropicApiClient client, CredentialStore credentialStore,
            UsageHistoryStore history, AccountProfileStore profileStore)
        {
            _client = client;
            _credentialStore = credentialStore;
            _profileStore = profileStore;
            History = history;
            Usage = UsageData.Empty();
            PollInterval = Defaults.PollInterval;
            RefreshAccountProfile();
            RegisterSystemObservers();
        }

        /// What Claude Code currently believes about the account, read from
        /// .claude.json. Preferred over the token claims because a refreshed
        /// token keeps whatever plan it was minted with.
        public AccountProfile AccountProfile
        {
            get { return _accountProfile; }
        }

        /// Best-effort plan family ("claude_max", "max", "pro"). null until we
        /// have either a profile or credentials.
        public string SubscriptionType
        {
            get
            {
                if (_accountProfile != null && _accountProfile.OrganizationType != null)
                    return _accountProfile.OrganizationType;
                return _cachedCredentials == null ? null : _cachedCredentials.SubscriptionType;
            }
        }

        /// Opaque internal tier id (e.g. "default_claude_max_5x"), used to tell
        /// Max 5x from Max 20x in the popover badge.
        public string RateLimitTier
        {
            get
            {
                if (_accountProfile != null && _accountProfile.Tier != null)
                    return _accountProfile.Tier;
                return _cachedCredentials == null ? null : _cachedCredentials.RateLimitTier;
            }
        }

        /// Where the plan pill's text came from, for the Preferences
        /// diagnostics row.
        public string PlanSource
        {
            get { return _accountProfile != null ? _profileStore.FilePath : "OAuth token claims"; }
        }

        public string CredentialSource
        {
            get { return _cachedCredentials == null ? null : _cachedCredentials.SourceDescription; }
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
        }

        public Task RefreshNowAsync()
        {
            return FetchOnceAsync();
        }

        /// Drops the in-memory token cache so the next fetch re-reads the
        /// credentials file. Use after `claude /login` or on a 401.
        public void InvalidateCredentials()
        {
            _cachedCredentials = null;
        }

        public Credentials LoadCredentials()
        {
            return LoadCachedCredentials();
        }

        private async void RunLoop(CancellationToken token)
        {
            // Immediate first fetch so the tray shows real data within seconds.
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

        /// Floored at 30s per spec. Windows battery saver is the closest
        /// analogue to macOS low-power mode, so we back off the same 5x there.
        private double EffectiveInterval
        {
            get
            {
                double baseInterval = Math.Max(30, PollInterval);
                try
                {
                    var status = SystemInformation.PowerStatus;
                    bool onBattery = status.PowerLineStatus == PowerLineStatus.Offline;
                    bool saving = (status.BatteryChargeStatus & BatteryChargeStatus.Low) != 0;
                    if (onBattery && saving) return baseInterval * 5;
                }
                catch
                {
                }
                return baseInterval;
            }
        }

        /// Re-parses .claude.json only when its last-write time has moved - the
        /// file is a few hundred KB of unrelated Claude Code state and this
        /// runs on every poll. The _hasCheckedProfile flag is what makes the
        /// *first* look happen: on a machine with no such file both timestamps
        /// are null, and gating on them alone would either skip forever or
        /// re-parse forever.
        ///
        /// A plan change rewrites this file without any token being re-issued,
        /// so this is the path that keeps the pill honest on an upgrade.
        private void RefreshAccountProfile()
        {
            DateTime? modified = _profileStore.ModifiedAtUtc();
            if (_hasCheckedProfile && modified == _profileModifiedUtc) return;
            _hasCheckedProfile = true;
            _profileModifiedUtc = modified;

            AccountProfile loaded = _profileStore.Load();
            if (loaded != null || modified.HasValue)
            {
                // A readable file that no longer names an account means a
                // sign-out. Fall back to the token claims rather than pinning
                // a stale plan.
                _accountProfile = loaded;
            }
            // File gone entirely (moved profile, deleted): keep what we had -
            // the account didn't change, our view of the disk did.
        }

        private async Task FetchOnceAsync()
        {
            IsFetching = true;
            RaiseChanged();
            // A plan change lands in .claude.json without any token being
            // re-issued, so re-read it whenever the file has moved.
            RefreshAccountProfile();
            try
            {
                Credentials credentials = LoadCachedCredentials();
                UsageData fresh = await _client.FetchUsageAsync(credentials).ConfigureAwait(true);

                Usage = fresh;
                LastError = null;
                LastFetchAtUtc = DateTime.UtcNow;

                var sample = new UsageSample();
                sample.TimestampUtc = fresh.LastUpdatedUtc;
                sample.SessionPercent = fresh.SessionPercent;
                sample.WeeklyPercent = fresh.WeeklyPercent;
                History.Append(sample);

                var handler = UsageFetched;
                if (handler != null) handler(this, fresh);
            }
            catch (ApiException ex)
            {
                if (ex.Kind == ApiErrorKind.Unauthorized)
                {
                    // The token was rejected. Drop the cache so the next poll
                    // re-reads the file — the user may have just re-logged in.
                    _cachedCredentials = null;
                }
                Usage.IsStale = true;
                LastError = ex.Message;
            }
            catch (CredentialException ex)
            {
                Usage.IsStale = true;
                LastError = ex.Message;
            }
            catch (Exception ex)
            {
                Usage.IsStale = true;
                LastError = ex.Message;
            }
            finally
            {
                IsFetching = false;
                RaiseChanged();
            }
        }

        /// Reads the credentials file at most once per token lifetime. Within
        /// 5 minutes of expiry we re-read so the next request gets a fresh
        /// token before the API rejects it.
        private Credentials LoadCachedCredentials()
        {
            if (_cachedCredentials != null && !_cachedCredentials.ExpiresSoon) return _cachedCredentials;
            Credentials fresh = _credentialStore.Load();
            _cachedCredentials = fresh;
            return fresh;
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
