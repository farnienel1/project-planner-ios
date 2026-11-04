import XCTest
@testable import Project_Planner

/// Schedule booking shows hours and overtime rates with `ScheduleCoverageFormat.hours` (to the hundredth), never
/// snapped to the half hour (7.25h used to read "7.5") or cut to one decimal (×1.25 used to read "1.2×").
@MainActor
final class BookingUIFormatTests: XCTestCase {
    func testQuarterHoursAreNotSnappedToTheHalfHour() {
        XCTAssertEqual(ScheduleCoverageFormat.hours(7.25), "7.25")
        XCTAssertEqual(ScheduleCoverageFormat.hours(8.5), "8.5")
        XCTAssertEqual(ScheduleCoverageFormat.hours(34), "34")
    }

    func testQuarterStepRatesKeepBothDecimals() {
        XCTAssertEqual(ScheduleCoverageFormat.hours(1.25), "1.25")
        XCTAssertEqual(ScheduleCoverageFormat.hours(1.75), "1.75")
        XCTAssertEqual(ScheduleCoverageFormat.hours(2), "2")
    }
}
