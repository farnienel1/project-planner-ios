import XCTest
@testable import Project_Planner

@MainActor
final class WarningScanCanonicalTests: XCTestCase {
    private let calendar = CanonicalBusinessEngine.businessCalendar

    func testSevenDayWindowIsTodayThroughSixDaysLater() throws {
        let monday = try day("2026-10-05")
        let window = try window(
            on: monday,
            mode: .numberOfDays,
            days: 7,
            ranges: Self.halfMonth
        )
        XCTAssertEqual(dayKey(window.start), "2026-10-05")
        XCTAssertEqual(dayKey(window.end), "2026-10-11")
    }

    func testWorkingWeekIsMondayToFriday() throws {
        let friday = try day("2026-10-09")
        let window = try window(
            on: friday,
            mode: .endOfWorkingWeek,
            days: 7,
            ranges: Self.halfMonth
        )
        XCTAssertEqual(dayKey(window.start), "2026-10-05")
        XCTAssertEqual(dayKey(window.end), "2026-10-09")
        let unbookedEnd = CanonicalBusinessEngine.unbookedLabourWindowEnd(
            coverageEnd: window.end,
            clashLookaheadMode: WarningClashLookaheadMode.endOfWorkingWeek.rawValue,
            includeWeekends: true
        )
        XCTAssertEqual(dayKey(unbookedEnd), "2026-10-11")
        let weekdaysOnly = CanonicalBusinessEngine.unbookedLabourWindowEnd(
            coverageEnd: window.end,
            clashLookaheadMode: WarningClashLookaheadMode.endOfWorkingWeek.rawValue,
            includeWeekends: false
        )
        XCTAssertEqual(dayKey(weekdaysOnly), "2026-10-09")
    }

    func testInvoicingPeriodKeepsHalfMonthAndCustomRuns() throws {
        let ninth = try day("2026-10-09")
        let twentieth = try day("2026-10-20")
        let half = try window(on: ninth, mode: .endOfInvoicingPeriod, days: 7, ranges: Self.halfMonth)
        XCTAssertEqual(dayKey(half.start), "2026-10-01")
        XCTAssertEqual(dayKey(half.end), "2026-10-15")
        let custom = try window(on: twentieth, mode: .endOfInvoicingPeriod, days: 7, ranges: Self.customMonth)
        XCTAssertEqual(dayKey(custom.start), "2026-10-17")
        XCTAssertEqual(dayKey(custom.end), "2026-10-31")
    }

    func testStartDateEndDateDocumentKeepsThoseDays() {
        let settings = FirebaseBackend.organizationSettingsFromOrgDocument([
            "invoicing": [
                "paymentRunMode": "date_ranges",
                "paymentRunDateRanges": [
                    ["startDate": 1, "endDate": 16],
                    ["startDate": 17, "endDate": 31],
                ],
            ],
        ])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.startDay), [1, 17])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.endDay), [16, 31])
    }

    func testMissingEndDayDoesNotBecomeTheNextDay() {
        let settings = FirebaseBackend.organizationSettingsFromOrgDocument([
            "invoicing": [
                "paymentRunDateRanges": [
                    ["startDay": 1],
                    ["startDay": 16, "endDay": 31],
                ],
            ],
        ])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.startDay), [16])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.endDay), [31])
    }

    func testMissingRangesStayHalfMonth() {
        let settings = FirebaseBackend.organizationSettingsFromOrgDocument([
            "invoicing": ["paymentRunMode": "date_ranges"],
        ])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.startDay), [1, 16])
        XCTAssertEqual(settings.invoicing.paymentRunDateRanges.map(\.endDay), [15, 31])
    }

    func testOperativeModeHidesStaffWarnings() {
        let operative = CanonicalBusinessEngine.CanonicalStaffAccountRole(
            isSuperAdmin: false,
            isAdmin: true,
            isManager: true,
            isOperativeMode: true
        )
        XCTAssertFalse(CanonicalBusinessEngine.canViewStaffWarnings(operative))
        XCTAssertFalse(CanonicalBusinessEngine.isStaffAccount(operative))
        XCTAssertFalse(CanonicalBusinessEngine.seesEveryJob(operative))

        let manager = CanonicalBusinessEngine.CanonicalStaffAccountRole(
            isSuperAdmin: false,
            isAdmin: false,
            isManager: true,
            isOperativeMode: false
        )
        XCTAssertTrue(CanonicalBusinessEngine.canViewStaffWarnings(manager))
        XCTAssertTrue(CanonicalBusinessEngine.seesEveryJob(manager))

        let admin = CanonicalBusinessEngine.CanonicalStaffAccountRole(
            isSuperAdmin: false,
            isAdmin: true,
            isManager: false,
            isOperativeMode: false
        )
        XCTAssertTrue(CanonicalBusinessEngine.canViewStaffWarnings(admin))
    }

    private func window(
        on reference: Date,
        mode: WarningClashLookaheadMode,
        days: Int,
        ranges: [PaymentRunDateRange]
    ) throws -> (start: Date, end: Date) {
        var invoicing = OrganizationInvoicingSettings.default
        invoicing.paymentRunMode = .dateRanges
        invoicing.paymentRunDateRanges = ranges
        let detection = OrgWarningDetectionSettings(
            clashLookaheadMode: mode,
            clashLookaheadDays: days
        )
        return CanonicalBusinessEngine.warningBounds(
            detection: detection,
            invoicing: invoicing,
            reference: reference
        )
    }

    private func day(_ key: String) throws -> Date {
        try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: key, calendar: calendar))
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static let halfMonth = [
        PaymentRunDateRange(startDay: 1, endDay: 15),
        PaymentRunDateRange(startDay: 16, endDay: 31),
    ]

    private static let customMonth = [
        PaymentRunDateRange(startDay: 1, endDay: 16),
        PaymentRunDateRange(startDay: 17, endDay: 31),
    ]
}
