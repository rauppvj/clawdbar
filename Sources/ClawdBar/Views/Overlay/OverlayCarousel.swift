import SwiftUI

/// Multi-page carousel for the floating overlay. Wraps a stack of pages and
/// renders dot indicators + arrow affordances at the bottom. Pages are
/// preserved in the view tree (with opacity) so transitions feel instant
/// and inner state survives switching.
struct OverlayCarousel<P0: View, P1: View, P2: View, P3: View>: View {
    let page0: P0
    let page1: P1
    let page2: P2
    let page3: P3

    @State private var current: Int = 0
    private let count = 4

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                page0.opacity(current == 0 ? 1 : 0).allowsHitTesting(current == 0)
                page1.opacity(current == 1 ? 1 : 0).allowsHitTesting(current == 1)
                page2.opacity(current == 2 ? 1 : 0).allowsHitTesting(current == 2)
                page3.opacity(current == 3 ? 1 : 0).allowsHitTesting(current == 3)
            }
            .animation(.easeInOut(duration: 0.18), value: current)

            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            arrow("chevron.left") {
                if current > 0 { current -= 1 }
            }
            .disabled(current == 0)

            HStack(spacing: 5) {
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .fill(i == current ? Theme.accentWarm : Theme.textMuted.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .onTapGesture { current = i }
                }
            }

            arrow("chevron.right") {
                if current < count - 1 { current += 1 }
            }
            .disabled(current == count - 1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .padding(.bottom, 6)
    }

    private func arrow(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
