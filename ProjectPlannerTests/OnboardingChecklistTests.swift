import XCTest
@testable import Project_Planner

/// RULEBOOK 1.85.0 §32: the Getting started checklist through `CanonicalBusinessEngine` (no Swift rule). Expected
/// values are the web `lib/canonical/onboardingChecklist.test.ts` cases.
@MainActor
final class OnboardingChecklistTests: XCTestCase {
    private let fullOrg: [String: Any] = [
        "name": "Acme",
        "officeAddressLine1": "1 High St",
        "companyLogoURL": "https://x/logo.png",
        "payrollTimePolicy": ["standardDayStart": "07:30"],
        "invoicing": ["paymentRunMode": "date_ranges", "payePaydayHistory": [["day": 25, "effectiveFrom": "2026-01-01"]]],
    ]

    func testNewCompanyNothingDone() {
        let list = CanonicalBusinessEngine.onboardingChecklist(organization: ["name": "Acme"], people: 0, pendingInvites: 0, jobs: 0, complianceDocuments: 0)
        XCTAssertEqual(list?.progressLabel, "0 of 6 done")
        XCTAssertEqual(list?.items.map(\.key), ["company", "workingHours", "payRuns", "team", "firstJob", "accreditations"])
        XCTAssertEqual(list?.items.map(\.destination), ["companyDetails", "workingHours", "paymentRuns", "manageUsers", "projects", "insuranceAccreditations"])
        XCTAssertNotNil(CanonicalBusinessEngine.onboardingCardVisible(organization: ["name": "Acme"], people: 0, pendingInvites: 0, jobs: 0, complianceDocuments: 0, viewerIsAdmin: true))
    }

    func testDoneHiddenLoadingAndDismissed() {
        let done = CanonicalBusinessEngine.onboardingChecklist(organization: fullOrg, people: 0, pendingInvites: 1, jobs: 2, complianceDocuments: 0)
        XCTAssertEqual(done?.progressLabel, "5 of 6 done")
        XCTAssertEqual(done?.complete, true)
        XCTAssertNil(CanonicalBusinessEngine.onboardingCardVisible(organization: fullOrg, people: 0, pendingInvites: 1, jobs: 2, complianceDocuments: 0, viewerIsAdmin: true))
        XCTAssertNil(CanonicalBusinessEngine.onboardingCardVisible(organization: ["name": "Acme"], people: nil, pendingInvites: nil, jobs: nil, complianceDocuments: nil, viewerIsAdmin: true))
        XCTAssertNil(CanonicalBusinessEngine.onboardingCardVisible(organization: ["name": "Acme"], people: 0, pendingInvites: 0, jobs: 0, complianceDocuments: 0, viewerIsAdmin: false))
        XCTAssertNil(CanonicalBusinessEngine.onboardingCardVisible(organization: ["name": "Acme", "onboardingDismissedAt": 1], people: 0, pendingInvites: 0, jobs: 0, complianceDocuments: 0, viewerIsAdmin: true))
        XCTAssertEqual(CanonicalBusinessEngine.onboardingDismissWriteFields(userId: "u1")?["onboardingDismissedBy"] as? String, "u1")
    }

    func testStoredFieldsKept() {
        let json = OnboardingOrganizationDocument.json(fromOrganizationData: fullOrg.merging(["members": ["a": "admin"]]) { a, _ in a })
        let doc = OnboardingOrganizationDocument.document(json: json)
        XCTAssertEqual(doc["name"] as? String, "Acme")
        XCTAssertNil(doc["members"])
        XCTAssertEqual((doc["invoicing"] as? [String: Any])?["paymentRunMode"] as? String, "date_ranges")
    }
}
