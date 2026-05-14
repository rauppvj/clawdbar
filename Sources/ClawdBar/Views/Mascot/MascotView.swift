import SwiftUI

/// Procedural capybara on a 16×16 pixel grid. Animates body + eyes per
/// `MascotAnimationState`: idle "breathing" at low usage, working bob in the
/// middle band, a panic shake when the rate-limit window is closing in.
///
/// Body and eye groups are rendered as separate `PixelShape` views so each can
/// receive independent `.scaleEffect` / `.offset` transforms — Canvas alone
/// can't do per-part animation. A `TimelineView` drives the values from wall
/// time; pass `frozen: true` for one-shot renders (icon export, menu-bar bake).
struct MascotView: View {
    var mood: UsageData.Mood
    var severity: UsageData.Severity

    /// Outer pixel size (the mascot is 16×16 "pixels").
    var pixel: CGFloat = 4

    /// When true, render a single-color silhouette with transparent eye holes
    /// (intended for `NSImage.isTemplate = true` menu-bar rendering).
    var monochrome: Bool = false

    /// Drives body + eye animations. If `nil`, derived from `mood` so callers
    /// that don't track live usage (onboarding previews, About branding) still
    /// pick a sensible default state.
    var animationState: MascotAnimationState? = nil

    /// Skip the live `TimelineView` and render the frame at `t = 0`. Use for
    /// `ImageRenderer` bakes — the result is deterministic and reproducible.
    var frozen: Bool = false

    private var effectiveState: MascotAnimationState {
        animationState ?? MascotAnimationState.from(mood: mood)
    }

