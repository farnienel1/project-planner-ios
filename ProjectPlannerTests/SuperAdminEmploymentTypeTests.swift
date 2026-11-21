import XCTest
@testable import Project_Planner

/// 17 Nov owner bug: the Super Admin could never be set to PAYE. Web Edit User hid Employment type and the annual leave
/// allowance for every Super Admin; on iPhone the Employment type menu showed, but `UserStore.updateUserEmploymentType`
/// refused every Super Admin (and the organisation creator) without a message, and Edit user hid the annual leave
/// allowance sections for the Super Admin (and the allowance fields for every admin). The rulebook hides neither for
/// any level (§4.4, §8): who may change pay is `canChangePersonPay`, and only the Super Admin edits their own profile
/// (`canEditTargetUserPermissions`). These tests keep it that way.
@MainActor
final class SuperAdminEmploymentTypeTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text of a declaration from its marker to its closing brace.
    private func body(_ text: String, marker: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: marker), "missing \(marker)")
        var depth = 0
        var seenOpen = false
        var index = start.lowerBound
        while index < text.endIndex {
            let ch = text[index]
            if ch == "{" { depth += 1; seenOpen = true }
            if ch == "}" { depth -= 1 }
            index = text.index(after: index)
            if seenOpen && depth == 0 { break }
        }
        return String(text[start.lowerBound..<index])
    }

    func testTheSuperAdminMayChangeTheirOwnPayAndEmploymentType() {
        // §8: an admin may change pay, including their own (the Super Admin is an admin).
        XCTAssertTrue(CanonicalBusinessEngine.canChangePersonPay(
            writerUserId: "super-1", writerIsPlatformOwner: false, writerIsAdmin: true, writerIsManager: false,
            writerHasOperativesAccess: false, writerIsOperativeMode: false,
            subjectUserId: "super-1", subjectIsOperative: false
        ))
        // Unchanged: an operative never changes their own.
        XCTAssertFalse(CanonicalBusinessEngine.canChangePersonPay(
            writerUserId: "op-1", writerIsPlatformOwner: false, writerIsAdmin: false, writerIsManager: false,
            writerHasOperativesAccess: false, writerIsOperativeMode: true,
            subjectUserId: "op-1", subjectIsOperative: true
        ))
    }

    func testDataHealthListsASuperAdminWithNoStoredEmploymentType() {
        let roster: [[String: Any]] = [
            ["id": "super-1", "email": "super@example.com", "isSuperAdmin": true, "role": "admin", "isActive": true],
            ["id": "admin-1", "email": "admin@example.com", "role": "admin", "employmentType": "paye", "isActive": true],
            ["id": "op-1", "email": "op@example.com", "role": "operative", "employmentType": "self_employed", "isActive": true],
        ]
        let ids = CanonicalBusinessEngine.callJSON("usersMissingEmploymentType", arguments: [roster]) as? [String]
        XCTAssertEqual(ids, ["super-1"])
    }

    /// Edit user shows the annual leave allowance for every level: operative, manager, admin and the Super Admin.
    func testEditUserShowsTheLeaveAllowanceForEveryLevel() throws {
        let text = try source("Project Planner/Views/ManageUsersView.swift")
        for marker in [
            "private var shouldShowAnnualLeaveAccessToggle: Bool {",
            "private var shouldShowAnnualLeaveEntitlementSection: Bool {",
        ] {
            let decl = try body(text, marker: marker)
            XCTAssertFalse(decl.contains("if isViewingSuperAdminProfile { return false }"), "\(marker) must not hide the Super Admin")
            XCTAssertFalse(decl.contains("isSuperAdmin {"), "\(marker) must not hide the Super Admin")
            XCTAssertTrue(decl.contains("return draftHasUserLevel"), "\(marker) must show for every level")
        }
        let level = try body(text, marker: "private var draftHasUserLevel: Bool {")
        XCTAssertTrue(level.contains("isViewingSuperAdminProfile"), "the Super Admin's profile shows the allowance")
        XCTAssertTrue(level.contains("RulebookRosterLists.inviteHasNoLevel(permissions)"), "the level comes from the rulebook")
    }

    /// The level test the leave sections use (`userMissingLevel` through `CanonicalBusinessEngine`): every level has one,
    /// so each shows the allowance; a draft with no level flag has none.
    func testEveryLevelFlagCountsAsAUserLevel() {
        XCTAssertFalse(RulebookRosterLists.inviteHasNoLevel(UserPermissions(operativeMode: true)), "operative")
        XCTAssertFalse(RulebookRosterLists.inviteHasNoLevel(UserPermissions(manager: true)), "manager")
        XCTAssertFalse(RulebookRosterLists.inviteHasNoLevel(UserPermissions(adminAccess: true)), "admin")
        XCTAssertTrue(RulebookRosterLists.inviteHasNoLevel(UserPermissions()), "no level flag")
    }

    // MARK: Behaviour — who may save the Super Admin's employment type and leave allowance (review of #258)

    private func person(_ id: String, superAdmin: Bool = false, admin: Bool = false, manager: Bool = false, operative: Bool = false) -> AppUser {
        AppUser(
            id: id,
            email: "\(id.lowercased())@example.test",
            organizationId: "TEST-ORG-SA",
            role: operative ? .operative : (admin || superAdmin ? .admin : .manager),
            firstName: "TEST-\(id)",
            surname: "Person",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(adminAccess: admin || superAdmin, manager: manager || admin || superAdmin, operativeMode: operative),
            isSuperAdmin: superAdmin
        )
    }

    /// The gate `updateUserEmploymentType`, `updateUserAnnualLeaveEntitlement` and `updateUserAnnualLeaveEnabled`
    /// run before anything else: the Super Admin's own change is allowed; another admin's change to the Super Admin is
    /// still refused; other people are left to `canChangePersonPay` and the leave saves' own checks.
    func testTheSuperAdminsOwnChangeIsAllowedAndAnotherAdminsIsRefused() {
        let superAdmin = person("SUPER", superAdmin: true)
        let admin = person("ADMIN", admin: true)
        let manager = person("MGR", manager: true)
        let operative = person("OP", operative: true)
        let store = UserStore()
        store.organizationUsers = [superAdmin, admin, manager, operative]

        store.currentUser = superAdmin
        XCTAssertTrue(store.mayChangeEmploymentAndLeaveFields(of: superAdmin), "the Super Admin sets their own (the owner bug)")
        for other in [admin, manager, operative] {
            XCTAssertTrue(store.mayChangeEmploymentAndLeaveFields(of: other), "\(other.id): not decided by the Super Admin gate")
        }

        store.currentUser = admin
        XCTAssertFalse(store.mayChangeEmploymentAndLeaveFields(of: superAdmin), "another admin never edits the Super Admin here")
        XCTAssertTrue(store.mayChangeEmploymentAndLeaveFields(of: operative))

        store.currentUser = nil
        XCTAssertFalse(store.mayChangeEmploymentAndLeaveFields(of: operative), "nobody signed in changes nothing")
    }

    // MARK: Behaviour — the allowance draft (review of #258, item 4)

    private func formatDays(_ days: Double) -> String {
        days == days.rounded() ? String(Int(days)) : String(days)
    }

    func testAStoredZeroAllowanceNobodyTouchedIsNotAChange() {
        let admin = AppUser(id: "ADMIN", email: "a@example.test", organizationId: "O", role: .admin, annualLeaveDaysPerYear: 0)
        let seed = AnnualLeaveEntitlementDraft.seeded(from: admin, formatDays: formatDays)
        XCTAssertEqual(seed.daysText, "0")
        // Before: the check parsed "0" as invalid and called it dirty, so Save failed with "Enter a valid annual leave
        // allowance". An untouched figure is never a change, never checked and never written.
        XCTAssertEqual(seed.editedFields(since: seed), [])
        var typed = seed
        typed.daysText = "0.0"
        XCTAssertEqual(typed.editedFields(since: seed), [], "the same figure written differently")
        typed.daysText = "22"
        XCTAssertEqual(typed.editedFields(since: seed), [AnnualLeaveEntitlementDraft.daysField])
    }

    func testOrganisationDefaultsArrivingAfterTheEditorOpenedAreNeverWritten() {
        // Opened while the organisation's leave defaults were still loading: the figures are the rulebook default.
        var pending = AppUser(id: "ADMIN", email: "a@example.test", organizationId: "O", role: .admin, annualLeaveDaysPerYear: 25)
        pending.annualLeaveDefaultsPending = true
        pending.annualLeaveStoredKeys = []
        let seed = AnnualLeaveEntitlementDraft.seeded(from: pending, formatDays: formatDays)
        // The row is then re-read with the organisation's defaults (28 days, April): the draft still shows what was
        // opened, and nothing is a change, so nothing is written onto the admin.
        var reread = pending
        reread.annualLeaveDaysPerYear = 28
        reread.annualLeaveYearStartMonth = 4
        reread.annualLeaveYearEndMonth = 3
        reread.annualLeaveDefaultsPending = false
        XCTAssertEqual(seed.editedFields(since: seed), [])
        XCTAssertEqual(AnnualLeaveEntitlementDraft.fieldsToWrite(edited: [], user: reread), [])
        // Only the figure the person changed is written; the pending figures they did not change are left out.
        var edited = seed
        edited.carriesOver.toggle()
        let fields = edited.editedFields(since: seed)
        XCTAssertEqual(fields, [AnnualLeaveEntitlementDraft.carriesOverField])
        XCTAssertEqual(AnnualLeaveEntitlementDraft.fieldsToWrite(edited: fields, user: pending), [AnnualLeaveEntitlementDraft.carriesOverField])
    }

    /// Edit user compares the allowance with the figures it was opened with, never the re-read roster row, and writes
    /// only the changed fields.
    func testEditUserSavesOnlyTheAllowanceFiguresThatChanged() throws {
        let text = try source("Project Planner/Views/ManageUsersView.swift")
        let dirty = try body(text, marker: "private var annualLeaveEntitlementDirty: Bool {")
        XCTAssertTrue(dirty.contains("editedFields(since: leaveEntitlementSeed)"))
        XCTAssertFalse(dirty.contains("rosterRow"), "never compared with the row as re-read")
        XCTAssertTrue(text.contains("fields: AnnualLeaveEntitlementDraft.fieldsToWrite(edited: editedLeaveFields, user: subjectUser)"))
    }

    /// The saves never refuse the Super Admin's own employment type or leave allowance.
    func testUserStoreSavesDoNotRefuseTheSuperAdmin() throws {
        let text = try source("Project Planner/Core/UserStore.swift")
        for marker in [
            "func updateUserEmploymentType(userId: String, employmentType: EmploymentType, effectiveAt: Date? = nil) async -> Bool {",
            "func updateUserAnnualLeaveEntitlement(",
            "func updateUserAnnualLeaveEnabled(userId: String, enabled: Bool) async -> Bool {",
        ] {
            let decl = try body(text, marker: marker)
            XCTAssertFalse(decl.contains("if isOrganizationCreator(userId: userId) { return false }"), marker)
            let collapsed = decl.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            XCTAssertFalse(
                collapsed.contains("if updated.isSuperAdmin || isOrganizationCreator(userId: updated.id) { return false }"),
                "\(marker) must not refuse every Super Admin"
            )
            XCTAssertTrue(collapsed.contains("guard mayChangeEmploymentAndLeaveFields(of: updated) else { return false }"), "\(marker) runs the Super Admin gate")
        }
    }
}
