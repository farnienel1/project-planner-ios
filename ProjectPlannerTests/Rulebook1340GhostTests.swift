import XCTest
@testable import Project_Planner

/// RULEBOOK 1.34.0 §11 iOS follow-on (web hand-off v1.34.0): ghost operatives. Every answer comes from the packed script
/// through `CanonicalBusinessEngine` (`parseUserDocument`, `rosterSegment`, `listedRosterUsers`, `personDedupeKey`,
/// `ghostBadgeLabel`, `canCreateGhost`, `ghostAddFormRows`, `ghostCreateError`, `ghostCreateWrites`); these tests lock
/// the Swift inputs (every AppUser → rulebook row carries `ghost`) and how the answers are read. TEST data only.
@MainActor
final class Rulebook1340GhostTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: "TEST-ORG-1340", name: "TEST-Company 1340"))
    }

    private func ghost(_ id: String = "TEST-GHOST-1", email: String = "") -> AppUser {
        var user = AppUser(
            id: id,
            email: email,
            organizationId: "TEST-ORG-1340",
            role: .operative,
            firstName: "TEST-Gary",
            surname: "Ghost-\(id)",
            isActive: true,
            passwordSet: false,
            permissions: UserPermissions(operativeMode: true),
            assignedManagerUserIds: ["TEST-ADMIN-1"]
        )
        user.isGhost = true
        return user
    }

    private func admin() -> AppUser {
        AppUser(
            id: "TEST-ADMIN-1",
            email: "test-admin@example.com",
            organizationId: "TEST-ORG-1340",
            role: .admin,
            firstName: "TEST-Ann",
            surname: "Admin",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(adminAccess: true)
        )
    }

    // MARK: Reading a ghost

    func testParseAppUserDocumentReadsGhostWithNoEmailAndNoLogin() {
        let user = FirebaseBackend.parseAppUserDocument(
            userId: "TEST-GHOST-1",
            data: [
                "organizationId": "TEST-ORG-1340",
                "email": "",
                "role": "operative",
                "operativeMode": true,
                "firstName": "TEST-Gary",
                "surname": "Ghost",
                "ghost": true,
                "passwordSet": false,
                "isActive": true,
                "employmentType": "self_employed",
                "payBasis": "day",
                "dayRate": 250,
                "assignedManagerUserIds": ["TEST-ADMIN-1"],
                "inviteEmailHint": "Gary@Example.com",
            ]
        )
        XCTAssertTrue(user.isGhost)
        XCTAssertEqual(user.email, "")
        XCTAssertFalse(user.passwordSet)
        XCTAssertEqual(user.inviteEmailHint, "gary@example.com")
        XCTAssertFalse(user.parsedWithoutRulebook)
    }

    func testGhostWithoutStoredPasswordSetNeverReadsAsSignedUp() {
        let user = FirebaseBackend.parseAppUserDocument(
            userId: "TEST-GHOST-2",
            data: ["organizationId": "TEST-ORG-1340", "email": "", "firstName": "TEST-G", "surname": "Two", "ghost": true]
        )
        XCTAssertTrue(user.isGhost)
        XCTAssertFalse(user.passwordSet)
    }

    /// Review fix: `isGhostUser` is the stored Bool `true` only, as the security rules read it.
    func testGhostFlagIsTheBoolTrueOnly() {
        for value: Any in [1, "true", NSNull()] {
            let user = FirebaseBackend.parseAppUserDocument(
                userId: "TEST-NOT-GHOST",
                data: ["organizationId": "TEST-ORG-1340", "email": "", "firstName": "TEST-N", "surname": "G", "ghost": value]
            )
            XCTAssertFalse(user.isGhost, "\(value)")
        }
        XCTAssertTrue(FirebaseBackend.storedGhostFlag(true))
        XCTAssertFalse(FirebaseBackend.storedGhostFlag(1))
        XCTAssertFalse(FirebaseBackend.storedGhostFlag("true"))
        XCTAssertFalse(FirebaseBackend.storedGhostFlag(nil))
    }

    func testOwnProfileNeverWritesGhostMarkers() {
        XCTAssertEqual(Set(FirebaseBackend.ownProfileForbiddenFields), ["ghost", "inviteEmailHint"])
        let payload = FirebaseBackend.userDocumentPayload(ghost())
        XCTAssertNil(payload["ghost"])
        XCTAssertNil(payload["inviteEmailHint"])
    }

    func testOrdinaryUserIsNotAGhost() {
        let user = FirebaseBackend.parseAppUserDocument(
            userId: "TEST-USER-1",
            data: ["organizationId": "TEST-ORG-1340", "email": "test-user@example.com", "firstName": "TEST-U", "surname": "One"]
        )
        XCTAssertFalse(user.isGhost)
        XCTAssertNil(user.inviteEmailHint)
    }

    // MARK: Serialisers pass `ghost` through

    func testEveryAppUserRowCarriesGhost() {
        let g = ghost()
        XCTAssertEqual(RulebookPeople.person(g)["ghost"] as? Bool, true)
        XCTAssertEqual(LineManagerRulebook.row(g)["ghost"] as? Bool, true)
        XCTAssertEqual(RulebookRosterLists.levelRow(g)["ghost"] as? Bool, true)
        XCTAssertEqual(CanonicalBusinessEngine.timesheetPerson(g)["ghost"] as? Bool, true)
        XCTAssertEqual(GhostRulebook.rosterProfileRow(g)["ghost"] as? Bool, true)
        let members = UserTimesheetAccessRulebook.payload(viewer: admin(), members: [g])["members"] as? [[String: Any]]
        XCTAssertEqual(members?.first?["ghost"] as? Bool, true)
        XCTAssertEqual(RulebookPeople.person(admin())["ghost"] as? Bool, false)
        XCTAssertEqual(UserStore.userDeletePerson(g)["ghost"] as? Bool, true)
    }

    // MARK: People lists

    func testGhostIsActiveAndListedNeverAPendingLeftover() {
        let g = ghost()
        XCTAssertEqual(GhostRulebook.segment(g), "active")
        XCTAssertEqual(g.rosterSegment, .active)
        let listed = GhostRulebook.listed([g, admin()], claimedEmails: ["test-admin@example.com"])
        XCTAssertEqual(listed?.map(\.id).sorted(), ["TEST-ADMIN-1", "TEST-GHOST-1"])
        var inactive = g
        inactive.isActive = false
        XCTAssertEqual(GhostRulebook.segment(inactive), "inactive")
    }

    func testPersonDedupeKeyKeepsEveryNoEmailPersonApart() {
        XCTAssertEqual(GhostRulebook.dedupeKey(id: "ABC", email: " Gary@Example.com "), "gary@example.com")
        XCTAssertEqual(GhostRulebook.dedupeKey(id: "ABC", email: ""), "id:abc")
        XCTAssertNotEqual(GhostRulebook.dedupeKey(id: "A", email: ""), GhostRulebook.dedupeKey(id: "B", email: ""))
    }

    func testAnnualLeavePeopleListEveryGhost() {
        let rows = AnnualLeavePersonBuilder.build(users: [ghost("TEST-GHOST-A"), ghost("TEST-GHOST-B")], operatives: [])
        XCTAssertEqual(Set(rows.compactMap(\.userId)), ["TEST-GHOST-A", "TEST-GHOST-B"])
    }

    func testGhostBadge() {
        XCTAssertEqual(GhostRulebook.badge(ghost()), "No app login")
        XCTAssertEqual(GhostRulebook.badge(ghost(email: "gary@example.com")), "No app login · Invited")
        XCTAssertEqual(GhostRulebook.badge(admin()), "")
    }

    // MARK: Adding a ghost

    func testWhoMayCreateAGhost() {
        XCTAssertTrue(GhostRulebook.canCreateGhost(admin()))
        XCTAssertFalse(GhostRulebook.canCreateGhost(ghost()))
        XCTAssertFalse(GhostRulebook.canCreateGhost(nil))
    }

    func testGhostFormRowsHideEverythingAGhostDoesNotNeed() throws {
        let rows = try XCTUnwrap(CanonicalBusinessEngine.ghostAddFormRows(ghost: true, canCreateGhost: true, ghostAccountsEnabled: true))
        func row(_ field: String) -> RulebookGhostFormRow? { rows.first { $0.field == field } }
        XCTAssertEqual(row("ghostToggle")?.visible, true)
        XCTAssertEqual(row("email")?.visible, false)
        XCTAssertEqual(row("mobileNumber")?.visible, false)
        XCTAssertEqual(row("employmentType")?.visible, false)
        XCTAssertEqual(row("permissions")?.visible, false)
        XCTAssertEqual(row("pay")?.required, true)
        XCTAssertEqual(row("lineManagers")?.required, true)
        XCTAssertEqual(row("trade")?.required, false)
        let refused = try XCTUnwrap(CanonicalBusinessEngine.ghostAddFormRows(ghost: true, canCreateGhost: false, ghostAccountsEnabled: true))
        XCTAssertEqual(refused.first { $0.field == "ghostToggle" }?.visible, false)
        XCTAssertEqual(refused.first { $0.field == "email" }?.visible, true)
    }

    // MARK: Ghost accounts switch (owner decision 7 Nov "1b")

    /// The Ghost account toggle stays hidden until the platform owner sets `platformConfig/app.ghostAccounts` true
    /// after the iPhone 1.34 update is out. A missing document or field is off; the permission alone never shows it.
    func testGhostToggleHiddenUntilTheGhostAccountsSwitchIsOn() throws {
        XCTAssertEqual(CanonicalBusinessEngine.ghostAccountsEnabled(config: nil, organizationId: "TEST-ORG"), false)
        XCTAssertEqual(CanonicalBusinessEngine.ghostAccountsEnabled(config: [:], organizationId: "TEST-ORG"), false)
        XCTAssertEqual(CanonicalBusinessEngine.ghostAccountsEnabled(config: ["ghostAccounts": "true"], organizationId: "TEST-ORG"), false)
        XCTAssertEqual(CanonicalBusinessEngine.ghostAccountsEnabled(config: ["privatePay": true], organizationId: "TEST-ORG"), false)
        XCTAssertEqual(CanonicalBusinessEngine.ghostAccountsEnabled(config: ["ghostAccounts": true], organizationId: "TEST-ORG"), true)
        XCTAssertEqual(
            CanonicalBusinessEngine.ghostAccountsEnabled(config: ["ghostAccountsOrganizationIds": ["TEST-ORG"]], organizationId: "TEST-ORG"),
            true
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.ghostAccountsEnabled(config: ["ghostAccountsOrganizationIds": ["TEST-ORG"]], organizationId: "test-org"),
            false
        )

        XCTAssertTrue(CanonicalBusinessEngine.ghostToggleVisible(canCreateGhost: true, ghostAccountsEnabled: true))
        XCTAssertFalse(CanonicalBusinessEngine.ghostToggleVisible(canCreateGhost: true, ghostAccountsEnabled: false))
        XCTAssertFalse(CanonicalBusinessEngine.ghostToggleVisible(canCreateGhost: false, ghostAccountsEnabled: true))

        let off = try XCTUnwrap(CanonicalBusinessEngine.ghostAddFormRows(ghost: true, canCreateGhost: true, ghostAccountsEnabled: false))
        XCTAssertEqual(off.first { $0.field == "ghostToggle" }?.visible, false)
        // A ghost flag left on (`startAsGhost`) never turns the form into the ghost form while the switch is off.
        XCTAssertEqual(off.first { $0.field == "email" }?.visible, true)
        XCTAssertEqual(off.first { $0.field == "permissions" }?.visible, true)
    }

    /// `SecuritySwitchContext` reads the switch from the `platformConfig/app` document it already holds.
    func testSecuritySwitchContextReadsTheGhostAccountsSwitch() {
        defer { SecuritySwitchContext.reset() }
        SecuritySwitchContext.update(config: nil)
        XCTAssertFalse(SecuritySwitchContext.ghostAccountsEnabled(organizationId: "TEST-ORG"))
        SecuritySwitchContext.update(config: ["ghostAccountsOrganizationIds": ["TEST-ORG"]])
        XCTAssertTrue(SecuritySwitchContext.ghostAccountsEnabled(organizationId: "TEST-ORG"))
        XCTAssertFalse(SecuritySwitchContext.ghostAccountsEnabled(organizationId: "TEST-OTHER"))
        XCTAssertFalse(SecuritySwitchContext.switches(organizationId: "TEST-ORG").privatePay)
    }

    private var draft: [String: Any] {
        ["firstName": "TEST-Gary", "surname": "Ghost", "payBasis": "day", "dayRate": 250.0, "lineManagerIds": ["TEST-ADMIN-1"]]
    }

    func testGhostCreateErrorReadsNullAsAllowed() {
        XCTAssertEqual(CanonicalBusinessEngine.ghostCreateError(draft: draft, roster: nil), .some(nil))
        var withEmail = draft
        withEmail["email"] = "gary@example.com"
        let refused = CanonicalBusinessEngine.ghostCreateError(draft: withEmail, roster: nil)
        XCTAssertNotNil(refused ?? nil)
        var noRate = draft
        noRate["dayRate"] = 0.0
        XCTAssertEqual(CanonicalBusinessEngine.ghostCreateError(draft: noRate, roster: nil), .some(CanonicalBusinessEngine.ghostRateRequiredMessage))
    }

    func testGhostCreateWritesShapeIsKeptExactly() throws {
        let plan = try XCTUnwrap(CanonicalBusinessEngine.ghostCreateWrites(
            organizationId: "TEST-ORG-1340",
            ghostId: "TEST-GHOST-9",
            draft: draft,
            actorUserId: "TEST-ADMIN-1",
            privatePay: false,
            roster: nil
        ))
        XCTAssertEqual(plan.user.path, "users/TEST-GHOST-9")
        XCTAssertEqual(plan.user.fields["email"] as? String, "")
        XCTAssertEqual(plan.user.fields["ghost"] as? Bool, true)
        XCTAssertEqual(plan.user.fields["passwordSet"] as? Bool, false)
        XCTAssertNil(plan.user.fields["isSuperAdmin"])
        XCTAssertEqual(plan.user.fields["employmentType"] as? String, "self_employed")
        XCTAssertEqual((plan.user.fields["dayRate"] as? NSNumber)?.doubleValue, 250)
        XCTAssertEqual(plan.user.fields["updatedFrom"] as? String, "ios")
        XCTAssertTrue(plan.user.serverTimestampFields.contains("createdAt"))
        XCTAssertNil(plan.payProfile)

        let privatePlan = try XCTUnwrap(CanonicalBusinessEngine.ghostCreateWrites(
            organizationId: "TEST-ORG-1340",
            ghostId: "TEST-GHOST-9",
            draft: draft,
            actorUserId: "TEST-ADMIN-1",
            privatePay: true,
            roster: nil
        ))
        XCTAssertNil(privatePlan.user.fields["dayRate"])
        XCTAssertNotNil(privatePlan.payProfile)
    }

    // MARK: Empty emails never name another person (review of #203)

    private func row(_ docId: String, email: String = "", linkedUserId: String? = nil) -> Operative {
        var op = Operative(firstName: "TEST-Row", lastName: docId, email: email, startDate: Date(timeIntervalSince1970: 0), dayRate: 200)
        op.firestoreDocumentId = docId
        op.linkedUserId = linkedUserId
        return op
    }

    /// Two ghosts and a no-email row that belongs to neither: each ghost reaches only its own row (kept under its id or
    /// `linkedUserId`), and a ghost with no row reaches none — never the first empty-email row.
    func testOperativeRowNeverMatchesAnotherEmptyEmailRow() {
        let stranger = row("TEST-ROW-STRANGER")
        let converted = row("TEST-ROW-CONVERTED", linkedUserId: "TEST-GHOST-2")
        let keptUnderId = row("TEST-GHOST-3")
        let rows = [stranger, converted, keptUnderId]
        XCTAssertNil(OperativeStore.operativeRow(for: ghost("TEST-GHOST-1"), in: rows))
        XCTAssertEqual(OperativeStore.operativeRow(for: ghost("TEST-GHOST-2"), in: rows)?.documentId, "TEST-ROW-CONVERTED")
        XCTAssertEqual(OperativeStore.operativeRow(for: ghost("TEST-GHOST-3"), in: rows)?.documentId, "TEST-GHOST-3")
    }

    /// A person with an email reaches the row on that email, never a no-email row.
    func testOperativeRowWithEmailMatchesOnlyThatEmail() {
        var person = admin()
        person.role = .operative
        let rows = [row("TEST-ROW-EMPTY"), row("TEST-ROW-ANN", email: "test-admin@example.com")]
        XCTAssertEqual(OperativeStore.operativeRow(for: person, in: rows)?.documentId, "TEST-ROW-ANN")
        XCTAssertNil(OperativeStore.operativeRow(for: person, in: [row("TEST-ROW-EMPTY")]))
    }

    /// `syncActiveOperativesWithUserAccounts` mirrors a ghost's rate, trade and active flag only onto its own row.
    func testRosterSyncTargetForAGhostIsNeverAnotherEmptyEmailRow() {
        let rows = [row("TEST-ROW-STRANGER"), row("TEST-ROW-OTHER")]
        XCTAssertNil(UserStore.syncTargetOperativeRow(for: ghost("TEST-GHOST-1"), in: rows))
        XCTAssertNil(UserStore.syncTargetOperativeRow(for: ghost("TEST-GHOST-2"), in: rows))
        let own = row("TEST-ROW-OWN", linkedUserId: "TEST-GHOST-2")
        XCTAssertEqual(UserStore.syncTargetOperativeRow(for: ghost("TEST-GHOST-2"), in: rows + [own])?.documentId, "TEST-ROW-OWN")
    }

    /// A no-email row links to the account it is kept under, never the first account with an empty email.
    func testScheduleConflictLinkForANoEmailRowIsItsOwnGhost() {
        let users = [ghost("TEST-GHOST-1"), ghost("TEST-GHOST-2")]
        XCTAssertNil(ScheduleBookingConflictEngine.linkedUserId(for: row("TEST-ROW-STRANGER"), users: users))
        XCTAssertEqual(
            ScheduleBookingConflictEngine.linkedUserId(for: row("TEST-ROW-C", linkedUserId: "TEST-GHOST-2"), users: users),
            "TEST-GHOST-2"
        )
    }
}
