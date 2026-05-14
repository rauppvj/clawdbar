import SwiftUI

enum Theme {
    // Backgrounds
    static let bgDeep = Color(red: 0x0E / 255, green: 0x0E / 255, blue: 0x10 / 255)
    static let bgPanel = Color(red: 0x17 / 255, green: 0x17 / 255, blue: 0x1B / 255)
    static let bgRaised = Color(red: 0x22 / 255, green: 0x22 / 255, blue: 0x28 / 255)
    static let stroke = Color.white.opacity(0.06)

    // Accents
    static let accentWarm = Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0x4C / 255)   // warm orange
    static let accentCool = Color(red: 0xA8 / 255, green: 0x8B / 255, blue: 0xFF / 255)   // soft purple

    // Text
    static let textPrimary = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF5 / 255)
    static let textSecondary = Color(red: 0xA0 / 255, green: 0xA0 / 255, blue: 0xA8 / 255)
    static let textMuted = Color(red: 0x6A / 255, green: 0x6A / 255, blue: 0x72 / 255)

    // Severity
    static func color(for severity: UsageData.Severity) -> Color {
        switch severity {
        case .ok:       return Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255)
        case .warning:  return Color(red: 0xFA / 255, green: 0xCC / 255, blue: 0x15 / 255)
        case .danger:   return Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0x4C / 255)
        case .critical: return Color(red: 0xFF / 255, green: 0x5C / 255, blue: 0x5C / 255)
        }
    }

    /// Press Start 2P (SIL OFL) when bundled successfully; system monospaced as a fallback.
    /// The font is registered eagerly at app launch via BundledFont.registerAll(),
    /// so by the time any view calls this, .custom() succeeds or silently falls back.
    @MainActor
    static func retro(size: CGFloat, weight: Font.Weight = .bold) -> Font {
        if BundledFont.hasPressStart2P {
            return .custom("PressStart2P-Regular", size: size * 0.85, relativeTo: .body)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}

extension UsageData {
    enum Mood: String {
        case idle = "Idle"
        case musing = "Musing"
        case focused = "Focused"
        case cooking = "Cooking"
        case sweating = "Sweating"
        case melting = "Melting"
        case toast = "Toast"

        static func from(percent: Double?) -> Mood {
            guard let p = percent else { return .idle }
            switch p {
            case ..<10:  return .idle
            case ..<30:  return .musing
            case ..<55:  return .focused
            case ..<75:  return .cooking
            case ..<88:  return .sweating
            case ..<97:  return .melting
            default:     return .toast
            }
        }

        /// Rotating verb variants per mood — same vibe as Claude Code's
        /// "Cogitating / Pondering / Brewing…" status text. UI sites cycle
        /// through these so the popover/overlay/menu bar feel alive instead
        /// of locked on one word.
        var labelVariants: [String] {
            switch self {
            case .idle:     return ["Idle", "Resting", "Yawning", "Lounging"]
            case .musing:   return ["Musing", "Pondering", "Mulling", "Reflecting"]
            case .focused:  return ["Focused", "Cogitating", "Computing", "Thinking", "Crafting"]
            case .cooking:  return ["Cooking", "Brewing", "Iterating", "Forging", "Percolating"]
            case .sweating: return ["Sweating", "Grinding", "Stewing", "Chugging", "Smelting"]
            case .melting:  return ["Melting", "Frying", "Boiling", "Frazzling", "Singeing"]
            case .toast:    return ["Toast", "Cooked", "Maxed", "Crispy", "Burnt"]
            }
        }

        /// Picks one variant from `labelVariants` based on a shared time slot
        /// — all UI sites passing the same date show the same word, so the
        /// popover and overlay stay in sync.
        func label(at date: Date = .now) -> String {
            let variants = labelVariants
            let slot = Int(date.timeIntervalSinceReferenceDate / 10) % variants.count
            return variants[slot]
        }
    }

    /// Mood is driven by the higher of session vs weekly utilization,
    /// since hitting either limit is what matters.
    var mood: Mood {
        let max = [sessionPercent ?? 0, weeklyPercent ?? 0].max() ?? 0
        return Mood.from(percent: max)
    }
}
