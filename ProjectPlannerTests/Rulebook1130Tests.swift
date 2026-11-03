import XCTest
@testable import Project_Planner

/// RULEBOOK 1.12.2 / 1.13.0–1.13.2 behaviour on iOS through `CanonicalBusinessEngine`. Every expected value was
/// checked in node against the packed `canonical-business.js` (sha256 76ddcbc1…cfc).
@MainActor
final class Rulebook1130Tests: XCTestCase {
    // MARK: Half-applied user type (1.12.2 §11)

    private func managerSubject(id: String = "U1", organizationId: String = "ORG-A") -> [String: Any] {
        let flags: [String: Bool] = ["adminAccess": false, "manager": true, "operativeMode": false]
        var row: [String: Any] = flags
        row["permissions"] = flags
        row["role"] = "manager"
        row["isSuperAdmin"] = false
        row["id"] = id
        row["organizationId"] = organizationId
        return row
    }

    func testAccountTypeSyncStateFindsAPartlySavedType() throws {
        let stale = try XCTUnwrap(CanonicalBusinessEngine.accountTypeSyncState(
            person: managerSubject(), organizationId: "org-a", members: ["u1": "admin"]
        ))
        XCTAssertFalse(stale.inSync)
        XCTAssertEqual(stale.level, .manager)
        XCTAssertEqual(stale.membersRole, "admin")
        XCTAssertEqual(stale.repair, .manager)

        let same = try XCTUnwrap(CanonicalBusinessEngine.accountTypeSyncState(
            person: managerSubject(), organizationId: "org-a", members: ["U1": "manager"]
        ))
        XCTAssertTrue(same.inSync)
        XCTAssertNil(same.repair)

        let missing = try XCTUnwrap(CanonicalBusinessEngine.accountTypeSyncState(
            person: managerSubject(), organizationId: "org-a", members: [:]
        ))
        XCTAssertTrue(missing.inSync, "no members entry is not an admin mismatch")
        XCTAssertEqual(
            CanonicalBusinessEngine.accountTypeOutOfSyncMessage,
            "This person's user type was only partly saved. Press Save to finish it on every record."
        )
    }

    // MARK: Weekend bookings (1.13.1 §4.3) and the lunch warning (1.13.0 §8)

    private func day(_ key: String) throws -> Date {
        try XCTUnwrap(OrganizationRulebookContext.date(fromDayKey: key))
    }

    func testWeekendDaysOfferCustomHoursOnly() throws {
        XCTAssertEqual(CanonicalBusinessEngine.allowedTimeSlotsOnDay("2026-11-04", timeZone: "Europe/London"), [.fullDay, .am, .pm, .custom])
        XCTAssertEqual(CanonicalBusinessEngine.allowedTimeSlotsOnDay("2026-11-07", timeZone: "Europe/London"), [.custom])
        XCTAssertEqual(CanonicalBusinessEngine.allowedTimeSlotsOnDay("2026-11-08", timeZone: "Europe/London"), [.custom])
        XCTAssertFalse(CanonicalBusinessEngine.timeSlotAllowedOnDay("FULL DAY", dayKey: "2026-11-07", timeZone: "Europe/London"))
        XCTAssertTrue(CanonicalBusinessEngine.timeSlotAllowedOnDay("CUSTOM_HOURS", dayKey: "2026-11-07", timeZone: "Europe/London"))
        XCTAssertTrue(CanonicalBusinessEngine.timeSlotAllowedOnDay("AM", dayKey: "2026-11-04", timeZone: "Europe/London"))
        // A stored weekend FULL DAY still shows its own slot when edited.
        let saturday = try day("2026-11-07")
        XCTAssertTrue(CanonicalBusinessEngine.slotOffered(.fullDay, on: saturday, storedTimeSlot: "FULL DAY"))
        XCTAssertFalse(CanonicalBusinessEngine.slotOffered(.am, on: saturday, storedTimeSlot: "FULL DAY"))
        XCTAssertEqual(TimeSlot.defaultPickerSlot(on: saturday), .customHours)
        XCTAssertEqual(TimeSlot.defaultPickerSlot(on: try day("2026-11-04")), .fullDay)
        XCTAssertEqual(ManagerTimeSlot.offered(on: [saturday]), [.customHours])
    }

