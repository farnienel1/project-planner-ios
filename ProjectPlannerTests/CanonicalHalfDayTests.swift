import XCTest
@testable import Project_Planner

/// The AM/PM split, slot intervals, leave coverage, and qualification dismiss keys all come from
/// the packed canonical script. These tests pin the Swift wrappers to that script's answers.
@MainActor
final class CanonicalHalfDayTests: XCTestCase {
    private let monday = LogicFixtures.day(2026, 10, 5, hour: 8)
    private let mondayKey = "2026-10-05"

    private func policy(
        day start: String,
        _ end: String,
        break breakStart: String,
        _ breakEnd: String
    ) -> OrgPayrollTimePolicy {
        var policy = OrgPayrollTimePolicy.default
        policy.standardDayStart = start
        policy.standardDayEnd = end
        policy.breakWindowStart = breakStart
        policy.breakWindowEnd = breakEnd
        return policy
    }

    // MARK: - Script surface

    func testScriptExportsTheSharedFunctionsAndConstants() {
        let names = Set(CanonicalBusinessEngine.exportNames())
        XCTAssertFalse(names.isEmpty, "the packed script did not load")
        let functions = [
            "halfDayWindows", "slotInterval", "namedSlotKind", "standardDayWindow", "standardBreakWindow",
            "parseClockMinutes", "formatClockMinutes", "mergeMinuteIntervals", "subtractMinuteIntervals",
            "leaveCoverageRows", "leaveSlotKind", "qualificationDismissKey",
            "withoutDismissedQualificationRows", "standardDayCoverage",
        ]
        for name in functions {
            XCTAssertTrue(names.contains(name), "\(name) is not exported")
            XCTAssertEqual(CanonicalBusinessEngine.exportKind(name), "function", name)
        }
        XCTAssertEqual(
            CanonicalBusinessEngine.constant("CANONICAL_STANDARD_DAY", as: CanonicalMinuteInterval.self),
            CanonicalMinuteInterval(start: 450, end: 960)
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.constant("CANONICAL_STANDARD_BREAK", as: CanonicalMinuteInterval.self),
            CanonicalMinuteInterval(start: 720, end: 750)
        )
        XCTAssertEqual(CanonicalBusinessEngine.constant("MIN_HALF_DAY_MINUTES", as: Int.self), 60)
    }

    // MARK: - halfDayWindows

    func testDefaultPolicySplitsAtTheBreak() throws {
        let windows = try XCTUnwrap(CanonicalBusinessEngine.halfDayWindows(.init(policy: .default)))
        XCTAssertEqual(windows.day, CanonicalMinuteInterval(start: 450, end: 960))
        XCTAssertEqual(windows.am, CanonicalMinuteInterval(start: 450, end: 720))
        XCTAssertEqual(windows.pm, CanonicalMinuteInterval(start: 750, end: 960))
        XCTAssertEqual(windows.pivot, "break")
        XCTAssertEqual(windows.breakWindow, CanonicalMinuteInterval(start: 720, end: 750))
    }

    func testLaterBreakMovesTheSplit() throws {
        let input = CanonicalStandardDayInput(policy: policy(day: "07:00", "17:00", break: "12:30", "13:30"))
        let windows = try XCTUnwrap(CanonicalBusinessEngine.halfDayWindows(input))
        XCTAssertEqual(windows.am, CanonicalMinuteInterval(start: 420, end: 750))
        XCTAssertEqual(windows.pm, CanonicalMinuteInterval(start: 810, end: 1020))
        XCTAssertEqual(windows.pivot, "break")
    }

    func testBreakOutsideTheDayFallsBackToTheMidpoint() throws {
        let input = CanonicalStandardDayInput(policy: policy(day: "13:00", "19:00", break: "12:00", "12:30"))
        let windows = try XCTUnwrap(CanonicalBusinessEngine.halfDayWindows(input))
        XCTAssertEqual(windows.pivot, "midpoint")
        XCTAssertEqual(windows.am, CanonicalMinuteInterval(start: 780, end: 960))
        XCTAssertEqual(windows.pm, CanonicalMinuteInterval(start: 960, end: 1140))
        XCTAssertNil(windows.breakWindow)
    }

