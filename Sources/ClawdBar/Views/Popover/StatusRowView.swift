import SwiftUI

struct StatusRowView: View {
    let title: String
    let percent: Double?
    let severity: UsageData.Severity
    let resetAt: Date?
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Theme.retro(size: 10))
                    .tracking(2)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(resetCaption)
                    .font(Theme.retro(size: 10, weight: .regular))
                    .foregroundStyle(Theme.textMuted)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(percentText)
                    .font(Theme.retro(size: 34, weight: .heavy))
                    .foregroundStyle(isStale ? Theme.textMuted : Theme.color(for: severity))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%")
                    .font(Theme.retro(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }

            UsageBarView(percent: percent, severity: severity)
                .opacity(isStale ? 0.5 : 1)
        }
    }

    private var percentText: String {
        guard let p = percent else { return "––" }
        return "\(Int(p.rounded()))"
    }

    private var resetCaption: String {
        guard let resetAt else { return "RESET —" }
        let delta = resetAt.timeIntervalSinceNow
        if delta < 0 { return "RESET NOW" }
        if delta < 60 { return "RESETS <1M" }
        if delta < 3600 {
            return "RESETS IN \(Int(delta / 60))M"
        }
        if delta < 86_400 {
            let h = Int(delta / 3600)
            let m = Int(delta.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? "RESETS IN \(h)H \(m)M" : "RESETS IN \(h)H"
        }
        let d = Int(delta / 86_400)
        let h = Int(delta.truncatingRemainder(dividingBy: 86_400) / 3600)
        return h > 0 ? "RESETS IN \(d)D \(h)H" : "RESETS IN \(d)D"
    }
}
