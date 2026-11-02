import XCTest
@testable import Project_Planner

@MainActor
final class AnnualLeaveLogicTests: XCTestCase {
    private var calendar: Calendar { LogicFixtures.utc }
    private var london: Calendar { CanonicalBusinessEngine.businessCalendar }
    private let userId = "user-1"

    func testCalendarYearLeaveWindow() {
        let range = AnnualLeavePolicy.leaveYearRange(
            containing: LogicFixtures.day(2026, 6, 15, calendar: calendar),
            startMonth: 1,
            endMonth: 12,
            calendar: calendar
        )
        let start = range?.start
        let end = range?.end
        XCTAssertEqual(london.component(.day, from: start!), 1)
        XCTAssertEqual(london.component(.month, from: start!), 1)
        XCTAssertEqual(london.component(.year, from: start!), 2026)
        XCTAssertEqual(london.component(.day, from: end!), 31)
        XCTAssertEqual(london.component(.month, from: end!), 12)
        XCTAssertEqual(london.component(.year, from: end!), 2026)
    }

    func testAprilToMarchRolloverBoundary() {
        let before = AnnualLeavePolicy.leaveYearRange(
            containing: LogicFixtures.day(2026, 3, 31, calendar: calendar),
            startMonth: 4,
            endMonth: 3,
            calendar: calendar
        )
        let after = AnnualLeavePolicy.leaveYearRange(
            containing: LogicFixtures.day(2026, 4, 1, calendar: calendar),
            startMonth: 4,
            endMonth: 3,
            calendar: calendar
        )
        XCTAssertEqual(london.component(.year, from: before!.start), 2025)
        XCTAssertEqual(london.component(.month, from: before!.start), 4)
        XCTAssertEqual(london.component(.year, from: before!.end), 2026)
        XCTAssertEqual(london.component(.month, from: before!.end), 3)
        XCTAssertEqual(london.component(.day, from: before!.end), 31)
        XCTAssertEqual(london.component(.year, from: after!.start), 2026)
        XCTAssertEqual(london.component(.month, from: after!.start), 4)

        let previous = AnnualLeavePolicy.previousLeaveYearRange(
            beforeCurrentYearStart: after!.start,
            startMonth: 4,
            endMonth: 3,
            calendar: london
        )
        XCTAssertEqual(previous?.start, before?.start)
        XCTAssertEqual(previous?.end, before?.end)
    }

    func testHalfDaysAndCarryOver() {
        let previousMorning = LogicFixtures.holiday(
            userId: userId,
            start: LogicFixtures.day(2025, 5, 6, calendar: calendar),
            end: LogicFixtures.day(2025, 5, 6, calendar: calendar),
            slot: .morning
        )
        let previousFull = LogicFixtures.holiday(
            userId: userId,
            start: LogicFixtures.day(2025, 6, 2, calendar: calendar),
            end: LogicFixtures.day(2025, 6, 6, calendar: calendar)
        )
        let summary = AnnualLeavePolicy.usageSummary(
            bookings: [previousMorning, previousFull],
            profileUserId: userId,
            operativeId: nil,
            daysPerYear: 25,
            startMonth: 4,
            endMonth: 3,
            carriesOver: true,
            referenceDate: LogicFixtures.day(2026, 5, 1, calendar: calendar),
            calendar: calendar
        )
        XCTAssertClose(summary.takenDays, 0)
        XCTAssertClose(summary.carryOverDays, 19.5, "25 − 0.5 − 5 unused from the previous leave year")
        XCTAssertClose(summary.entitlementDays, 44.5)
        XCTAssertClose(summary.remainingDays ?? -1, 44.5)
    }

