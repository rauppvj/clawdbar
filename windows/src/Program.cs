using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace ClawdBar
{
    internal static class Program
    {
        private const string ProbeCredentialsFlag = "--probe-credentials";
        private const string ProbeApiFlag = "--probe-api";
        private const string ResetFlag = "--reset-onboarding";
        private const string HelpFlag = "--help";

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AttachConsole(int processId);

        private const int AttachParentProcess = -1;

        [STAThread]
        private static int Main(string[] args)
        {
            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i];
                if (arg == ProbeCredentialsFlag) return RunConsole(ProbeCredentials);
                if (arg == ProbeApiFlag) return RunConsole(ProbeApi);
                if (arg == ResetFlag) return RunConsole(ResetOnboarding);
                if (arg == HelpFlag || arg == "-h" || arg == "/?") return RunConsole(PrintHelp);
            }

            // One tray icon per user session; a second launch just exits.
            bool createdNew;
            using (var mutex = new Mutex(true, "ClawdBar.SingleInstance", out createdNew))
            {
                if (!createdNew)
                {
                    MessageBox.Show("ClawdBar is already running — look for the capybara in your notification area.",
                        "ClawdBar", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 0;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayContext());
                GC.KeepAlive(mutex);
            }
            return 0;
        }

        // ------------------------------------------------------ CLI probes

        /// A WinExe has no console of its own, so we borrow the calling one.
        private static int RunConsole(Func<int> body)
        {
            AttachConsole(AttachParentProcess);
            Console.WriteLine();
            int code = body();
            Console.WriteLine();
            return code;
        }

        private static int PrintHelp()
        {
            Console.WriteLine("ClawdBar for Windows");
            Console.WriteLine("  (no flags)                launch the tray app");
            Console.WriteLine("  " + ProbeCredentialsFlag + "     inspect stored credentials (shape only)");
            Console.WriteLine("  " + ProbeApiFlag + "             spend 1 Haiku token, dump anthropic-* headers");
            Console.WriteLine("  " + ResetFlag + "       delete the settings file");
            return 0;
        }

        private static int ProbeCredentials()
        {
            try
            {
                Credentials credentials = new CredentialStore().Load();
                Console.WriteLine("source          : " + credentials.SourceDescription);
                Console.WriteLine("accessToken     : " + Mask(credentials.AccessToken));
                Console.WriteLine("refreshToken    : " + (credentials.RefreshToken == null ? "<absent>" : Mask(credentials.RefreshToken)));
                Console.WriteLine("expiresAt       : " + (credentials.ExpiresAtUtc.HasValue
                    ? credentials.ExpiresAtUtc.Value.ToLocalTime().ToString("u", CultureInfo.InvariantCulture) +
                      (credentials.IsExpired ? "  (EXPIRED)" : "")
                    : "<absent>"));
                Console.WriteLine("scopes          : " + string.Join(", ", credentials.Scopes.ToArray()));
                Console.WriteLine("subscriptionType: " + (credentials.SubscriptionType ?? "<absent>"));
                Console.WriteLine("rateLimitTier   : " + (credentials.RateLimitTier ?? "<absent>"));
                return 0;
            }
            catch (Exception ex)
            {
                Console.WriteLine("FAILED: " + ex.Message);
                return 1;
            }
        }

        /// Prints length and a short prefix only — never the token itself.
        private static string Mask(string token)
        {
            if (string.IsNullOrEmpty(token)) return "<empty>";
            string head = token.Length > 8 ? token.Substring(0, 8) : token;
            return head + "... (" + token.Length.ToString(CultureInfo.InvariantCulture) + " chars)";
        }

        private static int ProbeApi()
        {
            try
            {
                var settings = new AppSettings();
                Credentials credentials = new CredentialStore().Load();
                var client = new AnthropicApiClient(settings.ApiBaseUrl, settings.ApiModel);

                Console.WriteLine("POST " + settings.ApiBaseUrl + "/v1/messages  (model " + settings.ApiModel + ", max_tokens 1)");
                UsageData usage = client.FetchUsageAsync(credentials).GetAwaiter().GetResult();

                var keys = new List<string>(usage.RawHeaders.Keys);
                keys.Sort(StringComparer.Ordinal);
                for (int i = 0; i < keys.Count; i++)
                {
                    Console.WriteLine("  " + keys[i] + ": " + usage.RawHeaders[keys[i]]);
                }
                Console.WriteLine();
                Console.WriteLine("parsed 5h: " + Fmt(usage.SessionPercent) + "  resets " + FmtDate(usage.SessionResetAt));
                Console.WriteLine("parsed 7d: " + Fmt(usage.WeeklyPercent) + "  resets " + FmtDate(usage.WeeklyResetAt));
                return 0;
            }
            catch (Exception ex)
            {
                Console.WriteLine("FAILED: " + ex.Message);
                return 1;
            }
        }

        private static string Fmt(double? percent)
        {
            return percent.HasValue
                ? percent.Value.ToString("0.##", CultureInfo.InvariantCulture) + "%"
                : "<absent>";
        }

        private static string FmtDate(DateTime? date)
        {
            return date.HasValue
                ? date.Value.ToLocalTime().ToString("u", CultureInfo.InvariantCulture)
                : "<absent>";
        }

        private static int ResetOnboarding()
        {
            bool ok = AppSettings.DeleteStoredSettings();
            Console.WriteLine(ok
                ? "Deleted " + AppSettings.FilePath
                : "Could not delete " + AppSettings.FilePath);
            return ok ? 0 : 1;
        }
    }

    /// Windows counterpart of the MenuBarExtra scene: owns the tray icon and
    /// every window hanging off it, and keeps the app alive with no main form.
    internal sealed class TrayContext : ApplicationContext
    {
        private readonly AppSettings _settings;
        private readonly UsageDaemon _daemon;
        private readonly NotificationManager _notifications;
        private readonly NotifyIcon _tray;

        private PopupForm _popup;
        private OverlayForm _overlay;
        private SettingsForm _settingsForm;
        private Icon _currentIcon;

        public TrayContext()
        {
            _settings = new AppSettings();

            var client = new AnthropicApiClient(_settings.ApiBaseUrl, _settings.ApiModel);
            _daemon = new UsageDaemon(client, new CredentialStore(), new UsageHistoryStore());
            _daemon.PollInterval = _settings.PollInterval;

            _notifications = new NotificationManager(DeliverNotification);

            _tray = new NotifyIcon();
            _tray.Icon = AppIcon.Load();
            _tray.Text = "ClawdBar";
            _tray.Visible = true;
            _tray.ContextMenuStrip = BuildMenu();
            _tray.MouseClick += OnTrayClick;
            _tray.BalloonTipClicked += delegate { ShowPopup(); };

            _daemon.Changed += OnDaemonChanged;
            _daemon.UsageFetched += OnUsageFetched;

            // Onboarding drives the first credential read on a fresh install,
            // so the poll loop does not race it with a second one.
            if (!_settings.OnboardingDone)
            {
                using (var onboarding = new OnboardingForm(_settings, _daemon))
                {
                    onboarding.ShowDialog();
                }
                _daemon.PollInterval = _settings.PollInterval;
            }

            _daemon.Start();
            RefreshTray();

            if (_settings.OverlayEnabledOnLaunch) ToggleOverlay();
        }

        private ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("Show panel", null, delegate { ShowPopup(); });
            menu.Items.Add("Refresh now", null, async delegate { await _daemon.RefreshNowAsync(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Toggle floating widget", null, delegate { ToggleOverlay(); });
            menu.Items.Add("Preferences...", null, delegate { ShowSettings(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quit ClawdBar", null, delegate { Quit(); });
            return menu;
        }

        private void OnTrayClick(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) ShowPopup();
        }

        private void OnDaemonChanged(object sender, EventArgs e)
        {
            RefreshTray();
        }

        private void OnUsageFetched(object sender, UsageData usage)
        {
            _notifications.Evaluate(usage, _settings);
        }

        /// Rebuilds the tray bitmap. Like the macOS build, the mascot frame is
        /// frozen at t = 0 rather than animated — a tray icon that repaints
        /// several times a second flickers and burns CPU for no benefit.
        private void RefreshTray()
        {
            try
            {
                Icon fresh = TrayIconRenderer.Render(_daemon, _settings, 0);
                Icon previous = _currentIcon;
                _currentIcon = fresh;
                _tray.Icon = fresh;
                if (previous != null) previous.Dispose();
            }
            catch
            {
                // A failed icon render must never take the app down; the old
                // icon simply stays on screen.
            }
            _tray.Text = TrayIconRenderer.Tooltip(_daemon);
        }

        private void DeliverNotification(string title, string body, bool sound)
        {
            try
            {
                // ToolTipIcon selects the notification sound on Windows: None is
                // silent, Warning plays the system alert.
                _tray.ShowBalloonTip(6000, title, body, sound ? ToolTipIcon.Warning : ToolTipIcon.None);
            }
            catch
            {
            }
        }

        private void ShowPopup()
        {
            if (_popup == null || _popup.IsDisposed)
            {
                _popup = new PopupForm(_daemon, _settings, ToggleOverlay, ShowSettings, Quit);
            }
            if (_popup.Visible)
            {
                _popup.Hide();
                return;
            }
            _popup.ShowNearTray();
        }

        private void ToggleOverlay()
        {
            if (_overlay == null || _overlay.IsDisposed)
            {
                _overlay = new OverlayForm(_daemon, _settings);
            }
            _overlay.ToggleVisible();
        }

        private void ShowSettings()
        {
            if (_settingsForm != null && !_settingsForm.IsDisposed)
            {
                _settingsForm.Activate();
                return;
            }
            _settingsForm = new SettingsForm(_settings, _daemon, OnSettingsChanged, ResetOverlaySize);
            _settingsForm.FormClosed += delegate { _settingsForm = null; };
            _settingsForm.Show();
            _settingsForm.Activate();
        }

        private void OnSettingsChanged()
        {
            _daemon.PollInterval = _settings.PollInterval;
            RefreshTray();
            if (_overlay != null && !_overlay.IsDisposed)
            {
                _overlay.ApplySettings();
                _overlay.Invalidate();
            }
        }

        private void ResetOverlaySize()
        {
            if (_overlay == null || _overlay.IsDisposed) return;
            _overlay.ResetSize();
        }

        private void Quit()
        {
            _tray.Visible = false;
            ExitThread();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (_daemon != null)
                {
                    _daemon.Changed -= OnDaemonChanged;
                    _daemon.UsageFetched -= OnUsageFetched;
                    _daemon.Dispose();
                }
                if (_tray != null)
                {
                    _tray.Visible = false;
                    _tray.Dispose();
                }
                if (_currentIcon != null) _currentIcon.Dispose();
                if (_popup != null && !_popup.IsDisposed) _popup.Dispose();
                if (_overlay != null && !_overlay.IsDisposed) _overlay.Dispose();
                if (_settingsForm != null && !_settingsForm.IsDisposed) _settingsForm.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