    func testBreakTooCloseToTheStartFallsBackToTheMidpoint() throws {
        let input = CanonicalStandardDayInput(policy: policy(day: "07:30", "16:00", break: "08:00", "08:30"))
        let windows = try XCTUnwrap(CanonicalBusinessEngine.halfDayWindows(input))
        XCTAssertEqual(windows.pivot, "midpoint")
        XCTAssertEqual(windows.am, CanonicalMinuteInterval(start: 450, end: 705))
        XCTAssertEqual(windows.pm, CanonicalMinuteInterval(start: 705, end: 960))
    }

    func testInvertedOrUnparsableDayUsesTheCanonicalDay() throws {
        let inverted = try XCTUnwrap(CanonicalBusinessEngine.halfDayWindows(.init(policy: policy(day: "16:00", "07:30", break: "12:00", "12:30"))))
        XCTAssertEqual(inverted.day, CanonicalMinuteInterval(start: 450, end: 960))
        let unparsable = try XCTUnwrap(CanonicalBusinessEngine.halfDayWindows(.init(policy: policy(day: "soon", "later", break: "12:00", "12:30"))))
        XCTAssertEqual(unparsable.day, CanonicalMinuteInterval(start: 450, end: 960))
        XCTAssertEqual(CanonicalBusinessEngine.standardDayWindow(.init()), CanonicalMinuteInterval(start: 450, end: 960))
        XCTAssertEqual(CanonicalBusinessEngine.standardBreakWindow(.init()), CanonicalMinuteInterval(start: 720, end: 750))
        XCTAssertNil(CanonicalBusinessEngine.standardBreakWindow(.init(breakWindowStart: "12:30", breakWindowEnd: "12:00")))
    }

    // MARK: - slotInterval and namedSlotKind

    func testSlotIntervalUsesTimesThenTheHalves() {
        let day = CanonicalStandardDayInput(policy: .default)
        XCTAssertEqual(
            CanonicalBusinessEngine.slotInterval(timeSlot: "CUSTOM_HOURS", workStartTime: "07:30", workEndTime: "09:30", day: day),
            CanonicalMinuteInterval(start: 450, end: 570)
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.slotInterval(timeSlot: "AM", workStartTime: nil, workEndTime: nil, day: day),
            CanonicalMinuteInterval(start: 450, end: 720)
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.slotInterval(timeSlot: "PM", workStartTime: nil, workEndTime: nil, day: day),
            CanonicalMinuteInterval(start: 750, end: 960)
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.slotInterval(timeSlot: "FULL DAY", workStartTime: nil, workEndTime: nil, day: day),
            CanonicalMinuteInterval(start: 450, end: 960)
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.slotInterval(timeSlot: "Evening", workStartTime: nil, workEndTime: nil, day: day),
            CanonicalMinuteInterval(start: 960, end: 1200)
        )
    }

    func testNamedSlotKindNormalisesEverySpelling() {
        XCTAssertEqual(CanonicalBusinessEngine.namedSlotKind("FULL DAY"), "FULL_DAY")
        XCTAssertEqual(CanonicalBusinessEngine.namedSlotKind("FULL_DAY"), "FULL_DAY")
        XCTAssertEqual(CanonicalBusinessEngine.namedSlotKind("Morning"), "AM")
        XCTAssertEqual(CanonicalBusinessEngine.namedSlotKind("PM"), "PM")
        XCTAssertEqual(CanonicalBusinessEngine.namedSlotKind("CUSTOM_HOURS"), "CUSTOM")
        XCTAssertEqual(CanonicalBusinessEngine.namedSlotKind("Evening"), "EVENING")
        XCTAssertEqual(CanonicalBusinessEngine.namedSlotKind("Overtime"), "OVERTIME")
        XCTAssertEqual(CanonicalBusinessEngine.namedSlotKind(nil), "UNKNOWN")
        XCTAssertEqual(CanonicalBusinessEngine.leaveSlotKind("PM"), "PM")
        XCTAssertEqual(CanonicalBusinessEngine.leaveSlotKind(nil), "FULL_DAY")
    }

