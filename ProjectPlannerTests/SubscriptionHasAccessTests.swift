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

    func testVisibleCopyContainsSubscriptionHasRunOut() {
        let superAdmin = SubscriptionLapsedCopy.visibleText(isSuperAdmin: true)
        let otherRole = SubscriptionLapsedCopy.visibleText(isSuperAdmin: false)
        XCTAssertTrue(superAdmin.contains("subscription has run out"))
        XCTAssertTrue(otherRole.contains("subscription has run out"))
        XCTAssertTrue(superAdmin.contains("Project Planner web app"))
        XCTAssertTrue(otherRole.contains("Ask the super admin to renew."))
        XCTAssertFalse(superAdmin.lowercased().contains("transfer"))
        XCTAssertFalse(otherRole.lowercased().contains("transfer"))
        XCTAssertFalse(superAdmin.lowercased().contains("stripe"))
        XCTAssertFalse(otherRole.lowercased().contains("stripe"))
        XCTAssertFalse(superAdmin.contains("http"))
        XCTAssertFalse(otherRole.contains("http"))
    }
}
