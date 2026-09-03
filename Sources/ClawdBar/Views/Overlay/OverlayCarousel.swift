import SwiftUI

/// Multi-page carousel for the floating overlay. Wraps a stack of pages and
/// renders dot indicators + arrow affordances at the bottom. Pages are
/// preserved in the view tree (with opacity) so transitions feel instant
/// and inner state survives switching.
///
/// `pageCount` can be smaller than the number of slots — the service-status
/// page drops out when the user turns that feature off, and the pager has to
/// shrink with it instead of paging to an empty view.
struct OverlayCarousel<P0: View, P1: View, P2: View, P3: View, P4: View>: View {
    let pageCount: Int
    let page0: P0
    let page1: P1
    let page2: P2
    let page3: P3
    let page4: P4

    @State private var current: Int = 0

    init(
        pageCount: Int = 5,
        page0: P0,
        page1: P1,
        page2: P2,
        page3: P3,
        page4: P4
    ) {
        self.pageCount = pageCount
        self.page0 = page0
        self.page1 = page1
        self.page2 = page2
        self.page3 = page3
        self.page4 = page4
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                page0.opacity(isVisible(0) ? 1 : 0).allowsHitTesting(isVisible(0))
                page1.opacity(isVisible(1) ? 1 : 0).allowsHitTesting(isVisible(1))
                page2.opacity(isVisible(2) ? 1 : 0).allowsHitTesting(isVisible(2))
                page3.opacity(isVisible(3) ? 1 : 0).allowsHitTesting(isVisible(3))
                page4.opacity(isVisible(4) ? 1 : 0).allowsHitTesting(isVisible(4))
            }
            .animation(.easeInOut(duration: 0.18), value: current)

            controls
        }
        .onChange(of: pageCount) { _, newCount in
            // Feature turned off while its page was on screen — step back.
            if current >= newCount { current = max(0, newCount - 1) }
        }
    }

    private func isVisible(_ index: Int) -> Bool {
        index < pageCount && current == index
    }

    private var controls: some View {
        HStack(spacing: 10) {
            arrow("chevron.left") {
                if current > 0 { current -= 1 }
            }
            .disabled(current == 0)

            HStack(spacing: 5) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Circle()
                        .fill(i == current ? Theme.accentWarm : Theme.textMuted.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .onTapGesture { current = i }
                }
            }

            arrow("chevron.right") {
                if current < pageCount - 1 { current += 1 }
            }
            .disabled(current >= pageCount - 1)
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