    func testSubtractMinuteIntervalsLeavesTheGaps() {
        let gaps = CanonicalBusinessEngine.subtractMinuteIntervals(
            CanonicalMinuteInterval(start: 450, end: 720),
            covered: [CanonicalMinuteInterval(start: 500, end: 560), CanonicalMinuteInterval(start: 540, end: 600)]
        )
        XCTAssertEqual(gaps, [CanonicalMinuteInterval(start: 450, end: 500), CanonicalMinuteInterval(start: 600, end: 720)])
        XCTAssertEqual(
            CanonicalBusinessEngine.mergeMinuteIntervals([.init(start: 600, end: 700), .init(start: 450, end: 600)]),
            [CanonicalMinuteInterval(start: 450, end: 700)]
        )
    }

    // MARK: - Call sites

    func testOperativeAndManagerClashIntervalsAreTheEngineHalves() throws {
        let windows = try XCTUnwrap(CanonicalBusinessEngine.halfDayWindows(.init(policy: LogicFixtures.policy)))
        let am = LogicFixtures.booking(on: monday, slot: .morning)
        let pm = LogicFixtures.booking(on: monday, slot: .afternoon)
        XCTAssertEqual(OperativeBookingInterval.clashInterval(for: am, policy: LogicFixtures.policy)?.0, windows.am.start)
        XCTAssertEqual(OperativeBookingInterval.clashInterval(for: am, policy: LogicFixtures.policy)?.1, windows.am.end)
        XCTAssertEqual(OperativeBookingInterval.clashInterval(for: pm, policy: LogicFixtures.policy)?.0, windows.pm.start)
        XCTAssertEqual(OperativeBookingInterval.clashInterval(for: pm, policy: LogicFixtures.policy)?.1, windows.pm.end)
        XCTAssertFalse(OperativeBookingInterval.bookingsOverlap(am, pm, policy: LogicFixtures.policy))

        let manager = ManagerSiteBooking(userId: "user-1", date: monday, timeSlot: .afternoon, locationType: .office)
        XCTAssertEqual(ManagerScheduleInterval.clashInterval(for: manager, policy: LogicFixtures.policy)?.0, windows.pm.start)
        XCTAssertEqual(ManagerScheduleInterval.clashInterval(for: manager, policy: LogicFixtures.policy)?.1, windows.pm.end)
        XCTAssertEqual(manager.minutesSortKey(policy: LogicFixtures.policy), windows.pm.start)
        let block = manager.calendarBlock(on: monday, policy: LogicFixtures.policy)
        let minutes = Calendar.current.dateComponents([.hour, .minute], from: block.start)
        XCTAssertEqual((minutes.hour ?? 0) * 60 + (minutes.minute ?? 0), windows.pm.start)

        // Pay for a half day is unchanged: half the standard paid hours.
        XCTAssertClose(am.paidBookedHours(policy: LogicFixtures.policy), 4)
        XCTAssertClose(pm.paidBookedHours(policy: LogicFixtures.policy), 4)
    }

    func testRecalibratedHalfDayWritesTheEngineWindow() {
        let newPolicy = policy(day: "07:00", "17:00", break: "12:30", "13:30")
        let booking = LogicFixtures.booking(on: monday, slot: .afternoon, start: "12:00", end: "16:00")
        let choice = PayrollPolicyBookingRecalibrator.recalibratedOperativeChoice(from: booking, newPolicy: newPolicy)
        XCTAssertEqual(choice.timeSlot, .afternoon)
        XCTAssertEqual(choice.workStartTime, "13:30")
        XCTAssertEqual(choice.workEndTime, "17:00")
    }

    // MARK: - leaveCoverageRows

