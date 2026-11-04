import XCTest
@testable import Project_Planner

/// The iOS rulebook-bypass sweep: screens that kept their own copy of a rule the packed script already owns now call
/// it through `CanonicalBusinessEngine`. One test per swap, named after the rulebook function it relies on.
@MainActor
final class RulebookSweepTests: XCTestCase {
    private var orgCalendar: Calendar { OrganizationRulebookContext.calendar }

    private func orgDay(_ key: String) -> Date {
        CanonicalBusinessEngine.date(fromDayKey: key)!
    }

    // MARK: 1. Leave day counts (`leaveDaysInRange`)

    /// A Friday-to-Monday request takes two days, not four: the weekend inside a multi-day record is not leave
    /// (`leaveRecordDayKeys`). The request card and the "remaining after" note used to count every calendar day.
    func testLeaveCardCountsSkipTheWeekendInsideARequest() {
        let request = LogicFixtures.holiday(userId: "user-1", start: orgDay("2026-11-06"), end: orgDay("2026-11-09"))
        XCTAssertEqual(AnnualLeaveDateFormat.leaveDays(request), 2)
        XCTAssertTrue(AnnualLeaveDateFormat.bookingTitle(request).hasSuffix("· 2 days"), AnnualLeaveDateFormat.bookingTitle(request))

        let halfDays = LogicFixtures.holiday(
            userId: "user-1", start: orgDay("2026-11-06"), end: orgDay("2026-11-09"), slot: .morning
        )
        XCTAssertEqual(AnnualLeaveDateFormat.leaveDays(halfDays), 1)

        // A single-day record is that day, even on a weekend (rulebook §9).
        let saturday = LogicFixtures.holiday(userId: "user-1", start: orgDay("2026-11-07"), end: orgDay("2026-11-07"))
        XCTAssertEqual(AnnualLeaveDateFormat.leaveDays(saturday), 1)

        let span = AnnualLeaveDisplaySpan(bookings: [request, saturday])
        XCTAssertEqual(span.dayTotal, 3)
    }

    // MARK: 2. Leave balance matching (`leaveRecordsForAccount`)

    private func staffUser(id: String, email: String, formerUserIds: [String] = [], operativeMode: Bool = true) -> AppUser {
        var u = AppUser(
            id: id,
            email: email,
            organizationId: "org-test",
            role: operativeMode ? .operative : .manager,
            firstName: "Ada",
            surname: "Lovelace",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(operativeMode: operativeMode)
        )
        u.formerUserIds = formerUserIds
        return u
    }

    /// Leave booked under an old invite id counts towards the person's balance: the balance reads the account's
    /// records (`leaveRecordsForAccount` via `HolidayStore.myBookings`). It used to compare `userId` with the
    /// current id or the email only, so this day was never taken from the allowance.
    func testLeaveUnderAFormerIdCountsInTheBalance() {
        let person = staffUser(id: "uid-new", email: "ada@example.com", formerUserIds: ["invite-old"])
        let store = HolidayStore()
        store.bookings = [
            LogicFixtures.holiday(userId: "INVITE-OLD", start: orgDay("2026-11-04"), end: orgDay("2026-11-04")),
            LogicFixtures.holiday(userId: "someone-else", start: orgDay("2026-11-05"), end: orgDay("2026-11-05")),
        ]
        let mine = store.myBookings(account: person, operatives: [])
        XCTAssertEqual(mine.map(\.userId), ["INVITE-OLD"])
        let summary = AnnualLeavePolicy.usageSummary(
            bookings: mine,
            daysPerYear: 25,
            startMonth: 1,
            endMonth: 12,
            carriesOver: false,
            referenceDate: orgDay("2026-11-04")
        )
        XCTAssertEqual(summary.takenDays, 1)
        XCTAssertEqual(summary.remainingDays, 24)
    }

    /// The requester behind a leave record is `resolveBookingPerson`: a catalogue row on the account's email finds the
    /// account (no Swift email match, no operative-mode filter).
    func testLeaveRequesterResolvesThroughTheRulebook() {
        let account = staffUser(id: "uid-1", email: "Ada@Example.com", operativeMode: false)
        let operativeId = UUID()
        let catalogue = LogicFixtures.operative(id: operativeId, email: "ada@example.com")
        var record = LogicFixtures.holiday(userId: "", start: orgDay("2026-11-04"), end: orgDay("2026-11-04"))
        record.userId = nil
        record.operativeIdRaw = catalogue.documentId
        XCTAssertEqual(
            AnnualLeaveApproval.requester(for: record, users: [account], operatives: [catalogue])?.id,
            "uid-1"
        )
    }

    // MARK: 3. Past timesheet runs (`isTimesheetFullySigned`)

    /// A self-signed admin's past run is complete with their own signature (`timesheetSelfSigned` →
    /// `isTimesheetFullySigned(fields, hasLineManager: false)`); an operative's still waits for the line manager.
    func testSelfSignedPastRunIsCompleteWithTheOwnersSignature() {
        OrganizationRulebookContext.update(
            from: Organization(firestoreDocumentId: "TEST-ORG-SWEEP", name: "TEST-Sweep", creatorUserId: "TEST-FOUNDER")
        )
        defer {
            RulebookRosterSnapshot.update([])
            OrganizationRulebookContext.update(from: nil)
        }
        var admin = AppUser(
            id: "TEST-ADMIN-SS", email: "admin@example.test", organizationId: "TEST-ORG-SWEEP", role: .admin,
            firstName: "Admin", surname: "Test", passwordSet: true,
            permissions: UserPermissions(adminAccess: true, manager: true, timesheetSelfSign: true)
        )
        admin.hasNoLineManager = true
        var operative = staffUser(id: "TEST-OP", email: "op@example.test")
        operative.setLineManagerUserIds([admin.id])
        RulebookRosterSnapshot.update([admin, operative])

        var draft = TimesheetDraft()
        draft.operativeSignedAt = orgDay("2026-10-30")
        draft.operativeSignedByName = "Admin Test"
        XCTAssertTrue(TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: admin))
        XCTAssertFalse(TimesheetApprovalPolicy.isTimesheetFullyApproved(draft: draft, user: operative))
    }

    // MARK: 4. Warning hours (`ScheduleCoverageFormat.hours`)

    /// Unbooked-labour and clash rows show hours as the pay rule gives them: 7.25h stays 7.25, never 7.5.
    func testWarningHoursAreNotSnappedToTheHalfHour() {
        XCTAssertEqual(WarningsComputation.formatHours(7.25), "7.25")
        XCTAssertEqual(WarningsComputation.formatHours(3.5), "3.5")
        XCTAssertEqual(WarningsComputation.formatHours(8), "8")
        XCTAssertEqual(WarningsComputation.formatHours(7.25), ScheduleCoverageFormat.hours(7.25))
    }
}
