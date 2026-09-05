import SwiftUI

/// The two secondary panels under the rate-limit bars. Token spend leads
/// because it changes every session; service status is a page you only need on
/// the rare day something is actually broken — but it carries a badge so a
/// live incident still pulls the eye while it sits behind a tab.
enum PopoverTab: String, CaseIterable, Identifiable {
    case tokens
    case status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokens: return "TOKENS"
        case .status: return "SERVICE"
        }
    }
}

struct PopoverTabStrip: View {
    let tabs: [PopoverTab]
    @Binding var selection: PopoverTab
    /// Dot colour drawn next to a tab's title, or nil for no badge.
    var badge: (PopoverTab) -> Color?

    var body: some View {
        HStack(spacing: 14) {
            ForEach(tabs) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = tab }
                } label: {
                    VStack(spacing: 4) {
                        HStack(spacing: 5) {
                            Text(tab.title)
                                .font(Theme.retro(size: 9, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(tab == selection ? Theme.textPrimary : Theme.textMuted)
                            if let color = badge(tab) {
                                Circle()
                                    .fill(color)
                                    .frame(width: 5, height: 5)
                                    .shadow(color: color.opacity(0.7), radius: 2)
                            }
                        }
                        Rectangle()
                            .fill(tab == selection ? Theme.accentWarm : .clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
