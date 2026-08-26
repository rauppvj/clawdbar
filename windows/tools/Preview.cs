using System;
using System.Drawing;
using System.Windows.Forms;

namespace ClawdBar
{
    /// Developer harness. Opens one ClawdBar window standalone so it can be
    /// inspected or screenshotted without going through the tray icon.
    /// Not part of the shipped app — built separately by build-preview.cmd.
    ///
    ///   Preview.exe popup      the tray panel
    ///   Preview.exe settings   the preferences window
    ///   Preview.exe onboarding the first-run flow
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

            // One real fetch so the windows render against live numbers.
            try { daemon.RefreshNowAsync().GetAwaiter().GetResult(); }
            catch (Exception ex) { Console.WriteLine("fetch failed: " + ex.Message); }

            string which = args.Length > 0 ? args[0].ToLowerInvariant() : "popup";
            Form form;

            if (which == "settings")
            {
                form = new SettingsForm(settings, daemon, null, null);
            }
            else if (which == "onboarding")
            {
                form = new OnboardingForm(settings, daemon);
            }
            else
            {
                var popup = new PopupForm(daemon, settings, null, null,
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