    private func leaveInput(bookings: [CanonicalLeaveBooking]) -> CanonicalLeaveCoverageInput {
        CanonicalLeaveCoverageInput(
            startDayKey: mondayKey,
            endDayKey: mondayKey,
            day: CanonicalStandardDayInput(policy: .default),
            includeWeekends: false,
            people: [CanonicalLeavePerson(personKey: "u1", name: "Ada Lovelace", userId: "u1", operativeIds: ["op1"])],
            leave: [
                CanonicalLeaveRecord(
                    id: "leave-1",
                    userId: "u1",
                    startDayKey: mondayKey,
                    endDayKey: mondayKey,
                    timeSlot: "PM",
                    approved: true
                ),
            ],
            bookings: bookings
        )
    }

    func testMorningBookingAgainstAfternoonLeaveIsSilent() {
        let rows = CanonicalBusinessEngine.leaveCoverageRows(leaveInput(bookings: [
            CanonicalLeaveBooking(id: "b1", personId: "op1", kind: "operative", dayKey: mondayKey, timeSlot: "AM"),
        ]))
        XCTAssertEqual(rows, [])
    }

    func testShortMorningBookingAgainstAfternoonLeaveReportsTheGap() throws {
        let rows = try XCTUnwrap(CanonicalBusinessEngine.leaveCoverageRows(leaveInput(bookings: [
            CanonicalLeaveBooking(
                id: "b1",
                personId: "op1",
                kind: "operative",
                dayKey: mondayKey,
                timeSlot: "CUSTOM_HOURS",
                workStartTime: "07:30",
                workEndTime: "09:30",
                label: "100 · Site"
            ),
        ])))
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.kind, "leave_cover")
        XCTAssertEqual(row.personKey, "u1")
        XCTAssertEqual(row.userId, "u1")
        XCTAssertEqual(row.leaveSlot, "PM")
        XCTAssertEqual(row.workingWindow, CanonicalMinuteInterval(start: 450, end: 720))
        XCTAssertEqual(row.missing, [CanonicalMinuteInterval(start: 570, end: 720)])
        XCTAssertEqual(row.missingHours, 2.5, accuracy: 0.001)
        XCTAssertEqual(row.bookedHours, 2, accuracy: 0.001)
        XCTAssertEqual(row.severity, "medium")
        XCTAssertEqual(row.title, "Half-day leave not covered")
    }

    func testFullDayBookingAgainstAfternoonLeaveIsAClash() throws {
        let rows = try XCTUnwrap(CanonicalBusinessEngine.leaveCoverageRows(leaveInput(bookings: [
            CanonicalLeaveBooking(id: "b1", personId: "op1", kind: "operative", dayKey: mondayKey, timeSlot: "FULL DAY", label: "100 · Site"),
        ])))
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.kind, "leave_clash")
        XCTAssertEqual(row.severity, "high")
        XCTAssertEqual(row.leaveWindow, CanonicalMinuteInterval(start: 750, end: 960))
        XCTAssertEqual(row.clashes.count, 1)
        XCTAssertEqual(row.clashes.first?.bookingId, "b1")
        XCTAssertEqual(row.clashes.first?.overlapStart, 750)
        XCTAssertEqual(row.clashes.first?.overlapEnd, 960)
        XCTAssertEqual(row.title, "Booked during annual leave")
    }

    // MARK: - Dismissed qualification warnings

    func testQualificationDismissKeyAndFilter() {
        XCTAssertEqual(
            CanonicalBusinessEngine.qualificationDismissKey(operativeId: "OP", qualificationId: "Q", expiryDayKey: "2026-09-01"),
            "qual|OP|Q|2026-09-01"
        )
        let rows: [[String: Any]] = [
            ["id": "expired", "dismissKey": "qual|OP|Q|2026-09-01", "daysUntilExpiry": -3],
            ["id": "upcoming", "dismissKey": "qual|OP|R|2026-11-01", "daysUntilExpiry": 5],
        ]
        let kept = CanonicalBusinessEngine.withoutDismissedQualificationRows(
            rows,
            dismissedKeys: ["qual|OP|Q|2026-09-01", "qual|OP|R|2026-11-01"]
        )
        XCTAssertEqual(kept?.map { $0["id"] as? String }, ["upcoming"], "only an expired row can be dismissed")
        XCTAssertEqual(CanonicalBusinessEngine.withoutDismissedQualificationRows(rows, dismissedKeys: [])?.count, 2)
    }
}
