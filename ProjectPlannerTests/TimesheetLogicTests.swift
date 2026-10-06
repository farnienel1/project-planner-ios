import XCTest
@testable import Project_Planner

@MainActor
final class TimesheetLogicTests: XCTestCase {
    private let monday = LogicFixtures.day(2026, 10, 5, hour: 8)
    private let tuesday = LogicFixtures.day(2026, 10, 6, hour: 8)

    func testFullDayDeductsUnpaidBreak() {
        let booking = LogicFixtures.booking(on: monday, slot: .fullDay)
        let paid = booking.paidBookedHours(policy: LogicFixtures.policy)
        XCTAssertClose(paid, 8, "07:30–16:00 is 8.5h wall minus the 30-minute unpaid break")
    }

    func testRemovedBreakIsPaid() {
        let booking = LogicFixtures.booking(
            on: monday,
            slot: .customHours,
            start: "07:30",
            end: "16:00",
            breakRemoved: true
        )
        XCTAssertClose(booking.paidBookedHours(policy: LogicFixtures.policy), 8.5)
    }

    func testPaidBreakSettingKeepsWallHours() {
        var policy = OrgPayrollTimePolicy.default
        policy.breakPaid = true
        let booking = LogicFixtures.booking(on: monday, slot: .fullDay)
        XCTAssertClose(booking.paidBookedHours(policy: policy), 8.5)
    }

    func testMorningSlotPaysHalfTheStandardDay() {
        let booking = LogicFixtures.booking(on: monday, slot: .morning)
        XCTAssertClose(booking.paidBookedHours(policy: LogicFixtures.policy), 4)
        XCTAssertClose(booking.overtimeHoursBeyondPaidStandard(policy: LogicFixtures.policy), 0)
    }

    func testWeekdayHoursAfterStandardEndAreOvertime() {
        let booking = LogicFixtures.booking(on: monday, slot: .customHours, start: "07:30", end: "18:00")
        let result = booking.payrollHoursResult(policy: LogicFixtures.policy)
        XCTAssertClose(result.totalPaidHours, 11, "8h inside the window plus 2h × 1.5")
        XCTAssertClose(booking.overtimeHoursBeyondPaidStandard(policy: LogicFixtures.policy), 2)
    }

    func testDailyAndWeeklyTotalsAndCancelledShifts() {
        let operativeId = UUID()
        let user = LogicFixtures.selfEmployedUser()
        let operative = LogicFixtures.operative(id: operativeId, email: user.email)
        let mondayShift = LogicFixtures.booking(on: monday, operativeId: operativeId)
        let tuesdayShift = LogicFixtures.booking(on: tuesday, operativeId: operativeId)
        let cancelled = LogicFixtures.booking(
            on: tuesday,
            status: .cancelled,
            operativeId: operativeId
        )
        let week = WeekRange.titled(start: monday, end: LogicFixtures.day(2026, 10, 11))
        let summary = TimesheetPayrollCollector.collect(
            for: user,
            week: week,
            bookings: [mondayShift, tuesdayShift, cancelled],
            managerBookings: [],
            operatives: [operative],
            projects: [],
            smallWorks: [],
            history: .empty,
            policy: LogicFixtures.policy
        )
        XCTAssertEqual(summary.shiftCount, 2)
        XCTAssertClose(summary.totalHours, 16)
        XCTAssertClose(summary.baseAmount, 400)
        XCTAssertClose(summary.overtimeAmount, 0)
        XCTAssertClose(summary.workAmount, 400)

        let mondayOnly = TimesheetPayrollCollector.collect(
            for: user,
            in: monday...monday,
            bookings: [mondayShift, tuesdayShift],
            managerBookings: [],
            operatives: [operative],
            projects: [],
            smallWorks: [],
            history: .empty,
            policy: LogicFixtures.policy
        )
        XCTAssertEqual(mondayOnly.shiftCount, 1)
        XCTAssertClose(mondayOnly.totalHours, 8)
    }

