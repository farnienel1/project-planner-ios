import XCTest
@testable import Project_Planner

@MainActor
final class SchedulePeriodTests: XCTestCase {
    func testWeekStartsMondayAndSundayBelongsToThatWeek() {
        let calendar = Calendar.current
        let sunday = LogicFixtures.day(2026, 10, 11, hour: 15, calendar: calendar)
        XCTAssertEqual(calendar.component(.weekday, from: sunday), 1)
        let range = WeekRange.from(start: sunday)
        XCTAssertEqual(calendar.component(.weekday, from: range.start), 2)
        XCTAssertEqual(calendar.component(.weekday, from: range.end), 1)
        XCTAssertEqual(calendar.dateComponents([.day], from: range.start, to: range.end).day, 6)
        XCTAssertTrue(calendar.isDate(range.start, inSameDayAs: LogicFixtures.day(2026, 10, 5, calendar: calendar)))
    }

    func testWeekContainingMonthEndStaysSevenDays() {
        let calendar = Calendar.current
        let saturday = LogicFixtures.day(2026, 10, 31, calendar: calendar)
        let sunday = LogicFixtures.day(2026, 11, 1, calendar: calendar)
        let fromSaturday = WeekRange.from(start: saturday)
        let fromSunday = WeekRange.from(start: sunday)
        XCTAssertTrue(calendar.isDate(fromSaturday.start, inSameDayAs: fromSunday.start))
        XCTAssertTrue(calendar.isDate(fromSaturday.start, inSameDayAs: LogicFixtures.day(2026, 10, 26, calendar: calendar)))
        XCTAssertTrue(calendar.isDate(fromSaturday.end, inSameDayAs: sunday))
    }

    func testClockChangeWeekStaysMondayToSunday() {
        var settings = OrganizationInvoicingSettings.default
        settings.paymentRunMode = .recurringTimeframe
        settings.recurringRunStartDay = .monday
        settings.recurringRunEndDay = .sunday
        let calendar = Calendar.current
        let changeoverSunday = LogicFixtures.day(2026, 10, 25, hour: 1, minute: 30, calendar: calendar)
        let period = TimesheetPayrollPolicy.payPeriodContaining(
            referenceDate: changeoverSunday,
            settings: settings,
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.weekday, from: period.start), 2)
        XCTAssertEqual(calendar.component(.weekday, from: period.end), 1)
        XCTAssertEqual(calendar.dateComponents([.day], from: period.start, to: period.end).day, 6)
        let day = calendar.startOfDay(for: changeoverSunday)
        XCTAssertTrue(day >= period.start && day <= period.end)

        let nextMonday = LogicFixtures.day(2026, 10, 26, hour: 9, calendar: calendar)
        let nextWeek = TimesheetPayrollPolicy.payPeriodContaining(
            referenceDate: nextMonday,
            settings: settings,
            calendar: calendar
        )
        XCTAssertFalse(calendar.isDate(nextWeek.start, inSameDayAs: period.start))
        XCTAssertEqual(calendar.component(.weekday, from: nextWeek.start), 2)
    }

    func testSundayStartWeekWrapsToTheFollowingSaturday() {
        var settings = OrganizationInvoicingSettings.default
        settings.paymentRunMode = .recurringTimeframe
        settings.recurringRunStartDay = .sunday
        settings.recurringRunEndDay = .saturday
        let calendar = Calendar.current
        let wednesday = LogicFixtures.day(2026, 10, 7, hour: 9, calendar: calendar)
        let period = InvoicingPeriodResolver.resolve(
            invoicing: settings,
            referenceDate: wednesday,
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.weekday, from: period.currentPeriodStart), 1)
        XCTAssertEqual(calendar.component(.weekday, from: period.currentPeriodEnd), 7)
        XCTAssertEqual(
            calendar.dateComponents([.day], from: period.currentPeriodStart, to: period.currentPeriodEnd).day,
            6
        )
        XCTAssertTrue(wednesday >= period.currentPeriodStart && wednesday <= period.currentPeriodEnd)
    }

    func testMonthEndAndLeapDayClampThePaymentRun() {
        let calendar = LogicFixtures.utc
        var settings = OrganizationInvoicingSettings.default
        settings.paymentRunMode = .dateRanges
        settings.paymentRunDateRanges = [
            PaymentRunDateRange(startDay: 1, endDay: 15),
            PaymentRunDateRange(startDay: 16, endDay: 31),
        ]
        let february = InvoicingPeriodResolver.resolve(
            invoicing: settings,
            referenceDate: LogicFixtures.day(2026, 2, 20, calendar: calendar),
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.day, from: february.currentPeriodStart), 16)
        XCTAssertEqual(calendar.component(.day, from: february.currentPeriodEnd), 28)

        let leap = InvoicingPeriodResolver.resolve(
            invoicing: settings,
            referenceDate: LogicFixtures.day(2028, 2, 20, calendar: calendar),
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.day, from: leap.currentPeriodEnd), 29)

        let january = InvoicingPeriodResolver.resolve(
            invoicing: settings,
            referenceDate: LogicFixtures.day(2026, 1, 31, calendar: calendar),
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.day, from: january.currentPeriodEnd), 31)

        let firstHalf = InvoicingPeriodResolver.resolve(
            invoicing: settings,
            referenceDate: LogicFixtures.day(2026, 3, 10, calendar: calendar),
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.day, from: firstHalf.currentPeriodStart), 1)
        XCTAssertEqual(calendar.component(.day, from: firstHalf.currentPeriodEnd), 15)
    }

    func testCompletedPayRunIsThePreviousHalfMonth() {
        let calendar = LogicFixtures.utc
        var settings = OrganizationInvoicingSettings.default
        settings.paymentRunMode = .dateRanges
        settings.paymentRunDateRanges = [
            PaymentRunDateRange(startDay: 1, endDay: 15),
            PaymentRunDateRange(startDay: 16, endDay: 31),
        ]
        let completed = TimesheetPayrollPolicy.timesheetWeekRange(
            for: settings,
            referenceDate: LogicFixtures.day(2026, 10, 10, calendar: calendar),
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.month, from: completed.start), 9)
        XCTAssertEqual(calendar.component(.day, from: completed.start), 16)
        XCTAssertEqual(calendar.component(.day, from: completed.end), 30)
    }

    func testQuickSelectSkipsWeekends() {
        var selected = Set<Date>()
        let friday = LogicFixtures.day(2026, 10, 2)
        ScheduleDateSelectionPolicy.quickSelect(count: 3, into: &selected, startingFrom: friday)
        let calendar = Calendar.current
        let days = selected.sorted()
        XCTAssertEqual(days.count, 3)
        XCTAssertTrue(days.allSatisfy { PayrollTimePolicyCatalog.isWeekday($0, calendar: calendar) })
        XCTAssertTrue(calendar.isDate(days[0], inSameDayAs: friday))
        XCTAssertTrue(calendar.isDate(days[1], inSameDayAs: LogicFixtures.day(2026, 10, 5)))
        XCTAssertTrue(calendar.isDate(days[2], inSameDayAs: LogicFixtures.day(2026, 10, 6)))
    }
}
