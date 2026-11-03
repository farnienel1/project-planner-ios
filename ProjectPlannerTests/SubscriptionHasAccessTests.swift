import XCTest
@testable import Project_Planner

final class SubscriptionHasAccessTests: XCTestCase {
    func testClosedBillingStatusHasNoAccess() throws {
        let canceled = try XCTUnwrap(CanonicalBusinessEngine.hasAccess(billing: ["status": "canceled"]))
        XCTAssertFalse(canceled)

        let fromDocument = OrganizationBillingMap.payload(from: [
            "billingStatus": "trial",
            "billing": ["status": "canceled", "billingInterval": "month"]
        ])
        XCTAssertEqual(fromDocument?["status"] as? String, "canceled")
        XCTAssertFalse(try XCTUnwrap(CanonicalBusinessEngine.hasAccess(billing: fromDocument)))
    }

    func testOpenBillingStatusHasAccess() throws {
        let active = try XCTUnwrap(CanonicalBusinessEngine.hasAccess(billing: ["status": "active"]))
        XCTAssertTrue(active)

        let missing = try XCTUnwrap(CanonicalBusinessEngine.hasAccess(billing: nil))
        XCTAssertTrue(missing)

        let stillActive = try XCTUnwrap(CanonicalBusinessEngine.hasAccess(billing: [
            "status": "active",
            "cancelAtPeriodEnd": true,
            "billingInterval": "year"
        ]))
        XCTAssertTrue(stillActive)
    }

    func testManualTrialFlagsDoNotCloseSubscriptionAccess() throws {
        let payload = OrganizationBillingMap.payload(from: [
            "billingStatus": "trial",
            "trialAccessBlocked": true,
            "accessBlocked": true
        ])
        XCTAssertNil(payload)
        XCTAssertTrue(try XCTUnwrap(CanonicalBusinessEngine.hasAccess(billing: payload)))
    }

    func testVisibleCopyIsTheRulebookLapsedMessage() {
        let admin = SubscriptionLapsedCopy.visibleText(isAdmin: true)
        let otherRole = SubscriptionLapsedCopy.visibleText(isAdmin: false)
        // RULEBOOK 1.13.0 §19: `SUBSCRIPTION_LAPSED_MESSAGE` for everyone, `SUBSCRIPTION_LAPSED_ADMIN_NOTE` for admins.
        XCTAssertEqual(otherRole, "The organisation's Project Planner subscription has lapsed. Please contact your system administrator and ask them to renew.")
        XCTAssertEqual(admin, otherRole + "\nYou are an admin: renew the subscription in Settings → Billing.")
        for text in [admin, otherRole] {
            XCTAssertFalse(text.lowercased().contains("web app"))
            XCTAssertFalse(text.contains("£"))
            XCTAssertFalse(text.lowercased().contains("transfer"))
            XCTAssertFalse(text.lowercased().contains("stripe"))
            XCTAssertFalse(text.contains("http"))
        }
    }

    func testSubscriptionAccessBlocksEveryoneButTheOwner() {
        let lapsed: [String: Any] = ["status": "canceled"]
        XCTAssertEqual(CanonicalBusinessEngine.subscriptionAccess(billing: lapsed, viewerIsAdmin: false, viewerIsPlatformOwner: false), .blocked)
        XCTAssertEqual(CanonicalBusinessEngine.subscriptionAccess(billing: lapsed, viewerIsAdmin: true, viewerIsPlatformOwner: false), .adminBillingOnly)
        XCTAssertEqual(CanonicalBusinessEngine.subscriptionAccess(billing: lapsed, viewerIsAdmin: false, viewerIsPlatformOwner: true), .open)
        XCTAssertEqual(CanonicalBusinessEngine.subscriptionAccess(billing: nil, viewerIsAdmin: false, viewerIsPlatformOwner: false), .open)
        XCTAssertEqual(CanonicalBusinessEngine.subscriptionAccess(billing: ["status": "active"], viewerIsAdmin: false, viewerIsPlatformOwner: false), .open)
    }
}
