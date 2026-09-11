using System;
using System.Drawing;
using System.Windows.Forms;

namespace ClawdBar
{
    /// Developer harness. Opens one ClawdBar window standalone so it can be
    /// inspected or screenshotted without going through the tray icon.
    /// Not part of the shipped app — built separately by build-preview.cmd.
    ///
    ///   Preview.exe popup [tab]  the tray panel (tab: tokens | status)
    ///   Preview.exe settings [n] the preferences window, on nav item n
    ///   Preview.exe onboarding   the first-run flow
    ///   Preview.exe overlay [n]  the floating widget, on carousel page n
    internal static class Preview
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            var settings = new AppSettings();
            var daemon = new UsageDaemon(
                new AnthropicApiClient(settings.ApiBaseUrl, settings.ApiModel),
                new CredentialStore(),
                new UsageHistoryStore());

            var status = new StatusMonitor();
            var tokens = new TokenUsageMonitor();

            // One real fetch of each so the windows render against live data.
            try { daemon.RefreshNowAsync().GetAwaiter().GetResult(); }
            catch (Exception ex) { Console.WriteLine("fetch failed: " + ex.Message); }
            try { status.RefreshNowAsync().GetAwaiter().GetResult(); }
            catch (Exception ex) { Console.WriteLine("status fetch failed: " + ex.Message); }
            // The panel hides the SERVICE tab unless the monitor is actually
            // polling, so the harness has to start it or the tab strip can
            // never be screenshotted.
            if (settings.ServiceStatusEnabled) status.Start();
            try { tokens.RefreshNowAsync().GetAwaiter().GetResult(); }
            catch (Exception ex) { Console.WriteLine("token scan failed: " + ex.Message); }

            string which = args.Length > 0 ? args[0].ToLowerInvariant() : "popup";
            Form form;

            if (which == "settings")
            {
                var preferences = new SettingsForm(settings, daemon, status, tokens, null, null);
                int nav;
                if (args.Length > 1 && int.TryParse(args[1], out nav)) preferences.ShowPage(nav);
                form = preferences;
            }
            else if (which == "onboarding")
            {
                form = new OnboardingForm(settings, daemon);
            }
            else if (which == "overlay")
            {
                var overlay = new OverlayForm(daemon, status, settings);
                overlay.ShowInTaskbar = true;
                // Optional second argument picks the carousel page, so each
                // page can be screenshotted for the docs.
                int page;
                if (args.Length > 1 && int.TryParse(args[1], out page)) overlay.ShowPage(page);
                form = overlay;
            }
            else
            {
                // Optional second argument picks the tab, so each panel can
                // be screenshotted for the docs.
                if (args.Length > 1) settings.PopoverTab = args[1].ToLowerInvariant();
                var popup = new PopupForm(daemon, status, tokens, settings, null, null,
                    delegate { Application.Exit(); });
                popup.AutoHideOnDeactivate = false;
                popup.ShowInTaskbar = true;
                popup.StartPosition = FormStartPosition.Manual;
                Rectangle work = Screen.PrimaryScreen.WorkingArea;
                popup.Location = new Point(work.Left + 60, work.Top + 60);
                form = popup;
            }

            Application.Run(form);
        }
    }
}
