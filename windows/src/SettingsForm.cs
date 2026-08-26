using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.Windows.Forms;

namespace ClawdBar
{
    /// Preferences window. macOS gets a native tabbed Settings scene; on
    /// Windows we build a dark-themed left-nav dialog, because a stock
    /// TabControl cannot be themed dark without owner-drawing every part.
    internal sealed class SettingsForm : Form
    {
        private readonly AppSettings _settings;
        private readonly UsageDaemon _daemon;
        private readonly Action _onSettingsChanged;
        private readonly Action _onResetOverlaySize;

        private readonly Panel _content;
        private readonly List<Label> _navItems = new List<Label>();
        private readonly List<Panel> _pages = new List<Panel>();

        private Label _testResult;
        private Button _testButton;

        public SettingsForm(AppSettings settings, UsageDaemon daemon,
            Action onSettingsChanged, Action onResetOverlaySize)
        {
            _settings = settings;
            _daemon = daemon;
            _onSettingsChanged = onSettingsChanged;
            _onResetOverlaySize = onResetOverlaySize;

            Text = "ClawdBar Preferences";
            ClientSize = new Size(660, 480);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            BackColor = Theme.BgDeep;
            ForeColor = Theme.TextPrimary;
            try { Icon = AppIcon.Load(); } catch { }

            var nav = new Panel();
            nav.Dock = DockStyle.Left;
            nav.Width = 160;
            nav.BackColor = Theme.BgPanel;
            Controls.Add(nav);

            _content = new Panel();
            _content.Dock = DockStyle.Fill;
            _content.BackColor = Theme.BgDeep;
            _content.Padding = new Padding(20, 16, 20, 16);
            Controls.Add(_content);
            _content.BringToFront();

            string[] names = { "General", "Appearance", "Floating", "Notifications", "Data Source", "About" };
            _pages.Add(BuildGeneralPage());
            _pages.Add(BuildAppearancePage());
            _pages.Add(BuildFloatingPage());
            _pages.Add(BuildNotificationsPage());
            _pages.Add(BuildDataSourcePage());
            _pages.Add(BuildAboutPage());

            for (int i = 0; i < names.Length; i++)
            {
                int captured = i;
                var item = new Label();
                item.Text = "   " + names[i];
                item.Dock = DockStyle.Top;
                item.Height = 38;
                item.TextAlign = ContentAlignment.MiddleLeft;
                item.ForeColor = Theme.TextSecondary;
                item.BackColor = Theme.BgPanel;
                item.Font = Theme.Ui(14, FontStyle.Regular);
                item.Cursor = Cursors.Hand;
                item.Click += delegate { SelectPage(captured); };
                _navItems.Add(item);
            }
            // Docked-top controls stack in reverse insertion order.
            for (int i = _navItems.Count - 1; i >= 0; i--) nav.Controls.Add(_navItems[i]);

            for (int i = 0; i < _pages.Count; i++)
            {
                _pages[i].Dock = DockStyle.Fill;
                _pages[i].Visible = false;
                _content.Controls.Add(_pages[i]);
            }
            Windowing.CenterOnPrimary(this);
            SelectPage(0);
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            Windowing.BringToFront(this);
        }

        private void SelectPage(int index)
        {
            for (int i = 0; i < _navItems.Count; i++)
            {
                bool active = i == index;
                _navItems[i].BackColor = active ? Theme.BgRaised : Theme.BgPanel;
                _navItems[i].ForeColor = active ? Theme.TextPrimary : Theme.TextSecondary;
                _pages[i].Visible = active;
            }
        }

        // ------------------------------------------------------------- pages

        private Panel BuildGeneralPage()
        {
            var page = NewPage();
            var layout = new Stacker(page);

            layout.Header("Polling");
            layout.NumberRow("Poll interval", 30, 300, 5, (decimal)_settings.PollInterval, "s",
                delegate(decimal value)
                {
                    _settings.PollInterval = (double)value;
                    _daemon.PollInterval = (double)value;
                    _settings.Save();
                },
                delegate { return Defaults.PollInterval; });
            layout.Caption("Costs about 1 Haiku token per poll. Defaults to 60s; minimum 30s.");

            layout.Header("Startup");
            layout.CheckRow("Launch ClawdBar at login", LaunchAtLogin.IsEnabled,
                delegate(bool value)
                {
                    bool ok = LaunchAtLogin.SetEnabled(value);
                    _settings.LaunchAtLogin = ok ? value : LaunchAtLogin.IsEnabled;
                    _settings.Save();
                    return _settings.LaunchAtLogin;
                });
            layout.Caption("Adds a value under HKCU\\...\\CurrentVersion\\Run pointing at this .exe. " +
                           "Moving or renaming the .exe breaks it — re-toggle after moving.");
            return page;
        }