    func testOvertimeLineUsesDayRateMultiplier() {
        let operativeId = UUID()
        let user = LogicFixtures.selfEmployedUser(dayRate: 200)
        let operative = LogicFixtures.operative(id: operativeId, email: user.email, dayRate: 200)
        let booking = LogicFixtures.booking(
            on: monday,
            slot: .customHours,
            start: "07:30",
            end: "18:00",
            operativeId: operativeId
        )
        let summary = TimesheetPayrollCollector.collect(
            for: user,
            in: monday...monday,
            bookings: [booking],
            managerBookings: [],
            operatives: [operative],
            projects: [],
            smallWorks: [],
            history: .empty,
            policy: LogicFixtures.policy
        )
        XCTAssertClose(summary.overtimeHours, 2)
        XCTAssertClose(summary.overtimeAmount, 75, "£200 × (2/8) × 1.5")
        XCTAssertClose(summary.baseAmount, 200)
        XCTAssertEqual(summary.lineItems.filter(\.isOvertimeLine).count, 1)
    }

    func testTouchingClockWindowsDoNotOverlap() {
        let morning = LogicFixtures.booking(on: monday, slot: .customHours, start: "08:00", end: "12:00")
        let afternoon = LogicFixtures.booking(on: monday, slot: .customHours, start: "12:00", end: "16:00")
        XCTAssertFalse(OperativeBookingInterval.bookingsOverlap(morning, afternoon, policy: LogicFixtures.policy))
    }

    func testOverlappingClockWindowsAreDetected() {
        let first = LogicFixtures.booking(on: monday, slot: .customHours, start: "08:00", end: "12:00")
        let second = LogicFixtures.booking(on: monday, slot: .customHours, start: "10:00", end: "14:00")
        XCTAssertTrue(OperativeBookingInterval.bookingsOverlap(first, second, policy: LogicFixtures.policy))
    }

    func testManagerDayMergesOverlappingEntries() {
        let first = LogicFixtures.managerBooking(on: monday, start: "08:00", end: "12:00")
        let second = LogicFixtures.managerBooking(on: monday, start: "10:00", end: "14:00")
        let union = LogicFixtures.managerBooking(on: monday, start: "08:00", end: "14:00")
        let merged = ManagerScheduleInterval.combinedPaidBookedHours(
            for: [first, second],
            policy: LogicFixtures.policy
        )
        XCTAssertClose(merged, union.paidBookedHours(policy: LogicFixtures.policy))
        let summed = first.paidBookedHours(policy: LogicFixtures.policy)
            + second.paidBookedHours(policy: LogicFixtures.policy)
        XCTAssertGreaterThan(summed, merged)
    }

    func testOverlappingOperativeShiftsArePaidOnce() {
        let operativeId = UUID()
        let user = LogicFixtures.selfEmployedUser()
        let operative = LogicFixtures.operative(id: operativeId, email: user.email)
        let first = LogicFixtures.booking(
            on: monday,
            slot: .customHours,
            start: "08:00",
            end: "12:00",
            operativeId: operativeId
        )
        let second = LogicFixtures.booking(
            on: monday,
            slot: .customHours,
            start: "10:00",
            end: "14:00",
            operativeId: operativeId
        )
        let union = LogicFixtures.booking(on: monday, slot: .customHours, start: "08:00", end: "14:00")
        let summary = TimesheetPayrollCollector.collect(
            for: user,
            in: monday...monday,
            bookings: [first, second],
            managerBookings: [],
            operatives: [operative],
            projects: [],
            smallWorks: [],
            history: .empty,
            policy: LogicFixtures.policy
        )
        XCTAssertClose(
            summary.totalHours,
            union.paidBookedHours(policy: LogicFixtures.policy),
            "overlapping 08:00–12:00 and 10:00–14:00 should pay the 08:00–14:00 union once"
        )
    }

    func testEntryCrossingMidnightCountsTheOvernightHours() {
        let booking = LogicFixtures.booking(on: monday, slot: .customHours, start: "22:00", end: "02:00")
        XCTAssertClose(
            booking.totalBookedHours(policy: LogicFixtures.policy),
            4,
            "22:00–02:00 is 4 hours, not the standard day window"
        )
        XCTAssertClose(booking.paidBookedHours(policy: LogicFixtures.policy), 4)
    }
}
