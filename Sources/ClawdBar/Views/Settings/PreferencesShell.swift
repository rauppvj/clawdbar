import SwiftUI

enum PreferencesTab: String, CaseIterable, Identifiable {
    case general, appearance, floating, notifications, dataSource, about
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .floating: return "Floating"
        case .notifications: return "Notifications"
        case .dataSource: return "Data Source"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .floating: return "rectangle.on.rectangle"
        case .notifications: return "bell"
        case .dataSource: return "antenna.radiowaves.left.and.right"
        case .about: return "info.circle"
        }
    }
}

/// Custom Preferences "shell" — replaces SwiftUI's TabView, which on macOS is
/// backed by an NSToolbar that re-layouts on any view-tree churn (60 fps
/// during slider drags = dancing icons). This shell is 100% SwiftUI: an
/// HStack of buttons on top and a switch of content below. No AppKit toolbar
/// involved, so it doesn't react to downstream state churn.
struct PreferencesShell<General: View, Appearance: View, Floating: View, Notifications: View, DataSource: View, About: View>: View {

    @State private var selection: PreferencesTab = .general

    let general: General
    let appearance: Appearance
    let floating: Floating
    let notifications: Notifications
    let dataSource: DataSource
    let about: About

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 600, height: 460)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .general:       general
        case .appearance:    appearance
        case .floating:      floating
        case .notifications: notifications
        case .dataSource:    dataSource
        case .about:         about
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(PreferencesTab.allCases) { tab in
                TabButton(
                    tab: tab,
                    selected: selection == tab,
                    action: { selection = tab }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

private struct TabButton: View {
    let tab: PreferencesTab
    let selected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 16, weight: .regular))
                Text(tab.displayName)
                    .font(.caption)
            }
            .frame(width: 84, height: 50)
            .background(background)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var background: some View {
        if selected {
            Color.accentColor.opacity(0.18)
        } else if hovered {
            Color.primary.opacity(0.06)
        } else {
            Color.clear
        }
    }
}
