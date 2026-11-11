import XCTest
@testable import Project_Planner

/// RULEBOOK 1.40.0 §4.4, §9 iOS follow-on (web hand-off v1.40.0; owner decisions 11 Nov): Annual leave → Team
/// (`annualLeaveTeamPeople`, `annualLeaveTeamTabVisible`), the allowance by employment type and manual adjustments
/// (`annualLeaveBalance` with `employment` / `adjustments`, `annualLeaveAdjustmentCreateFields`,
/// `parseAnnualLeaveAdjustmentDocument`, `canAdjustAnnualLeave`). Every answer comes from the packed script; these
/// tests lock the Swift inputs (AppUser → rulebook rows) and how the answers are read. TEST data only.
@MainActor
final class Rulebook1400AnnualLeaveTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: "TEST-ORG-1400", name: "TEST-Company 1400"))
    }

    private func user(
        _ id: String,
        role: UserRole,
        permissions: UserPermissions,
        managers: [String] = [],
        passwordSet: Bool = true,
        isActive: Bool = true,
        firstName: String = "TEST",
        surname: String? = nil,
        email: String? = nil
    ) -> AppUser {
        AppUser(
            id: id,
            email: email ?? "\(id.lowercased())@example.com",
            organizationId: "TEST-ORG-1400",
            role: role,
            firstName: firstName,
            surname: surname ?? id,
            isActive: isActive,
            passwordSet: passwordSet,
            permissions: permissions,
            assignedManagerUserIds: managers
        )
    }

    private var roster: [AppUser] {
        var selfBooker = user("TEST-MGR-1", role: .manager, permissions: UserPermissions(manager: true), managers: ["TEST-ADMIN-1"])
        selfBooker.permissions.annualLeaveSelfBook = true
        return [
            user("TEST-ADMIN-1", role: .admin, permissions: UserPermissions(adminAccess: true)),
            selfBooker,
            user("TEST-OP-1", role: .operative, permissions: UserPermissions(operativeMode: true), managers: ["test-mgr-1"]),
            user("TEST-OP-2", role: .operative, permissions: UserPermissions(operativeMode: true), managers: ["TEST-ADMIN-1"]),
            // Never listed: a deleted profile, a pending invite, an inactive person.
            user("TEST-DEL-1", role: .operative, permissions: UserPermissions(operativeMode: true), managers: ["TEST-MGR-1"],
                 firstName: "Deleted", surname: "user", email: ""),
            user("TEST-PEND-1", role: .operative, permissions: UserPermissions(operativeMode: true), managers: ["TEST-MGR-1"], passwordSet: false),
            user("TEST-GONE-1", role: .operative, permissions: UserPermissions(operativeMode: true), managers: ["TEST-MGR-1"], isActive: false),
        ]
    }

    // MARK: Team (§9)

    func testAnAdminSeesEveryCurrentPersonButThemselfSelfBookersIncluded() {
        let users = roster
        let ids = AnnualLeavePersonBuilder.teamPeople(viewer: users[0], users: users, operatives: []).compactMap(\.userId)
        XCTAssertEqual(ids, ["TEST-MGR-1", "TEST-OP-1", "TEST-OP-2"])
        XCTAssertTrue(AnnualLeavePersonBuilder.teamTabVisible(viewer: users[0], users: users, operatives: []))
    }

    func testAManagerSeesOnlyTheirReportsAndAnOperativeHasNoTab() {
        let users = roster
        XCTAssertEqual(AnnualLeavePersonBuilder.teamPeople(viewer: users[1], users: users, operatives: []).compactMap(\.userId), ["TEST-OP-1"])
        XCTAssertTrue(AnnualLeavePersonBuilder.teamTabVisible(viewer: users[1], users: users, operatives: []))
        XCTAssertTrue(AnnualLeavePersonBuilder.teamPeople(viewer: users[2], users: users, operatives: []).isEmpty)
        XCTAssertFalse(AnnualLeavePersonBuilder.teamTabVisible(viewer: users[2], users: users, operatives: []))
        XCTAssertEqual(
            CanonicalBusinessEngine.annualLeaveTeamEmptyMessage(viewer: RulebookPeople.person(users[2])),
            "Nobody reports to you yet. People you line-manage appear here."
        )
    }

    // MARK: Allowance by employment type (§4.4)

    private func balance(
        employment: AnnualLeaveEmployment?,
        bookings: [CanonicalBusinessEngine.CanonicalLeaveBooking] = [],
        adjustments: [AnnualLeaveAdjustmentRecord] = [],
        on dayKey: String = "2026-11-10"
    ) throws -> RulebookAnnualLeaveBalance {
        try XCTUnwrap(CanonicalBusinessEngine.annualLeaveBalanceFull(
            annualLeaveEnabled: true, daysPerYear: 25, startMonth: 1, endMonth: 12,
            orgDaysPerYear: 25, orgStartMonth: 1, orgEndMonth: 12, carriesOver: false,
            yearAllowance: nil, yearAllowanceKey: nil, bookings: bookings, onDayKey: dayKey,
            nonWorkingDayKeys: [], employmentStartDayKey: nil, maxCarryOverDays: nil,
            employment: employment, adjustments: adjustments, timeZone: "Europe/London"
        ))
    }

    func testSelfEmployedHasNoAllowanceAndPayeDoes() throws {
        XCTAssertFalse(try balance(employment: AnnualLeaveEmployment(employmentType: "self_employed")).hasAllowance)
        let paye = try balance(employment: AnnualLeaveEmployment(employmentType: "paye"))
        XCTAssertTrue(paye.hasAllowance)
        XCTAssertEqual(paye.remaining, 25)
        // No employment passed: every day counts, as before 1.40.0.
        XCTAssertTrue(try balance(employment: nil).hasAllowance)
    }

    func testSelfEmployedToPayeFromJulyIsProRataAndEarlierLeaveDoesNotCount() throws {
        let employment = AnnualLeaveEmployment(
            employmentType: "paye",
            transitionFrom: "self_employed",
            effectiveAt: Date(timeIntervalSince1970: 1_782_860_400) // 2026-07-01 00:00 Europe/London
        )
        let records = [
            CanonicalBusinessEngine.CanonicalLeaveBooking(startDayKey: "2026-03-02", endDayKey: "2026-03-06", timeSlot: "FULL DAY", status: "approved"),
            CanonicalBusinessEngine.CanonicalLeaveBooking(startDayKey: "2026-08-03", endDayKey: "2026-08-04", timeSlot: "FULL DAY", status: "approved"),
        ]
        let result = try balance(employment: employment, bookings: records)
        XCTAssertEqual(result.yearEntitlement, 13)
        XCTAssertTrue(result.proRata)
        XCTAssertEqual(result.taken, 7)
        XCTAssertEqual(result.allowanceTaken, 2)
        XCTAssertEqual(result.remaining, 11)
    }

    // MARK: Adjustments (§4.4)

    func testAdjustmentsCountForTheirYearOnlyAndMayTakeRemainingBelowZero() throws {
        let adjustments = [
            AnnualLeaveAdjustmentRecord(id: "A", userId: "TEST-OP-1", days: -30, reason: "TEST", yearKey: "2026-01-01", createdBy: "TEST-ADMIN-1", createdByName: "TEST Admin", createdAtMs: 1),
            AnnualLeaveAdjustmentRecord(id: "B", userId: "TEST-OP-1", days: 10, reason: "TEST", yearKey: "2025-01-01", createdBy: "TEST-ADMIN-1", createdByName: "TEST Admin", createdAtMs: 2),
        ]
        let paye = try balance(employment: AnnualLeaveEmployment(employmentType: "paye"), adjustments: adjustments)
        XCTAssertEqual(paye.adjustmentDays, -30)
        XCTAssertEqual(paye.remaining, -5)
        let selfEmployed = try balance(employment: AnnualLeaveEmployment(employmentType: "self_employed"), adjustments: adjustments)
        XCTAssertEqual(selfEmployed.adjustmentDays, 0)
    }

    func testAdjustmentWriteShapeReaderAndPermissions() throws {
        XCTAssertNotNil(CanonicalBusinessEngine.annualLeaveAdjustmentValidationError(days: 0.3, reason: "TEST"))
        XCTAssertNotNil(CanonicalBusinessEngine.annualLeaveAdjustmentValidationError(days: 1, reason: " "))
        XCTAssertNil(CanonicalBusinessEngine.annualLeaveAdjustmentValidationError(days: -1.5, reason: "TEST unpaid day"))
        let fields = try XCTUnwrap(CanonicalBusinessEngine.annualLeaveAdjustmentCreateFields(
            userId: "TEST-OP-1", days: 2, reason: " TEST long service ", yearKey: "2026-01-01",
            createdBy: "TEST-ADMIN-1", createdByName: "TEST Admin"
        ))
        XCTAssertEqual(fields["reason"] as? String, "TEST long service")
        XCTAssertEqual((fields["days"] as? NSNumber)?.doubleValue, 2)
        let read = try XCTUnwrap(CanonicalBusinessEngine.parseAnnualLeaveAdjustmentDocument(
            docId: "ADJ-1",
            data: fields.merging(["createdAt": ["seconds": 1_700_000_000, "nanoseconds": 0]]) { _, new in new }
        ))
        XCTAssertEqual(read.userId, "TEST-OP-1")
        XCTAssertEqual(read.createdAtMs, 1_700_000_000_000)
        XCTAssertEqual(CanonicalBusinessEngine.annualLeaveAdjustmentLabel(2), "+2 days")

        let users = roster
        let rows = RulebookPeople.roster(users)
        XCTAssertTrue(CanonicalBusinessEngine.canAdjustAnnualLeave(viewer: RulebookPeople.person(users[0]), subject: RulebookPeople.person(users[2]), roster: rows))
        XCTAssertTrue(CanonicalBusinessEngine.canAdjustAnnualLeave(viewer: RulebookPeople.person(users[1]), subject: RulebookPeople.person(users[2]), roster: rows))
        XCTAssertFalse(CanonicalBusinessEngine.canAdjustAnnualLeave(viewer: RulebookPeople.person(users[2]), subject: RulebookPeople.person(users[2]), roster: rows))
        XCTAssertFalse(CanonicalBusinessEngine.canAdjustAnnualLeave(viewer: RulebookPeople.person(users[1]), subject: RulebookPeople.person(users[3]), roster: rows))
    }

    func testTheAdjustedNoticeIsAKnownCompanyActivityType() {
        XCTAssertEqual(AppNotification.NotificationType(stored: "annual_leave_adjusted"), .annualLeaveAdjusted)
        XCTAssertTrue(CanonicalBusinessEngine.companyActivityNoticeTypes.contains("annual_leave_adjusted"))
        let text = CanonicalBusinessEngine.annualLeaveAdjustedNoticeText(personName: "TEST Olly", actorName: "TEST Mo", days: 2, reason: "TEST")
        XCTAssertEqual(text.title, "Annual leave adjusted")
    }
}
