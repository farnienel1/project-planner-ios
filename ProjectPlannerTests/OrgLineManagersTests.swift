import XCTest
@testable import Project_Planner

/// RULEBOOK 1.88.0 §8, §11 "Line managers per organisation" (web hand-off v1.88.0): which line manager applies in an
/// organisation (`organizationLineManagerFields`) and where an edit is saved (`orgLineManagerEditTarget`) are the
/// packed script's; these lock the Swift mapping and `OrgLineManagerOverlay`. TEST data.
@MainActor
final class OrgLineManagersTests: XCTestCase {
    private func jane(home: String? = "TEST-A") -> AppUser {
        var user = AppUser(id: "jane", email: "jane@example.test", organizationId: "TEST-B", role: .operative, permissions: UserPermissions())
        user.storedOrganizationId = home
        user.assignedManagerUserIds = ["bobA"]
        user.assignedManagerUserId = "bobA"
        return user
    }

    /// This company's `memberLineManagers/{uid}` record for Jane, as stored (with write metadata).
    private let record: [String: Any] = [
        "assignedManagerUserIds": ["carolB"],
        "assignedManagerUserId": "carolB",
        "hasNoLineManager": false,
        "updatedAt": Date(),
        "updatedBy": "TEST-ADMIN-B",
        "updatedFrom": "web",
    ]

    private var parsedRecords: [String: [String: Any]] {
        CanonicalBusinessEngine.parseMemberLineManagerDocuments([(id: "JANE", data: record)])
    }

    func testCollectionNameMatchesTheRulebook() {
        XCTAssertEqual(
            CanonicalBusinessEngine.constant("MEMBER_LINE_MANAGERS_COLLECTION", as: String.self),
            CanonicalBusinessEngine.memberLineManagersCollection
        )
    }

    func testRecordsAreKeyedByLowerCaseIdAndKeepOnlyTheThreeKeys() {
        let parsed = parsedRecords
        XCTAssertEqual(Array(parsed.keys), ["jane"])
        XCTAssertEqual(parsed["jane"]?["assignedManagerUserIds"] as? [String], ["carolB"])
        XCTAssertNil(parsed["jane"]?["updatedBy"])
        // A record holding none of the three keys is no record.
        XCTAssertTrue(CanonicalBusinessEngine.parseMemberLineManagerDocuments([(id: "x", data: ["updatedBy": "a"])]).isEmpty)
    }

    func testVisitingMemberReadsTheRecord() {
        let shown = OrgLineManagerOverlay.apply([jane()], organizationId: "TEST-B", records: parsedRecords)
        XCTAssertEqual(shown?.first?.assignedManagerUserIds, ["carolB"])
        XCTAssertEqual(shown.map { OrgLineManagerOverlay.accountFields($0[0]).ids }, ["bobA"])
        XCTAssertNil(OrgLineManagerOverlay.apply(shown ?? [], organizationId: "TEST-B", records: parsedRecords), "idempotent")
        // The record removed: no line manager here (never the home company's).
        let back = OrgLineManagerOverlay.apply(shown ?? [], organizationId: "TEST-B", records: [:])
        XCTAssertEqual(back?.first?.assignedManagerUserIds, [])
        XCTAssertNotNil(back?.first?.orgLineManagerOverlay)
        // No company open (sign-out / switch): the overlay comes off too.
        let closed = OrgLineManagerOverlay.apply(shown ?? [], organizationId: "", records: parsedRecords)
        XCTAssertEqual(closed?.first?.assignedManagerUserIds, ["bobA"])
    }

    /// Owner answer 24 Nov: a line manager belongs to each company. Home → the users document; a visitor with no record
    /// here → no line manager here (empty fields, `lineManagerRequiredError` set), never the home company's.
    func testHomeReadsTheUsersDocumentAndAVisitorWithNoRecordHasNone() {
        // Home company: the users document whatever the record says.
        XCTAssertNil(OrgLineManagerOverlay.apply([jane(home: "TEST-B")], organizationId: "TEST-B", records: parsedRecords))
        // No company stored on the users document: its own fields, as before 1.88.0.
        XCTAssertNil(OrgLineManagerOverlay.apply([jane(home: nil)], organizationId: "TEST-B", records: [:]))
        // A visitor with no record here: no line manager here.
        let fields = CanonicalBusinessEngine.organizationLineManagerFields(
            organizationId: "TEST-B",
            homeOrganizationId: "TEST-A",
            assignedManagerUserIds: ["bobA"],
            assignedManagerUserId: "bobA",
            hasNoLineManager: false,
            record: nil
        )
        XCTAssertEqual(fields?.source, "none")
        XCTAssertEqual(fields?.ids, [])
        XCTAssertNil(fields?.single)
        let shown = OrgLineManagerOverlay.apply([jane()], organizationId: "TEST-B", records: [:])
        XCTAssertEqual(shown?.first?.assignedManagerUserIds, [])
        XCTAssertNil(shown?.first?.assignedManagerUserId)
        XCTAssertEqual(shown.map { OrgLineManagerOverlay.accountFields($0[0]).ids }, ["bobA"], "the users document's own fields stay under the overlay")
        // The home company's line manager is never shown here, and an operative cannot be saved without one here.
        if let visitor = shown?.first {
            XCTAssertEqual(LineManagerRulebook.selectedIds(for: visitor, roster: [visitor]), [])
            XCTAssertNotNil(AnnualLeaveApproval.lineManagerRequiredError(for: visitor, users: [visitor]))
        } else {
            XCTFail("a visitor with no record must be laid over")
        }
        // The record arriving later gives this company's line manager.
        let laid = OrgLineManagerOverlay.apply(shown ?? [], organizationId: "TEST-B", records: parsedRecords)
        XCTAssertEqual(laid?.first?.assignedManagerUserIds, ["carolB"])
    }

