import XCTest
@testable import ClawdBar

final class NotificationManagerTests: XCTestCase {

    @MainActor
    func testEvaluateIsNoOpWhenDisabled() async {
        let settings = AppSettings(defaults: makeDefaults())
        settings.notificationsEnabled = false
        let mgr = NotificationManager()
        // No auth, no enable — should not throw or fire.
        await mgr.evaluate(usage: usage(session: 99, weekly: 99), settings: settings)
    }

    @MainActor
    func testEvaluateBailsWhenUnauthorized() async {
        let settings = AppSettings(defaults: makeDefaults())
        settings.notificationsEnabled = true
        let mgr = NotificationManager()
        // authState remains .notDetermined by default.
        await mgr.evaluate(usage: usage(session: 99, weekly: 99), settings: settings)
        // We can't observe a notification was *not* posted via UNUserNotificationCenter
        // in this scope, but we at least confirm no crash and the call completes.
    }

    @MainActor
    func testThresholdLevelLogic() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.warningThreshold = 80
        settings.criticalThreshold = 95
        // We poke level resolution by reading the public bucketing helper via UsageData.severity
        XCTAssertEqual(UsageData.severity(for: 50), .warning)
        XCTAssertEqual(UsageData.severity(for: 79.9), .warning)
        XCTAssertEqual(UsageData.severity(for: 80), .danger)
        XCTAssertEqual(UsageData.severity(for: 94), .danger)
        XCTAssertEqual(UsageData.severity(for: 95), .critical)
    }

    @MainActor
    func testAppSettingsPersistAcrossInits() {
        let suite = makeDefaults()
        let a = AppSettings(defaults: suite)
        a.warningThreshold = 73
        a.notificationSound = false
        a.notifyForWeekly = false

        let b = AppSettings(defaults: suite)
        XCTAssertEqual(b.warningThreshold, 73)
        XCTAssertFalse(b.notificationSound)
        XCTAssertFalse(b.notifyForWeekly)
    }

    // MARK: helpers

    private func makeDefaults() -> UserDefaults {
        let name = "clawdbar.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func usage(session: Double, weekly: Double) -> UsageData {
        UsageData(
            sessionPercent: session, sessionResetAt: nil,
            weeklyPercent: weekly, weeklyResetAt: nil,
            lastUpdated: .now, isStale: false, rawHeaders: [:]
        )
    }
}
