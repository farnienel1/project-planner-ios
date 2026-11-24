import XCTest
@testable import Project_Planner

/// RULEBOOK 1.81.0 §11 "Names per organisation" (web hand-off v1.81.0): which entry names a person, where an edit is
/// saved and the write shape are the packed script's (`parseMemberNameDocuments`, `applyMemberNames`,
/// `memberNameEditTarget`, `memberNameWriteFields`); these lock the Swift mapping and `MemberNameOverlay`. TEST data.
@MainActor
final class MemberNamesTests: XCTestCase {
    private func person(_ id: String, first: String, last: String, home: String? = "TEST-A") -> AppUser {
        var user = AppUser(id: id, email: "\(id.lowercased())@example.test", organizationId: "TEST-B", role: .manager, permissions: UserPermissions())
        user.firstName = first
        user.surname = last
        user.storedOrganizationId = home
        return user
    }

    func testEntryWinsAndComesOffAgain() {
        let names = CanonicalBusinessEngine.parseMemberNames([(id: "U1", data: ["firstName": "Farns", "surname": "Nel", "updatedAt": Date()])])
        XCTAssertEqual(names["u1"]?["firstName"], "Farns")
        let farnie = person("u1", first: "Farnie", last: "Nel")
        let shown = MemberNameOverlay.apply([farnie], names: names)
        XCTAssertEqual(shown?.first?.firstName, "Farns")
        XCTAssertEqual(shown.map { MemberNameOverlay.accountName($0[0]).firstName }, "Farnie")
        XCTAssertNil(MemberNameOverlay.apply(shown ?? [], names: names), "idempotent")
        let back = MemberNameOverlay.apply(shown ?? [], names: [:])
        XCTAssertEqual(back?.first?.firstName, "Farnie")
        XCTAssertNil(back?.first?.orgNameOverlay)
    }

    func testNoEntryIsUnchanged() {
        XCTAssertNil(MemberNameOverlay.apply([person("u2", first: "Sam", last: "Smith")], names: [:]))
        let other = CanonicalBusinessEngine.parseMemberNames([(id: "u9", data: ["firstName": "X"])])
        XCTAssertNil(MemberNameOverlay.apply([person("u2", first: "Sam", last: "Smith")], names: other))
    }

    func testEditTargetAndWriteShape() {
        XCTAssertEqual(CanonicalBusinessEngine.memberNameEditTarget(organizationId: "TEST-A", homeOrganizationId: "TEST-A"), "account")
        XCTAssertEqual(CanonicalBusinessEngine.memberNameEditTarget(organizationId: "TEST-B", homeOrganizationId: "TEST-A"), "organization")
        let fields = CanonicalBusinessEngine.memberNameWriteFields(firstName: " Farns ", surname: "Nel", writerUserId: "admin")
        XCTAssertEqual(fields?["firstName"] as? String, "Farns")
        XCTAssertEqual(fields?["updatedFrom"] as? String, "ios")
        XCTAssertNil(CanonicalBusinessEngine.memberNameWriteFields(firstName: " ", surname: "", writerUserId: "admin"))
        XCTAssertTrue(CanonicalBusinessEngine.canWriteMemberName(writerUserId: "U1", subjectUserId: "u1", writerIsAdmin: false))
        XCTAssertFalse(CanonicalBusinessEngine.canWriteMemberName(writerUserId: "mgr", subjectUserId: "u1", writerIsAdmin: false))
    }
}
