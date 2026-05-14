import SwiftUI

/// 4th carousel page on the floating overlay: the capybara sits on the floor,
/// water rises with whichever rate-limit window (5h or 7d) is closer to the
/// edge. By 100% she's fully submerged. Mood-driven sweat drops + sparks come
/// for free from MascotView, so the panic story emerges from existing systems.
struct TamagotchiPage: View {
    @Bindable var daemon: UsageDaemon

    /// 0…1 — clamped, mirrors `mood` derivation (max of session vs weekly).
    private var level: Double {
        let s = daemon.usage.sessionPercent ?? 0
        let w = daemon.usage.weeklyPercent ?? 0
        return min(max(max(s, w) / 100, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Capybara — sits a touch above the bottom edge so legs aren't clipped.
                VStack {
                    Spacer()
                    MascotView(
                        mood: daemon.usage.mood,
                        severity: daemon.usage.sessionSeverity,
                        // Floor to an integer so cell rects land on whole-pixel
                        // boundaries — keeps the silhouette crisp instead of
                        // antialiased at fractional sizes.
                        pixel: max(3, (min(geo.size.width, geo.size.height) / 24).rounded(.down)),
                        // Live animation state derived from current usage —
                        // sleep / chill / work / panic as the water rises.
                        animationState: daemon.usage.mascotAnimationState
                    )
                    .padding(.bottom, 20)
                }
                .frame(width: geo.size.width, height: geo.size.height)

                // Water — translucent so the capybara shows through dimly when submerged.
                WaterLayer()
                    .frame(height: geo.size.height * CGFloat(level))
                    .clipped()

                // Header label: % and mood text, retro typeface.
                VStack {
                    HStack {
                        Text("\(Int((level * 100).rounded()))%")
                            .font(Theme.retro(size: 9, weight: .regular))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        TimelineView(.animation(minimumInterval: 10)) { context in
                            Text(daemon.usage.mood.label(at: context.date).uppercased())
                                .font(Theme.retro(size: 9, weight: .regular))
                                .foregroundStyle(Theme.color(for: daemon.usage.sessionSeverity))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    Spacer()
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(false)
            }
        }
    }
}

/// Solid translucent water body with a 2-row pixelated wave that shimmers
/// across time — like an ASCII ripple marching sideways. Two stacked rows
/// out of phase by one frame give a more wave-like feel than a single row.
private struct WaterLayer: View {
    private let waveHeight: CGFloat = 8  // two 4pt rows stacked

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.25, green: 0.45, blue: 0.68, opacity: 0.55)
            AnimatedWave().frame(height: waveHeight)
        }
    }
}

private struct AnimatedWave: View {
    private let cellSize: CGFloat = 4
    private let waveOn = Color(red: 0.32, green: 0.58, blue: 0.80, opacity: 0.85)
    private let waveDim = Color(red: 0.22, green: 0.42, blue: 0.62, opacity: 0.55)

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.45)) { context in
            // Single int that ticks ~2× per second; controls horizontal march.
            let tick = Int(context.date.timeIntervalSinceReferenceDate * 2)
            GeometryReader { geo in
                let cols = max(1, Int(geo.size.width / cellSize))
                let cellW = geo.size.width / CGFloat(cols)
                VStack(spacing: 0) {
                    // Top row: bright cells march one direction.
                    waveRow(cols: cols, cellW: cellW, parity: tick, color: waveOn)
                    // Bottom row: dim cells march opposite (offset by 1) so the
                    // surface reads as a single wave instead of two stripes.
                    waveRow(cols: cols, cellW: cellW, parity: tick + 1, color: waveDim)
                }
            }
        }
    }

    private func waveRow(cols: Int, cellW: CGFloat, parity: Int, color: Color) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<cols, id: \.self) { i in
                Rectangle()
                    .fill((i + parity) % 2 == 0 ? color : Color.clear)
                    .frame(width: cellW, height: cellSize)
            }
        }
    }
}
