import XCTest
@testable import Project_Planner

@MainActor
final class UserProfileCanonicalTests: XCTestCase {
    private func iso(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    func testScriptExportsUserProfileFunctions() {
        let names = [
            "normalizeEmploymentType",
            "employmentTypeOnDay",
            "applyEmploymentTypeChange",
            "employmentEffectiveLabel",
            "accountKindFromFlags",
            "isBillableSelfEmployedDay",
        ]
        for name in names {
            XCTAssertEqual(CanonicalBusinessEngine.exportKind(name), "function", name)
        }
    }

    func testNormalizeEmploymentTypeAcceptsCamelCaseOnRead() {
        XCTAssertEqual(CanonicalBusinessEngine.normalizeEmploymentType("selfEmployed"), "self_employed")
        XCTAssertEqual(CanonicalBusinessEngine.normalizeEmploymentType("self_employed"), "self_employed")
        XCTAssertEqual(CanonicalBusinessEngine.normalizeEmploymentType("paye"), "paye")
        XCTAssertEqual(EmploymentType.fromCanonical("selfEmployed"), .selfEmployed)
    }

    func testImmediateEmploymentChangeClearsTheTransition() {
        let now = iso("2026-10-09T12:00:00Z")
        let change = CanonicalBusinessEngine.applyEmploymentTypeChange(
            previousType: "self_employed",
            nextType: "paye",
            previousTransitionFrom: nil,
            previousEffectiveAt: nil,
            effectiveAt: nil,
            now: now
        )
        XCTAssertEqual(change?.employmentType, "paye")
        XCTAssertNil(change?.employmentTypeTransitionFrom)
        XCTAssertNil(change?.employmentTypeEffectiveAt)
    }

    func testPayeFromTomorrowKeepsSelfEmployedOnEarlierDays() {
        let now = iso("2026-10-09T12:00:00Z")
        let tomorrow = iso("2026-10-10T12:00:00Z")
        let change = CanonicalBusinessEngine.applyEmploymentTypeChange(
            previousType: "self_employed",
            nextType: "paye",
            previousTransitionFrom: nil,
            previousEffectiveAt: nil,
            effectiveAt: tomorrow,
            now: now
        )
        XCTAssertEqual(change?.employmentType, "paye")
        XCTAssertEqual(change?.employmentTypeTransitionFrom, "self_employed")
        XCTAssertNotNil(change?.employmentTypeEffectiveAt)

        let dayBefore = iso("2026-10-09T12:00:00Z")
        XCTAssertEqual(
            CanonicalBusinessEngine.employmentTypeOnDay(
                employmentType: change?.employmentType,
                transitionFrom: change?.employmentTypeTransitionFrom,
                effectiveAt: change?.employmentTypeEffectiveAt,
                date: dayBefore
            ),
            "self_employed"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.employmentTypeOnDay(
                employmentType: change?.employmentType,
                transitionFrom: change?.employmentTypeTransitionFrom,
                effectiveAt: change?.employmentTypeEffectiveAt,
                date: tomorrow
            ),
            "paye"
        )
        XCTAssertTrue(
            CanonicalBusinessEngine.isBillableSelfEmployedDay(
                employmentType: change?.employmentType,
                transitionFrom: change?.employmentTypeTransitionFrom,
                effectiveAt: change?.employmentTypeEffectiveAt,
                date: dayBefore
            )
        )

        var user = AppUser(
            id: "user-1",
            email: "op@example.com",
            organizationId: "org",
            role: .operative,
            firstName: "Test",
            surname: "Operative",
            permissions: UserPermissions(operativeMode: true)
        )
        user.employmentType = .paye
        user.employmentTypeTransitionFrom = .selfEmployed
        user.employmentTypeEffectiveAt = change?.employmentTypeEffectiveAt
        XCTAssertEqual(user.employmentType(on: dayBefore), .selfEmployed)
        XCTAssertEqual(user.employmentType(on: tomorrow), .paye)
    }

    func testAccountKindFromFlags() {
        XCTAssertEqual(
            CanonicalBusinessEngine.accountKindFromFlags(
                isSuperAdmin: true, role: "admin", adminAccess: true, manager: true, operativeMode: false
            ),
            "admin"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.accountKindFromFlags(
                isSuperAdmin: false, role: "operative", adminAccess: false, manager: false, operativeMode: true
            ),
            "operative"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.accountKindFromFlags(
                isSuperAdmin: false, role: "manager", adminAccess: false, manager: true, operativeMode: false
            ),
            "manager"
        )
    }

    func testOpenOperativeFromWarningFollowsThePermissionGate() {
        let operative = AppUser(
            id: "op-1",
            email: "op@example.com",
            organizationId: "org",
            role: .operative,
            firstName: "Test",
            surname: "Operative",
            permissions: UserPermissions(operativeMode: true)
        )
        let managerWithout = AppUser(
            id: "mgr-off",
            email: "mgr@example.com",
            organizationId: "org",
            role: .manager,
            firstName: "Test",
            surname: "Manager",
            permissions: UserPermissions(manager: true, operatives: false)
        )
        let managerWith = AppUser(
            id: "mgr-on",
            email: "mgr2@example.com",
            organizationId: "org",
            role: .manager,
            firstName: "Test",
            surname: "Manager",
            permissions: UserPermissions(manager: true, operatives: true)
        )
        let admin = AppUser(
            id: "admin-1",
            email: "admin@example.com",
            organizationId: "org",
            role: .admin,
            firstName: "Test",
            surname: "Admin",
            permissions: UserPermissions(adminAccess: true, operatives: false)
        )

        XCTAssertNil(WarningOperativeAccess.destination(actor: managerWithout, target: operative))
        XCTAssertEqual(
            WarningOperativeAccess.destination(actor: managerWith, target: operative),
            .editUser(userId: "op-1")
        )
        XCTAssertEqual(
            WarningOperativeAccess.destination(actor: admin, target: operative),
            .editUser(userId: "op-1")
        )
        XCTAssertNil(WarningOperativeAccess.destination(actor: operative, target: operative))
    }
}
