import XCTest
@testable import ClawdBar

final class PlanBadgeTests: XCTestCase {

    func testKnownPlans() {
        XCTAssertEqual(PlanBadge.label(subscriptionType: "pro", rateLimitTier: "default_claude_ai"), "PRO")
        XCTAssertEqual(PlanBadge.label(subscriptionType: "team", rateLimitTier: nil), "TEAM")
        XCTAssertEqual(PlanBadge.label(subscriptionType: "enterprise", rateLimitTier: nil), "ENTERPRISE")
        XCTAssertEqual(PlanBadge.label(subscriptionType: "free", rateLimitTier: nil), "FREE")
    }

    func testMaxMultiplierComesFromEitherClaim() {
        // Multiplier only in the opaque tier id.
        XCTAssertEqual(PlanBadge.label(subscriptionType: "max", rateLimitTier: "default_claude_max_20x"), "MAX 20×")
        XCTAssertEqual(PlanBadge.label(subscriptionType: "max", rateLimitTier: "default_claude_max_5x"), "MAX 5×")
        // Multiplier only in the subscription type.
        XCTAssertEqual(PlanBadge.label(subscriptionType: "max_20x", rateLimitTier: nil), "MAX 20×")
        XCTAssertEqual(PlanBadge.label(subscriptionType: "max_5x", rateLimitTier: nil), "MAX 5×")
        // Neither carries it — a bare MAX is still right.
        XCTAssertEqual(PlanBadge.label(subscriptionType: "max", rateLimitTier: nil), "MAX")
    }

    func testMaxTierAloneIsEnough() {
        // Seen in the wild: subscriptionType lags behind the tier id.
        XCTAssertEqual(PlanBadge.label(subscriptionType: "pro", rateLimitTier: "default_claude_max_5x"), "MAX 5×")
    }

    func testCasingAndWhitespaceAreTolerated() {
        XCTAssertEqual(PlanBadge.label(subscriptionType: "  Max  ", rateLimitTier: "DEFAULT_CLAUDE_MAX_20X"), "MAX 20×")
        XCTAssertEqual(PlanBadge.label(subscriptionType: "PRO", rateLimitTier: nil), "PRO")
    }

    func testUnknownPlanIsShownRatherThanSwallowed() {
        XCTAssertEqual(PlanBadge.label(subscriptionType: "startup", rateLimitTier: nil), "STARTUP")
    }

    func testNothingToShow() {
        XCTAssertNil(PlanBadge.label(subscriptionType: nil, rateLimitTier: "default_claude_ai"))
        XCTAssertNil(PlanBadge.label(subscriptionType: "", rateLimitTier: nil))
        XCTAssertNil(PlanBadge.label(subscriptionType: "   ", rateLimitTier: nil))
    }
}
