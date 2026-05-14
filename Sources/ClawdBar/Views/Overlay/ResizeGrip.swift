import SwiftUI

/// Tiny corner affordance the user can drag to resize the borderless overlay
/// panel. A native NSPanel with `.borderless` strips the system resize handles,
/// so we provide our own. Only shown when the user has unlocked the size.
struct ResizeGrip: View {
    let onResize: (CGSize) -> Void
    @State private var lastTranslation: CGSize = .zero

    var body: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Theme.textMuted)
            .padding(5)
            .background(Theme.bgRaised.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .local)
                    .onChanged { value in
                        let delta = CGSize(
                            width: value.translation.width - lastTranslation.width,
                            height: value.translation.height - lastTranslation.height
                        )
                        lastTranslation = value.translation
                        onResize(delta)
                    }
                    .onEnded { _ in
                        lastTranslation = .zero
                    }
            )
            .help("Drag to resize")
    }
}
