import XCTest
@testable import Project_Planner

@MainActor
final class MoneyAndValidationTests: XCTestCase {
    func testDayRateAndHourlyAmountsLandOnPennies() {
        let day = ResolvedPayrollRate(basis: .dayRate, dayRate: 200, hourlyRate: nil)
        XCTAssertClose(day.payForHours(8, standardDayHours: 8), 200)
        XCTAssertClose(day.payForHours(4, standardDayHours: 8), 100)

        let hourly = ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: 12.5)
        XCTAssertClose(hourly.payForHours(8, standardDayHours: 8), 100)
        XCTAssertClose(hourly.payForHours(1.5, standardDayHours: 8), 18.75)
    }

    func testSignedTimesheetTotalDropsDeclinesAndUsesEdits() {
        let day = LogicFixtures.day(2026, 10, 5)
        let labour = TimesheetPayrollLineItem(
            id: "op-day-normal",
            date: day,
            jobNumber: "100",
            projectName: "Site",
            details: "Full day",
            paidHours: 8,
            payrollBasis: .dayRate,
            dayRate: 100,
            hourlyRate: nil,
            amount: 100,
            isPayeDay: false,
            isOvertimeLine: false
        )
        let draft = TimesheetDraft(
            expenseEntries: [
                TimesheetExpenseEntry(
                    id: UUID(),
                    title: "Fuel",
                    details: "",
                    jobNumber: "100",
                    date: day,
                    amount: 10.10,
                    managerDecision: .approved
                ),
                TimesheetExpenseEntry(
                    id: UUID(),
                    title: "Parking",
                    details: "",
                    jobNumber: "100",
                    date: day,
                    amount: 4.50,
                    managerDecision: .declined
                ),
            ],
            priceWorkEntries: [
                TimesheetPriceWorkEntry(
                    id: UUID(),
                    title: "Extra sockets",
                    details: "",
                    jobNumber: "100",
                    agreedManagerName: "Manager",
                    startDate: day,
                    amount: 20,
                    managerDecision: .edited,
                    managerRevisedAmount: 15.25
                ),
            ]
        )
        let signed = TimesheetDraftAdjustments.grandTotal(
            lines: [labour],
            draft: draft,
            managerHasSigned: true
        )
        XCTAssertClose(signed, 125.35, "100 + 10.10 + 15.25; declined parking is omitted")
        let unsigned = TimesheetDraftAdjustments.grandTotal(
            lines: [labour],
            draft: draft,
            managerHasSigned: false
        )
        XCTAssertClose(unsigned, 134.60)
    }

    func testInvoiceTotalDoesNotAddVAT() {
        let labour = TimesheetPayrollLineItem(
            id: "op-day-normal",
            date: LogicFixtures.day(2026, 10, 5),
            jobNumber: "100",
            projectName: "Site",
            details: "Full day",
            paidHours: 8,
            payrollBasis: .dayRate,
            dayRate: 100,
            hourlyRate: nil,
            amount: 100,
            isPayeDay: false,
            isOvertimeLine: false
        )
        let total = TimesheetDraftAdjustments.grandTotal(
            lines: [labour],
            draft: TimesheetDraft(),
            managerHasSigned: true
        )
        XCTAssertClose(total, 100, "invoice totals are the net amount; 20% VAT is not added")
    }

    func testPayrollAmountsRoundToPennies() {
        let rate = ResolvedPayrollRate(basis: .dayRate, dayRate: 100, hourlyRate: nil)
        let raw = rate.payForHours(1.0 / 3.0, standardDayHours: 8)
        let pennies = (raw * 100).rounded() / 100
        XCTAssertClose(
            raw,
            pennies,
            accuracy: 0.000_000_1,
            "£100 day rate for 20 minutes (1/3 hour of an 8-hour day) should be stored in pennies"
        )
    }

    func testPaymentRunMustCoverTheMonthWithoutOverlap() {
        var settings = OrganizationInvoicingSettings.default
        settings.paymentRunMode = .dateRanges
        settings.paymentRunDateRanges = [
            PaymentRunDateRange(startDay: 1, endDay: 15),
            PaymentRunDateRange(startDay: 16, endDay: 31),
        ]
        XCTAssertNil(settings.fullMonthCoverageWarning())
        XCTAssertNil(settings.paymentRunRangesOverlapWarning())

        settings.paymentRunDateRanges = [
            PaymentRunDateRange(startDay: 1, endDay: 10),
            PaymentRunDateRange(startDay: 16, endDay: 31),
        ]
        XCTAssertNotNil(settings.fullMonthCoverageWarning())

        settings.paymentRunDateRanges = [
            PaymentRunDateRange(startDay: 1, endDay: 20),
            PaymentRunDateRange(startDay: 16, endDay: 31),
        ]
        XCTAssertNotNil(settings.paymentRunRangesOverlapWarning())
    }

    func testLeaveBookedBackwardsDoesNotConsumeDays() {
        let calendar = LogicFixtures.utc
        let backwards = LogicFixtures.holiday(
            userId: "user-1",
            start: LogicFixtures.day(2026, 5, 10, calendar: calendar),
            end: LogicFixtures.day(2026, 5, 8, calendar: calendar)
        )
        let consumed = AnnualLeavePolicy.consumedDays(
            bookings: [backwards],
            userId: "user-1",
            operativeId: nil,
            statuses: [.approved],
            rangeStart: LogicFixtures.day(2026, 1, 1, calendar: calendar),
            rangeEnd: LogicFixtures.day(2026, 12, 31, calendar: calendar),
            calendar: calendar
        )
        XCTAssertClose(consumed, 0)
    }
}
