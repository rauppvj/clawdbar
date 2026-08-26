using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace ClawdBar
{
    internal static class Theme
    {
        // Backgrounds
        public static readonly Color BgDeep = Color.FromArgb(0x0E, 0x0E, 0x10);
        public static readonly Color BgPanel = Color.FromArgb(0x17, 0x17, 0x1B);
        public static readonly Color BgRaised = Color.FromArgb(0x22, 0x22, 0x28);
        public static readonly Color Stroke = Color.FromArgb(38, 255, 255, 255);

        // Accents
        public static readonly Color AccentWarm = Color.FromArgb(0xFF, 0x8A, 0x4C);
        public static readonly Color AccentCool = Color.FromArgb(0xA8, 0x8B, 0xFF);

        // Text
        public static readonly Color TextPrimary = Color.FromArgb(0xF5, 0xF5, 0xF5);
        public static readonly Color TextSecondary = Color.FromArgb(0xA0, 0xA0, 0xA8);
        public static readonly Color TextMuted = Color.FromArgb(0x6A, 0x6A, 0x72);

        // Mascot body
        public static readonly Color MascotTan = Color.FromArgb(0x8B, 0x6F, 0x4E);
        public static readonly Color MascotTanDark = Color.FromArgb(0x6E, 0x57, 0x3D);

        public static Color ColorFor(Severity severity)
        {
            switch (severity)
            {
                case Severity.Ok: return Color.FromArgb(0x4A, 0xDE, 0x80);
                case Severity.Warning: return Color.FromArgb(0xFA, 0xCC, 0x15);
                case Severity.Danger: return Color.FromArgb(0xFF, 0x8A, 0x4C);
                default: return Color.FromArgb(0xFF, 0x5C, 0x5C);
            }
        }

        public static Color Fade(Color color, double alpha)
        {
            int a = (int)Math.Round(Math.Max(0, Math.Min(1, alpha)) * 255);
            return Color.FromArgb(a, color.R, color.G, color.B);
        }

        // ------------------------------------------------------------- fonts

        private static readonly Dictionary<string, Font> FontCache =
            new Dictionary<string, Font>(StringComparer.Ordinal);

        private static PrivateFontCollection _collection;
        private static IntPtr _fontBuffer = IntPtr.Zero;
        private static bool _fontLoadAttempted;
        private static FontFamily _pressStart;

        /// Press Start 2P (SIL OFL) when the embedded TTF loads; Consolas as
        /// the fallback. Sized at 0.85x like the macOS build, because Press
        /// Start 2P renders visually larger than a system font at the same pt.
        public static Font Retro(float size)
        {
            return Retro(size, FontStyle.Regular);
        }

        public static Font Retro(float size, FontStyle style)
        {
            EnsureFontLoaded();
            string key = "R|" + size.ToString("0.##", CultureInfo.InvariantCulture) + "|" + (int)style;
            Font cached;
            if (FontCache.TryGetValue(key, out cached)) return cached;

            Font font;
            if (_pressStart != null)
            {
                try
                {
                    font = new Font(_pressStart, size * 0.85f, FontStyle.Regular, GraphicsUnit.Pixel);
                }
                catch
                {
                    font = new Font(FontFamily.GenericMonospace, size, style, GraphicsUnit.Pixel);
                }
            }
            else
            {
                font = MonospaceFallback(size, style);
            }

            FontCache[key] = font;
            return font;
        }

        /// Plain UI font for prose that would be unreadable in Press Start 2P.
        public static Font Ui(float size, FontStyle style)
        {
            string key = "U|" + size.ToString("0.##", CultureInfo.InvariantCulture) + "|" + (int)style;
            Font cached;
            if (FontCache.TryGetValue(key, out cached)) return cached;
            var font = new Font("Segoe UI", size, style, GraphicsUnit.Pixel);
            FontCache[key] = font;
            return font;
        }

        public static Font Mono(float size, FontStyle style)
        {
            string key = "M|" + size.ToString("0.##", CultureInfo.InvariantCulture) + "|" + (int)style;
            Font cached;
            if (FontCache.TryGetValue(key, out cached)) return cached;
            var font = MonospaceFallback(size, style);
            FontCache[key] = font;
            return font;
        }

        private static Font MonospaceFallback(float size, FontStyle style)
        {
            try
            {
                return new Font("Consolas", size, style, GraphicsUnit.Pixel);
            }
            catch
            {
                return new Font(FontFamily.GenericMonospace, size, style, GraphicsUnit.Pixel);
            }
        }

        public static bool HasPressStart2P
        {
            get
            {
                EnsureFontLoaded();
                return _pressStart != null;
            }
        }

        private static void EnsureFontLoaded()
        {
            if (_fontLoadAttempted) return;
            _fontLoadAttempted = true;
            try
            {
                byte[] data = ReadEmbeddedFont();
                if (data == null) return;
                _collection = new PrivateFontCollection();
                _fontBuffer = Marshal.AllocCoTaskMem(data.Length);
                Marshal.Copy(data, 0, _fontBuffer, data.Length);
                _collection.AddMemoryFont(_fontBuffer, data.Length);
                if (_collection.Families.Length > 0) _pressStart = _collection.Families[0];
            }
            catch
            {
                _pressStart = null;
            }
        }

        private static byte[] ReadEmbeddedFont()
        {
            var assembly = Assembly.GetExecutingAssembly();
            string[] names = assembly.GetManifestResourceNames();
            for (int i = 0; i < names.Length; i++)
            {
                if (names[i].IndexOf("PressStart2P", StringComparison.OrdinalIgnoreCase) < 0) continue;
                using (Stream stream = assembly.GetManifestResourceStream(names[i]))
                {
                    if (stream == null) continue;
                    var buffer = new byte[stream.Length];
                    int read = 0;
                    while (read < buffer.Length)
                    {
                        int chunk = stream.Read(buffer, read, buffer.Length - read);
                        if (chunk <= 0) break;
                        read += chunk;
                    }
                    return buffer;
                }
            }
            return null;
        }
    }

    internal static class AppIcon
    {
        public static Icon Load()
        {
            var assembly = Assembly.GetExecutingAssembly();
            string[] names = assembly.GetManifestResourceNames();
            for (int i = 0; i < names.Length; i++)
            {
                if (names[i].IndexOf("clawdbar.ico", StringComparison.OrdinalIgnoreCase) < 0) continue;
                using (Stream stream = assembly.GetManifestResourceStream(names[i]))
                {
                    if (stream != null) return new Icon(stream);
                }
            }
            return SystemIcons.Application;
        }
    }

    internal static class Windowing
    {
        /// FormStartPosition.CenterScreen picks whichever screen Windows feels
        /// like, which on a multi-monitor desktop can drop a first-run dialog
        /// on a display the user is not looking at. Always use the primary.
        public static void CenterOnPrimary(System.Windows.Forms.Form form)
        {
            form.StartPosition = System.Windows.Forms.FormStartPosition.Manual;
            Rectangle work = System.Windows.Forms.Screen.PrimaryScreen.WorkingArea;
            form.Location = new Point(
                work.Left + Math.Max(0, (work.Width - form.Width) / 2),
                work.Top + Math.Max(0, (work.Height - form.Height) / 2));
        }

        /// Pulls a window in front of whatever has focus. A background process
        /// cannot call SetForegroundWindow directly, so we flip TopMost on and
        /// straight back off — the window rises without staying pinned.
        public static void BringToFront(System.Windows.Forms.Form form)
        {
            form.TopMost = true;
            form.Activate();
            form.TopMost = false;
        }
    }

    /// Shared GDI+ helpers. Kept in one place so every surface (tray icon,
    /// popup, overlay) draws rounded rectangles and bars identically.
    internal static class Draw
    {
        /// GenericTypographic gives tight, predictable glyph metrics — but it
        /// also drops trailing spaces from MeasureString, which collapsed
        /// "RESETS IN 3H" to "RESETS IN3H" and made single-character widths
        /// short enough for the next run to overlap. MeasureTrailingSpaces
        /// restores the space without giving up the tight metrics.
        public static readonly StringFormat Format = BuildFormat();

        private static StringFormat BuildFormat()
        {
            var format = new StringFormat(StringFormat.GenericTypographic);
            format.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces;
            return format;
        }

        public static GraphicsPath RoundedRect(RectangleF bounds, float radius)
        {
            var path = new GraphicsPath();
            if (radius <= 0.01f)
            {
                path.AddRectangle(bounds);
                return path;
            }
            float d = radius * 2;
            d = Math.Min(d, Math.Min(bounds.Width, bounds.Height));
            path.AddArc(bounds.X, bounds.Y, d, d, 180, 90);
            path.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
            path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
            path.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        public static void FillRounded(Graphics g, RectangleF bounds, float radius, Color color)
        {
            using (var path = RoundedRect(bounds, radius))
            using (var brush = new SolidBrush(color))
            {
                g.FillPath(brush, path);
            }
        }

        public static void StrokeRounded(Graphics g, RectangleF bounds, float radius, Color color, float width)
        {
            using (var path = RoundedRect(bounds, radius))
            using (var pen = new Pen(color, width))
            {
                g.DrawPath(pen, path);
            }
        }

        /// Progress bar used by the popup, the overlay and the tray icon.
        public static void UsageBar(Graphics g, RectangleF bounds, double? percent, Severity severity, double opacity)
        {
            double normalized = Math.Max(0, Math.Min(1, (percent.HasValue ? percent.Value : 0) / 100.0));
            float radius = bounds.Height / 2.4f;
            FillRounded(g, bounds, radius, Theme.Fade(Theme.BgRaised, opacity));
            if (normalized > 0)
            {
                var filled = new RectangleF(bounds.X, bounds.Y, (float)(bounds.Width * normalized), bounds.Height);
                if (filled.Width > 0.5f)
                {
                    FillRounded(g, filled, Math.Min(radius, filled.Width / 2f),
                        Theme.Fade(Theme.ColorFor(severity), opacity));
                }
            }
            if (!percent.HasValue)
            {
                StrokeRounded(g, bounds, radius, Theme.Stroke, 1f);
            }
        }

        /// Draws text with manual letter spacing. GDI+ has no tracking option,
        /// and the macOS design leans on wide tracking for its labels.
        public static void TrackedString(Graphics g, string text, Font font, Color color, float x, float y, float tracking)
        {
            using (var brush = new SolidBrush(color))
            {
                float cursor = x;
                for (int i = 0; i < text.Length; i++)
                {
                    string ch = text.Substring(i, 1);
                    g.DrawString(ch, font, brush, cursor, y, Format);
                    cursor += g.MeasureString(ch, font, PointF.Empty, Format).Width + tracking;
                }
            }
        }

        public static float MeasureTracked(Graphics g, string text, Font font, float tracking)
        {
            float total = 0;
            for (int i = 0; i < text.Length; i++)
            {
                total += g.MeasureString(text.Substring(i, 1), font, PointF.Empty, Format).Width + tracking;
            }
            return total;
        }

        public static void String(Graphics g, string text, Font font, Color color, float x, float y)
        {
            using (var brush = new SolidBrush(color))
            {
                g.DrawString(text, font, brush, x, y, Format);
            }
        }

        public static SizeF Measure(Graphics g, string text, Font font)
        {
            return g.MeasureString(text, font, PointF.Empty, Format);
        }

        public static void HighQuality(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        }
    }
}
