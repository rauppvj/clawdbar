using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Windows.Forms;

namespace ClawdBar
{
    /// First-run flow. Mirrors the macOS onboarding steps, minus the keychain
    /// approval step — on Windows the token is a file the user already owns,
    /// so there is no permission prompt to walk them through.
    internal sealed class OnboardingForm : Form
    {
        private enum Step { Welcome, Connect, Appearance, Done }

        private readonly AppSettings _settings;
        private readonly UsageDaemon _daemon;

        private Step _step = Step.Welcome;
        private string _connectStatus;
        private Color _connectColor;
        private bool _connected;
        private bool _probing;

        private readonly Panel _body;
        private readonly Button _back;
        private readonly Button _next;
        private readonly Panel _indicator;

        public OnboardingForm(AppSettings settings, UsageDaemon daemon)
        {
            _settings = settings;
            _daemon = daemon;
            _connectStatus = "";
            _connectColor = Theme.TextSecondary;

            Text = "Welcome to ClawdBar";
            ClientSize = new Size(560, 460);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            BackColor = Theme.BgDeep;
            ForeColor = Theme.TextPrimary;
            try { Icon = AppIcon.Load(); } catch { }

            _indicator = new Panel();
            _indicator.Dock = DockStyle.Top;
            _indicator.Height = 30;
            _indicator.BackColor = Theme.BgDeep;
            _indicator.Paint += PaintIndicator;
            Controls.Add(_indicator);

            var footer = new Panel();
            footer.Dock = DockStyle.Bottom;
            footer.Height = 60;
            footer.BackColor = Theme.BgDeep;
            Controls.Add(footer);

            _back = MakeButton("Back", 300, 14);
            _back.Click += delegate { Advance(-1); };
            footer.Controls.Add(_back);

            _next = MakeButton("Continue", 400, 14);
            _next.Click += delegate { Advance(1); };
            footer.Controls.Add(_next);

            _body = new Panel();
            _body.Dock = DockStyle.Fill;
            _body.BackColor = Theme.BgDeep;
            _body.Padding = new Padding(28, 10, 28, 10);
            Controls.Add(_body);
            _body.BringToFront();

            Windowing.CenterOnPrimary(this);
            Render();
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            Windowing.BringToFront(this);
        }

        private Button MakeButton(string text, int x, int y)
        {
            var button = new Button();
            button.Text = text;
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderColor = Theme.Stroke;
            button.BackColor = Theme.BgPanel;
            button.ForeColor = Theme.TextPrimary;
            button.Font = Theme.Ui(14, FontStyle.Regular);
            button.Size = new Size(130, 32);
            button.Location = new Point(x, y);
            return button;
        }

        private void PaintIndicator(object sender, PaintEventArgs e)
        {
            Draw.HighQuality(e.Graphics);
            int count = 4;
            float totalWidth = 0;
            for (int i = 0; i < count; i++) totalWidth += (i == (int)_step ? 32 : 14) + 8;
            float x = (_indicator.Width - totalWidth) / 2f;
            for (int i = 0; i < count; i++)
            {
                float width = i == (int)_step ? 32 : 14;
                Draw.FillRounded(e.Graphics, new RectangleF(x, 14, width, 4), 2,
                    i == (int)_step ? Theme.AccentWarm : Theme.Stroke);
                x += width + 8;
            }
        }

        private void Advance(int direction)
        {
            int index = (int)_step + direction;
            if (index < 0) return;
            if (index > (int)Step.Done)
            {
                Finish();
                return;
            }
            _step = (Step)index;
            Render();
        }

        private void Finish()
        {
            _settings.OnboardingDone = true;
            _settings.Save();
            DialogResult = DialogResult.OK;
            Close();
        }

        private void Render()
        {
            _body.Controls.Clear();
            _indicator.Invalidate();
            _back.Enabled = _step != Step.Welcome;
            _next.Text = _step == Step.Done ? "Finish" : "Continue";

            switch (_step)
            {
                case Step.Welcome: RenderWelcome(); break;
                case Step.Connect: RenderConnect(); break;
                case Step.Appearance: RenderAppearance(); break;
                default: RenderDone(); break;
            }
        }

        private void RenderWelcome()
        {
            var art = new Panel();
            art.Dock = DockStyle.Top;
            art.Height = 120;
            art.BackColor = Theme.BgDeep;
            art.Paint += delegate(object sender, PaintEventArgs e)
            {
                Draw.HighQuality(e.Graphics);
                Mascot.Draw(e.Graphics, new RectangleF((art.Width - 96) / 2f, 12, 96, 96),
                    Mood.Focused, MascotState.Chill, Clock.AnimationSeconds(), false, Theme.MascotTan);
            };
            _body.Controls.Add(art);

            Title("Welcome to ClawdBar", 140);
            Body("A tiny tray dashboard for your Claude Code 5h and 7d usage. It polls the " +
                 "Anthropic API on an interval (about 1 Haiku token per poll) and shows both " +
                 "windows at a glance — plus an optional floating widget, threshold alerts " +
                 "and a 7-day activity heatmap.", 180);
        }

