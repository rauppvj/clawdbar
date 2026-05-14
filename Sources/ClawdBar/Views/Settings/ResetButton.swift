import SwiftUI

/// Small "↺" affordance next to each setting. Hidden when the value already
/// matches its default so unchanged rows don't get visual noise.
struct ResetButton: View {
    let isModified: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .opacity(isModified ? 1 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!isModified)
        .help("Reset to default")
        .frame(width: 18)
    }
}
