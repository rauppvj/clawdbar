import Foundation
// `@preconcurrency` so this builds on older Xcode toolchains (16.x) where
// the UserNotifications framework's types aren't yet annotated Sendable.
// Newer Xcode (26.x) compiles fine without it; the marker just downgrades
// Sendable errors to warnings on the older SDKs.
@preconcurrency import UserNotifications
import Observation

@MainActor
@Observable
final class NotificationManager {
    enum AuthState: Equatable { case notDetermined, granted, denied }

    private(set) var authState: AuthState = .notDetermined

    private enum Level: Int, Comparable {
        case none = 0, warning, critical
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    private var lastFiredSession: Level = .none
    private var lastFiredWeekly: Level = .none

    func refreshAuthState() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: authState = .notDetermined
        case .denied: authState = .denied
        default: authState = .granted
        }
    }

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        authState = granted ? .granted : .denied
    }

    func evaluate(usage: UsageData, settings: AppSettings) async {
        guard settings.notificationsEnabled, authState == .granted else { return }

        if settings.notifyForSession {
            lastFiredSession = await maybeFire(
                window: "5h",
                percent: usage.sessionPercent,
                lastFired: lastFiredSession,
                settings: settings
            )
        }
        if settings.notifyForWeekly {
            lastFiredWeekly = await maybeFire(
                window: "7d",
                percent: usage.weeklyPercent,
                lastFired: lastFiredWeekly,
                settings: settings
            )
        }
    }

    private func maybeFire(
        window: String,
        percent: Double?,
        lastFired: Level,
        settings: AppSettings
    ) async -> Level {
        guard let percent else { return lastFired }
        let current: Level = {
            if percent >= settings.criticalThreshold { return .critical }
            if percent >= settings.warningThreshold  { return .warning }
            return .none
        }()
        if current > lastFired {
            await deliver(
                title: titleFor(level: current, window: window),
                body: "Claude Code \(window) usage at \(Int(percent.rounded()))%.",
                sound: settings.notificationSound
            )
        }
        if percent < settings.warningThreshold {
            return .none
        }
        return max(lastFired, current)
    }

    private func titleFor(level: Level, window: String) -> String {
        switch level {
        case .warning:  return "ClawdBar — \(window) approaching limit"
        case .critical: return "ClawdBar — \(window) critical"
        case .none:     return "ClawdBar"
        }
    }

    private func deliver(title: String, body: String, sound: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
