import XCTest
@testable import Project_Planner

/// Owner report (17 Nov 2026, UI only): on web the Daily Overview "Other" card showed the stored slot word
/// ("CUSTOM_HOURS"); on iOS its Office / Working from home / Site survey / custom-place rows showed the clock range twice
/// (as the subtitle and again in the pill) and no hours. They now read like a job's row: "Custom 06:00–17:30" and the
/// pay rule's hours pill. These tests lock the words; the figures come from the same functions a job's row uses.
@MainActor
final class DailyOverviewOtherRowTests: XCTestCase {
    private func officeBooking(_ slot: ManagerTimeSlot, start: String? = nil, end: String? = nil) -> ManagerSiteBooking {
        ManagerSiteBooking(
            userId: "TEST-admin",
            date: LogicFixtures.day(2026, 11, 17, hour: 8),
            timeSlot: slot,
            locationType: .office,
            workStartTime: start,
            workEndTime: end
        )
    }

    func testACustomHoursOfficeRowReadsLikeAJobRow() {
        let booking = officeBooking(.customHours, start: "06:00", end: "17:30")
        let coverage = booking.scheduleCoverageSubtitle()
        let subtitle = ProjectBookingCard.timesOnlySubtitle(booking.operativePayrollProbe(), fallback: coverage.text)
        XCTAssertEqual(subtitle, "Custom 06:00–17:30")
        XCTAssertFalse(subtitle.contains("CUSTOM_HOURS"))
        // The pill is the hours the job's row shows for the same booking, never the clock range again.
        let pill = booking.scheduleCoveragePillHours()
        XCTAssertEqual(pill, ScheduleCoverageFormat.hours(booking.payrollHoursResult().totalPaidHours) + "h")
        XCTAssertNotEqual(pill, "06:00–17:30")
    }

    func testNoRowShowsAStoredSlotWord() {
        let bookings = [
            officeBooking(.customHours, start: "06:00", end: "17:30"),
            officeBooking(.fullDay),
            officeBooking(.morning),
            officeBooking(.afternoon),
        ]
        for booking in bookings {
            let coverage = booking.scheduleCoverageSubtitle()
            let subtitle = ProjectBookingCard.timesOnlySubtitle(booking.operativePayrollProbe(), fallback: coverage.text)
            for text in [subtitle, booking.scheduleCoveragePillHours()] {
                XCTAssertNil(text.range(of: "[A-Z]+_[A-Z_]+", options: .regularExpression), "raw slot word in \"\(text)\"")
            }
        }
    }
}
