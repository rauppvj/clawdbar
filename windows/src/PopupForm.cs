using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
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

    /// Windows counterpart of PopoverView: the panel that opens from the tray
    /// icon. Same 340pt width and the same four action buttons as the macOS
    /// popover, redrawn with GDI+.
    internal sealed class PopupForm : Form
    {
        private const int PanelWidth = 340;
        private const int PanelHeight = 306;

        private readonly UsageDaemon _daemon;
        private readonly AppSettings _settings;
        private readonly Action _onToggleOverlay;
        private readonly Action _onOpenSettings;
        private readonly Action _onQuit;

        private readonly List<HitButton> _buttons = new List<HitButton>();
        private readonly Timer _tick;
        private readonly ToolTip _tips = new ToolTip();
        private HitButton _hovered;
        private int _moodPhase;

        /// The panel closes as soon as it loses focus, the way a tray flyout
        /// should. The preview harness turns this off so the window can be
        /// inspected while something else holds focus.
        public bool AutoHideOnDeactivate = true;

        public PopupForm(UsageDaemon daemon, AppSettings settings,
            Action onToggleOverlay, Action onOpenSettings, Action onQuit)
        {
            _daemon = daemon;
            _settings = settings;
            _onToggleOverlay = onToggleOverlay;
            _onOpenSettings = onOpenSettings;
            _onQuit = onQuit;

            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            ClientSize = new Size(PanelWidth, PanelHeight);
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
        }

        private void OnDaemonChanged(object sender, EventArgs e)
        {
            if (IsDisposed || !Visible) return;
            Invalidate();
        }

        private void BuildButtons()
        {
            var refresh = new HitButton(Glyphs.Refresh, "Refresh", async delegate
            {
                await _daemon.RefreshNowAsync();
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

            float y = PanelHeight - 36;
            float x = 8;
            for (int i = 0; i < 3; i++)
            {
                _buttons[i].Bounds = new RectangleF(x, y, 30, 28);
                x += 34;
            }
            _buttons[3].Bounds = new RectangleF(PanelWidth - 38, y, 30, 28);
        }

        /// Positions the panel next to the tray, adapting to whichever screen
        /// edge the taskbar is docked on.
        public void ShowNearTray()
        {
            Point cursor = Cursor.Position;
            Screen screen = Screen.FromPoint(cursor);
            Rectangle work = screen.WorkingArea;
            Rectangle full = screen.Bounds;

            int x = cursor.X - PanelWidth / 2;
            int y;

            if (work.Bottom < full.Bottom) y = work.Bottom - PanelHeight - 8;          // taskbar at bottom
            else if (work.Top > full.Top) y = work.Top + 8;                            // taskbar at top
            else if (work.Right < full.Right) { x = work.Right - PanelWidth - 8; y = cursor.Y - PanelHeight / 2; }
            else if (work.Left > full.Left) { x = work.Left + 8; y = cursor.Y - PanelHeight / 2; }
            else y = work.Bottom - PanelHeight - 8;

            if (x < work.Left + 4) x = work.Left + 4;
            if (x + PanelWidth > work.Right - 4) x = work.Right - PanelWidth - 4;
            if (y < work.Top + 4) y = work.Top + 4;
            if (y + PanelHeight > work.Bottom - 4) y = work.Bottom - PanelHeight - 4;

            Location = new Point(x, y);
            _tick.Start();
            Show();
            Activate();
            Invalidate();
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
            HitButton found = null;
            for (int i = 0; i < _buttons.Count; i++)
            {
                if (_buttons[i].Bounds.Contains(e.Location)) { found = _buttons[i]; break; }
            }
            if (!ReferenceEquals(found, _hovered))
            {
                _hovered = found;
                _tips.SetToolTip(this, found == null ? null : found.Tooltip);
                Cursor = found == null ? Cursors.Default : Cursors.Hand;
                Invalidate();
            }
        }

        protected override void OnMouseClick(MouseEventArgs e)
        {
            base.OnMouseClick(e);
            for (int i = 0; i < _buttons.Count; i++)
            {
                if (_buttons[i].Enabled && _buttons[i].Bounds.Contains(e.Location))
                {
                    _buttons[i].OnClick();
                    Invalidate();
                    return;
                }
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Draw.HighQuality(g);
            g.Clear(Theme.BgDeep);

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

            PaintDivider(g, PanelHeight - 45);
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
                x = PaintBadge(g, plan, x, y + 1, Theme.Fade(Theme.AccentWarm, 0.15), Theme.AccentWarm) + 6;
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

        /// User-friendly plan name from the OAuth token's subscriptionType.
        private string PlanLabel()
        {
            string sub = _daemon.SubscriptionType;
            if (string.IsNullOrEmpty(sub)) return null;
            switch (sub.ToLowerInvariant())
            {
                case "max":
                    string tier = _daemon.RateLimitTier;
                    if (tier != null && tier.ToLowerInvariant().IndexOf("20x", StringComparison.Ordinal) >= 0)
                        return "MAX 20X";
                    return "MAX";
                case "pro": return "PRO";
                case "team": return "TEAM";
                default: return sub.ToUpperInvariant();
            }
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
                if (_tick != null) _tick.Dispose();
                if (_tips != null) _tips.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