        private Panel BuildAppearancePage()
        {
            var page = NewPage();
            var layout = new Stacker(page);

            layout.Header("Tray icon");
            var styles = new List<string>();
            var styleValues = new List<TrayStyle>();
            foreach (TrayStyle style in Enum.GetValues(typeof(TrayStyle)))
            {
                styles.Add(AppSettings.DisplayName(style));
                styleValues.Add(style);
            }
            layout.ComboRow("Icon style", styles, styleValues.IndexOf(_settings.TrayStyle),
                delegate(int index)
                {
                    _settings.TrayStyle = styleValues[index];
                    _settings.Save();
                    if (_onSettingsChanged != null) _onSettingsChanged();
                });
            layout.Caption("A Windows tray slot is square, so each style is redrawn to fit. " +
                           "The full 5h / 7d numbers always live in the tooltip.");

            layout.Header("Mascot");
            layout.CheckRow("Show mascot in the overlay", _settings.ShowMascot,
                delegate(bool value)
                {
                    _settings.ShowMascot = value;
                    _settings.Save();
                    if (_onSettingsChanged != null) _onSettingsChanged();
                    return value;
                });
            return page;
        }

        private Panel BuildFloatingPage()
        {
            var page = NewPage();
            var layout = new Stacker(page);

            layout.Header("Floating window");
            layout.CheckRow("Show floating window on launch", _settings.OverlayEnabledOnLaunch,
                delegate(bool value) { _settings.OverlayEnabledOnLaunch = value; _settings.Save(); return value; });

            layout.NumberRow("Opacity", 20, 100, 5, (decimal)Math.Round(_settings.OverlayOpacity * 100), "%",
                delegate(decimal value)
                {
                    _settings.OverlayOpacity = (double)value / 100.0;
                    _settings.Save();
                    if (_onSettingsChanged != null) _onSettingsChanged();
                },
                delegate { return Defaults.OverlayOpacity * 100; });

            layout.CheckRow("Click-through (overlay ignores the mouse)", _settings.OverlayClickThrough,
                delegate(bool value)
                {
                    _settings.OverlayClickThrough = value;
                    _settings.Save();
                    if (_onSettingsChanged != null) _onSettingsChanged();
                    return value;
                });

            var corners = new List<string>();
            var cornerValues = new List<SnapCorner>();
            foreach (SnapCorner corner in Enum.GetValues(typeof(SnapCorner)))
            {
                corners.Add(AppSettings.DisplayName(corner));
                cornerValues.Add(corner);
            }
            layout.ComboRow("Default corner on first show", corners, cornerValues.IndexOf(_settings.OverlayDefaultCorner),
                delegate(int index) { _settings.OverlayDefaultCorner = cornerValues[index]; _settings.Save(); });

            layout.CheckRow("Lock window size (no resize)", _settings.OverlayLocked,
                delegate(bool value)
                {
                    _settings.OverlayLocked = value;
                    _settings.Save();
                    if (_onSettingsChanged != null) _onSettingsChanged();
                    return value;
                });
            layout.Caption("When unlocked, drag the grip in the overlay's bottom-right corner. " +
                           "Size is clamped between 140 and 320 px.");

            layout.ButtonRow("Reset to default size (200 x 200)", delegate
            {
                if (_onResetOverlaySize != null) _onResetOverlaySize();
            });
            layout.Caption("The default is deliberately watch-sized — small and unobtrusive.");
            return page;
        }

