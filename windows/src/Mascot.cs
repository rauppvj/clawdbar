using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;

namespace ClawdBar
{
    /// Deterministic per-frame animation values. Each state computes scale and
    /// offset from wall time, so a live frame and a frozen (t = 0) frame come
    /// from the same function — no animation state to keep in sync.
    internal struct MascotValues
    {
        public float BodyScale;
        public float BodyOffsetX;
        public float BodyOffsetY;
        public float EyeXScale;
        public float EyeYScale;
        public float EyeXOffset;

        public static MascotValues Neutral()
        {
            var v = new MascotValues();
            v.BodyScale = 1;
            v.EyeXScale = 1;
            v.EyeYScale = 1;
            return v;
        }

        public static MascotValues For(MascotState state, double t)
        {
            var v = Neutral();
            switch (state)
            {
                case MascotState.Sleep:
                    {
                        // 5s slow breathe (scale 1 -> 1.015, drifting down 2px), eyes closed.
                        double phase = (Math.Sin(t * 2 * Math.PI / 5) + 1) / 2;
                        v.BodyScale = (float)(1 + phase * 0.015);
                        v.BodyOffsetY = (float)(phase * 2);
                        v.EyeYScale = 0.12f;
                        break;
                    }
                case MascotState.Chill:
                    {
                        // 3s breathe + a ~0.15s blink every 5s.
                        double breathe = (Math.Sin(t * 2 * Math.PI / 3) + 1) / 2;
                        double blinkSlot = t % 5.0;
                        bool blinking = blinkSlot >= 4.70 && blinkSlot <= 4.85;
                        v.BodyScale = (float)(1 + breathe * 0.02);
                        v.EyeYScale = blinking ? 0.1f : 1f;
                        break;
                    }
                case MascotState.Work:
                    {
                        // 1.1s bob + a 0.5s sideways glance every 2.5s.
                        double bob = Math.Sin(t * 2 * Math.PI / 1.1);
                        double lookSlot = t % 2.5;
                        bool looking = lookSlot >= 1.375 && lookSlot <= 1.875;
                        v.BodyOffsetY = (float)(-1.5 - bob * 1.5);
                        v.EyeXOffset = looking ? -3f : 0f;
                        break;
                    }
                default:
                    {
                        // 0.09s random shake + 0.4s wide-eye pulse.
                        int frame = (int)(t / 0.09);
                        double shakeX = PseudoRandom01(frame * 2) * 6 - 3;
                        double shakeY = PseudoRandom01(frame * 2 + 1) * 6 - 3;
                        double eyePulse = (Math.Sin(t * 2 * Math.PI / 0.4) + 1) / 2;
                        float eyeScale = (float)(1.25 + eyePulse * 0.2);
                        v.BodyOffsetX = (float)shakeX;
                        v.BodyOffsetY = (float)shakeY;
                        v.EyeXScale = eyeScale;
                        v.EyeYScale = eyeScale;
                        break;
                    }
            }
            return v;
        }

        /// Deterministic pseudo-random in [0, 1) — Knuth multiplicative hash,
        /// masked to 32 bits and normalized.
        private static double PseudoRandom01(int seed)
        {
            unchecked
            {
                long masked = ((long)seed * 2654435761L) & 0xFFFFFFFFL;
                return masked / (double)0xFFFFFFFFL;
            }
        }
    }

    /// Procedural capybara on a 16x16 pixel grid, drawn with GDI+ rectangles.
    /// The macOS build renders this with SwiftUI Canvas; the cell data and the
    /// animation bands are identical so both platforms show the same creature.
    internal static class Mascot
    {
        private const int Grid = 16;

        private static readonly int[,] EarCells = {
            { 3, 3 }, { 3, 4 }, { 4, 4 },      // left ear: tip top-outer, base steps inward
            { 12, 3 }, { 12, 4 }, { 11, 4 },   // right ear: mirrored
        };

        private static readonly int[,] EyeCells = { { 5, 7 }, { 10, 7 } };

