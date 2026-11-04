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
}