    func testWeekendPrefillAndNoteComeFromTheRulebook() throws {
        let policy = OrgPayrollTimePolicy.default
        let saturdayWindow = try XCTUnwrap(CanonicalBusinessEngine.weekendCustomHoursDefault(policy: policy, dayKey: "2026-11-07", timeZone: "Europe/London"))
        XCTAssertEqual(saturdayWindow.start, "07:30")
        XCTAssertEqual(saturdayWindow.end, "13:00")
        XCTAssertNil(CanonicalBusinessEngine.weekendCustomHoursDefault(policy: policy, dayKey: "2026-11-08", timeZone: "Europe/London"), "all-hours Sunday")
        XCTAssertNil(CanonicalBusinessEngine.weekendCustomHoursDefault(policy: policy, dayKey: "2026-11-04", timeZone: "Europe/London"))
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingNote(policy: policy, dayKey: "2026-11-07", timeZone: "Europe/London"),
            "Saturday is paid on the hours you enter: 07:30\u{2013}13:00 counts as 8h, hours outside it at 2×. Change it in Working hours."
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingNote(policy: policy, dayKey: "2026-11-08", timeZone: "Europe/London"),
            "Sunday is paid on the hours you enter, every hour at 2×. Change it in Working hours."
        )
        XCTAssertNil(CanonicalBusinessEngine.weekendBookingNote(policy: policy, dayKey: "2026-11-04", timeZone: "Europe/London"))
    }

    func testOneRequestNeverMixesWeekdaysAndWeekendDays() throws {
        XCTAssertTrue(CanonicalBusinessEngine.bookingDaysMixWeekdayAndWeekend(["2026-11-06", "2026-11-07"], timeZone: "Europe/London"))
        XCTAssertFalse(CanonicalBusinessEngine.bookingDaysMixWeekdayAndWeekend(["2026-11-07", "2026-11-08"], timeZone: "Europe/London"))
        XCTAssertFalse(CanonicalBusinessEngine.bookingDaysMixWeekdayAndWeekend(["2026-11-04", "2026-11-05"], timeZone: "Europe/London"))
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendWeekdayMixMessage,
            "Weekends cannot be booked alongside Weekdays. Make your weekday booking first then weekend separately."
        )
        var selected: Set<Date> = [try day("2026-11-06")]
        let message = ScheduleDateSelectionPolicy.toggle(
            date: try day("2026-11-07"),
            selected: &selected,
            policy: .default,
            calendar: OrganizationRulebookContext.calendar
        )
        XCTAssertEqual(message, CanonicalBusinessEngine.weekendWeekdayMixMessage)
        XCTAssertEqual(selected.count, 1)
    }

    func testCustomHoursOverTheUnpaidBreakAskForConfirmation() {
        let policy = OrgPayrollTimePolicy.default
        let warning = "You are booking custom hours that cover the unpaid lunch break. Turn off Unpaid break to make sure they are paid for this time."
        XCTAssertEqual(CanonicalBusinessEngine.customHoursBreakWarning(
            policy: policy, dayKey: "2026-11-04", workStartTime: "08:00", workEndTime: "16:00", isBreakRemoved: false, timeZone: "Europe/London"
        ), warning)
        XCTAssertNil(CanonicalBusinessEngine.customHoursBreakWarning(
            policy: policy, dayKey: "2026-11-04", workStartTime: "08:00", workEndTime: "16:00", isBreakRemoved: true, timeZone: "Europe/London"
        ), "Unpaid break off")
        XCTAssertNil(CanonicalBusinessEngine.customHoursBreakWarning(
            policy: policy, dayKey: "2026-11-04", workStartTime: "08:00", workEndTime: "11:00", isBreakRemoved: false, timeZone: "Europe/London"
        ), "does not reach the break")
        XCTAssertNil(CanonicalBusinessEngine.customHoursBreakWarning(
            policy: policy, dayKey: "2026-11-07", workStartTime: "08:00", workEndTime: "16:00", isBreakRemoved: false, timeZone: "Europe/London"
        ), "weekend")
        var paidBreak = policy
        paidBreak.breakPaid = true
        XCTAssertNil(CanonicalBusinessEngine.customHoursBreakWarning(
            policy: paidBreak, dayKey: "2026-11-04", workStartTime: "08:00", workEndTime: "16:00", isBreakRemoved: false, timeZone: "Europe/London"
        ), "paid break")
    }

    func testAnOvernightBookingKeepsItsClockTimes() {
        // RULEBOOK 1.13.0 Q5: a finish before the start crosses midnight (`slotInterval` runs past 24:00).
        let interval = CanonicalBusinessEngine.slotInterval(
            timeSlot: "CUSTOM_HOURS",
            workStartTime: "22:00",
            workEndTime: "06:00",
            day: CanonicalStandardDayInput(policy: .default)
        )
        XCTAssertEqual(interval?.start, 22 * 60)
        XCTAssertEqual(interval?.end, 30 * 60)
    }
}
