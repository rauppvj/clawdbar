using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Windows.Forms;

namespace ClawdBar
{
    /// The floating "smartwatch" widget. Borderless, always-on-top, rounded,
    /// draggable by its background, with the same four carousel pages as the
    /// macOS overlay: current usage, activity heatmap, stats, tamagotchi.
    internal sealed class OverlayForm : Form
    {
        private const int MinSide = 140;
        private const int MaxSide = 320;
        private const int GripSize = 16;

        private readonly UsageDaemon _daemon;
        private readonly AppSettings _settings;
        private readonly Timer _animation;

        private int _page;
        private bool _positionLocked;
        private UsageStats _stats;
        private DateTime _statsComputedAt = DateTime.MinValue;

        private readonly List<HitButton> _hits = new List<HitButton>();

        public OverlayForm(UsageDaemon daemon, AppSettings settings)
        {
            _daemon = daemon;
            _settings = settings;

            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = Theme.BgDeep;
            MinimumSize = new Size(MinSide, MinSide);
            MaximumSize = new Size(MaxSide, MaxSide);
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);

            RestoreFrame();
            BuildContextMenu();
            ApplySettings();

            _animation = new Timer();
            _animation.Interval = 100;
            _animation.Tick += delegate { Invalidate(); };

            _daemon.Changed += OnDaemonChanged;
        }

        private void OnDaemonChanged(object sender, EventArgs e)
        {
            if (IsDisposed || !Visible) return;
            _statsComputedAt = DateTime.MinValue;
            Invalidate();
        }

        // ------------------------------------------------------------ window

        private void RestoreFrame()
        {
            int w = Clamp(_settings.OverlayWidth, MinSide, MaxSide);
            int h = Clamp(_settings.OverlayHeight, MinSide, MaxSide);
            Size = new Size(w, h);

            if (_settings.OverlayFrameSaved)
            {
                var location = new Point(_settings.OverlayX, _settings.OverlayY);
                if (IsOnAScreen(new Rectangle(location, Size)))
                {
                    Location = location;
                    return;
                }
            }
            SnapTo(_settings.OverlayDefaultCorner);
        }

        private static bool IsOnAScreen(Rectangle frame)
        {
            Screen[] screens = Screen.AllScreens;
            for (int i = 0; i < screens.Length; i++)
            {
                if (screens[i].WorkingArea.IntersectsWith(frame)) return true;
            }
            return false;
        }

        public void SnapTo(SnapCorner corner)
        {
            Rectangle work = Screen.FromControl(this).WorkingArea;
            const int margin = 16;
            int x, y;
            switch (corner)
            {
                case SnapCorner.TopLeft: x = work.Left + margin; y = work.Top + margin; break;
                case SnapCorner.TopRight: x = work.Right - Width - margin; y = work.Top + margin; break;
                case SnapCorner.BottomLeft: x = work.Left + margin; y = work.Bottom - Height - margin; break;
                default: x = work.Right - Width - margin; y = work.Bottom - Height - margin; break;
            }
            Location = new Point(x, y);
            SaveFrame();
        }

        public void ResetSize()
        {
            Size = new Size(Defaults.OverlaySize, Defaults.OverlaySize);
            UpdateRegion();
            SaveFrame();
            Invalidate();
        }

        private void SaveFrame()
        {
            _settings.OverlayX = Location.X;
            _settings.OverlayY = Location.Y;
            _settings.OverlayWidth = Width;
            _settings.OverlayHeight = Height;
            _settings.OverlayFrameSaved = true;
            _settings.Save();
        }

        /// Re-applies opacity and click-through from settings. Called on show
        /// and whenever the Preferences sliders change.
        public void ApplySettings()
        {
            Opacity = Math.Max(0.2, Math.Min(1.0, _settings.OverlayOpacity));
            ApplyClickThrough(_settings.OverlayClickThrough);
        }