        private Panel BuildNotificationsPage()
        {
            var page = NewPage();
            var layout = new Stacker(page);

            layout.Header("Alerts");
            layout.CheckRow("Enable threshold alerts", _settings.NotificationsEnabled,
                delegate(bool value) { _settings.NotificationsEnabled = value; _settings.Save(); return value; });
            layout.Caption("Delivered as tray balloon notifications. Windows shows them in the " +
                           "Action Center; if nothing appears, check Focus Assist.");

            layout.Header("Thresholds");
            layout.NumberRow("Warning at", 50, 95, 1, (decimal)_settings.WarningThreshold, "%",
                delegate(decimal value) { _settings.WarningThreshold = (double)value; _settings.Save(); },
                delegate { return Defaults.WarningThreshold; });
            layout.NumberRow("Critical at", 80, 100, 1, (decimal)_settings.CriticalThreshold, "%",
                delegate(decimal value) { _settings.CriticalThreshold = (double)value; _settings.Save(); },
                delegate { return Defaults.CriticalThreshold; });

            layout.Header("Windows");
            layout.CheckRow("Alert on 5h (session) crossings", _settings.NotifyForSession,
                delegate(bool value) { _settings.NotifyForSession = value; _settings.Save(); return value; });
            layout.CheckRow("Alert on 7d (weekly) crossings", _settings.NotifyForWeekly,
                delegate(bool value) { _settings.NotifyForWeekly = value; _settings.Save(); return value; });
            layout.CheckRow("Play sound", _settings.NotificationSound,
                delegate(bool value) { _settings.NotificationSound = value; _settings.Save(); return value; });
            return page;
        }

        private Panel BuildDataSourcePage()
        {
            var page = NewPage();
            var layout = new Stacker(page);

            layout.Header("Credentials");
            string source = _daemon.CredentialSource;
            layout.InfoRow("Source", string.IsNullOrEmpty(source) ? "Not read yet" : source);
            layout.InfoRow("Expected path", CredentialStore.DefaultFilePath);
            layout.Caption("Claude Code on Windows stores its OAuth token in that file. " +
                           "Windows Credential Manager (\"" + CredentialStore.CredentialManagerTarget +
                           "\") is checked as a fallback.");

            layout.Header("Connection");
            _testButton = layout.ButtonRow("Test connection", null);
            _testButton.Click += OnTestConnection;

            Button reread = layout.ButtonRow("Re-read credentials", null);
            reread.Click += delegate
            {
                _daemon.InvalidateCredentials();
                OnTestConnection(this, EventArgs.Empty);
            };

            _testResult = layout.Caption("");

            layout.Header("Advanced");
            layout.TextRow("API base URL", _settings.ApiBaseUrl,
                delegate(string value) { _settings.ApiBaseUrl = value; _settings.Save(); });
            layout.TextRow("Model", _settings.ApiModel,
                delegate(string value) { _settings.ApiModel = value; _settings.Save(); });
            layout.Caption("Restart ClawdBar after editing these.");
            return page;
        }

        private async void OnTestConnection(object sender, EventArgs e)
        {
            _testButton.Enabled = false;
            _testResult.ForeColor = Theme.TextSecondary;
            _testResult.Text = "Testing...";
            try
            {
                await _daemon.RefreshNowAsync();
                if (_daemon.LastError != null)
                {
                    _testResult.ForeColor = Theme.ColorFor(Severity.Critical);
                    _testResult.Text = "Failed: " + _daemon.LastError;
                }
                else if (_daemon.Usage.SessionPercent.HasValue || _daemon.Usage.WeeklyPercent.HasValue)
                {
                    _testResult.ForeColor = Theme.ColorFor(Severity.Ok);
                    _testResult.Text = "OK - session " + Percent(_daemon.Usage.DisplaySessionPercent) +
                        ", weekly " + Percent(_daemon.Usage.DisplayWeeklyPercent) + ".";
                }
                else
                {
                    _testResult.ForeColor = Theme.AccentWarm;
                    _testResult.Text = "Connected, but the response carried no usage headers.";
                }
            }
            finally
            {
                _testButton.Enabled = true;
            }
        }

        private static string Percent(int? value)
        {
            return value.HasValue ? value.Value.ToString(CultureInfo.InvariantCulture) + "%" : "-";
        }

