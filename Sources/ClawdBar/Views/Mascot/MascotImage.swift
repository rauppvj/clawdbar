import SwiftUI
import AppKit

/// Bakes the procedural MascotView (SwiftUI Canvas + TimelineView) into an
/// NSImage so the macOS menu bar can render it reliably. The menu bar refuses
/// to host TimelineView-driven views (no render loop), and live Canvas drawing
/// sometimes gets template-flattened — both surfaced as "nothing appears" bugs.
@MainActor
enum MascotImage {
    /// Bakes MascotView into an NSImage. When `monochrome` is true, the body
    /// is a single-color silhouette with transparent eye holes — AppKit then
    /// auto-tints it to fit the current menu-bar appearance (white in dark
    /// mode, black in light mode) because we set `isTemplate = true`.
    static func render(
        mood: UsageData.Mood,
        severity: UsageData.Severity,
        pointSize: CGFloat = 18,
        monochrome: Bool = false
    ) -> NSImage? {
        let pixel = pointSize / 16
        let renderer = ImageRenderer(content:
            // `frozen: true` so the baked NSImage is deterministic across
            // poll cycles — without it `TimelineView` would emit whatever
            // frame happened to be live at render time and the menu-bar
            // mascot would micro-jitter between refreshes.
            MascotView(mood: mood, severity: severity, pixel: pixel, monochrome: monochrome, frozen: true)
                .frame(width: pointSize, height: pointSize)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = monochrome
        return image
    }
}

/// Same baking trick for the mini progress bar that appears in menu-bar
/// styles. SwiftUI shapes inside the menu bar item sometimes clip or
/// drop their fill — converting to an NSImage sidesteps both.
@MainActor
enum BarImage {
    static func render(percent: Double?, severity: UsageData.Severity, width: CGFloat, height: CGFloat = 6) -> NSImage? {
        let view = singleBarView(percent: percent, severity: severity, width: width, height: height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let image = renderer.nsImage
        image?.isTemplate = false
        return image
    }

    @ViewBuilder
    static func singleBarView(percent: Double?, severity: UsageData.Severity, width: CGFloat, height: CGFloat) -> some View {
        let normalized = max(0, min(1, (percent ?? 0) / 100))
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: height / 3, style: .continuous)
                .fill(Color.secondary.opacity(0.30))
            RoundedRectangle(cornerRadius: height / 3, style: .continuous)
                .fill(Theme.color(for: severity))
                .frame(width: width * normalized)
        }
        .frame(width: width, height: height)
    }
}

/// Two stacked bars, baked into one NSImage so the menu bar item shows both.
/// Stacking SwiftUI views inside a MenuBarExtra label is unreliable — the
/// system can flatten a VStack to a single row, which is why "Dual Bar"
/// rendered only one bar.
@MainActor
enum DualBarImage {
    static func render(
        sessionPercent: Double?, sessionSeverity: UsageData.Severity,
        weeklyPercent: Double?, weeklySeverity: UsageData.Severity,
        width: CGFloat = 28, barHeight: CGFloat = 5, spacing: CGFloat = 2
    ) -> NSImage? {
        let view = VStack(spacing: spacing) {
            BarImage.singleBarView(percent: sessionPercent, severity: sessionSeverity, width: width, height: barHeight)
            BarImage.singleBarView(percent: weeklyPercent, severity: weeklySeverity, width: width, height: barHeight)
        }
        .frame(width: width, height: barHeight * 2 + spacing)

        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let image = renderer.nsImage
        image?.isTemplate = false
        return image
    }
}