        public void ToggleVisible()
        {
            if (Visible)
            {
                Hide();
            }
            else
            {
                ApplySettings();
                Show();
                UpdateRegion();
            }
        }

        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            if (Visible) _animation.Start(); else _animation.Stop();
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            UpdateRegion();
        }

        protected override void OnResizeEnd(EventArgs e)
        {
            base.OnResizeEnd(e);
            SaveFrame();
        }

        protected override void OnMove(EventArgs e)
        {
            base.OnMove(e);
            UpdateRegion();
        }

        private void UpdateRegion()
        {
            var bounds = new RectangleF(0, 0, ClientSize.Width, ClientSize.Height);
            using (GraphicsPath path = Draw.RoundedRect(bounds, 18))
            {
                Region = new Region(path);
            }
        }

        // Never steal focus from whatever the user is typing in.
        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        private const int WS_EX_TOOLWINDOW = 0x00000080;
        private const int WS_EX_NOACTIVATE = 0x08000000;
        private const int WS_EX_TRANSPARENT = 0x00000020;
        private const int WS_EX_LAYERED = 0x00080000;

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
                return cp;
            }
        }

        [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
        private static extern int GetWindowLong(IntPtr hWnd, int index);

        [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
        private static extern int SetWindowLong(IntPtr hWnd, int index, int newLong);

        private const int GWL_EXSTYLE = -20;

        /// Click-through is an extended window style on Windows, the analogue
        /// of NSWindow.ignoresMouseEvents on macOS.
        private void ApplyClickThrough(bool enabled)
        {
            if (!IsHandleCreated) return;
            int style = GetWindowLong(Handle, GWL_EXSTYLE);
            if (enabled) style |= WS_EX_TRANSPARENT | WS_EX_LAYERED;
            else style &= ~WS_EX_TRANSPARENT;
            SetWindowLong(Handle, GWL_EXSTYLE, style);
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            UpdateRegion();
            ApplyClickThrough(_settings.OverlayClickThrough);
        }

        private const int WM_NCHITTEST = 0x0084;
        private const int HTCLIENT = 1;
        private const int HTCAPTION = 2;
        private const int HTBOTTOMRIGHT = 17;

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_NCHITTEST)
            {
                Point screen = new Point(m.LParam.ToInt32() & 0xFFFF, (m.LParam.ToInt32() >> 16) & 0xFFFF);
                // Sign-extend for multi-monitor setups with negative coords.
                screen = new Point((short)(m.LParam.ToInt32() & 0xFFFF), (short)((m.LParam.ToInt32() >> 16) & 0xFFFF));
                Point local = PointToClient(screen);

                if (!_settings.OverlayLocked && GripBounds().Contains(local))
                {
                    m.Result = (IntPtr)HTBOTTOMRIGHT;
                    return;
                }
                for (int i = 0; i < _hits.Count; i++)
                {
                    if (_hits[i].Bounds.Contains(local))
                    {
                        m.Result = (IntPtr)HTCLIENT;
                        return;
                    }
                }
                m.Result = (IntPtr)(_positionLocked ? HTCLIENT : HTCAPTION);
                return;
            }
            base.WndProc(ref m);
        }

        private RectangleF GripBounds()
        {
            return new RectangleF(ClientSize.Width - GripSize - 2, ClientSize.Height - GripSize - 2, GripSize, GripSize);
        }

        // ------------------------------------------------------- context menu

        private void BuildContextMenu()
        {
            var menu = new ContextMenuStrip();

            menu.Items.Add("Hide", null, delegate { Hide(); });
            menu.Items.Add(new ToolStripSeparator());

            var snap = new ToolStripMenuItem("Snap to Corner");
            foreach (SnapCorner corner in Enum.GetValues(typeof(SnapCorner)))
            {
                SnapCorner captured = corner;
                snap.DropDownItems.Add(AppSettings.DisplayName(corner), null,
                    delegate { SnapTo(captured); });
            }
            menu.Items.Add(snap);

            var opacity = new ToolStripMenuItem("Opacity");
            double[] levels = { 1.0, 0.75, 0.5, 0.25 };
            for (int i = 0; i < levels.Length; i++)
            {
                double captured = levels[i];
                opacity.DropDownItems.Add(((int)(captured * 100)).ToString(CultureInfo.InvariantCulture) + "%", null,
                    delegate
                    {
                        _settings.OverlayOpacity = captured;
                        _settings.Save();
                        ApplySettings();
                    });
            }
            menu.Items.Add(opacity);

            var clickThrough = new ToolStripMenuItem("Click-Through");
            clickThrough.CheckOnClick = true;
            clickThrough.Checked = _settings.OverlayClickThrough;
            clickThrough.Click += delegate
            {
                _settings.OverlayClickThrough = clickThrough.Checked;
                _settings.Save();
                ApplySettings();
            };
            menu.Items.Add(clickThrough);

            var lockPosition = new ToolStripMenuItem("Lock Position");
            lockPosition.CheckOnClick = true;
            lockPosition.Click += delegate { _positionLocked = lockPosition.Checked; };
            menu.Items.Add(lockPosition);

            ContextMenuStrip = menu;
        }

        // ------------------------------------------------------------ paging

        protected override void OnMouseClick(MouseEventArgs e)
        {
            base.OnMouseClick(e);
            DispatchClick(e);
        }

        /// The second click of a double-click arrives as WM_LBUTTONDBLCLK and
        /// never reaches OnMouseClick, so clicking "next" twice quickly would
        /// advance only one page. Route it to the same handler.
        protected override void OnMouseDoubleClick(MouseEventArgs e)
        {
            base.OnMouseDoubleClick(e);
            DispatchClick(e);
        }

        private void DispatchClick(MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;
            for (int i = 0; i < _hits.Count; i++)
            {
                if (_hits[i].Enabled && _hits[i].Bounds.Contains(e.Location))
                {
                    _hits[i].OnClick();
                    Invalidate();
                    return;
                }
            }
        }

        private UsageStats Stats()
        {
            // Recomputing on every animation frame would walk the whole history
            // 10x a second; once per data change (or 5s) is plenty.
            if (_stats == null || (DateTime.UtcNow - _statsComputedAt).TotalSeconds > 5)
            {
                _stats = UsageStats.Compute(_daemon.History.Samples, 56, DateTime.UtcNow);
                _statsComputedAt = DateTime.UtcNow;
            }
            return _stats;
        }

        // ----------------------------------------------------------- painting

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Draw.HighQuality(g);
            g.Clear(Theme.BgDeep);

            var bounds = new RectangleF(0, 0, ClientSize.Width, ClientSize.Height);
            Draw.StrokeRounded(g, new RectangleF(0.5f, 0.5f, bounds.Width - 1, bounds.Height - 1), 18, Theme.Stroke, 1f);

            _hits.Clear();

            switch (_page)
            {
                case 1: PaintHeatmap(g, bounds); break;
                case 2: PaintStats(g, bounds); break;
                case 3: PaintTamagotchi(g, bounds); break;
                default: PaintCurrent(g, bounds); break;
            }

            PaintPager(g, bounds);
            if (!_settings.OverlayLocked) PaintGrip(g);
        }

        private void PaintCurrent(Graphics g, RectangleF bounds)
        {
            UsageData usage = _daemon.Usage;
            Severity severity = usage.SessionSeverity;

            // Header dot + USAGE
            using (var brush = new SolidBrush(Theme.ColorFor(severity)))
            {
                g.FillEllipse(brush, 14, 12, 6, 6);
            }
            Draw.TrackedString(g, "USAGE", Theme.Retro(9), Theme.TextSecondary, 26, 9, 3f);

            // Big session percent
            string big = usage.SessionPercent.HasValue
                ? ((int)Math.Round(usage.SessionPercent.Value)).ToString(CultureInfo.InvariantCulture) + "%"
                : "––";
            float bigSize = Math.Max(22f, bounds.Height * 0.28f);
            Font bigFont = Theme.Retro(bigSize);
            SizeF measured = Draw.Measure(g, big, bigFont);
            while (measured.Width > bounds.Width - 20 && bigSize > 12f)
            {
                bigSize -= 2f;
                bigFont = Theme.Retro(bigSize);
                measured = Draw.Measure(g, big, bigFont);
            }
            float bigY = bounds.Height * 0.36f - measured.Height / 2f;
            Draw.String(g, big, bigFont, Theme.ColorFor(severity), (bounds.Width - measured.Width) / 2f, bigY);

            // 5H reset caption
            string reset = "5H · " + ShortReset(usage.SessionResetAt);
            Font small = Theme.Retro(8);
            float resetWidth = Draw.MeasureTracked(g, reset, small, 1.5f);
            Draw.TrackedString(g, reset, small, Theme.TextMuted,
                (bounds.Width - resetWidth) / 2f, bigY + measured.Height + 6, 1.5f);

            // Footer: 7D mini stat + mood
            float footerY = bounds.Height - 46;
            Draw.String(g, "7D", Theme.Retro(9), Theme.TextMuted, 14, footerY + 3);
            string weekly = usage.WeeklyPercent.HasValue
                ? ((int)Math.Round(usage.WeeklyPercent.Value)).ToString(CultureInfo.InvariantCulture) + "%"
                : "––";
            Draw.String(g, weekly, Theme.Retro(12), Theme.ColorFor(usage.WeeklySeverity), 34, footerY);

            string mood = Moods.Label(usage.Mood, DateTime.UtcNow).ToUpperInvariant();
            Font moodFont = Theme.Retro(9);
            float moodWidth = Draw.Measure(g, mood, moodFont).Width;
            Draw.String(g, mood, moodFont, Theme.AccentWarm, bounds.Width - 14 - moodWidth, footerY + 3);
        }

        private void PaintHeatmap(Graphics g, RectangleF bounds)
        {
            UsageStats stats = Stats();
            Draw.TrackedString(g, "ACTIVITY", Theme.Retro(11), Theme.TextPrimary, 14, 12, 2.5f);

            const int columns = 8;
            const int rows = 7;
            float available = bounds.Width - 28;
            float spacing = 2;
            float cell = Math.Max(6f, Math.Min(13f, (available - spacing * (columns - 1)) / columns));
            float gridWidth = cell * columns + spacing * (columns - 1);
            float startX = (bounds.Width - gridWidth) / 2f;
            float startY = 40;

            List<DailyActivity> days = stats.ActivityByDay;
            int total = columns * rows;
            // Oldest day first, most recent in the bottom-right cell. Cells
            // beyond the history window stay null and render as padding.
            int offset = days.Count - total;

            for (int col = 0; col < columns; col++)
            {
                for (int row = 0; row < rows; row++)
                {
                    int index = col * rows + row;
                    int dayIndex = index + offset;
                    DailyActivity activity = null;
                    if (dayIndex >= 0 && dayIndex < days.Count) activity = days[dayIndex];

                    var rect = new RectangleF(startX + col * (cell + spacing), startY + row * (cell + spacing), cell, cell);
                    Draw.FillRounded(g, rect, 2.5f, HeatColor(activity));
                }
            }

            float footerY = bounds.Height - 46;
            Font small = Theme.Retro(8);
            if (stats.DaysTracked > 0)
            {
                string label = stats.DaysTracked.ToString(CultureInfo.InvariantCulture) +
                    (stats.DaysTracked == 1 ? " day tracked" : " days tracked");
                Draw.String(g, label, small, Theme.AccentWarm, 14, footerY);
            }
            else
            {
                Draw.String(g, "Tracking…", small, Theme.TextMuted, 14, footerY);
            }

            // less [][][][][] more legend. At the default 200px the words would
            // run into the "N days tracked" label, so they only appear once the
            // user has grown the overlay enough to fit both.
            Font tiny = Theme.Retro(7);
            bool showWords = bounds.Width >= 260;
            float legendX = bounds.Width - 14;
            if (showWords)
            {
                float moreWidth = Draw.Measure(g, "more", tiny).Width;
                legendX -= moreWidth;
                Draw.String(g, "more", tiny, Theme.TextMuted, legendX, footerY + 1);
                legendX -= 3;
            }
            for (int level = 4; level >= 0; level--)
            {
                legendX -= 8;
                Draw.FillRounded(g, new RectangleF(legendX, footerY + 1, 8, 8), 1.5f, LegendColor(level));
                legendX -= 3;
            }
            if (showWords)
            {
                float lessWidth = Draw.Measure(g, "less", tiny).Width;
                Draw.String(g, "less", tiny, Theme.TextMuted, legendX - lessWidth, footerY + 1);
            }
        }

        private static Color HeatColor(DailyActivity activity)
        {
            if (activity == null) return Theme.Fade(Theme.BgRaised, 0.4);
            return LegendColor(activity.Level);
        }

        private static Color LegendColor(int level)
        {
            switch (level)
            {
                case 0: return Theme.BgRaised;
                case 1: return Theme.Fade(Theme.AccentCool, 0.35);
                case 2: return Theme.Fade(Theme.AccentCool, 0.55);
                case 3: return Theme.Fade(Theme.AccentCool, 0.8);
                case 4: return Theme.AccentCool;
                default: return Theme.Fade(Theme.BgRaised, 0.4);
            }
        }

        private void PaintStats(Graphics g, RectangleF bounds)
        {
            UsageStats stats = Stats();
            Draw.TrackedString(g, "STATS", Theme.Retro(11), Theme.TextPrimary, 14, 12, 2.5f);

            float pad = 14;
            float gap = 8;
            float cellWidth = (bounds.Width - pad * 2 - gap) / 2f;
            float cellHeight = Math.Max(34f, (bounds.Height - 100) / 2f);
            float top = 40;

            Color streakColor = stats.CurrentStreak == 0 ? Theme.TextMuted : Theme.AccentWarm;
            string peakHour = stats.PeakHour.HasValue
                ? stats.PeakHour.Value.ToString(CultureInfo.InvariantCulture) + "h" : "—";

            PaintStatCell(g, new RectangleF(pad, top, cellWidth, cellHeight), "STREAK",
                stats.CurrentStreak.ToString(CultureInfo.InvariantCulture) + "d", streakColor);
            PaintStatCell(g, new RectangleF(pad + cellWidth + gap, top, cellWidth, cellHeight), "LONGEST",
                stats.LongestStreak.ToString(CultureInfo.InvariantCulture) + "d", Theme.AccentCool);
            PaintStatCell(g, new RectangleF(pad, top + cellHeight + gap, cellWidth, cellHeight), "PEAK HOUR",
                peakHour, Theme.AccentWarm);
            PaintStatCell(g, new RectangleF(pad + cellWidth + gap, top + cellHeight + gap, cellWidth, cellHeight), "DAYS",
                stats.DaysTracked.ToString(CultureInfo.InvariantCulture), Theme.TextPrimary);

            Font small = Theme.Retro(9);
            string footer = stats.FirstSeen.HasValue
                ? "Since " + stats.FirstSeen.Value.ToLocalTime().ToString("MMM d", CultureInfo.InvariantCulture) +
                  " · " + stats.TotalSamples.ToString(CultureInfo.InvariantCulture) + " polls"
                : "Tracking starts on first poll";
            Draw.String(g, footer, small, Theme.TextMuted, pad, bounds.Height - 46);
        }

        private void PaintStatCell(Graphics g, RectangleF bounds, string label, string value, Color accent)
        {
            Draw.FillRounded(g, bounds, 6, Theme.BgPanel);
            Draw.TrackedString(g, label, Theme.Retro(8), Theme.TextMuted, bounds.X + 9, bounds.Y + 7, 1.5f);

            float size = 18;
            Font font = Theme.Retro(size);
            while (Draw.Measure(g, value, font).Width > bounds.Width - 18 && size > 8)
            {
                size -= 1;
                font = Theme.Retro(size);
            }
            Draw.String(g, value, font, accent, bounds.X + 9, bounds.Y + 7 + 14);
        }

        /// The capybara sits on the floor while water rises with whichever
        /// window is closer to its limit. At 100% she is fully submerged.
        private void PaintTamagotchi(Graphics g, RectangleF bounds)
        {
            UsageData usage = _daemon.Usage;
            double s = usage.SessionPercent.HasValue ? usage.SessionPercent.Value : 0;
            double w = usage.WeeklyPercent.HasValue ? usage.WeeklyPercent.Value : 0;
            double level = Math.Min(1, Math.Max(0, Math.Max(s, w) / 100.0));

            float pixel = Math.Max(3f, (float)Math.Floor(Math.Min(bounds.Width, bounds.Height) / 24f));
            float side = pixel * 16;
            var mascotBounds = new RectangleF(
                (bounds.Width - side) / 2f,
                bounds.Height - side - 34,
                side, side);

            double t = Clock.AnimationSeconds();
            if (_settings.ShowMascot)
            {
                Mascot.Draw(g, mascotBounds, usage.Mood, usage.MascotState, t, false, Theme.MascotTan);
            }

            // Water
            float waterHeight = (float)(bounds.Height * level);
            if (waterHeight > 0.5f)
            {
                var water = new RectangleF(0, bounds.Height - waterHeight, bounds.Width, waterHeight);
                using (var brush = new SolidBrush(Color.FromArgb(140, 64, 115, 173)))
                {
                    g.FillRectangle(brush, water);
                }
                PaintWave(g, water.X, water.Y, water.Width, t);
            }

            // Header: level % and mood
            Font small = Theme.Retro(9);
            string pct = ((int)Math.Round(level * 100)).ToString(CultureInfo.InvariantCulture) + "%";
            Draw.String(g, pct, small, Theme.TextSecondary, 14, 12);

            string mood = Moods.Label(usage.Mood, DateTime.UtcNow).ToUpperInvariant();
            float moodWidth = Draw.Measure(g, mood, small).Width;
            Draw.String(g, mood, small, Theme.ColorFor(usage.SessionSeverity), bounds.Width - 14 - moodWidth, 12);
        }

        /// Two stacked pixel rows marching out of phase, so the surface reads
        /// as one wave instead of two stripes.
        private void PaintWave(Graphics g, float x, float y, float width, double t)
        {
            const float cell = 4;
            int columns = Math.Max(1, (int)(width / cell));
            float cellWidth = width / columns;
            int tick = (int)(t * 2);

            using (var bright = new SolidBrush(Color.FromArgb(217, 82, 148, 204)))
            using (var dim = new SolidBrush(Color.FromArgb(140, 56, 107, 158)))
            {
                for (int i = 0; i < columns; i++)
                {
                    if ((i + tick) % 2 == 0)
                        g.FillRectangle(bright, x + i * cellWidth, y, cellWidth, cell);
                    if ((i + tick + 1) % 2 == 0)
                        g.FillRectangle(dim, x + i * cellWidth, y + cell, cellWidth, cell);
                }
            }
        }

        private void PaintPager(Graphics g, RectangleF bounds)
        {
            const int count = 4;
            float dotSpacing = 11;
            float centerY = bounds.Height - 18;
            float dotsWidth = dotSpacing * (count - 1);
            float arrowGap = 18;
            float totalWidth = dotsWidth + arrowGap * 2 + 20;
            float startX = (bounds.Width - totalWidth) / 2f;

            var capsule = new RectangleF(startX - 6, centerY - 10, totalWidth + 12, 20);
            Draw.FillRounded(g, capsule, 10, Theme.Fade(Theme.BgPanel, 0.85));

            // Left arrow
            var leftBounds = new RectangleF(startX, centerY - 8, 16, 16);
            var left = new HitButton(Glyphs.ChevronLeft, "Previous", delegate { if (_page > 0) _page--; });
            left.Bounds = leftBounds;
            left.Enabled = _page > 0;
            _hits.Add(left);

            // Dots
            float dotsStart = startX + arrowGap + 10;
            for (int i = 0; i < count; i++)
            {
                int captured = i;
                var dotBounds = new RectangleF(dotsStart + i * dotSpacing - 5, centerY - 6, 12, 12);
                var dot = new HitButton(null, null, delegate { _page = captured; });
                dot.Bounds = dotBounds;
                _hits.Add(dot);

                using (var brush = new SolidBrush(i == _page ? Theme.AccentWarm : Theme.Fade(Theme.TextMuted, 0.5)))
                {
                    g.FillEllipse(brush, dotsStart + i * dotSpacing - 2.5f, centerY - 2.5f, 5, 5);
                }
            }

            // Right arrow
            var rightBounds = new RectangleF(dotsStart + dotsWidth + arrowGap - 8, centerY - 8, 16, 16);
            var right = new HitButton(Glyphs.ChevronRight, "Next", delegate { if (_page < count - 1) _page++; });
            right.Bounds = rightBounds;
            right.Enabled = _page < count - 1;
            _hits.Add(right);

            Font glyphFont = Glyphs.Font(9);
            PaintGlyph(g, glyphFont, left);
            PaintGlyph(g, glyphFont, right);
        }

        private void PaintGlyph(Graphics g, Font font, HitButton button)
        {
            if (string.IsNullOrEmpty(button.Glyph)) return;
            SizeF size = Draw.Measure(g, button.Glyph, font);
            Draw.String(g, button.Glyph, font,
                button.Enabled ? Theme.TextSecondary : Theme.Fade(Theme.TextMuted, 0.4),
                button.Bounds.X + (button.Bounds.Width - size.Width) / 2f,
                button.Bounds.Y + (button.Bounds.Height - size.Height) / 2f);
        }

        private void PaintGrip(Graphics g)
        {
            RectangleF grip = GripBounds();
            using (var pen = new Pen(Theme.Fade(Theme.TextMuted, 0.7), 1.5f))
            {
                for (int i = 0; i < 3; i++)
                {
                    float offset = i * 4;
                    g.DrawLine(pen,
                        grip.Right - 2 - offset, grip.Bottom - 2,
                        grip.Right - 2, grip.Bottom - 2 - offset);
                }
            }
        }

        private static string ShortReset(DateTime? resetAt)
        {
            if (!resetAt.HasValue) return "—";
            double delta = (resetAt.Value - DateTime.UtcNow).TotalSeconds;
            if (delta < 0) return "NOW";
            if (delta < 3600) return ((int)(delta / 60)).ToString(CultureInfo.InvariantCulture) + "M";
            if (delta < 86400)
            {
                int h = (int)(delta / 3600);
                int m = (int)((delta % 3600) / 60);
                return m > 0
                    ? h.ToString(CultureInfo.InvariantCulture) + "H " + m.ToString(CultureInfo.InvariantCulture) + "M"
                    : h.ToString(CultureInfo.InvariantCulture) + "H";
            }
            return ((int)(delta / 86400)).ToString(CultureInfo.InvariantCulture) + "D";
        }

        private static int Clamp(int value, int min, int max)
        {
            if (value < min) return min;
            if (value > max) return max;
            return value;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _daemon.Changed -= OnDaemonChanged;
                if (_animation != null) _animation.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