    var body: some View {
        if frozen {
            content(at: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                content(at: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    @ViewBuilder
    private func content(at t: Double) -> some View {
        let v = MascotAnim.values(for: effectiveState, at: t)
        ZStack {
            // Layer 1: body silhouette (ears + body block + legs).
            PixelShape(cells: bodySilhouetteCells)
                .fill(bodyColor)

            // Layer 2: right-edge depth column — color mode only.
            if !monochrome {
                PixelShape(cells: Self.shadowCells)
                    .fill(bodyDarker)
            }

            // Layer 3: each eye as its own view so it scales / offsets around
            // its own anchor (independent blink + look + wide).
            if !monochrome {
                eyeView(at: (5, 7), v: v)
                eyeView(at: (10, 7), v: v)
            }

            // Layer 4: mood-driven strain drops (independent of animation state
            // so high-usage moods still telegraph stress even at small sizes).
            if !monochrome {
                if mood == .sweating || mood == .melting || mood == .toast {
                    PixelShape(cells: [(14, 6), (14, 7)])
                        .fill(Theme.accentCool)
                }
                if mood == .melting || mood == .toast {
                    PixelShape(cells: [(1, 6), (1, 7)])
                        .fill(Theme.accentCool)
                }
                if mood == .toast {
                    PixelShape(cells: sparkCells(at: t))
                        .fill(Theme.accentWarm)
                }
            }
        }
        .frame(width: pixel * 16, height: pixel * 16)
        .scaleEffect(v.bodyScale, anchor: .center)
        .offset(x: v.bodyOffsetX, y: v.bodyOffsetY)
    }

    private func eyeView(at cell: (Int, Int), v: MascotAnim.Values) -> some View {
        // Anchor is the center of the cell in the view's unit coords, so
        // scale shrinks/grows the eye around its own midpoint rather than the
        // joint center of both eyes.
        let anchor = UnitPoint(
            x: (CGFloat(cell.0) + 0.5) / 16,
            y: (CGFloat(cell.1) + 0.5) / 16
        )
        return PixelShape(cells: [cell])
            .fill(faceColor)
            .frame(width: pixel * 16, height: pixel * 16)
            .scaleEffect(x: v.eyeXScale, y: v.eyeYScale, anchor: anchor)
            .offset(x: v.eyeXOffset)
    }

    // MARK: - Colors

    private static let tan = Color(red: 0x8B / 255, green: 0x6F / 255, blue: 0x4E / 255)
    private static let tanDark = Color(red: 0x6E / 255, green: 0x57 / 255, blue: 0x3D / 255)

    private var bodyColor: Color { monochrome ? .black : Self.tan }
    private var bodyDarker: Color { monochrome ? .black : Self.tanDark }
    private var faceColor: Color { Theme.bgDeep }

    // MARK: - Cell data

    private static let earCells: [(Int, Int)] = [
        (3, 3), (3, 4), (4, 4),    // left ear: tip top-outer, base steps inward
        (12, 3), (12, 4), (11, 4), // right ear: mirrored
    ]

    private static let eyeCells: [(Int, Int)] = [(5, 7), (10, 7)]

    private static let shadowCells: [(Int, Int)] = (5...9).map { (13, $0) }

    /// Body + ears + legs as a single set of cells so abutting rects unionize
    /// on fill and render seamlessly. Eye cells are punched out as transparent
    /// holes in monochrome mode (menu-bar bg shows through).
    private var bodySilhouetteCells: [(Int, Int)] {
        var cells: [(Int, Int)] = []
        cells.append(contentsOf: Self.earCells)

        let eyeHoles: Set<[Int]> = monochrome
            ? Set(Self.eyeCells.map { [$0.0, $0.1] })
            : []
        for y in 5...9 {
            for x in 2...13 {
                if eyeHoles.contains([x, y]) { continue }
                cells.append((x, y))
            }
        }
        for y in 10...11 {
            for x in [3, 6, 9, 12] {
                cells.append((x, y))
            }
        }
        return cells
    }

    private func sparkCells(at t: Double) -> [(Int, Int)] {
        Int(t * 2) % 2 == 0
            ? [(1, 1), (14, 2), (3, 14)]
            : [(2, 2), (13, 1), (14, 13)]
    }
}

// MARK: - Pixel grid shape

/// Renders a set of integer-grid cells as a single SwiftUI `Path`. Cells that
/// abut share edges internally on fill, so they render as one continuous shape
/// instead of N independent rectangles with antialiased seams.
struct PixelShape: Shape {
    let cells: [(Int, Int)]
    var grid: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let pixel = min(rect.width, rect.height) / grid
        var p = Path()
        for cell in cells {
            p.addRect(CGRect(
                x: CGFloat(cell.0) * pixel,
                y: CGFloat(cell.1) * pixel,
                width: pixel,
                height: pixel
            ))
        }
        return p
    }
}

// MARK: - Animation state

/// Four-band visual mode for the mascot, derived from current usage.
/// Boundaries are spec'd in the design reference: 0–25 sleep, 25–60 chill,
/// 60–80 work, 80+ panic. Decoupled from `UsageData.Mood` so the verb labels
/// (Pondering / Cogitating / Brewing) and the animation choice can evolve
/// independently.
enum MascotAnimationState: String {
    case sleep, chill, work, panic

    static func from(percent: Double?) -> Self {
        guard let p = percent else { return .sleep }
        switch p {
        case ..<25: return .sleep
        case ..<60: return .chill
        case ..<80: return .work
        default:    return .panic
        }
    }

    static func from(mood: UsageData.Mood) -> Self {
        switch mood {
        case .idle:                                  return .sleep
        case .musing, .focused:                      return .chill
        case .cooking:                               return .work
        case .sweating, .melting, .toast:            return .panic
        }
    }
}

extension UsageData {
    /// Single value the mascot views consume to pick which animation to run.
    var mascotAnimationState: MascotAnimationState {
        let p = [sessionPercent ?? 0, weeklyPercent ?? 0].max() ?? 0
        return MascotAnimationState.from(percent: p)
    }
}

// MARK: - Time-driven animation values

/// Deterministic per-frame animation values. Each state computes scale/offset
/// from wall time so live (`TimelineView`) and frozen (`t = 0`) renders share
/// the same function — no animation state to keep in sync across re-mounts.
enum MascotAnim {
    struct Values {
        var bodyScale: CGFloat = 1
        var bodyOffsetX: CGFloat = 0
        var bodyOffsetY: CGFloat = 0
        var eyeXScale: CGFloat = 1
        var eyeYScale: CGFloat = 1
        var eyeXOffset: CGFloat = 0
    }

    static func values(for state: MascotAnimationState, at t: Double) -> Values {
        switch state {
        case .sleep:
            // 5s slow breathe (scale 1 ↔ 1.015 + drift down 2px), eyes closed.
            let phase = (sin(t * 2 * .pi / 5) + 1) / 2
            return Values(
                bodyScale: 1 + phase * 0.015,
                bodyOffsetY: phase * 2,
                eyeYScale: 0.12
            )

        case .chill:
            // 3s breathe + ~5s blink (eye snaps closed for ~0.15s every cycle).
            let breathe = (sin(t * 2 * .pi / 3) + 1) / 2
            let blinkSlot = t.truncatingRemainder(dividingBy: 5)
            let blinking = blinkSlot >= 4.70 && blinkSlot <= 4.85
            return Values(
                bodyScale: 1 + breathe * 0.02,
                eyeYScale: blinking ? 0.1 : 1
            )

        case .work:
            // 1.1s bob (0 → -3 → 0) + 2.5s look-sideways for ~0.5s each cycle.
            let bob = sin(t * 2 * .pi / 1.1)              // -1 … 1
            let lookSlot = t.truncatingRemainder(dividingBy: 2.5)
            let looking = lookSlot >= 1.375 && lookSlot <= 1.875
            return Values(
                bodyOffsetY: -1.5 - bob * 1.5,            // -3 … 0
                eyeXOffset: looking ? -3 : 0
            )

        case .panic:
            // 0.09s random shake + 0.4s wide-eye pulse (scale 1.25 ↔ 1.45).
            let frame = Int(t / 0.09)
            let shakeX = (pseudoRandom01(frame * 2) * 6) - 3
            let shakeY = (pseudoRandom01(frame * 2 + 1) * 6) - 3
            let eyePulse = (sin(t * 2 * .pi / 0.4) + 1) / 2
            let eyeScale: CGFloat = 1.25 + CGFloat(eyePulse) * 0.2
            return Values(
                bodyOffsetX: CGFloat(shakeX),
                bodyOffsetY: CGFloat(shakeY),
                eyeXScale: eyeScale,
                eyeYScale: eyeScale
            )
        }
    }

    /// Deterministic pseudo-random in [0, 1) — hash int seed via Knuth's
    /// multiplicative constant, mask to 32 bits, normalize.
    private static func pseudoRandom01(_ seed: Int) -> Double {
        let masked = (seed &* 2_654_435_761) & 0xFFFF_FFFF
        return Double(masked) / Double(0xFFFF_FFFF)
    }
}