        private Panel BuildAboutPage()
        {
            var page = NewPage();

            var art = new Panel();
            art.Height = 80;
            art.Dock = DockStyle.Top;
            art.BackColor = Theme.BgDeep;
            art.Paint += delegate(object sender, PaintEventArgs e)
            {
                Draw.HighQuality(e.Graphics);
                Mascot.Draw(e.Graphics, new RectangleF(0, 8, 64, 64), Mood.Focused, MascotState.Chill,
                    Clock.AnimationSeconds(), false, Theme.MascotTan);
            };

            var layout = new Stacker(page);
            layout.Header("ClawdBar for Windows");
            layout.Caption("Version 0.1 — a Windows port of ClawdBar by rauppvj (MIT).");
            layout.Caption("Unofficial. Not affiliated with Anthropic.");
            layout.Caption("Each poll spends approximately one Haiku-tier token against your " +
                           "Anthropic account — on the order of US$0.0001/day at the default interval.");
            layout.Caption("The OAuth token is read locally and only ever sent to the configured API host. " +
                           "No telemetry, no analytics.");
            layout.InfoRow("History file", UsageHistoryStore.DefaultPath);
            layout.InfoRow("Settings file", AppSettings.FilePath);

            Button link = layout.ButtonRow("Open the original project on GitHub", null);
            link.Click += delegate
            {
                try { Process.Start("https://github.com/rauppvj/clawdbar"); } catch { }
            };

            Button reset = layout.ButtonRow("Reset preferences and quit...", null);
            reset.Click += delegate
            {
                DialogResult answer = MessageBox.Show(this,
                    "Clears every ClawdBar preference and quits. Relaunch to see onboarding again.\r\n\r\n" +
                    "Your Claude Code credentials and your usage history are untouched.",
                    "Reset preferences?", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
                if (answer != DialogResult.OK) return;
                AppSettings.DeleteStoredSettings();
                LaunchAtLogin.SetEnabled(false);
                Application.Exit();
            };

            page.Controls.Add(art);
            art.BringToFront();
            return page;
        }

        private static Panel NewPage()
        {
            var page = new Panel();
            page.BackColor = Theme.BgDeep;
            page.AutoScroll = true;
            return page;
        }
    }

    /// Tiny vertical layout helper. Docked-top controls stack in reverse
    /// insertion order in WinForms, so this keeps an explicit cursor instead
    /// and positions everything absolutely.
    internal sealed class Stacker
    {
        private readonly Panel _host;
        private int _y = 4;
        private const int LabelWidth = 250;
        private const int RowHeight = 30;
        private const int ControlX = 260;

        public Stacker(Panel host)
        {
            _host = host;
        }

        public void Header(string text)
        {
            if (_y > 4) _y += 12;
            var label = new Label();
            label.Text = text.ToUpperInvariant();
            label.Font = Theme.Ui(12, FontStyle.Bold);
            label.ForeColor = Theme.AccentWarm;
            label.AutoSize = true;
            label.Location = new Point(0, _y);
            label.BackColor = Color.Transparent;
            _host.Controls.Add(label);
            _y += 24;
        }

        public Label Caption(string text)
        {
            var label = new Label();
            label.Text = text;
            label.Font = Theme.Ui(12, FontStyle.Regular);
            label.ForeColor = Theme.TextMuted;
            label.Location = new Point(0, _y);
            label.Size = new Size(430, 0);
            label.AutoSize = true;
            label.MaximumSize = new Size(430, 0);
            label.BackColor = Color.Transparent;
            _host.Controls.Add(label);
            _y += Math.Max(18, label.PreferredHeight) + 8;
            return label;
        }

        public void InfoRow(string label, string value)
        {
            AddLabel(label);
            var box = new TextBox();
            box.Text = value;
            box.ReadOnly = true;
            box.BorderStyle = BorderStyle.FixedSingle;
            box.BackColor = Theme.BgPanel;
            box.ForeColor = Theme.TextSecondary;
            box.Font = Theme.Mono(12, FontStyle.Regular);
            box.Location = new Point(ControlX, _y - 2);
            box.Width = 170;
            _host.Controls.Add(box);
            _y += RowHeight;
        }

        public CheckBox CheckRow(string label, bool initial, Func<bool, bool> onChange)
        {
            var box = new CheckBox();
            box.Text = label;
            box.Checked = initial;
            box.ForeColor = Theme.TextPrimary;
            box.BackColor = Color.Transparent;
            box.Font = Theme.Ui(13, FontStyle.Regular);
            box.FlatStyle = FlatStyle.Flat;
            box.AutoSize = true;
            box.Location = new Point(0, _y);
            bool guard = false;
            box.CheckedChanged += delegate
            {
                if (guard) return;
                bool applied = onChange(box.Checked);
                if (applied != box.Checked)
                {
                    guard = true;
                    box.Checked = applied;
                    guard = false;
                }
            };
            _host.Controls.Add(box);
            _y += RowHeight;
            return box;
        }

