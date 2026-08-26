using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ClawdBar
{
    /// Windows counterpart of MenuBarLabelView. The macOS menu bar can host a
    /// wide label ("S:12% W:34%"); a Windows tray slot is a square icon, so
    /// every style is redrawn to fit a square and the full text moves into the
    /// tooltip instead.
    internal static class TrayIconRenderer
    {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool DestroyIcon(IntPtr handle);

        public static int IconSize
        {
            get
            {
                try
                {
                    int size = SystemInformation.SmallIconSize.Width;
                    return size >= 16 ? size : 16;
                }
                catch
                {
                    return 16;
                }
            }
        }

        public static Icon Render(UsageDaemon daemon, AppSettings settings, double animationSeconds)
        {
            int size = IconSize;
            using (var bitmap = new Bitmap(size, size))
            {
                using (Graphics g = Graphics.FromImage(bitmap))
                {
                    g.Clear(Color.Transparent);
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;

                    UsageData usage = daemon.Usage;
                    if (!usage.HasEverUpdated)
                    {
                        DrawPlaceholder(g, size, daemon.LastError != null);
                    }
                    else
                    {
                        double opacity = usage.IsStale ? 0.55 : 1.0;
                        switch (settings.TrayStyle)
                        {
                            case TrayStyle.Numeric: DrawNumeric(g, size, usage, opacity); break;
                            case TrayStyle.MiniBar: DrawMiniBar(g, size, usage, opacity); break;
                            case TrayStyle.Mascot: DrawMascot(g, size, usage, animationSeconds, opacity); break;
                            case TrayStyle.DualBar: DrawDualBar(g, size, usage, opacity); break;
                            default: DrawHybrid(g, size, usage, animationSeconds, opacity); break;
                        }
                    }
                }
                return ToIcon(bitmap);
            }
        }

        /// Bitmap -> Icon. GetHicon allocates an unmanaged handle that Icon
        /// does not own, so we clone into a managed icon and destroy the handle
        /// immediately — otherwise a poll every 60s leaks a GDI handle a minute.
        private static Icon ToIcon(Bitmap bitmap)
        {
            IntPtr handle = bitmap.GetHicon();
            try
            {
                using (var temp = Icon.FromHandle(handle))
                {
                    return (Icon)temp.Clone();
                }
            }
            finally
            {
                DestroyIcon(handle);
            }
        }

        private static void DrawPlaceholder(Graphics g, int size, bool isError)
        {
            Color color = isError ? Theme.AccentWarm : Theme.TextSecondary;
            float inset = size * 0.18f;
            var rect = new RectangleF(inset, inset, size - inset * 2, size - inset * 2);
            using (var pen = new Pen(color, Math.Max(1.4f, size / 12f)))
            {
                g.DrawEllipse(pen, rect);
            }
            if (isError)
            {
                using (var brush = new SolidBrush(color))
                {
                    float w = Math.Max(1.5f, size / 9f);
                    g.FillRectangle(brush, size / 2f - w / 2f, size * 0.30f, w, size * 0.28f);
                    g.FillRectangle(brush, size / 2f - w / 2f, size * 0.65f, w, w);
                }
            }
            else
            {
                using (var brush = new SolidBrush(color))
                {
                    float d = Math.Max(2f, size / 6f);
                    g.FillEllipse(brush, size / 2f - d / 2f, size / 2f - d / 2f, d, d);
                }
            }
        }

        private static void DrawNumeric(Graphics g, int size, UsageData usage, double opacity)
        {
            string text = usage.DisplaySessionPercent.HasValue
                ? usage.DisplaySessionPercent.Value.ToString(CultureInfo.InvariantCulture)
                : "--";
            Color color = Theme.Fade(Theme.ColorFor(usage.SessionSeverity), opacity);
            DrawFittedNumber(g, new RectangleF(0, 0, size, size), text, color);
        }

        private static void DrawMiniBar(Graphics g, int size, UsageData usage, double opacity)
        {
            float barHeight = Math.Max(3f, size * 0.22f);
            float margin = Math.Max(1f, size * 0.09f);
            var textArea = new RectangleF(0, 0, size, size - barHeight - margin);
            string text = usage.DisplaySessionPercent.HasValue
                ? usage.DisplaySessionPercent.Value.ToString(CultureInfo.InvariantCulture)
                : "--";
            DrawFittedNumber(g, textArea, text, Theme.Fade(Theme.TextPrimary, opacity));
            var bar = new RectangleF(margin, size - barHeight - margin * 0.5f, size - margin * 2, barHeight);
            Draw.UsageBar(g, bar, usage.SessionPercent, usage.SessionSeverity, opacity);
        }

        private static void DrawDualBar(Graphics g, int size, UsageData usage, double opacity)
        {
            float margin = Math.Max(1f, size * 0.10f);
            float spacing = Math.Max(2f, size * 0.14f);
            float barHeight = Math.Max(3f, (size - margin * 2 - spacing) / 2f);
            float width = size - margin * 2;
            float top = (size - (barHeight * 2 + spacing)) / 2f;

            Draw.UsageBar(g, new RectangleF(margin, top, width, barHeight),
                usage.SessionPercent, usage.SessionSeverity, opacity);
            Draw.UsageBar(g, new RectangleF(margin, top + barHeight + spacing, width, barHeight),
                usage.WeeklyPercent, usage.WeeklySeverity, opacity);
        }

        private static void DrawMascot(Graphics g, int size, UsageData usage, double t, double opacity)
        {
            DrawMascotInto(g, new RectangleF(0, 0, size, size), usage, t, opacity);
        }

        private static void DrawHybrid(Graphics g, int size, UsageData usage, double t, double opacity)
        {
            float barHeight = Math.Max(2.5f, size * 0.17f);
            float margin = Math.Max(1f, size * 0.09f);
            DrawMascotInto(g, new RectangleF(0, -size * 0.06f, size, size - barHeight), usage, t, opacity);
            var bar = new RectangleF(margin, size - barHeight - margin * 0.4f, size - margin * 2, barHeight);
            Draw.UsageBar(g, bar, usage.SessionPercent, usage.SessionSeverity, opacity);
        }

        /// The tray has no template-image tinting like the macOS menu bar, so
        /// the mascot is drawn in full colour — the tan body reads against both
        /// light and dark taskbars.
        private static void DrawMascotInto(Graphics g, RectangleF bounds, UsageData usage, double t, double opacity)
        {
            if (opacity >= 0.99)
            {
                Mascot.Draw(g, bounds, usage.Mood, usage.MascotState, t, false, Theme.MascotTan);
                return;
            }
            // Fade by compositing through a temp layer, since the mascot draws
            // several colours and each would need its own alpha otherwise.
            int w = (int)Math.Ceiling(bounds.Width);
            int h = (int)Math.Ceiling(Math.Abs(bounds.Height) + Math.Abs(bounds.Y) + 2);
            if (w <= 0 || h <= 0) return;
            using (var layer = new Bitmap(w, h))
            {
                using (Graphics lg = Graphics.FromImage(layer))
                {
                    lg.SmoothingMode = SmoothingMode.AntiAlias;
                    lg.Clear(Color.Transparent);
                    Mascot.Draw(lg, new RectangleF(0, bounds.Y < 0 ? 0 : bounds.Y, bounds.Width, bounds.Height),
                        usage.Mood, usage.MascotState, t, false, Theme.MascotTan);
                }
                var matrix = new System.Drawing.Imaging.ColorMatrix();
                matrix.Matrix33 = (float)opacity;
                using (var attributes = new System.Drawing.Imaging.ImageAttributes())
                {
                    attributes.SetColorMatrix(matrix);
                    g.DrawImage(layer, new Rectangle((int)bounds.X, (int)Math.Min(0, bounds.Y), w, h),
                        0, 0, w, h, GraphicsUnit.Pixel, attributes);
                }
            }
        }

        /// Picks the largest font size whose rendering still fits the box, so
        /// "7" and "100" both fill a 16px icon without clipping.
        private static void DrawFittedNumber(Graphics g, RectangleF bounds, string text, Color color)
        {
            Font font = null;
            for (float candidate = bounds.Height; candidate >= 5f; candidate -= 0.5f)
            {
                Font probe = Theme.Mono(candidate, FontStyle.Bold);
                SizeF measured = Draw.Measure(g, text, probe);
                if (measured.Width <= bounds.Width && measured.Height <= bounds.Height)
                {
                    font = probe;
                    break;
                }
            }
            if (font == null) font = Theme.Mono(5f, FontStyle.Bold);

            SizeF size = Draw.Measure(g, text, font);
            float x = bounds.X + (bounds.Width - size.Width) / 2f;
            float y = bounds.Y + (bounds.Height - size.Height) / 2f;
            Draw.String(g, text, font, color, x, y);
        }

        public static string Tooltip(UsageDaemon daemon)
        {
            UsageData usage = daemon.Usage;
            if (!usage.HasEverUpdated)
            {
                return daemon.LastError != null ? "ClawdBar - " + ShortError(daemon.LastError) : "ClawdBar - starting...";
            }
            string s = usage.DisplaySessionPercent.HasValue
                ? usage.DisplaySessionPercent.Value.ToString(CultureInfo.InvariantCulture) + "%" : "-";
            string w = usage.DisplayWeeklyPercent.HasValue
                ? usage.DisplayWeeklyPercent.Value.ToString(CultureInfo.InvariantCulture) + "%" : "-";
            string text = "ClawdBar  5h " + s + "  |  7d " + w + "  |  " + Moods.Label(usage.Mood, DateTime.UtcNow);
            if (daemon.LastError != null) text += "  (" + ShortError(daemon.LastError) + ")";
            // The tray tooltip is capped at 127 characters by the shell.
            return text.Length > 127 ? text.Substring(0, 127) : text;
        }

        public static string ShortError(string message)
        {
            if (string.IsNullOrEmpty(message)) return "ERR";
            if (message.IndexOf("401", StringComparison.Ordinal) >= 0) return "AUTH";
            if (message.IndexOf("429", StringComparison.Ordinal) >= 0) return "RATE";
            if (message.IndexOf("network", StringComparison.OrdinalIgnoreCase) >= 0) return "OFFLINE";
            if (message.IndexOf("No credentials", StringComparison.OrdinalIgnoreCase) >= 0) return "NO LOGIN";
            return "ERR";
        }
    }
}
