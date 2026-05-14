import Foundation
import Observation

/// Single source of truth for every default value. Used by AppSettings.init
/// AND by the per-setting "reset to default" buttons in the Settings view.
enum AppSettingsDefaults {
    static let pollInterval: TimeInterval = 60
    static let launchAtLogin: Bool = false
    static let menuBarStyle: MenuBarStyle = .numeric
    static let showMascot: Bool = true
    static let overlayEnabledOnLaunch: Bool = false
    static let overlayOpacity: Double = 1.0
    static let overlayClickThrough: Bool = false
    static let overlayDefaultCorner: SnapCorner = .topRight
    static let overlayLocked: Bool = true
    static let notificationsEnabled: Bool = true
    static let warningThreshold: Double = 80
    static let criticalThreshold: Double = 95
    static let notificationSound: Bool = true
    static let notifyForSession: Bool = true
    static let notifyForWeekly: Bool = true
    static let apiBaseURL: String = "https://api.anthropic.com"
    static let apiModel: String = "claude-haiku-4-5-20251001"
}

enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    case numeric, miniBar, mascot, dualBar, hybrid
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .numeric:  return "Numeric"
        case .miniBar:  return "Mini Bar"
        case .mascot:   return "Mascot"
        case .dualBar:  return "Dual Bar"
        case .hybrid:   return "Hybrid"
        }
    }
}

enum SnapCorner: String, CaseIterable, Identifiable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .topLeft:     return "Top Left"
        case .topRight:    return "Top Right"
        case .bottomLeft:  return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

@MainActor
@Observable
final class AppSettings {

    // MARK: - General
    var pollInterval: TimeInterval {
        didSet { defaults.set(pollInterval, forKey: Key.pollInterval) }
    }
    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    // MARK: - Appearance
    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Key.menuBarStyle) }
    }
    var showMascot: Bool {
        didSet { defaults.set(showMascot, forKey: Key.showMascot) }
    }

    // MARK: - Floating
    var overlayEnabledOnLaunch: Bool {
        didSet { defaults.set(overlayEnabledOnLaunch, forKey: Key.overlayOnLaunch) }
    }
    var overlayOpacity: Double {
        didSet { defaults.set(overlayOpacity, forKey: Key.overlayOpacity) }
    }
    var overlayClickThrough: Bool {
        didSet { defaults.set(overlayClickThrough, forKey: Key.overlayClickThrough) }
    }
    var overlayDefaultCorner: SnapCorner {
        didSet { defaults.set(overlayDefaultCorner.rawValue, forKey: Key.overlayCorner) }
    }
    var overlayLocked: Bool {
        didSet { defaults.set(overlayLocked, forKey: Key.overlayLocked) }
    }

    // MARK: - Notifications
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }
    var warningThreshold: Double {
        didSet { defaults.set(warningThreshold, forKey: Key.warningThreshold) }
    }
    var criticalThreshold: Double {
        didSet { defaults.set(criticalThreshold, forKey: Key.criticalThreshold) }
    }
    var notificationSound: Bool {
        didSet { defaults.set(notificationSound, forKey: Key.notificationSound) }
    }
    var notifyForSession: Bool {
        didSet { defaults.set(notifyForSession, forKey: Key.notifyForSession) }
    }
    var notifyForWeekly: Bool {
        didSet { defaults.set(notifyForWeekly, forKey: Key.notifyForWeekly) }
    }

    // MARK: - Data Source
    var apiBaseURL: String {
        didSet { defaults.set(apiBaseURL, forKey: Key.apiBaseURL) }
    }
    var apiModel: String {
        didSet { defaults.set(apiModel, forKey: Key.apiModel) }
    }

    // MARK: - Onboarding
    var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: Key.onboardingDone) }
    }

    // MARK: - Internals
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.pollInterval = (defaults.object(forKey: Key.pollInterval) as? TimeInterval) ?? AppSettingsDefaults.pollInterval
        self.launchAtLogin = (defaults.object(forKey: Key.launchAtLogin) as? Bool) ?? AppSettingsDefaults.launchAtLogin
        self.menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Key.menuBarStyle) ?? "") ?? AppSettingsDefaults.menuBarStyle
        self.showMascot = (defaults.object(forKey: Key.showMascot) as? Bool) ?? AppSettingsDefaults.showMascot
        self.overlayEnabledOnLaunch = (defaults.object(forKey: Key.overlayOnLaunch) as? Bool) ?? AppSettingsDefaults.overlayEnabledOnLaunch
        self.overlayOpacity = (defaults.object(forKey: Key.overlayOpacity) as? Double) ?? AppSettingsDefaults.overlayOpacity
        self.overlayClickThrough = (defaults.object(forKey: Key.overlayClickThrough) as? Bool) ?? AppSettingsDefaults.overlayClickThrough
        self.overlayDefaultCorner = SnapCorner(rawValue: defaults.string(forKey: Key.overlayCorner) ?? "") ?? AppSettingsDefaults.overlayDefaultCorner
        self.overlayLocked = (defaults.object(forKey: Key.overlayLocked) as? Bool) ?? AppSettingsDefaults.overlayLocked
        self.notificationsEnabled = (defaults.object(forKey: Key.notificationsEnabled) as? Bool) ?? AppSettingsDefaults.notificationsEnabled
        self.warningThreshold = (defaults.object(forKey: Key.warningThreshold) as? Double) ?? AppSettingsDefaults.warningThreshold
        self.criticalThreshold = (defaults.object(forKey: Key.criticalThreshold) as? Double) ?? AppSettingsDefaults.criticalThreshold
        self.notificationSound = (defaults.object(forKey: Key.notificationSound) as? Bool) ?? AppSettingsDefaults.notificationSound
        self.notifyForSession = (defaults.object(forKey: Key.notifyForSession) as? Bool) ?? AppSettingsDefaults.notifyForSession
        self.notifyForWeekly = (defaults.object(forKey: Key.notifyForWeekly) as? Bool) ?? AppSettingsDefaults.notifyForWeekly
        self.apiBaseURL = defaults.string(forKey: Key.apiBaseURL) ?? AppSettingsDefaults.apiBaseURL
        self.apiModel = defaults.string(forKey: Key.apiModel) ?? AppSettingsDefaults.apiModel
        self.onboardingDone = defaults.bool(forKey: Key.onboardingDone)
    }

    private enum Key {
        static let pollInterval         = "clawdbar.pollInterval"
        static let launchAtLogin        = "clawdbar.launchAtLogin"
        static let menuBarStyle         = "clawdbar.menuBarStyle"
        static let showMascot           = "clawdbar.showMascot"
        static let overlayOnLaunch      = "clawdbar.overlay.onLaunch"
        static let overlayOpacity       = "clawdbar.overlay.opacity"
        static let overlayClickThrough  = "clawdbar.overlay.clickThrough"
        static let overlayCorner        = "clawdbar.overlay.corner"
        static let overlayLocked        = "clawdbar.overlay.locked"
        static let notificationsEnabled = "clawdbar.notifications.enabled"
        static let warningThreshold     = "clawdbar.notifications.warning"
        static let criticalThreshold    = "clawdbar.notifications.critical"
        static let notificationSound    = "clawdbar.notifications.sound"
        static let notifyForSession     = "clawdbar.notifications.session"
        static let notifyForWeekly      = "clawdbar.notifications.weekly"
        static let apiBaseURL           = "clawdbar.api.baseURL"
        static let apiModel             = "clawdbar.api.model"
        static let onboardingDone       = "clawdbar.onboarding.done"
    }
}
