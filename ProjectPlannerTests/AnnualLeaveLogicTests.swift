import XCTest
@testable import Project_Planner

@MainActor
final class AnnualLeaveLogicTests: XCTestCase {
    private var calendar: Calendar { LogicFixtures.utc }
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
        XCTAssertEqual(calendar.component(.day, from: start!), 1)
        XCTAssertEqual(calendar.component(.month, from: start!), 1)
        XCTAssertEqual(calendar.component(.year, from: start!), 2026)
        XCTAssertEqual(calendar.component(.day, from: end!), 31)
        XCTAssertEqual(calendar.component(.month, from: end!), 12)
        XCTAssertEqual(calendar.component(.year, from: end!), 2026)
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
        XCTAssertEqual(calendar.component(.year, from: before!.start), 2025)
        XCTAssertEqual(calendar.component(.month, from: before!.start), 4)
        XCTAssertEqual(calendar.component(.year, from: before!.end), 2026)
        XCTAssertEqual(calendar.component(.month, from: before!.end), 3)
        XCTAssertEqual(calendar.component(.day, from: before!.end), 31)
        XCTAssertEqual(calendar.component(.year, from: after!.start), 2026)
        XCTAssertEqual(calendar.component(.month, from: after!.start), 4)

        let previous = AnnualLeavePolicy.previousLeaveYearRange(
            beforeCurrentYearStart: after!.start,
            startMonth: 4,
            endMonth: 3,
            calendar: calendar
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
        XCTAssertClose(summary.remainingDays, 44.5)
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
            calendar: calendar
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
        XCTAssertClose(summary.remainingDays, 24)
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
}