        private void RenderConnect()
        {
            Title("Connect to Claude Code", 20);
            Body("ClawdBar reads the OAuth token that Claude Code already wrote to:", 60);

            var path = new TextBox();
            path.Text = CredentialStore.DefaultFilePath;
            path.ReadOnly = true;
            path.BorderStyle = BorderStyle.FixedSingle;
            path.BackColor = Theme.BgPanel;
            path.ForeColor = Theme.TextSecondary;
            path.Font = Theme.Mono(12, FontStyle.Regular);
            path.Location = new Point(0, 100);
            path.Width = 490;
            _body.Controls.Add(path);

            Body("No permission prompt is involved — it is a file in your own profile. " +
                 "Works with any Claude Code plan (Pro, Max, Max 20x, Team). " +
                 "If the test fails, run `claude /login` in a terminal first.", 132);

            var test = MakeButton(_connected ? "Re-test connection" : "Connect", 0, 210);
            test.Width = 180;
            test.Click += OnConnectClicked;
            _body.Controls.Add(test);

            var status = new Label();
            status.Text = _probing ? "Testing..." : _connectStatus;
            status.ForeColor = _connectColor;
            status.Font = Theme.Ui(13, FontStyle.Regular);
            status.Location = new Point(0, 254);
            status.MaximumSize = new Size(490, 0);
            status.AutoSize = true;
            status.BackColor = Color.Transparent;
            _body.Controls.Add(status);
        }

        private async void OnConnectClicked(object sender, EventArgs e)
        {
            if (_probing) return;
            _probing = true;
            Render();
            try
            {
                Credentials credentials = _daemon.LoadCredentials();
                await _daemon.RefreshNowAsync();

                if (_daemon.LastError != null)
                {
                    _connected = false;
                    _connectColor = Theme.ColorFor(Severity.Critical);
                    _connectStatus = "Reached the token, but the API call failed:\r\n" + _daemon.LastError;
                }
                else
                {
                    _connected = true;
                    _connectColor = Theme.ColorFor(Severity.Ok);
                    string plan = string.IsNullOrEmpty(credentials.SubscriptionType)
                        ? "unknown plan" : credentials.SubscriptionType.ToUpperInvariant();
                    string tier = string.IsNullOrEmpty(credentials.RateLimitTier) ? "-" : credentials.RateLimitTier;
                    _connectStatus = "Connected. Plan: " + plan + " (tier " + tier + ").\r\n" +
                        "5h " + Fmt(_daemon.Usage.DisplaySessionPercent) +
                        "   7d " + Fmt(_daemon.Usage.DisplayWeeklyPercent);
                }
            }
            catch (CredentialException ex)
            {
                _connected = false;
                _connectColor = Theme.AccentWarm;
                _connectStatus = ex.Message + "\r\nRun `claude /login` and try again.";
            }
            catch (Exception ex)
            {
                _connected = false;
                _connectColor = Theme.ColorFor(Severity.Critical);
                _connectStatus = ex.Message;
            }
            finally
            {
                _probing = false;
                Render();
            }
        }

        private static string Fmt(int? value)
        {
            return value.HasValue ? value.Value.ToString(CultureInfo.InvariantCulture) + "%" : "-";
        }

        private void RenderAppearance()
        {
            Title("Pick a tray icon style", 20);
            Body("All five styles fit the square tray slot. The full 5h / 7d numbers are " +
                 "always in the tooltip, whichever you pick.", 60);

            var styleValues = new List<TrayStyle>();
            foreach (TrayStyle style in Enum.GetValues(typeof(TrayStyle))) styleValues.Add(style);

            int y = 120;
            for (int i = 0; i < styleValues.Count; i++)
            {
                TrayStyle captured = styleValues[i];
                var radio = new RadioButton();
                radio.Text = "   " + AppSettings.DisplayName(captured);
                radio.Checked = _settings.TrayStyle == captured;
                radio.ForeColor = Theme.TextPrimary;
                radio.BackColor = Color.Transparent;
                radio.Font = Theme.Ui(14, FontStyle.Regular);
                radio.FlatStyle = FlatStyle.Flat;
                radio.AutoSize = true;
                radio.Location = new Point(40, y);
                radio.CheckedChanged += delegate
                {
                    if (!radio.Checked) return;
                    _settings.TrayStyle = captured;
                    _settings.Save();
                };
                _body.Controls.Add(radio);

                var preview = new Panel();
                preview.Size = new Size(32, 32);
                preview.Location = new Point(0, y - 6);
                preview.BackColor = Theme.BgPanel;
                preview.Paint += delegate(object sender, PaintEventArgs e)
                {
                    Draw.HighQuality(e.Graphics);
                    PaintStylePreview(e.Graphics, captured, new RectangleF(4, 4, 24, 24));
                };
                _body.Controls.Add(preview);

                y += 42;
            }
        }

