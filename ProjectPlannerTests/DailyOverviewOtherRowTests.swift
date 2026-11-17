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
            let chip = DailyOverviewTypeChip.kind(for: booking.payrollHoursResult(), timeSlot: booking.timeSlot.rawValue)
            for text in [subtitle, booking.scheduleCoveragePillHours(), chip?.label ?? ""] {
                // A stored slot word, underscored ("CUSTOM_HOURS") or spaced ("FULL DAY", "CUSTOM HOURS").
                XCTAssertNil(
                    text.range(of: "[A-Z]+_[A-Z_]+|\\bFULL DAY\\b|\\bCUSTOM HOURS\\b|\\bCUSTOM\\b", options: .regularExpression),
                    "raw slot word in \"\(text)\""
                )
            }
        }
    }

    /// Owner answer 17 Nov: the Type chip on the By project and Other rows is the rulebook's `scheduleCellKind`
    /// over `scheduleCellHours`, worded with `JOB_SCHEDULE_LEGEND` — the chip web shows.
    func testTypeChipIsTheRulebookKindInTheLegendWords() {
        XCTAssertEqual(DailyOverviewTypeChip.label(forTone: "standard"), "Standard")
        XCTAssertEqual(DailyOverviewTypeChip.label(forTone: "split"), "Std + OT")
        XCTAssertEqual(DailyOverviewTypeChip.label(forTone: "otOnly"), "OT only")
        XCTAssertEqual(DailyOverviewTypeChip.label(forTone: "halfDay"), "Half day")

        let booking = officeBooking(.customHours, start: "06:00", end: "17:30")
        let result = booking.payrollHoursResult()
        let chip = DailyOverviewTypeChip.kind(for: result, timeSlot: booking.timeSlot.rawValue)
        let hours = CanonicalBusinessEngine.scheduleCellHours(result.scheduleCellHoursInput)
        let kind = hours.flatMap {
            CanonicalBusinessEngine.scheduleCellKind(paidHours: $0.paidHours, overtimeHours: $0.overtimeHours, timeSlot: "CUSTOM_HOURS")
        }
        XCTAssertNotNil(chip)
        XCTAssertEqual(chip?.tone, kind?.tone)
        XCTAssertEqual(DailyOverviewTypeChip.kind(for: officeBooking(.morning).payrollHoursResult(), timeSlot: "AM")?.label, "Half day")
    }

    /// The chip is display only: the hours the row shows are the pay rule's, unchanged by it.
    func testTypeChipLeavesTheHoursAlone() {
        let booking = officeBooking(.customHours, start: "06:00", end: "17:30")
        let before = booking.payrollHoursResult().totalPaidHours
        _ = DailyOverviewTypeChip.kind(for: booking.payrollHoursResult(), timeSlot: booking.timeSlot.rawValue)
        XCTAssertEqual(booking.payrollHoursResult().totalPaidHours, before)
        XCTAssertEqual(booking.scheduleCoveragePillHours(), ScheduleCoverageFormat.hours(before) + "h")
    }

    /// Owner rule 17 Nov (both apps match): a manager row whose person has no account reads "Unknown person" on both
    /// Daily Overview lists (By project and Other / Site survey), as web does — never the stored id.
    func testAPersonWithNoAccountReadsUnknownPerson() {
        XCTAssertEqual(dailyOverviewManagerName(userId: "NoSuchUid123", users: []), unknownLabourPersonName)
        XCTAssertEqual(unknownLabourPersonName, "Unknown person")

        var named = LogicFixtures.selfEmployedUser(id: "TEST-admin", email: "test.admin@example.com")
        named.firstName = "Test"
        named.surname = "Admin"
        XCTAssertEqual(dailyOverviewManagerName(userId: "TEST-admin", users: [named]), "Test Admin")

        var nameless = LogicFixtures.selfEmployedUser(id: "TEST-blank", email: "blank@example.com")
        nameless.firstName = ""
        nameless.surname = ""
        XCTAssertEqual(dailyOverviewManagerName(userId: "TEST-blank", users: [nameless]), "blank@example.com")
    }
}