    func testBookingThatCrossesTheLeaveYearOnlyCountsDaysInsideIt() {
        let spanning = LogicFixtures.holiday(
            userId: userId,
            start: LogicFixtures.day(2026, 3, 30, calendar: calendar),
            end: LogicFixtures.day(2026, 4, 2, calendar: calendar)
        )
        let range = AnnualLeavePolicy.leaveYearRange(
            containing: LogicFixtures.day(2026, 4, 2, calendar: calendar),
            startMonth: 4,
            endMonth: 3,
            calendar: calendar
        )!
        let consumed = AnnualLeavePolicy.consumedDays(
            bookings: [spanning],
            userId: userId,
            operativeId: nil,
            statuses: [.approved],
            rangeStart: range.start,
            rangeEnd: range.end,
            calendar: london
        )
        XCTAssertClose(consumed, 2, "30–31 Mar belong to the previous leave year")
    }

    func testRequestOverAllowanceIsRejectedAndAShorterOneIsAllowed() {
        var used: [HolidayBooking] = []
        var cursor = LogicFixtures.day(2026, 1, 5, calendar: calendar)
        for _ in 0..<25 {
            while AnnualLeaveCalendarRules.isWeekend(cursor, calendar: calendar) {
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
            }
            used.append(LogicFixtures.holiday(userId: userId, start: cursor, end: cursor))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        let extra = LogicFixtures.day(2026, 6, 1, calendar: calendar)
        let blocked = AnnualLeavePolicy.validateProposedDayBookingsAgainstAllowance(
            selectedStartOfDays: [extra],
            timeSlot: .fullDay,
            bookings: used,
            profileUserId: userId,
            operativeId: nil,
            daysPerYear: 25,
            startMonth: 1,
            endMonth: 12,
            carriesOver: false,
            calendar: calendar
        )
        XCTAssertNotNil(blocked)

        let halfDayStillBlocked = AnnualLeavePolicy.validateProposedDaySlots(
            daySlots: [extra: .morning],
            bookings: used,
            profileUserId: userId,
            operativeId: nil,
            daysPerYear: 25,
            startMonth: 1,
            endMonth: 12,
            carriesOver: false,
            calendar: calendar
        )
        XCTAssertNotNil(halfDayStillBlocked)

        let within = AnnualLeavePolicy.validateProposedDayBookingsAgainstAllowance(
            selectedStartOfDays: [extra],
            timeSlot: .fullDay,
            bookings: Array(used.prefix(24)),
            profileUserId: userId,
            operativeId: nil,
            daysPerYear: 25,
            startMonth: 1,
            endMonth: 12,
            carriesOver: false,
            calendar: calendar
        )
        XCTAssertNil(within)
    }

    func testPendingLeaveReducesRemainingAndRejectedDoesNot() {
        let pending = LogicFixtures.holiday(
            userId: userId,
            start: LogicFixtures.day(2026, 2, 2, calendar: calendar),
            end: LogicFixtures.day(2026, 2, 3, calendar: calendar),
            status: .pending,
            slot: .afternoon
        )
        let rejected = LogicFixtures.holiday(
            userId: userId,
            start: LogicFixtures.day(2026, 3, 2, calendar: calendar),
            end: LogicFixtures.day(2026, 3, 6, calendar: calendar),
            status: .rejected
        )
        let summary = AnnualLeavePolicy.usageSummary(
            bookings: [pending, rejected],
            profileUserId: userId,
            operativeId: nil,
            daysPerYear: 25,
            startMonth: 1,
            endMonth: 12,
            carriesOver: false,
            referenceDate: LogicFixtures.day(2026, 2, 2, calendar: calendar),
            calendar: calendar
        )
        XCTAssertClose(summary.pendingDays, 1)
        XCTAssertClose(summary.takenDays, 0)
        XCTAssertClose(summary.remainingDays ?? -1, 24)
    }

    func testMorningAndAfternoonOnTheSameDayConsumeOneDay() {
        let morning = LogicFixtures.holiday(
            userId: userId,
            start: LogicFixtures.day(2026, 4, 7, calendar: calendar),
            end: LogicFixtures.day(2026, 4, 7, calendar: calendar),
            slot: .morning
        )
        let afternoon = LogicFixtures.holiday(
            userId: userId,
            start: LogicFixtures.day(2026, 4, 7, calendar: calendar),
            end: LogicFixtures.day(2026, 4, 7, calendar: calendar),
            slot: .afternoon
        )
        let consumed = AnnualLeavePolicy.consumedDays(
            bookings: [morning, afternoon],
            userId: userId,
            operativeId: nil,
            statuses: [.approved],
            rangeStart: LogicFixtures.day(2026, 1, 1, calendar: calendar),
            rangeEnd: LogicFixtures.day(2026, 12, 31, calendar: calendar),
            calendar: calendar
        )
        XCTAssertClose(consumed, 1)
    }

    func testOverlappingFullDayRequestsConsumeOneDay() {
        let first = LogicFixtures.holiday(
            userId: userId,
            start: LogicFixtures.day(2026, 4, 7, calendar: calendar),
            end: LogicFixtures.day(2026, 4, 9, calendar: calendar)
        )
        let second = LogicFixtures.holiday(
            userId: userId,
            start: LogicFixtures.day(2026, 4, 8, calendar: calendar),
            end: LogicFixtures.day(2026, 4, 10, calendar: calendar)
        )
        let consumed = AnnualLeavePolicy.consumedDays(
            bookings: [first, second],
            userId: userId,
            operativeId: nil,
            statuses: [.approved],
            rangeStart: LogicFixtures.day(2026, 1, 1, calendar: calendar),
            rangeEnd: LogicFixtures.day(2026, 12, 31, calendar: calendar),
            calendar: calendar
        )
        XCTAssertClose(consumed, 4, "7–10 Apr is four calendar days; the overlap on 8–9 Apr must not be counted twice")
    }

    func testBankHolidayBlocksTheDayEvenOnAWeekend() {
        let boxingDay = LogicFixtures.day(2026, 12, 26, calendar: calendar)
        XCTAssertTrue(AnnualLeaveCalendarRules.isWeekend(boxingDay, calendar: calendar))
        let holiday = BankHolidayDay(
            dayKey: BankHolidayDay.dayKey(for: boxingDay, calendar: calendar),
            date: boxingDay,
            name: "Boxing Day"
        )
        let reason = AnnualLeaveCalendarRules.blockReason(
            for: boxingDay,
            bankHolidays: [holiday.dayKey: holiday],
            calendar: calendar
        )
        guard case .bankHoliday(let name) = reason else {
            return XCTFail("expected a bank holiday block, got \(String(describing: reason))")
        }
        XCTAssertEqual(name, "Boxing Day")

        let ordinarySaturday = LogicFixtures.day(2026, 12, 19, calendar: calendar)
        XCTAssertEqual(
            AnnualLeaveCalendarRules.blockReason(for: ordinarySaturday, bankHolidays: [:], calendar: calendar),
            .weekend
        )

        let booking = LogicFixtures.holiday(
            userId: userId,
            start: LogicFixtures.day(2026, 12, 24, calendar: calendar),
            end: LogicFixtures.day(2026, 12, 28, calendar: calendar)
        )
        XCTAssertTrue(
            AnnualLeaveCalendarRules.bookingContainsBankHoliday(
                booking,
                bankHolidays: [holiday.dayKey: holiday],
                calendar: calendar
            )
        )
        XCTAssertTrue(AnnualLeaveCalendarRules.bookingContainsWeekend(booking, calendar: calendar))
    }

    func testIncreasingAHalfDayPastTheAllowanceIsRejected() {
        let booking = LogicFixtures.holiday(
            userId: userId,
            start: LogicFixtures.day(2026, 8, 3, calendar: calendar),
            end: LogicFixtures.day(2026, 8, 3, calendar: calendar),
            slot: .morning
        )
        var filled: [HolidayBooking] = [booking]
        var cursor = LogicFixtures.day(2026, 1, 5, calendar: calendar)
        while filled.count < 26 {
            while AnnualLeaveCalendarRules.isWeekend(cursor, calendar: calendar)
                || calendar.isDate(cursor, inSameDayAs: booking.startDate) {
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
            }
            filled.append(LogicFixtures.holiday(userId: userId, start: cursor, end: cursor))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        let error = AnnualLeavePolicy.validateTimeSlotIncreaseAgainstAllowance(
            booking: booking,
            newTimeSlot: .fullDay,
            bookings: filled,
            profileUserId: userId,
            operativeId: nil,
            daysPerYear: 25,
            startMonth: 1,
            endMonth: 12,
            carriesOver: false,
            calendar: calendar
        )
        XCTAssertNotNil(error)

        let downgrade = AnnualLeavePolicy.validateTimeSlotIncreaseAgainstAllowance(
            booking: booking,
            newTimeSlot: .afternoon,
            bookings: filled,
            profileUserId: userId,
            operativeId: nil,
            daysPerYear: 25,
            startMonth: 1,
            endMonth: 12,
            carriesOver: false,
            calendar: calendar
        )
        XCTAssertNil(downgrade)
    }

    // MARK: - Rulebook 1.2.0 self-book, line manager and deciders

    private func staff(
        _ id: String,
        role: UserRole,
        permissions: UserPermissions,
        lineManagers: [String] = [],
        hasNoLineManager: Bool = false
    ) -> AppUser {
        var user = AppUser(id: id, email: "\(id)@example.test", organizationId: "TEST-org", role: role, permissions: permissions)
        user.setLineManagerUserIds(lineManagers)
        user.hasNoLineManager = hasNoLineManager
        return user
    }

    /// Having no line manager does not make a manager a self-booker (`canSelfBookAnnualLeave`), and every
    /// operative and manager needs one (`lineManagerRequiredError`), whatever self-book (rulebook 1.3.0 §8, §11).
    func testNoLineManagerIsNotSelfBookAndNeedsALineManager() {
        let director = staff("dir-1", role: .manager, permissions: UserPermissions(manager: true), hasNoLineManager: true)
        XCTAssertFalse(AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: director, users: [director]))
        XCTAssertNotNil(AnnualLeaveApproval.lineManagerRequiredError(for: director, users: [director]))
        XCTAssertTrue(AnnualLeaveApproval.showsNoLineManagerNotice(for: director, users: [director]))

        var selfBooker = director
        selfBooker.permissions.annualLeaveSelfBook = true
        XCTAssertTrue(AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: selfBooker, users: [selfBooker]))
        // 1.3.0: the self-book permission no longer waives the line manager.
        XCTAssertEqual(
            AnnualLeaveApproval.lineManagerRequiredError(for: selfBooker, users: [selfBooker]),
            "Set a line manager — this person's timesheets and annual leave need approval."
        )

        let admin = staff("admin-1", role: .admin, permissions: UserPermissions(adminAccess: true))
        let report = staff("op-1", role: .operative, permissions: UserPermissions(operativeMode: true), lineManagers: ["admin-1"])
        XCTAssertNil(AnnualLeaveApproval.lineManagerRequiredError(for: report, users: [admin, report]))
        XCTAssertEqual(AnnualLeaveApproval.usersMissingLineManager([admin, report, director]).map(\.id).contains("dir-1"), true)
        XCTAssertFalse(AnnualLeaveApproval.usersMissingLineManager([admin, report, director]).map(\.id).contains("op-1"))
        XCTAssertFalse(AnnualLeaveApproval.usersMissingLineManager([admin, report, director]).map(\.id).contains("admin-1"))
    }