        public static void Draw(Graphics g, RectangleF bounds, Mood mood, MascotState state,
            double t, bool monochrome, Color monoColor)
        {
            float pixel = Math.Min(bounds.Width, bounds.Height) / Grid;
            if (pixel <= 0) return;

            MascotValues v = MascotValues.For(state, t);

            GraphicsState saved = g.Save();
            try
            {
                // Scale and offset the whole creature around its own center,
                // mirroring the SwiftUI scaleEffect(anchor: .center) + offset.
                float cx = bounds.X + bounds.Width / 2f;
                float cy = bounds.Y + bounds.Height / 2f;
                g.TranslateTransform(cx + v.BodyOffsetX, cy + v.BodyOffsetY);
                g.ScaleTransform(v.BodyScale, v.BodyScale);
                g.TranslateTransform(-cx, -cy);

                float originX = bounds.X + (bounds.Width - pixel * Grid) / 2f;
                float originY = bounds.Y + (bounds.Height - pixel * Grid) / 2f;

                Color bodyColor = monochrome ? monoColor : Theme.MascotTan;
                Color darkColor = monochrome ? monoColor : Theme.MascotTanDark;

                // Layer 1: body silhouette (ears + body block + legs).
                var silhouette = BodyCells(monochrome);
                FillCells(g, silhouette, originX, originY, pixel, bodyColor);

                if (!monochrome)
                {
                    // Layer 2: right-edge depth column.
                    var shadow = new List<Point>();
                    for (int y = 5; y <= 9; y++) shadow.Add(new Point(13, y));
                    FillCells(g, shadow, originX, originY, pixel, darkColor);

                    // Layer 3: eyes, each scaled around its own midpoint so the
                    // blink and the wide-eye pulse read per-eye.
                    for (int i = 0; i < EyeCells.GetLength(0); i++)
                    {
                        DrawEye(g, EyeCells[i, 0], EyeCells[i, 1], originX, originY, pixel, v);
                    }

                    // Layer 4: mood-driven strain, independent of the animation
                    // band so high usage still telegraphs stress at small sizes.
                    if (mood == Mood.Sweating || mood == Mood.Melting || mood == Mood.Toast)
                    {
                        FillCells(g, Cells(14, 6, 14, 7), originX, originY, pixel, Theme.AccentCool);
                    }
                    if (mood == Mood.Melting || mood == Mood.Toast)
                    {
                        FillCells(g, Cells(1, 6, 1, 7), originX, originY, pixel, Theme.AccentCool);
                    }
                    if (mood == Mood.Toast)
                    {
                        FillCells(g, SparkCells(t), originX, originY, pixel, Theme.AccentWarm);
                    }
                }
            }
            finally
            {
                g.Restore(saved);
            }
        }

        private static void DrawEye(Graphics g, int cellX, int cellY, float originX, float originY,
            float pixel, MascotValues v)
        {
            float centerX = originX + (cellX + 0.5f) * pixel + v.EyeXOffset;
            float centerY = originY + (cellY + 0.5f) * pixel;
            float w = pixel * v.EyeXScale;
            float h = pixel * v.EyeYScale;
            var rect = new RectangleF(centerX - w / 2f, centerY - h / 2f, Math.Max(w, 0.5f), Math.Max(h, 0.5f));
            using (var brush = new SolidBrush(Theme.BgDeep))
            {
                g.FillRectangle(brush, rect);
            }
        }

        /// Body + ears + legs as one cell set so abutting rects render as a
        /// single seamless shape. In monochrome mode the eye cells are punched
        /// out as transparent holes.
        private static List<Point> BodyCells(bool punchEyes)
        {
            var cells = new List<Point>();
            for (int i = 0; i < EarCells.GetLength(0); i++)
            {
                cells.Add(new Point(EarCells[i, 0], EarCells[i, 1]));
            }

            var holes = new HashSet<int>();
            if (punchEyes)
            {
                for (int i = 0; i < EyeCells.GetLength(0); i++)
                {
                    holes.Add(EyeCells[i, 0] * 100 + EyeCells[i, 1]);
                }
            }

            for (int y = 5; y <= 9; y++)
            {
                for (int x = 2; x <= 13; x++)
                {
                    if (holes.Contains(x * 100 + y)) continue;
                    cells.Add(new Point(x, y));
                }
            }

            int[] legs = { 3, 6, 9, 12 };
            for (int y = 10; y <= 11; y++)
            {
                for (int i = 0; i < legs.Length; i++) cells.Add(new Point(legs[i], y));
            }
            return cells;
        }

        private static List<Point> SparkCells(double t)
        {
            return ((int)(t * 2) % 2 == 0)
                ? Cells(1, 1, 14, 2, 3, 14)
                : Cells(2, 2, 13, 1, 14, 13);
        }

        private static List<Point> Cells(params int[] pairs)
        {
            var list = new List<Point>();
            for (int i = 0; i + 1 < pairs.Length; i += 2) list.Add(new Point(pairs[i], pairs[i + 1]));
            return list;
        }

        /// Fills cells through a single region so shared edges unionize instead
        /// of leaving antialiased seams between neighbouring rectangles.
        private static void FillCells(Graphics g, List<Point> cells, float originX, float originY,
            float pixel, Color color)
        {
            if (cells.Count == 0) return;
            using (var path = new GraphicsPath())
            {
                for (int i = 0; i < cells.Count; i++)
                {
                    path.AddRectangle(new RectangleF(
                        originX + cells[i].X * pixel,
                        originY + cells[i].Y * pixel,
                        pixel, pixel));
                }
                using (var region = new Region(path))
                using (var brush = new SolidBrush(color))
                {
                    g.FillRegion(brush, region);
                }
            }
        }
    }
}
