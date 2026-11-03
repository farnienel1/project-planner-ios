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

    func testVisibleCopySaysTheSubscriptionIsNotActive() {
        let superAdmin = SubscriptionLapsedCopy.visibleText(isSuperAdmin: true)
        let otherRole = SubscriptionLapsedCopy.visibleText(isSuperAdmin: false)
        // App Store 3.1.1 / 3.1.3: no price, renewal or web billing route.
        XCTAssertEqual(superAdmin, "Your organisation's subscription is not active.\nContact your organisation's administrator.")
        XCTAssertEqual(otherRole, superAdmin)
        for text in [superAdmin, otherRole] {
            XCTAssertFalse(text.lowercased().contains("renew"))
            XCTAssertFalse(text.lowercased().contains("web app"))
            XCTAssertFalse(text.contains("£"))
        }
        XCTAssertFalse(superAdmin.lowercased().contains("transfer"))
        XCTAssertFalse(otherRole.lowercased().contains("transfer"))
        XCTAssertFalse(superAdmin.lowercased().contains("stripe"))
        XCTAssertFalse(otherRole.lowercased().contains("stripe"))
        XCTAssertFalse(superAdmin.contains("http"))
        XCTAssertFalse(otherRole.contains("http"))
    }
}
