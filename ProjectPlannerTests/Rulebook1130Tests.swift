import XCTest
@testable import Project_Planner

/// RULEBOOK 1.12.2 / 1.13.0–1.13.2 behaviour on iOS through `CanonicalBusinessEngine`. Every expected value was
/// checked in node against the packed `canonical-business.js` (sha256 76ddcbc1…cfc).
@MainActor
final class Rulebook1130Tests: XCTestCase {
    // MARK: Half-applied user type (1.12.2 §11)

    private func managerSubject(id: String = "U1", organizationId: String = "ORG-A") -> [String: Any] {
        let flags: [String: Bool] = ["adminAccess": false, "manager": true, "operativeMode": false]
        var row: [String: Any] = flags
        row["permissions"] = flags
        row["role"] = "manager"
        row["isSuperAdmin"] = false
        row["id"] = id
        row["organizationId"] = organizationId
        return row
    }

    func testAccountTypeSyncStateFindsAPartlySavedType() throws {
        let stale = try XCTUnwrap(CanonicalBusinessEngine.accountTypeSyncState(
            person: managerSubject(), organizationId: "org-a", members: ["u1": "admin"]
        ))
        XCTAssertFalse(stale.inSync)
        XCTAssertEqual(stale.level, .manager)
        XCTAssertEqual(stale.membersRole, "admin")
        XCTAssertEqual(stale.repair, .manager)

        let same = try XCTUnwrap(CanonicalBusinessEngine.accountTypeSyncState(
            person: managerSubject(), organizationId: "org-a", members: ["U1": "manager"]
        ))
        XCTAssertTrue(same.inSync)
        XCTAssertNil(same.repair)

        let missing = try XCTUnwrap(CanonicalBusinessEngine.accountTypeSyncState(
            person: managerSubject(), organizationId: "org-a", members: [:]
        ))
        XCTAssertTrue(missing.inSync, "no members entry is not an admin mismatch")
        XCTAssertEqual(
            CanonicalBusinessEngine.accountTypeOutOfSyncMessage,
            "This person's user type was only partly saved. Press Save to finish it on every record."
        )
    }
}
