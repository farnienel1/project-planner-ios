import XCTest
@testable import Project_Planner

/// Launch data-integrity fixes: booking days at organisation midnight (`organizationDayStartMs`), planned listener
/// backoff, and pay that could not be calculated.
@MainActor
final class DataIntegrityFixesTests: XCTestCase {
    func testAPhoneMidnightAheadOfTheOrganisationIsStillThatDay() throws {
        var phone = Calendar(identifier: .gregorian)
        phone.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let picked = try XCTUnwrap(phone.date(from: DateComponents(year: 2026, month: 11, day: 4)))
        let stored = BookingDay.organizationMidnight(for: picked, phoneCalendar: phone)
        XCTAssertEqual(OrganizationRulebookContext.dayKey(stored), "2026-11-04", "the picked day, not the day before")
        XCTAssertEqual(stored, CanonicalBusinessEngine.organizationDayStart("2026-11-04"))
        // An organisation midnight is kept; any other instant is its organisation-zone day.
        XCTAssertEqual(BookingDay.organizationMidnight(for: stored, phoneCalendar: phone), stored)
        let afternoon = stored.addingTimeInterval(15 * 3600)
        XCTAssertEqual(BookingDay.organizationMidnight(for: afternoon, phoneCalendar: phone), stored)
    }

    func testPlannedListenersRetryWithBackoff() {
        XCTAssertEqual(FirebaseBackend.plannedListenerRetryDelay(attempt: 0), 2)
        XCTAssertEqual(FirebaseBackend.plannedListenerRetryDelay(attempt: 1), 4)
        XCTAssertEqual(FirebaseBackend.plannedListenerRetryDelay(attempt: 4), 32)
        XCTAssertEqual(FirebaseBackend.plannedListenerRetryDelay(attempt: 10), 60)
    }

    func testAPayThatCouldNotBeCalculatedIsNotZero() {
        let resolved = ResolvedPayrollRate(basis: .dayRate, dayRate: 200, hourlyRate: nil)
        XCTAssertNotNil(resolved.payForHoursIfCalculated(8, standardDayHours: 8))
        XCTAssertFalse(TimesheetPayrollSummary(totalHours: 0, overtimeHours: 0, shiftCount: 0, baseAmount: 0, overtimeAmount: 0, lineItems: []).calculationFailed)
    }
}