        /// Live thumbnail of each tray style using the current usage numbers,
        /// so the choice is made against real data rather than a mock.
        private void PaintStylePreview(Graphics g, TrayStyle style, RectangleF bounds)
        {
            UsageData usage = _daemon.Usage;
            double? session = usage.SessionPercent.HasValue ? usage.SessionPercent : (double?)42;
            double? weekly = usage.WeeklyPercent.HasValue ? usage.WeeklyPercent : (double?)67;
            Severity sessionSeverity = UsageData.SeverityFor(session);
            Severity weeklySeverity = UsageData.SeverityFor(weekly);

            switch (style)
            {
                case TrayStyle.Numeric:
                    PreviewNumber(g, bounds, session, Theme.ColorFor(sessionSeverity));
                    break;
                case TrayStyle.MiniBar:
                    PreviewNumber(g, new RectangleF(bounds.X, bounds.Y, bounds.Width, bounds.Height - 8), session, Theme.TextPrimary);
                    Draw.UsageBar(g, new RectangleF(bounds.X + 2, bounds.Bottom - 6, bounds.Width - 4, 5), session, sessionSeverity, 1);
                    break;
                case TrayStyle.Mascot:
                    Mascot.Draw(g, bounds, usage.Mood, usage.MascotState, 0, false, Theme.MascotTan);
                    break;
                case TrayStyle.DualBar:
                    Draw.UsageBar(g, new RectangleF(bounds.X + 2, bounds.Y + 6, bounds.Width - 4, 5), session, sessionSeverity, 1);
                    Draw.UsageBar(g, new RectangleF(bounds.X + 2, bounds.Y + 15, bounds.Width - 4, 5), weekly, weeklySeverity, 1);
                    break;
                default:
                    Mascot.Draw(g, new RectangleF(bounds.X, bounds.Y - 2, bounds.Width, bounds.Height - 6),
                        usage.Mood, usage.MascotState, 0, false, Theme.MascotTan);
                    Draw.UsageBar(g, new RectangleF(bounds.X + 2, bounds.Bottom - 5, bounds.Width - 4, 4), session, sessionSeverity, 1);
                    break;
            }
        }

        private void PreviewNumber(Graphics g, RectangleF bounds, double? percent, Color color)
        {
            string text = percent.HasValue
                ? ((int)Math.Round(percent.Value)).ToString(CultureInfo.InvariantCulture) : "--";
            Font font = Theme.Mono(bounds.Height * 0.8f, FontStyle.Bold);
            SizeF size = Draw.Measure(g, text, font);
            Draw.String(g, text, font, color,
                bounds.X + (bounds.Width - size.Width) / 2f,
                bounds.Y + (bounds.Height - size.Height) / 2f);
        }

        private void RenderDone()
        {
            Title("You're set", 20);
            Body("ClawdBar now lives in the notification area. Left-click the icon for the " +
                 "panel, right-click for the menu.\r\n\r\n" +
                 "The floating widget has four pages — current usage, activity heatmap, " +
                 "stats and the tamagotchi. Drag it anywhere; right-click it for snap, " +
                 "opacity and click-through.\r\n\r\n" +
                 "Everything is adjustable later under Preferences.", 60);

            var launch = new CheckBox();
            launch.Text = "Start ClawdBar when I log in";
            launch.Checked = LaunchAtLogin.IsEnabled;
            launch.ForeColor = Theme.TextPrimary;
            launch.BackColor = Color.Transparent;
            launch.Font = Theme.Ui(14, FontStyle.Regular);
            launch.FlatStyle = FlatStyle.Flat;
            launch.AutoSize = true;
            launch.Location = new Point(0, 240);
            launch.CheckedChanged += delegate
            {
                LaunchAtLogin.SetEnabled(launch.Checked);
                _settings.LaunchAtLogin = LaunchAtLogin.IsEnabled;
                _settings.Save();
            };
            _body.Controls.Add(launch);

            var overlay = new CheckBox();
            overlay.Text = "Show the floating widget on launch";
            overlay.Checked = _settings.OverlayEnabledOnLaunch;
            overlay.ForeColor = Theme.TextPrimary;
            overlay.BackColor = Color.Transparent;
            overlay.Font = Theme.Ui(14, FontStyle.Regular);
            overlay.FlatStyle = FlatStyle.Flat;
            overlay.AutoSize = true;
            overlay.Location = new Point(0, 274);
            overlay.CheckedChanged += delegate
            {
                _settings.OverlayEnabledOnLaunch = overlay.Checked;
                _settings.Save();
            };
            _body.Controls.Add(overlay);
        }

        private void Title(string text, int y)
        {
            var label = new Label();
            label.Text = text;
            label.Font = Theme.Ui(20, FontStyle.Bold);
            label.ForeColor = Theme.TextPrimary;
            label.BackColor = Color.Transparent;
            label.AutoSize = true;
            label.Location = new Point(0, y);
            _body.Controls.Add(label);
        }

        private void Body(string text, int y)
        {
            var label = new Label();
            label.Text = text;
            label.Font = Theme.Ui(13, FontStyle.Regular);
            label.ForeColor = Theme.TextSecondary;
            label.BackColor = Color.Transparent;
            label.MaximumSize = new Size(490, 0);
            label.AutoSize = true;
            label.Location = new Point(0, y);
            _body.Controls.Add(label);
        }
    }
}