    /// Rulebook 1.3.0 §8, §9: an admin with no active line manager is self-approved — own leave saves approved
    /// behind "Submit" and the timesheet is self-signed. An admin with a line manager asks like everyone else.
    func testAdminWithoutLineManagerIsSelfApproved() {
        let admin = staff("admin-1", role: .admin, permissions: UserPermissions(adminAccess: true))
        let manager = staff("mgr-1", role: .manager, permissions: UserPermissions(manager: true), lineManagers: ["admin-1"])
        let managedAdmin = staff("admin-2", role: .admin, permissions: UserPermissions(adminAccess: true), lineManagers: ["mgr-1"])
        let users = [admin, manager, managedAdmin]

        XCTAssertNil(AnnualLeaveApproval.lineManagerRequiredError(for: admin, users: users))
        XCTAssertTrue(AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: admin, users: users))
        XCTAssertEqual(RulebookPeople.timesheetSelfSigned(admin, users: users), true)
        XCTAssertEqual(RulebookPeople.leaveSubmitLabel(admin, users: users), "Submit")

        XCTAssertFalse(AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: managedAdmin, users: users))
        XCTAssertEqual(RulebookPeople.timesheetSelfSigned(managedAdmin, users: users), false)
        XCTAssertEqual(RulebookPeople.leaveSubmitLabel(managedAdmin, users: users), "Submit request")

        // A manager is never self-signed, line manager or not.
        XCTAssertEqual(RulebookPeople.timesheetSelfSigned(manager, users: users), false)
    }

    /// Rulebook 1.3.0 §13: recipient rules never name the actor or the subject under any of their ids.
    func testNotificationRecipientsNeverNameTheActor() throws {
        let admin = staff("admin-1", role: .admin, permissions: UserPermissions(adminAccess: true))
        var manager = staff("mgr-1", role: .manager, permissions: UserPermissions(manager: true), lineManagers: ["admin-1"])
        manager.sameEmailUserIds = ["mgr-old"]
        let report = staff("op-1", role: .operative, permissions: UserPermissions(operativeMode: true), lineManagers: ["mgr-1", "op-1"])
        let users = [admin, manager, report]
        let roster = RulebookPeople.roster(users)

        XCTAssertEqual(
            try XCTUnwrap(CanonicalBusinessEngine.timesheetSubmittedRecipients(subject: RulebookPeople.person(report), roster: roster)),
            ["mgr-1"]
        )
        XCTAssertEqual(
            try XCTUnwrap(CanonicalBusinessEngine.timesheetSubmittedRecipients(subject: RulebookPeople.person(admin), roster: roster)),
            []
        )
        XCTAssertEqual(
            try XCTUnwrap(CanonicalBusinessEngine.timesheetSignedRecipients(subject: "op-1", signer: RulebookPeople.person(report), roster: roster)),
            []
        )
        XCTAssertEqual(
            try XCTUnwrap(CanonicalBusinessEngine.holidayDecisionRecipients(requester: "op-1", decider: RulebookPeople.person(manager), roster: roster)),
            ["op-1"]
        )
        XCTAssertEqual(
            try XCTUnwrap(CanonicalBusinessEngine.bookingCreatedRecipients(bookedIds: ["op-1", "mgr-old"], booker: RulebookPeople.person(manager), roster: roster)),
            ["op-1"]
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.timesheetNotificationDedupeKey(
                type: "timesheet_signed_by_manager",
                subjectId: "op-1",
                periodStartDayKey: "2026-07-02",
                timeZone: "Europe/London"
            ),
            "timesheetSigned|op-1|1782946800"
        )
    }

    /// `canDecideLeave` / `leaveDecisionQueue`: never your own request; admins decide any; a line manager
    /// decides their reports'.
    func testDecidersComeFromTheRulebook() {
        let admin = staff("admin-1", role: .admin, permissions: UserPermissions(adminAccess: true))
        let manager = staff("mgr-1", role: .manager, permissions: UserPermissions(manager: true), lineManagers: ["admin-1"])
        let report = staff("op-1", role: .operative, permissions: UserPermissions(operativeMode: true), lineManagers: ["mgr-1"])
        let users = [admin, manager, report]
        let request = HolidayBooking(
            organizationId: "TEST-org",
            userId: "op-1",
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_000_000),
            status: .pending
        )
        XCTAssertTrue(AnnualLeaveApproval.canDecide(request, viewer: admin, users: users, operatives: []))
        XCTAssertTrue(AnnualLeaveApproval.canDecide(request, viewer: manager, users: users, operatives: []))
        XCTAssertFalse(AnnualLeaveApproval.canDecide(request, viewer: report, users: users, operatives: []))
        XCTAssertEqual(AnnualLeaveApproval.decidableRequests([request], viewer: manager, users: users, operatives: []).count, 1)
        XCTAssertEqual(AnnualLeaveApproval.decidableRequests([request], viewer: report, users: users, operatives: []).count, 0)
    }
}
