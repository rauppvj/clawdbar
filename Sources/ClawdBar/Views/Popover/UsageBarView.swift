import SwiftUI

struct UsageBarView: View {
    let percent: Double?
    let severity: UsageData.Severity

    var body: some View {
        GeometryReader { geo in
            let normalized = max(0, min(1, (percent ?? 0) / 100))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.bgRaised)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Theme.color(for: severity).opacity(0.85),
                                Theme.color(for: severity),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * normalized)
                    .animation(.easeOut(duration: 0.35), value: normalized)
                if percent == nil {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                }
            }
        }
        .frame(height: 8)
    }
}