        public NumericUpDown NumberRow(string label, int min, int max, int step, decimal initial,
            string unit, Action<decimal> onChange, Func<double> defaultValue)
        {
            AddLabel(label + (string.IsNullOrEmpty(unit) ? "" : " (" + unit + ")"));

            var spin = new NumericUpDown();
            spin.Minimum = min;
            spin.Maximum = max;
            spin.Increment = step;
            spin.Value = Math.Max(min, Math.Min(max, initial));
            spin.BackColor = Theme.BgPanel;
            spin.ForeColor = Theme.TextPrimary;
            spin.BorderStyle = BorderStyle.FixedSingle;
            spin.Font = Theme.Ui(13, FontStyle.Regular);
            spin.Location = new Point(ControlX, _y - 2);
            spin.Width = 90;
            spin.ValueChanged += delegate { onChange(spin.Value); };
            _host.Controls.Add(spin);

            AddResetButton(delegate
            {
                decimal value = (decimal)defaultValue();
                spin.Value = Math.Max(min, Math.Min(max, value));
            });

            _y += RowHeight;
            return spin;
        }

        public ComboBox ComboRow(string label, List<string> items, int selected, Action<int> onChange)
        {
            AddLabel(label);
            var combo = new ComboBox();
            combo.DropDownStyle = ComboBoxStyle.DropDownList;
            combo.FlatStyle = FlatStyle.Flat;
            combo.BackColor = Theme.BgPanel;
            combo.ForeColor = Theme.TextPrimary;
            combo.Font = Theme.Ui(13, FontStyle.Regular);
            combo.Location = new Point(ControlX, _y - 3);
            combo.Width = 150;
            for (int i = 0; i < items.Count; i++) combo.Items.Add(items[i]);
            combo.SelectedIndex = selected < 0 ? 0 : selected;
            combo.SelectedIndexChanged += delegate { onChange(combo.SelectedIndex); };
            _host.Controls.Add(combo);
            _y += RowHeight;
            return combo;
        }

        public TextBox TextRow(string label, string initial, Action<string> onChange)
        {
            AddLabel(label);
            var box = new TextBox();
            box.Text = initial;
            box.BorderStyle = BorderStyle.FixedSingle;
            box.BackColor = Theme.BgPanel;
            box.ForeColor = Theme.TextPrimary;
            box.Font = Theme.Mono(12, FontStyle.Regular);
            box.Location = new Point(ControlX, _y - 2);
            box.Width = 170;
            box.TextChanged += delegate { onChange(box.Text); };
            _host.Controls.Add(box);
            _y += RowHeight;
            return box;
        }

        public Button ButtonRow(string text, Action onClick)
        {
            var button = new Button();
            button.Text = text;
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderColor = Theme.Stroke;
            button.BackColor = Theme.BgPanel;
            button.ForeColor = Theme.TextPrimary;
            button.Font = Theme.Ui(13, FontStyle.Regular);
            button.AutoSize = true;
            button.Padding = new Padding(10, 4, 10, 4);
            button.Location = new Point(0, _y - 2);
            if (onClick != null) button.Click += delegate { onClick(); };
            _host.Controls.Add(button);
            _y += RowHeight + 4;
            return button;
        }

        private void AddLabel(string text)
        {
            var label = new Label();
            label.Text = text;
            label.Font = Theme.Ui(13, FontStyle.Regular);
            label.ForeColor = Theme.TextPrimary;
            label.BackColor = Color.Transparent;
            label.Location = new Point(0, _y + 2);
            label.Size = new Size(LabelWidth, 20);
            _host.Controls.Add(label);
        }

        /// Per-row "back to default" affordance, matching the macOS build's
        /// little revert arrows.
        private void AddResetButton(Action onClick)
        {
            var button = new Button();
            button.Text = "↺";
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderColor = Theme.Stroke;
            button.BackColor = Theme.BgPanel;
            button.ForeColor = Theme.TextSecondary;
            button.Font = Theme.Ui(13, FontStyle.Regular);
            button.Size = new Size(28, 24);
            button.Location = new Point(ControlX + 100, _y - 2);
            button.Click += delegate { onClick(); };
            _host.Controls.Add(button);
        }
    }
}