    /// Review of web #455 fix (a): a membership `lineManager` map (a 1.88 draft, or a flat copy an older build made)
    /// is never read — only the record counts; with no record a visitor has no line manager here.
    func testMembershipLineManagerMapIsIgnored() {
        let membership: [String: Any] = [
            "role": "operative",
            "lineManager": ["assignedManagerUserIds": ["carolB"], "assignedManagerUserId": "carolB", "hasNoLineManager": false],
        ]
        // The membership is not a record: none of the three keys at its top level → no record → none here.
        let fromMembership = CanonicalBusinessEngine.organizationLineManagerFields(
            organizationId: "TEST-B",
            homeOrganizationId: "TEST-A",
            assignedManagerUserIds: ["bobA"],
            assignedManagerUserId: "bobA",
            hasNoLineManager: false,
            record: membership
        )
        XCTAssertEqual(fromMembership?.source, "none")
        XCTAssertEqual(fromMembership?.ids, [])
        XCTAssertTrue(CanonicalBusinessEngine.parseMemberLineManagerDocuments([(id: "jane", data: membership)]).isEmpty)
    }

    func testEditTarget() {
        XCTAssertEqual(CanonicalBusinessEngine.orgLineManagerEditTarget(organizationId: "TEST-A", homeOrganizationId: "test-a"), "users")
        XCTAssertEqual(CanonicalBusinessEngine.orgLineManagerEditTarget(organizationId: "TEST-B", homeOrganizationId: "TEST-A"), "record")
        XCTAssertNil(CanonicalBusinessEngine.orgLineManagerEditTarget(organizationId: "TEST-B", homeOrganizationId: nil))
    }

    func testLineManagerIdsFollowTheOrganisation() {
        let fields = CanonicalBusinessEngine.organizationLineManagerFields(
            organizationId: "TEST-B",
            homeOrganizationId: "TEST-A",
            assignedManagerUserIds: ["bobA"],
            assignedManagerUserId: "bobA",
            hasNoLineManager: false,
            record: record
        )
        XCTAssertEqual(fields?.source, "record")
        XCTAssertEqual(fields?.ids, ["carolB"])
    }

    func testRecordWriteFields() {
        let fields = CanonicalBusinessEngine.memberLineManagerWriteFields(
            assignedManagerUserIds: [" carolB ", "CAROLB", "dave"],
            assignedManagerUserId: nil,
            hasNoLineManager: false,
            writerUserId: "TEST-ADMIN-B"
        )
        XCTAssertEqual(fields?["assignedManagerUserIds"] as? [String], ["carolB", "dave"])
        XCTAssertEqual(fields?["assignedManagerUserId"] as? String, "carolB")
        XCTAssertEqual(fields?["hasNoLineManager"] as? Bool, false)
        XCTAssertEqual(fields?["updatedBy"] as? String, "TEST-ADMIN-B")
        XCTAssertEqual(fields?["updatedFrom"] as? String, "ios")
        let none = CanonicalBusinessEngine.memberLineManagerWriteFields(
            assignedManagerUserIds: ["carolB"],
            assignedManagerUserId: "carolB",
            hasNoLineManager: true,
            writerUserId: nil
        )
        XCTAssertEqual(none?["assignedManagerUserIds"] as? [String], [])
        XCTAssertTrue(none?["assignedManagerUserId"] is NSNull)
        XCTAssertNil(none?["updatedBy"])
    }

    /// Owner bug 24 Nov: the profile summary and the Edit user picker read the same line manager (list only, no legacy
    /// single id; "No line manager" stored beside ids wins on both).
    func testSummaryAndPickerAgree() {
        var manager = AppUser(id: "farnie", email: "farnienelyt@gmail.com", organizationId: "TEST-B", role: .manager, firstName: "Farnie", surname: "Nel", passwordSet: true)
        manager.permissions.manager = true
        let roster = [manager]
        var luke = AppUser(id: "luke", email: "farnienel@hotmail.com", organizationId: "TEST-B", role: .operative, passwordSet: true, assignedManagerUserIds: ["farnie"])
        luke.assignedManagerUserId = nil
        XCTAssertEqual(LineManagerRulebook.summary(for: luke, roster: roster), "Farnie Nel")
        XCTAssertEqual(LineManagerRulebook.selectedIds(for: luke, roster: roster), ["farnie"])
        luke.hasNoLineManager = true
        XCTAssertEqual(LineManagerRulebook.summary(for: luke, roster: roster), "No line manager")
        XCTAssertEqual(LineManagerRulebook.selectedIds(for: luke, roster: roster), [])
    }
}
