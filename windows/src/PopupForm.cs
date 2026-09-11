using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace ClawdBar
{
    /// A clickable region inside a custom-painted form. WinForms controls
    /// would each bring their own themed background, so the popup and the
    /// overlay hit-test hand-drawn rectangles instead.
    internal sealed class HitButton
    {
        public RectangleF Bounds;
        public string Glyph;
        public string Tooltip;
        public Action OnClick;
        public bool Enabled;

        public HitButton(string glyph, string tooltip, Action onClick)
        {
            Glyph = glyph;
            Tooltip = tooltip;
            OnClick = onClick;
            Enabled = true;
        }
    }

    internal static class Glyphs
    {
        // Segoe MDL2 Assets ships with Windows 10/11.
        public const string Refresh = "";
        public const string Overlay = "";
        public const string Gear = "";
        public const string Power = "";
        public const string ChevronLeft = "";
        public const string ChevronRight = "";

        /// "OpenInNewWindow" — the affordance that leaves for status.claude.com.
        public const string OpenExternal = "";

        public static Font Font(float size)
        {
            try
            {
                return new Font("Segoe MDL2 Assets", size, FontStyle.Regular, GraphicsUnit.Pixel);
            }
            catch
            {
                return Theme.Ui(size, FontStyle.Bold);
            }
        }
    }

    /// The two secondary panels under the rate-limit bars. Token spend leads
    /// because it changes every session; service status is a page you only
    /// need on the rare day something is actually broken - but it carries a
    /// badge so a live incident still pulls the eye while it sits behind a tab.
    internal enum PopoverTab { Tokens, Status }

    /// Windows counterpart of PopoverView: the panel that opens from the tray
    /// icon. Same 340pt width and the same four action buttons as the macOS
    /// popover, redrawn with GDI+.
    internal sealed class PopupForm : Form
    {
        private const int PanelWidth = 340;
        /// Height without the tabbed panel. That block is added on top
        /// whenever at least one tab is enabled, because its size depends on
        /// how many rows status.claude.com is currently listing.
        private const int PanelBaseHeight = 306;

        private readonly UsageDaemon _daemon;
        private readonly StatusMonitor _status;
        private readonly TokenUsageMonitor _tokens;
        private readonly AppSettings _settings;
        private readonly Action _onToggleOverlay;
        private readonly Action _onOpenSettings;
        private readonly Action _onQuit;

        private readonly List<HitButton> _buttons = new List<HitButton>();
        /// Rebuilt on every paint: the plan pill's tooltip and the
        /// service-status affordances, which move with the snapshot.
        private readonly List<HitButton> _hotspots = new List<HitButton>();
        private readonly Timer _tick;
        private int _panelHeight = PanelBaseHeight;
        private readonly ToolTip _tips = new ToolTip();
        private HitButton _hovered;
        private int _moodPhase;

        /// Last known pointer position, or (-1, -1) when it left the panel.
        /// The token chart resolves its hovered column from this at paint time
        /// rather than from a cached HitButton: the hotspot list is rebuilt on
        /// every repaint, so a remembered button goes stale the moment the
        /// chart redraws.
        private Point _mouse = new Point(-1, -1);

        /// The panel closes as soon as it loses focus, the way a tray flyout
        /// should. The preview harness turns this off so the window can be
        /// inspected while something else holds focus.
        public bool AutoHideOnDeactivate = true;

        public PopupForm(UsageDaemon daemon, StatusMonitor status, TokenUsageMonitor tokens,
            AppSettings settings, Action onToggleOverlay, Action onOpenSettings, Action onQuit)
        {
            _daemon = daemon;
            _status = status;
            _tokens = tokens;
            _settings = settings;
            _onToggleOverlay = onToggleOverlay;
            _onOpenSettings = onOpenSettings;
            _onQuit = onQuit;

            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            ClientSize = new Size(PanelWidth, _panelHeight);
            BackColor = Theme.BgDeep;
            KeyPreview = true;
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);

            BuildButtons();

            _tick = new Timer();
            _tick.Interval = 600;
            _tick.Tick += delegate
            {
                _moodPhase = (_moodPhase + 1) % 4;
                Invalidate();
            };

            _daemon.Changed += OnDaemonChanged;
            if (_status != null) _status.Changed += OnSecondaryChanged;
            if (_tokens != null) _tokens.Changed += OnSecondaryChanged;
        }

        private void OnDaemonChanged(object sender, EventArgs e)
        {
            if (IsDisposed || !Visible) return;
            Invalidate();
        }

        /// A fresh snapshot can add or drop rows, so the panel is re-measured
        /// before it repaints. Shared by both secondary monitors.
        private void OnSecondaryChanged(object sender, EventArgs e)
        {
            if (IsDisposed) return;
            Relayout();
            if (Visible) Invalidate();
        }

        private void BuildButtons()
        {
            var refresh = new HitButton(Glyphs.Refresh, "Refresh", async delegate
            {
                Task status = _status != null && _status.IsPolling
                    ? _status.RefreshNowAsync()
                    : null;
                Task tokens = _tokens != null && _settings.TokenUsageEnabled
                    ? _tokens.RefreshNowAsync()
                    : null;
                await _daemon.RefreshNowAsync();
                if (status != null) await status;
                if (tokens != null) await tokens;
            });
            var overlay = new HitButton(Glyphs.Overlay, "Toggle floating window", delegate
            {
                if (_onToggleOverlay != null) _onToggleOverlay();
            });
            var settings = new HitButton(Glyphs.Gear, "Preferences", delegate
            {
                Hide();
                if (_onOpenSettings != null) _onOpenSettings();
            });
            var quit = new HitButton(Glyphs.Power, "Quit ClawdBar", delegate
            {
                if (_onQuit != null) _onQuit();
            });

            _buttons.Add(refresh);
            _buttons.Add(overlay);
            _buttons.Add(settings);
            _buttons.Add(quit);

            PositionButtons();
        }

        private void PositionButtons()
        {
            float y = _panelHeight - 36;
            float x = 8;
            for (int i = 0; i < 3; i++)
            {
                _buttons[i].Bounds = new RectangleF(x, y, 30, 28);
                x += 34;
            }
            _buttons[3].Bounds = new RectangleF(PanelWidth - 38, y, 30, 28);
        }

        /// Re-measures the panel around the current status snapshot. While the
        /// panel is open it grows upwards, so the action row stays where the
        /// cursor left it instead of sliding under the taskbar.
        private void Relayout()
        {
            int height = PanelBaseHeight + PanelBlockHeight();
            if (height == _panelHeight) return;

            int delta = height - _panelHeight;
            _panelHeight = height;
            ClientSize = new Size(PanelWidth, _panelHeight);
            PositionButtons();

            if (!Visible) return;
            Rectangle work = Screen.FromControl(this).WorkingArea;
            int top = Location.Y - delta;
            if (top + _panelHeight > work.Bottom - 4) top = work.Bottom - _panelHeight - 4;
            if (top < work.Top + 4) top = work.Top + 4;
            Location = new Point(Location.X, top);
        }

        /// Positions the panel next to the tray, adapting to whichever screen
        /// edge the taskbar is docked on.
        public async void ShowNearTray()
        {
            Relayout();
            Point cursor = Cursor.Position;
            Screen screen = Screen.FromPoint(cursor);
            Rectangle work = screen.WorkingArea;
            Rectangle full = screen.Bounds;

            int x = cursor.X - PanelWidth / 2;
            int y;

            if (work.Bottom < full.Bottom) y = work.Bottom - _panelHeight - 8;         // taskbar at bottom
            else if (work.Top > full.Top) y = work.Top + 8;                            // taskbar at top
            else if (work.Right < full.Right) { x = work.Right - PanelWidth - 8; y = cursor.Y - _panelHeight / 2; }
            else if (work.Left > full.Left) { x = work.Left + 8; y = cursor.Y - _panelHeight / 2; }
            else y = work.Bottom - _panelHeight - 8;

            if (x < work.Left + 4) x = work.Left + 4;
            if (x + PanelWidth > work.Right - 4) x = work.Right - PanelWidth - 4;
            if (y < work.Top + 4) y = work.Top + 4;
            if (y + _panelHeight > work.Bottom - 4) y = work.Bottom - _panelHeight - 4;

            Location = new Point(x, y);
            _tick.Start();
            Show();
            Activate();
            Invalidate();

            // Opening the panel is the moment the answer matters most, so top
            // the snapshots up; RefreshIfStale coalesces repeated opens.
            SurfaceIncidentIfNeeded();
            if (_tokens != null && _settings.TokenUsageEnabled) await _tokens.RefreshIfStaleAsync(30);
            if (_status != null && _status.IsPolling) await _status.RefreshIfStaleAsync(60);
        }

        /// Pop the status panel to the front when something is actually wrong.
        /// Only on open, and only for a live problem - otherwise the tab the
        /// user chose last wins.
        private void SurfaceIncidentIfNeeded()
        {
            if (!AvailableTabs().Contains(PopoverTab.Status)) return;
            if (_status.Status == null || ServiceLevels.IsHealthy(_status.Status.WorstLevel)) return;
            SelectTab(PopoverTab.Status);
        }

        /// ShowNearTray measures the panel before placing it, but the preview
        /// harness (and any future caller) shows the form directly — measure
        /// here too so the status block is never clipped.
        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            if (Visible) Relayout();
        }

        protected override void OnDeactivate(EventArgs e)
        {
            base.OnDeactivate(e);
            if (!AutoHideOnDeactivate) return;
            _tick.Stop();
            Hide();
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Escape)
            {
                Hide();
                return;
            }
            if (e.Control && e.KeyCode == Keys.R) { _buttons[0].OnClick(); e.Handled = true; }
            if (e.Control && e.KeyCode == Keys.Q) { _buttons[3].OnClick(); e.Handled = true; }
            if (e.Control && e.KeyCode == Keys.Oemcomma) { _buttons[2].OnClick(); e.Handled = true; }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            _mouse = e.Location;

            HitButton found = Hit(e.Location);
            if (!ReferenceEquals(found, _hovered))
            {
                _hovered = found;
                _tips.SetToolTip(this, found == null ? null : found.Tooltip);
                Cursor = found == null || found.OnClick == null ? Cursors.Default : Cursors.Hand;
                Invalidate();
                return;
            }
            // The chart readout follows the pointer across a single column,
            // which no HitButton transition would report.
            if (SelectedTab == PopoverTab.Tokens) Invalidate();
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            _mouse = new Point(-1, -1);
            Invalidate();
        }

        protected override void OnMouseClick(MouseEventArgs e)
        {
            base.OnMouseClick(e);
            HitButton hit = Hit(e.Location);
            if (hit == null || !hit.Enabled || hit.OnClick == null) return;
            hit.OnClick();
            Invalidate();
        }

        /// Action buttons first, then whatever the last paint left behind — the
        /// two never overlap, and this keeps the fixed row authoritative.
        private HitButton Hit(Point location)
        {
            for (int i = 0; i < _buttons.Count; i++)
            {
                if (_buttons[i].Bounds.Contains(location)) return _buttons[i];
            }
            for (int i = 0; i < _hotspots.Count; i++)
            {
                if (_hotspots[i].Bounds.Contains(location)) return _hotspots[i];
            }
            return null;
        }

        private HitButton AddHotspot(RectangleF bounds, string tooltip, Action onClick)
        {
            var hotspot = new HitButton(null, tooltip, onClick);
            hotspot.Bounds = bounds;
            _hotspots.Add(hotspot);
            return hotspot;
        }

        public static void OpenInBrowser(string url)
        {
            try { Process.Start(url); } catch { }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Draw.HighQuality(g);
            g.Clear(Theme.BgDeep);

            _hotspots.Clear();

            UsageData usage = _daemon.Usage;
            float y = 14;

            y = PaintHeader(g, usage, y);
            PaintDivider(g, y);
            y += 1;

            y += 14;
            y = PaintStatusRow(g, y, "CURRENT  ·  5H", usage.SessionPercent,
                usage.SessionSeverity, usage.SessionResetAt, usage.IsStale);
            y += 16;
            y = PaintStatusRow(g, y, "WEEKLY  ·  7D", usage.WeeklyPercent,
                usage.WeeklySeverity, usage.WeeklyResetAt, usage.IsStale);
            y += 14;

            PaintFooter(g, usage, y);

            // The tabbed panel is anchored to the bottom, right above the
            // action row, so the usage half of the panel never moves.
            int block = PanelBlockHeight();
            if (block > 0)
            {
                float top = _panelHeight - 45 - block;
                PaintDivider(g, top);
                PaintPanelBlock(g, top + 12);
            }

            PaintDivider(g, _panelHeight - 45);
            PaintActionRow(g);
        }

        private float PaintHeader(Graphics g, UsageData usage, float y)
        {
            const float left = 16;
            Color dot = Theme.ColorFor(usage.WorstSeverity);

            using (var glow = new SolidBrush(Theme.Fade(dot, 0.25)))
            {
                g.FillEllipse(glow, left - 3, y + 1, 14, 14);
            }
            using (var brush = new SolidBrush(dot))
            {
                g.FillEllipse(brush, left, y + 4, 8, 8);
            }

            Font titleFont = Theme.Retro(14);
            float x = left + 16;
            Draw.TrackedString(g, "USAGE", titleFont, Theme.TextPrimary, x, y, 3f);
            x += Draw.MeasureTracked(g, "USAGE", titleFont, 3f) + 8;

            string plan = PlanLabel();
            if (plan != null)
            {
                float badgeRight = PaintBadge(g, plan, x, y + 1, Theme.Fade(Theme.AccentWarm, 0.15), Theme.AccentWarm);
                AddHotspot(new RectangleF(x, y, badgeRight - x, 18), PlanBadge.Help, null);
                x = badgeRight + 6;
            }
            string binding = BindingLabel();
            if (binding != null)
            {
                x = PaintBadge(g, binding, x, y + 1, Theme.BgRaised, Theme.AccentCool) + 6;
            }

            if (_daemon.IsFetching)
            {
                PaintSpinner(g, new RectangleF(PanelWidth - 28, y + 2, 12, 12));
            }

            return y + 18 + 10;
        }

        private float PaintBadge(Graphics g, string text, float x, float y, Color background, Color foreground)
        {
            Font font = Theme.Retro(9);
            SizeF size = Draw.Measure(g, text, font);
            var rect = new RectangleF(x, y, size.Width + 12, size.Height + 4);
            Draw.FillRounded(g, rect, rect.Height / 2f, background);
            Draw.String(g, text, font, foreground, x + 6, y + 2);
            return rect.Right;
        }

        private void PaintSpinner(Graphics g, RectangleF bounds)
        {
            float sweep = (Environment.TickCount / 3) % 360;
            using (var pen = new Pen(Theme.AccentWarm, 2f))
            {
                g.DrawArc(pen, bounds.X, bounds.Y, bounds.Width, bounds.Height, sweep, 100);
            }
        }

        private void PaintDivider(Graphics g, float y)
        {
            using (var pen = new Pen(Theme.Stroke, 1f))
            {
                g.DrawLine(pen, 0, y, PanelWidth, y);
            }
        }

        private float PaintStatusRow(Graphics g, float y, string title, double? percent,
            Severity severity, DateTime? resetAt, bool isStale)
        {
            const float left = 16;
            const float right = PanelWidth - 16;

            Font labelFont = Theme.Retro(10);
            Draw.TrackedString(g, title, labelFont, Theme.TextSecondary, left, y, 2f);

            string caption = ResetCaption(resetAt);
            float captionWidth = Draw.MeasureTracked(g, caption, labelFont, 0.5f);
            Draw.TrackedString(g, caption, labelFont, Theme.TextMuted, right - captionWidth, y, 0.5f);

            y += 8 + Draw.Measure(g, title, labelFont).Height;

            string big = percent.HasValue
                ? ((int)Math.Round(percent.Value)).ToString(CultureInfo.InvariantCulture)
                : "––";
            Font bigFont = Theme.Retro(34);
            Color bigColor = isStale ? Theme.TextMuted : Theme.ColorFor(severity);
            Draw.String(g, big, bigFont, bigColor, left, y);
            SizeF bigSize = Draw.Measure(g, big, bigFont);

            Font pctFont = Theme.Retro(16);
            Draw.String(g, "%", pctFont, Theme.TextSecondary, left + bigSize.Width + 6,
                y + bigSize.Height - Draw.Measure(g, "%", pctFont).Height - 2);

            y += bigSize.Height + 8;

            Draw.UsageBar(g, new RectangleF(left, y, right - left, 8), percent, severity, isStale ? 0.5 : 1.0);
            return y + 8;
        }

        private void PaintFooter(Graphics g, UsageData usage, float y)
        {
            const float left = 16;
            string mood = "* " + Moods.Label(usage.Mood, DateTime.UtcNow) + new string('.', _moodPhase);
            Draw.String(g, mood, Theme.Retro(11), Theme.AccentWarm, left, y);

            Font small = Theme.Retro(9);
            if (_daemon.LastFetchAtUtc.HasValue)
            {
                string text = "upd " + TimeAgo(_daemon.LastFetchAtUtc.Value);
                float width = Draw.Measure(g, text, small).Width;
                Draw.String(g, text, small, Theme.TextMuted, PanelWidth - 16 - width, y + 2);
            }
            else if (_daemon.LastError != null)
            {
                string text = TrayIconRenderer.ShortError(_daemon.LastError);
                float width = Draw.Measure(g, text, small).Width;
                Draw.String(g, text, small, Theme.ColorFor(Severity.Critical), PanelWidth - 16 - width, y + 2);
            }
        }

        private void PaintActionRow(Graphics g)
        {
            Font glyphFont = Glyphs.Font(13);
            for (int i = 0; i < _buttons.Count; i++)
            {
                HitButton button = _buttons[i];
                bool hot = ReferenceEquals(button, _hovered);
                Draw.FillRounded(g, button.Bounds, 6, hot ? Theme.BgRaised : Theme.BgPanel);

                SizeF size = Draw.Measure(g, button.Glyph, glyphFont);
                Draw.String(g, button.Glyph, glyphFont,
                    button.Enabled ? Theme.TextPrimary : Theme.TextMuted,
                    button.Bounds.X + (button.Bounds.Width - size.Width) / 2f,
                    button.Bounds.Y + (button.Bounds.Height - size.Height) / 2f);
            }
        }

        // ------------------------------------------------------ tabbed panel

        private const int TabStripHeight = 22;

        /// Tokens first: it moves every session. Service status only earns a
        /// slot when the user has polling on at all.
        private List<PopoverTab> AvailableTabs()
        {
            var tabs = new List<PopoverTab>();
            if (_tokens != null && _settings.TokenUsageEnabled) tabs.Add(PopoverTab.Tokens);
            if (_status != null && _status.IsPolling) tabs.Add(PopoverTab.Status);
            return tabs;
        }

        private PopoverTab SelectedTab
        {
            get
            {
                List<PopoverTab> tabs = AvailableTabs();
                PopoverTab stored = _settings.PopoverTab == "status"
                    ? PopoverTab.Status
                    : PopoverTab.Tokens;
                if (tabs.Contains(stored)) return stored;
                return tabs.Count > 0 ? tabs[0] : PopoverTab.Tokens;
            }
        }

        private void SelectTab(PopoverTab tab)
        {
            string name = tab == PopoverTab.Status ? "status" : "tokens";
            if (_settings.PopoverTab == name) return;
            _settings.PopoverTab = name;
            _settings.Save();
            Relayout();
            Invalidate();
        }

        /// How much room the tabbed panel needs - 0 when both features are off.
        ///
        /// Both panels are measured and the taller one wins, even though only
        /// one is drawn. The macOS build stacks them in a ZStack for the same
        /// reason: a height that followed the selected tab would move the whole
        /// panel on every switch, and here the panel grows upwards, so the
        /// action row would slide out from under the cursor.
        private int PanelBlockHeight()
        {
            List<PopoverTab> tabs = AvailableTabs();
            if (tabs.Count == 0) return 0;

            int body = 0;
            for (int i = 0; i < tabs.Count; i++)
            {
                int height = tabs[i] == PopoverTab.Tokens ? TokenBodyHeight() : StatusBodyHeight();
                if (height > body) body = height;
            }
            return 12 + (tabs.Count > 1 ? TabStripHeight : 0) + body + 12;
        }

        private void PaintPanelBlock(Graphics g, float y)
        {
            List<PopoverTab> tabs = AvailableTabs();
            if (tabs.Count == 0) return;

            if (tabs.Count > 1)
            {
                PaintTabStrip(g, y, tabs);
                y += TabStripHeight;
            }
            if (SelectedTab == PopoverTab.Tokens) PaintTokenUsage(g, y);
            else PaintServiceStatus(g, y);
        }

        /// Titles with an underline under the active one, and a dot beside
        /// SERVICE whenever the status page is not all-green - the whole point
        /// of demoting that panel is that you should not have to go looking,
        /// so the tab has to come find you.
        private void PaintTabStrip(Graphics g, float y, List<PopoverTab> tabs)
        {
            const float left = 16;
            Font font = Theme.Retro(9, FontStyle.Bold);

            float x = left;
            for (int i = 0; i < tabs.Count; i++)
            {
                PopoverTab tab = tabs[i];
                bool active = tab == SelectedTab;
                string title = tab == PopoverTab.Tokens ? "TOKENS" : "SERVICE";
                float width = Draw.MeasureTracked(g, title, font, 1.5f);

                Draw.TrackedString(g, title, font,
                    active ? Theme.TextPrimary : Theme.TextMuted, x, y, 1.5f);

                float end = x + width;
                Color badge;
                if (TabBadge(tab, out badge))
                {
                    using (var glow = new SolidBrush(Theme.Fade(badge, 0.4)))
                    {
                        g.FillEllipse(glow, end + 1, y + 1, 9, 9);
                    }
                    using (var brush = new SolidBrush(badge))
                    {
                        g.FillEllipse(brush, end + 3, y + 3, 5, 5);
                    }
                    end += 11;
                }

                if (active)
                {
                    using (var brush = new SolidBrush(Theme.AccentWarm))
                    {
                        g.FillRectangle(brush, x, y + 14, width, 2);
                    }
                }

                PopoverTab chosen = tab;
                AddHotspot(new RectangleF(x - 4, y - 3, end - x + 8, 21), null,
                    delegate { SelectTab(chosen); });
                x = end + 16;
            }
        }

        private bool TabBadge(PopoverTab tab, out Color color)
        {
            color = Theme.TextMuted;
            if (tab != PopoverTab.Status || _status == null || _status.Status == null) return false;
            ServiceLevel worst = _status.Status.WorstLevel;
            if (ServiceLevels.IsHealthy(worst)) return false;
            color = Theme.ColorFor(worst);
            return true;
        }

        // ------------------------------------------------------- token spend

        private const int TokenLabelHeight = 16;
        private const int TokenBigHeight = 30;
        private const int TokenCaptionHeight = 13;
        private const int TokenChartHeight = 44;
        private const int TokenAxisHeight = 16;
        private const int TokenReadoutHeight = 16;

        /// Fixed height: the chart is 7 or 30 columns either way, and the
        /// empty state is shorter than the chart it stands in for. Reserving
        /// the full box means the first scan landing does not resize the panel
        /// under the pointer.
        private int TokenBodyHeight()
        {
            return TokenLabelHeight + TokenBigHeight + TokenCaptionHeight +
                   TokenChartHeight + TokenAxisHeight + TokenReadoutHeight;
        }

        private int RangeDays
        {
            get { return _settings.TokenRange == "month" ? 30 : 7; }
        }

        private string RangeLabel
        {
            get { return RangeDays == 30 ? "30D" : "7D"; }
        }

        /// Daily token spend, read from Claude Code's own transcripts. Answers
        /// the question the rate-limit bars cannot: not "how close am I to the
        /// ceiling" but "how much did I actually burn today, and how does that
        /// compare to the last week or month".
        private void PaintTokenUsage(Graphics g, float y)
        {
            const float left = 16;
            const float right = PanelWidth - 16;

            List<DailyTokenUsage> series = _tokens.Summary.Window(RangeDays);
            DailyTokenUsage today = series.Count > 0
                ? series[series.Count - 1]
                : DailyTokenUsage.Empty(DateTime.Now.Date);

            // The label goes *above* the number, not under it: "23M" on its own
            // answers nothing, and the first question anyone asks of this panel
            // is "how much did I spend today".
            Draw.TrackedString(g, "TOKENS TODAY", Theme.Retro(9), Theme.TextSecondary, left, y, 2f);
            PaintRangePicker(g, right, y - 3);

            float headlineTop = y;
            y += TokenLabelHeight;

            // Cache reads run 97-99% of the raw total on agentic work: every
            // turn replays a context that was paid for once. Leading with that
            // number makes an ordinary day read as tens of millions of tokens,
            // which is true and useless. So the headline is input + output -
            // the same two counters the claude.ai chart plots - and the two
            // cache counters are named in the caption rather than hidden.
            Draw.String(g, TokenUsageFormat.Compact(today.Totals.Uncached),
                Theme.Retro(26), Theme.AccentWarm, left, y);

            Font small = Theme.Retro(8);
            if (_tokens.IsScanning)
            {
                PaintSpinner(g, new RectangleF(right - 12, y + 6, 11, 11));
            }
            else if (_tokens.HasScanned && _tokens.SnapshotAgeSeconds.HasValue)
            {
                string age = "upd " + ShortAge(_tokens.SnapshotAgeSeconds.Value);
                float width = Draw.Measure(g, age, small).Width;
                Draw.String(g, age, small, Theme.TextMuted, right - width, y + 8);
            }
            y += TokenBigHeight;

            // Hovering the headline reads out today, the same as hovering its
            // own bar would.
            var headline = new RectangleF(left, headlineTop, right - left, y - headlineTop);
            bool headlineHovered = headline.Contains(_mouse);

            if (_tokens.Summary.FilesSeen == 0 && _tokens.HasScanned)
            {
                PaintTokenEmptyState(g, left, y, right - left);
                return;
            }

            string caption = TurnsCaption(today);
            if (caption.Length > 0)
            {
                Draw.String(g, Fit(g, caption, small, right - left), small, Theme.TextMuted, left, y);
            }
            y += TokenCaptionHeight;

            int hovered = PaintTokenChart(g, series, left, y, right - left);
            y += TokenChartHeight;

            PaintTokenAxis(g, series, left, y + 3, right - left);
            y += TokenAxisHeight;

            DailyTokenUsage readout = hovered >= 0
                ? series[hovered]
                : (headlineHovered ? today : null);
            if (readout != null)
            {
                Draw.String(g, Fit(g, DayReadout(readout), ReadoutFont, right - left),
                    ReadoutFont, Theme.TextPrimary, left, y + 2);
            }
            else
            {
                PaintRangeReadout(g, left, y + 2, right - left);
            }
        }

        /// Cache writes and cache reads, named beside the headline rather than
        /// folded into it: between the three lines all four counters stay on
        /// screen and nothing is silently swallowed by the big number.
        private static string TurnsCaption(DailyTokenUsage day)
        {
            TokenCounts counts = day.Totals;
            var parts = new List<string>();
            if (day.Messages > 0)
            {
                parts.Add(day.Messages.ToString(CultureInfo.InvariantCulture) +
                    (day.Messages == 1 ? " TURN" : " TURNS"));
            }
            if (counts.CacheCreation > 0) parts.Add("+" + TokenUsageFormat.Compact(counts.CacheCreation) + " CACHED");
            if (counts.CacheRead > 0) parts.Add("+" + TokenUsageFormat.Compact(counts.CacheRead) + " REPLAYED");
            return string.Join("  -  ", parts.ToArray());
        }

        private void PaintRangePicker(Graphics g, float right, float y)
        {
            Font font = Theme.Retro(8);
            int[] days = { 30, 7 };

            float x = right;
            for (int i = 0; i < days.Length; i++)
            {
                int chosen = days[i];
                string label = chosen.ToString(CultureInfo.InvariantCulture) + "D";
                SizeF size = Draw.Measure(g, label, font);
                var rect = new RectangleF(x - size.Width - 12, y, size.Width + 12, size.Height + 6);
                bool active = RangeDays == chosen;

                Draw.FillRounded(g, rect, 4, active ? Theme.Fade(Theme.AccentWarm, 0.18) : Theme.BgPanel);
                Draw.String(g, label, font, active ? Theme.AccentWarm : Theme.TextMuted,
                    rect.X + 6, rect.Y + 3);
                AddHotspot(rect, "Show the last " + chosen.ToString(CultureInfo.InvariantCulture) + " days",
                    delegate { SelectRange(chosen); });

                x = rect.X - 3;
            }
        }

        private void SelectRange(int days)
        {
            string name = days == 30 ? "month" : "week";
            if (_settings.TokenRange == name) return;
            _settings.TokenRange = name;
            _settings.Save();
            Invalidate();
        }

        /// Draws the bars and returns the index of the column under the
        /// pointer, or -1. The hover target is the whole column, not the drawn
        /// bar: on a quiet day that bar is a 3 px sliver and would be nearly
        /// unhittable.
        private int PaintTokenChart(Graphics g, List<DailyTokenUsage> series, float x, float y, float width)
        {
            if (series.Count == 0) return -1;

            long peak = 1;
            for (int i = 0; i < series.Count; i++)
            {
                long value = series[i].Totals.Uncached;
                if (value > peak) peak = value;
            }

            float spacing = RangeDays <= 7 ? 5f : 2f;
            float columnWidth = (width - spacing * (series.Count - 1)) / series.Count;

            int hovered = -1;
            for (int i = 0; i < series.Count; i++)
            {
                var column = new RectangleF(x + i * (columnWidth + spacing), y, columnWidth, TokenChartHeight);
                if (column.Contains(_mouse)) hovered = i;
            }

            DateTime today = DateTime.Now.Date;
            for (int i = 0; i < series.Count; i++)
            {
                DailyTokenUsage day = series[i];
                long value = day.Totals.Uncached;
                bool isToday = day.Day.Date == today;
                bool isHovered = hovered == i;

                Color color;
                if (value == 0) color = isHovered ? Theme.Fade(Theme.TextMuted, 0.45) : Theme.BgRaised;
                else if (isToday) color = Theme.AccentWarm;
                else color = Theme.Fade(Theme.AccentCool, isHovered ? 1.0 : 0.7);

                // Empty days still get a 2 px stub so the baseline stays
                // readable and an idle day is visibly different from a
                // missing one.
                float height = value == 0
                    ? 2f
                    : Math.Max(3f, (float)(TokenChartHeight * (value / (double)peak)));
                var bar = new RectangleF(x + i * (columnWidth + spacing),
                    y + TokenChartHeight - height, columnWidth, height);
                Draw.FillRounded(g, bar, Math.Min(2f, columnWidth / 2f), color);
            }
            return hovered;
        }

        /// A weekday letter per bar reads fine across seven columns; across
        /// thirty the columns are ~8 px wide and a two-digit date renders as a
        /// smear, so the month view gets endpoints instead.
        private void PaintTokenAxis(Graphics g, List<DailyTokenUsage> series, float x, float y, float width)
        {
            if (series.Count == 0) return;
            Font font = Theme.Retro(7);
            DateTime today = DateTime.Now.Date;

            if (RangeDays <= 7)
            {
                float spacing = 5f;
                float columnWidth = (width - spacing * (series.Count - 1)) / series.Count;
                for (int i = 0; i < series.Count; i++)
                {
                    DailyTokenUsage day = series[i];
                    string label = TokenUsageFormat.AxisLabel(day.Day, false);
                    float labelWidth = Draw.Measure(g, label, font).Width;
                    float center = x + i * (columnWidth + spacing) + columnWidth / 2f;
                    Draw.String(g, label, font,
                        day.Day.Date == today ? Theme.AccentWarm : Theme.TextMuted,
                        center - labelWidth / 2f, y);
                }
                return;
            }

            string first = TokenUsageFormat.MonthDay(series[0].Day);
            string middle = TokenUsageFormat.MonthDay(series[series.Count / 2].Day);
            Draw.String(g, first, font, Theme.TextMuted, x, y);
            float middleWidth = Draw.Measure(g, middle, font).Width;
            Draw.String(g, middle, font, Theme.TextMuted, x + (width - middleWidth) / 2f, y);
            float todayWidth = Draw.Measure(g, "TODAY", font).Width;
            Draw.String(g, "TODAY", font, Theme.AccentWarm, x + width - todayWidth, y);
        }

        /// "31 AUG  -  1.3M  -  1504 TURNS  -  2.9M ON CLAUDE.AI"
        ///
        /// The trailing figure is the same day as the claude.ai usage chart
        /// reports it: every transcript record, not every API call. It runs
        /// about twice the app's own number, and saying so here is cheaper
        /// than having the user find the gap and conclude the app is broken.
        private static string DayReadout(DailyTokenUsage day)
        {
            TokenCounts counts = day.Totals;
            var parts = new List<string>();
            parts.Add(TokenUsageFormat.MonthDay(day.Day));
            if (counts.IsEmpty)
            {
                parts.Add("IDLE");
                return string.Join("  -  ", parts.ToArray());
            }
            parts.Add(TokenUsageFormat.Compact(counts.Uncached));
            if (day.Messages > 0)
            {
                parts.Add(day.Messages.ToString(CultureInfo.InvariantCulture) +
                    (day.Messages == 1 ? " TURN" : " TURNS"));
            }
            if (day.RawTotals.Uncached > counts.Uncached)
            {
                parts.Add(TokenUsageFormat.Compact(day.RawTotals.Uncached) + " ON CLAUDE.AI");
            }
            return string.Join("  -  ", parts.ToArray());
        }

        /// The default readout: the whole range, in the app's own count and in
        /// the website's. Drawn as coloured runs rather than one string so the
        /// headline figure still leads at a glance.
        /// One size below the rest of the panel chrome. The readout has to
        /// carry three figures across 308 px in a fixed-pitch 8x8 pixel font,
        /// and macOS solves the same squeeze with minimumScaleFactor, which
        /// GDI+ has no equivalent of.
        private static Font ReadoutFont
        {
            get { return Theme.Retro(8); }
        }

        private void PaintRangeReadout(Graphics g, float x, float y, float width)
        {
            Font font = ReadoutFont;
            long total = _tokens.Summary.Total(RangeDays).Uncached;
            long mirrored = _tokens.Summary.RawTotal(RangeDays).Uncached;
            long average = total / Math.Max(RangeDays, 1);

            string head = RangeLabel + " " + TokenUsageFormat.Compact(total);
            string avg = "AVG " + TokenUsageFormat.Compact(average) + "/DAY";
            string tail = TokenUsageFormat.Compact(mirrored) + " ON CLAUDE.AI";

            float cursor = x;
            cursor = Run(g, head, font, Theme.TextPrimary, cursor, y) + 7;
            cursor = Run(g, "-", font, Theme.TextMuted, cursor, y) + 7;
            cursor = Run(g, avg, font, Theme.TextSecondary, cursor, y) + 7;

            // The mirror is the least important of the three, so it is what
            // gives way when the line runs out of room rather than the whole
            // readout shrinking.
            if (mirrored <= total) return;
            float needed = Draw.Measure(g, "-", font).Width + 7 + Draw.Measure(g, tail, font).Width;
            if (cursor + needed > x + width) return;
            cursor = Run(g, "-", font, Theme.TextMuted, cursor, y) + 7;
            Run(g, tail, font, Theme.TextMuted, cursor, y);
        }

        private static float Run(Graphics g, string text, Font font, Color color, float x, float y)
        {
            Draw.String(g, text, font, color, x, y);
            return x + Draw.Measure(g, text, font).Width;
        }

        private void PaintTokenEmptyState(Graphics g, float x, float y, float width)
        {
            Draw.TrackedString(g, "NO TRANSCRIPTS FOUND", Theme.Retro(9, FontStyle.Bold),
                Theme.TextSecondary, x, y, 1f);
            using (var brush = new SolidBrush(Theme.TextMuted))
            {
                g.DrawString(
                    "Token spend is read from " + _tokens.ProjectsDirectory +
                    ". Run Claude Code once and it will show up here.",
                    Theme.Ui(11, FontStyle.Regular), brush,
                    new RectangleF(x, y + 16, width, 40));
            }
        }

        // ----------------------------------------------------- service status

        private const int StatusTitleHeight = 16;
        private const int StatusHeadlineHeight = 16;
        private const int StatusRowHeight = 13;
        private const int StatusIncidentHeight = 34;

        /// How much room the service-status panel needs for the snapshot it is
        /// holding right now, excluding the block padding PanelBlockHeight adds.
        private int StatusBodyHeight()
        {
            if (_status == null || !_settings.ServiceStatusEnabled) return 0;

            int height = StatusTitleHeight;
            ServiceStatus snapshot = _status.Status;
            if (snapshot == null) return height + StatusHeadlineHeight;

            height += StatusHeadlineHeight;
            height += ((snapshot.Components.Count + 1) / 2) * StatusRowHeight;
            if (snapshot.Incidents.Count > 0) height += 6 + StatusIncidentHeight;
            if (snapshot.Incidents.Count > 1) height += 12;
            return height;
        }

        /// Compact mirror of status.claude.com: overall indicator, a dot per
        /// component, and the headline of any live incident. Answers the
        /// question a red usage number can't — "is the API itself down?".
        private void PaintServiceStatus(Graphics g, float y)
        {
            const float left = 16;
            const float right = PanelWidth - 16;

            Draw.TrackedString(g, "SERVICE STATUS", Theme.Retro(10), Theme.TextSecondary, left, y, 2f);

            Font glyphFont = Glyphs.Font(11);
            SizeF glyphSize = Draw.Measure(g, Glyphs.OpenExternal, glyphFont);
            var glyphBounds = new RectangleF(right - glyphSize.Width - 4, y - 3, glyphSize.Width + 8, glyphSize.Height + 6);
            AddHotspot(glyphBounds, "Open status.claude.com",
                delegate { OpenInBrowser(ServiceStatus.PageUrl); });
            Draw.String(g, Glyphs.OpenExternal, glyphFont,
                IsHovering(glyphBounds) ? Theme.TextPrimary : Theme.TextSecondary,
                glyphBounds.X + 4, glyphBounds.Y + 3);

            Font small = Theme.Retro(9);
            if (_status.IsFetching)
            {
                PaintSpinner(g, new RectangleF(glyphBounds.X - 18, y, 10, 10));
            }
            else if (_status.Status != null && _status.SnapshotAgeSeconds.HasValue)
            {
                string age = "upd " + ShortAge(_status.SnapshotAgeSeconds.Value);
                float width = Draw.Measure(g, age, small).Width;
                Draw.String(g, age, small, Theme.TextMuted, glyphBounds.X - 8 - width, y + 1);
            }

            y += StatusTitleHeight;

            ServiceStatus snapshot = _status.Status;
            if (snapshot == null)
            {
                Draw.String(g, _status.LastError == null ? "CHECKING..." : UnreachableCaption(_status.LastError),
                    small, Theme.TextMuted, left, y);
                return;
            }

            // Headline: the page's own wording, coloured by the worst level we
            // can see — which may be a step ahead of the page indicator.
            ServiceLevel worst = snapshot.WorstLevel;
            PaintDot(g, left + 1, y + 4, 7, worst);
            Font headlineFont = Theme.Retro(10);
            float headlineWidth = right - (left + 14);
            if (_status.LastError != null) headlineWidth -= 44;
            Draw.String(g, Fit(g, snapshot.Headline, headlineFont, headlineWidth),
                headlineFont, Theme.ColorFor(worst), left + 14, y);
            // A snapshot kept on screen through a failed refresh should say so.
            if (_status.LastError != null)
            {
                float width = Draw.Measure(g, "STALE", small).Width;
                Draw.String(g, "STALE", small, Theme.TextMuted, right - width, y + 1);
            }
            y += StatusHeadlineHeight;

            float columnWidth = (right - left) / 2f - 6;
            for (int i = 0; i < snapshot.Components.Count; i++)
            {
                ServiceComponent component = snapshot.Components[i];
                float x = left + (i % 2) * ((right - left) / 2f);
                float rowY = y + (i / 2) * StatusRowHeight;
                PaintComponentRow(g, component, x, rowY, columnWidth);
            }
            y += ((snapshot.Components.Count + 1) / 2) * StatusRowHeight;

            if (snapshot.Incidents.Count == 0) return;

            y += 6;
            PaintIncident(g, snapshot.Incidents[0], left, y, right - left);
            y += StatusIncidentHeight;

            if (snapshot.Incidents.Count > 1)
            {
                string more = "+" + (snapshot.Incidents.Count - 1).ToString(CultureInfo.InvariantCulture) +
                    (snapshot.Incidents.Count == 2 ? " more incident" : " more incidents");
                Draw.String(g, more, Theme.Retro(8), Theme.TextMuted, left, y + 1);
            }
        }

        private void PaintComponentRow(Graphics g, ServiceComponent component, float x, float y, float width)
        {
            PaintDot(g, x + 1, y + 3, 5, component.Level);

            Font font = Theme.Retro(8);
            float textX = x + 10;
            float available = width - 10;

            if (!component.IsHealthy)
            {
                string badge = ServiceLevels.Badge(component.Level);
                float badgeWidth = Draw.Measure(g, badge, font).Width;
                Draw.String(g, badge, font, Theme.ColorFor(component.Level), x + width - badgeWidth, y);
                available -= badgeWidth + 4;
            }

            var bounds = new RectangleF(x, y, width, StatusRowHeight);
            AddHotspot(bounds, component.Name, null);
            Draw.String(g, Fit(g, component.ShortName, font, available), font,
                component.IsHealthy ? Theme.TextSecondary : Theme.TextPrimary, textX, y);
        }

        private void PaintIncident(Graphics g, ServiceIncident incident, float x, float y, float width)
        {
            var bounds = new RectangleF(x, y, width, StatusIncidentHeight - 4);
            bool hot = IsHovering(bounds);
            Draw.FillRounded(g, bounds, 6, hot ? Theme.BgRaised : Theme.BgPanel);

            string tooltip = incident.Name;
            if (!string.IsNullOrEmpty(incident.LatestUpdate)) tooltip += "\r\n\r\n" + incident.LatestUpdate;
            string url = string.IsNullOrEmpty(incident.Url) ? ServiceStatus.PageUrl : incident.Url;
            AddHotspot(bounds, tooltip, delegate { OpenInBrowser(url); });

            Font font = Theme.Retro(8);
            Draw.String(g, "!", Theme.Retro(9), Theme.ColorFor(incident.Impact), x + 9, y + 5);
            Draw.String(g, Fit(g, incident.Name, font, width - 30), font, Theme.TextPrimary, x + 20, y + 5);
            if (incident.Stage.Length > 0)
            {
                Draw.String(g, incident.Stage.ToUpperInvariant(), font, Theme.TextMuted, x + 20, y + 17);
            }
        }

        private void PaintDot(Graphics g, float x, float y, float size, ServiceLevel level)
        {
            Color color = Theme.ColorFor(level);
            using (var glow = new SolidBrush(Theme.Fade(color, ServiceLevels.IsHealthy(level) ? 0.25 : 0.4)))
            {
                g.FillEllipse(glow, x - 2, y - 2, size + 4, size + 4);
            }
            using (var brush = new SolidBrush(color))
            {
                g.FillEllipse(brush, x, y, size, size);
            }
        }

        private bool IsHovering(RectangleF bounds)
        {
            return _hovered != null && bounds.Contains(
                _hovered.Bounds.X + _hovered.Bounds.Width / 2f,
                _hovered.Bounds.Y + _hovered.Bounds.Height / 2f);
        }

        /// Trims to fit the column, because a Statuspage name is written for a
        /// browser and this panel is 340 px wide.
        private static string Fit(Graphics g, string text, Font font, float maxWidth)
        {
            if (string.IsNullOrEmpty(text)) return "";
            if (Draw.Measure(g, text, font).Width <= maxWidth) return text;
            string trimmed = text;
            while (trimmed.Length > 1 && Draw.Measure(g, trimmed + "..", font).Width > maxWidth)
            {
                trimmed = trimmed.Substring(0, trimmed.Length - 1);
            }
            return trimmed + "..";
        }

        private static string UnreachableCaption(string error)
        {
            return error != null && error.IndexOf("network", StringComparison.OrdinalIgnoreCase) >= 0
                ? "OFFLINE - STATUS UNKNOWN"
                : "STATUS PAGE UNREACHABLE";
        }

        private static string ShortAge(double seconds)
        {
            if (seconds < 5) return "now";
            if (seconds < 60) return ((int)seconds).ToString(CultureInfo.InvariantCulture) + "s";
            if (seconds < 3600) return ((int)(seconds / 60)).ToString(CultureInfo.InvariantCulture) + "m";
            return ((int)(seconds / 3600)).ToString(CultureInfo.InvariantCulture) + "h";
        }

        /// User-friendly plan name pulled from the OAuth token's claims.
        /// See PlanBadge for why this can lag a plan change.
        private string PlanLabel()
        {
            return PlanBadge.Label(_daemon.SubscriptionType, _daemon.RateLimitTier);
        }

        /// Which window is currently the binding constraint, straight from the
        /// API's representative-claim header.
        private string BindingLabel()
        {
            string claim;
            if (!_daemon.Usage.RawHeaders.TryGetValue("anthropic-ratelimit-unified-representative-claim", out claim))
                return null;
            if (claim == "five_hour") return "5H BINDING";
            if (claim == "seven_day") return "7D BINDING";
            return claim.ToUpperInvariant();
        }

        public static string ResetCaption(DateTime? resetAt)
        {
            if (!resetAt.HasValue) return "RESET —";
            double delta = (resetAt.Value - DateTime.UtcNow).TotalSeconds;
            if (delta < 0) return "RESET NOW";
            if (delta < 60) return "RESETS <1M";
            if (delta < 3600) return "RESETS IN " + ((int)(delta / 60)).ToString(CultureInfo.InvariantCulture) + "M";
            if (delta < 86400)
            {
                int h = (int)(delta / 3600);
                int m = (int)((delta % 3600) / 60);
                return m > 0
                    ? "RESETS IN " + h.ToString(CultureInfo.InvariantCulture) + "H " + m.ToString(CultureInfo.InvariantCulture) + "M"
                    : "RESETS IN " + h.ToString(CultureInfo.InvariantCulture) + "H";
            }
            int d = (int)(delta / 86400);
            int hh = (int)((delta % 86400) / 3600);
            return hh > 0
                ? "RESETS IN " + d.ToString(CultureInfo.InvariantCulture) + "D " + hh.ToString(CultureInfo.InvariantCulture) + "H"
                : "RESETS IN " + d.ToString(CultureInfo.InvariantCulture) + "D";
        }

        public static string TimeAgo(DateTime utc)
        {
            double delta = (DateTime.UtcNow - utc).TotalSeconds;
            if (delta < 5) return "now";
            if (delta < 60) return ((int)delta).ToString(CultureInfo.InvariantCulture) + "s";
            if (delta < 3600) return ((int)(delta / 60)).ToString(CultureInfo.InvariantCulture) + "m";
            return ((int)(delta / 3600)).ToString(CultureInfo.InvariantCulture) + "h";
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _daemon.Changed -= OnDaemonChanged;
                if (_status != null) _status.Changed -= OnSecondaryChanged;
                if (_tokens != null) _tokens.Changed -= OnSecondaryChanged;
                if (_tick != null) _tick.Dispose();
                if (_tips != null) _tips.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
