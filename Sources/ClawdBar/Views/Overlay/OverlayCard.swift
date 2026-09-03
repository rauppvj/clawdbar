import SwiftUI

/// The floating overlay's card chrome: dark rounded body, hairline border,
/// and — the part that earns this its own type — a clip that keeps full-bleed
/// page content inside the rounded silhouette.
///
/// The tamagotchi page paints its water as a full-width rect anchored to the
/// bottom edge. Unclipped, that rect floods the corner cut-outs (and the top
/// ones at a full tank) and paints over the border, which reads as the water
/// leaking out of the panel. Clip first, stroke after.
struct OverlayCard<Content: View>: View {
    static var cornerRadius: CGFloat { 18 }

    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            shape.fill(Theme.bgDeep)
            content
        }
        .clipShape(shape)
        // Border on top of the clipped content, so a full tank can't paint
        // over the outline.
        .overlay(shape.strokeBorder(Theme.stroke, lineWidth: 1))
    }
}
