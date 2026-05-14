import SwiftUI

/// Top-level view hosted inside the floating overlay panel. Wraps the
/// existing single "current usage" view as page 0 of a carousel, with the
/// heatmap and stats pages alongside. The dark background + corner radius
/// + context menu + resize grip used to live on OverlayContentView; we lift
/// them up here so all pages share the same chrome.
struct OverlayCarouselHost: View {
    @Bindable var daemon: UsageDaemon
    @Bindable var settings: OverlaySettings
    var isResizable: Bool
    var onHide: () -> Void
    var onSnap: (OverlayContentView.Corner) -> Void
    var onSettingsChange: () -> Void
    var onResize: (CGSize) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.bgDeep)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )

            OverlayCarousel(
                page0: OverlayContentView(
                    daemon: daemon,
                    settings: settings,
                    onHide: onHide,
                    onSnap: onSnap,
                    onSettingsChange: onSettingsChange,
                    onResize: onResize,
                    isResizable: false,
                    asPage: true            // disable own background, no grip here
                ),
                page1: HeatmapPage(stats: UsageStats.compute(from: daemon.history.samples)),
                page2: StatsPage(stats: UsageStats.compute(from: daemon.history.samples)),
                page3: TamagotchiPage(daemon: daemon)
            )
        }
        .opacity(settings.opacity)
        .colorScheme(.dark)
        .overlay(alignment: .bottomTrailing) {
            if isResizable {
                ResizeGrip(onResize: onResize)
                    .padding(2)
            }
        }
        .contextMenu {
            Button("Hide", action: onHide)
            Divider()
            Menu("Snap to Corner") {
                ForEach(OverlayContentView.Corner.allCases) { corner in
                    Button(corner.rawValue) { onSnap(corner) }
                }
            }
            Menu("Opacity") {
                Button("100%") { settings.opacity = 1.0; onSettingsChange() }
                Button("75%")  { settings.opacity = 0.75; onSettingsChange() }
                Button("50%")  { settings.opacity = 0.5;  onSettingsChange() }
                Button("25%")  { settings.opacity = 0.25; onSettingsChange() }
            }
            Toggle("Click-Through", isOn: $settings.clickThrough)
            Toggle("Lock Position", isOn: $settings.locked)
        }
        .onChange(of: settings.clickThrough) { _, _ in onSettingsChange() }
        .onChange(of: settings.locked) { _, _ in onSettingsChange() }
    }
}
