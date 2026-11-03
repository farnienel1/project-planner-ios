import XCTest
@testable import Project_Planner

/// RULEBOOK 1.20.0 / 1.20.1 behaviour on iOS through `CanonicalBusinessEngine`. Every expected value was checked in node
/// against the packed `canonical-business.js` (sha256 1301236a…09de811a), fed the same stored shapes these Swift models
/// write (`OrgPayrollTimePolicy.asFirestoreDictionary`).
@MainActor
final class Rulebook1200Tests: XCTestCase {
    private let zone = "Europe/London"
    /// Monday 9 Nov 2026, Saturday 7 Nov 2026.
    private let monday = "2026-11-09"
    private let saturday = "2026-11-07"

    /// The owner's example: 06:30–14:30, lunch 10:00–10:45 unpaid (45 min), weekday overtime ×1.5. `derived` marks a
    /// policy saved from 1.20.0 (`paidHoursDerived`); the stored `standardPaidHours` is 8 either way.
    private func ownerPolicy(derived: Bool) -> OrgPayrollTimePolicy {
        var policy = OrgPayrollTimePolicy.default
        policy.standardDayStart = "06:30"
        policy.standardDayEnd = "14:30"
        policy.breakWindowStart = "10:00"
        policy.breakWindowEnd = "10:45"
        policy.unpaidBreakMinutes = 45
        policy.breakPaid = false
        policy.standardPaidHours = 8
        policy.paidHoursDerived = derived ? true : nil
        return policy
    }

    private func paid(_ policy: OrgPayrollTimePolicy, slot: String, _ start: String? = nil, _ end: String? = nil) throws -> RulebookPayrollHours {
        try XCTUnwrap(CanonicalBusinessEngine.payrollHoursResult(RulebookPayrollHoursInput(
            booking: CanonicalPayrollBooking(
                timeSlot: slot, workStartTime: start, workEndTime: end, isBreakRemoved: false, otMultiplierOverride: nil
            ),
            dayKey: monday,
            policy: policy,
            timeZone: zone
        )))
    }

    func testThePackedScriptIsRulebook1202OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 20, 2]), "rulebook \(stamp.version) predates 1.20.2")
        let names = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "derivedWeekdayPaidHours", "weekdayPaidHours", "withDerivedWeekdayPaidHours", "weekdayPaidDayPreview",
            "leaveHalfDayWindows", "leaveHalfDayLabel", "leaveComparableInterval", "allowedTimeSlotsOnDay",
            "bookingHoursLabel", "bookingRequestIdentity", "isSameBookingRequest", "payrollPolicyTimeOnStep",
        ] {
            XCTAssertTrue(names.contains(name), name)
        }
    }

    // MARK: Working hours (§4.3)

    func testWeekdayPreviewLineIsTheOwnerExample() throws {
        let preview = try XCTUnwrap(CanonicalBusinessEngine.weekdayPaidDayPreview(ownerPolicy(derived: false)))
        XCTAssertEqual(preview.line, "06:30–14:30 = 8h − 45 min unpaid break = 7h15m")
        XCTAssertEqual(preview.paidHours, 7.25, accuracy: 0.0001)
        XCTAssertEqual(preview.dayMinutes, 480)
        XCTAssertEqual(preview.breakMinutes, 45)
        var paidBreak = ownerPolicy(derived: false)
        paidBreak.breakPaid = true
        XCTAssertEqual(
            CanonicalBusinessEngine.weekdayPaidDayPreview(paidBreak)?.line,
            "06:30–14:30 = 8h, 45 min break paid = 8h"
        )
    }

    func testDerivedPolicyPaysTheDerivedDayAndAnOldPolicyKeepsItsStoredFigure() {
        XCTAssertEqual(CanonicalBusinessEngine.weekdayPaidHours(ownerPolicy(derived: true)), 7.25, accuracy: 0.0001)
        XCTAssertEqual(
            CanonicalBusinessEngine.weekdayPaidHours(ownerPolicy(derived: false)), 8, accuracy: 0.0001,
            "a policy saved before 1.20.0 (no paidHoursDerived) keeps its stored standardPaidHours"
        )
    }

    func testWithDerivedWeekdayPaidHoursMarksThePolicyAndWritesTheDerivedDay() throws {
        let derived = try XCTUnwrap(CanonicalBusinessEngine.withDerivedWeekdayPaidHours(ownerPolicy(derived: false)))
        XCTAssertEqual(derived.paidHoursDerived, true)
        XCTAssertEqual(derived.standardPaidHours, 7.25, accuracy: 0.0001)
        let stored = derived.asFirestoreDictionary()
        XCTAssertEqual(stored["paidHoursDerived"] as? Bool, true)
        XCTAssertEqual((stored["standardPaidHours"] as? NSNumber)?.doubleValue ?? -1, 7.25, accuracy: 0.0001)
        // Read back from Firestore it stays derived.
        let read = OrgPayrollTimePolicy.fromFirestore(stored)
        XCTAssertEqual(read.paidHoursDerived, true)
        XCTAssertEqual(CanonicalBusinessEngine.weekdayPaidHours(read), 7.25, accuracy: 0.0001)
    }

    func testAnOldPolicyDoesNotWriteTheFlag() {
        let stored = ownerPolicy(derived: false).asFirestoreDictionary()
        XCTAssertNil(stored["paidHoursDerived"])
        XCTAssertNil(OrgPayrollTimePolicy.fromFirestore(stored).paidHoursDerived)
    }

    func testTheIOSSaveRoundTripWritesPaidHoursDerivedAndTheDerivedStandardPaidHours() throws {
        let orgDocument: [String: Any] = ["payrollTimePolicy": ownerPolicy(derived: false).asFirestoreDictionary()]
        let fields = try XCTUnwrap(CanonicalBusinessEngine.payrollTimePolicyApplyNowWriteFields(
            orgDocument: orgDocument,
            policy: ownerPolicy(derived: false),
            todayKey: monday,
            timeZone: zone
        ))
        let written = try XCTUnwrap(fields["payrollTimePolicy"] as? [String: Any])
        XCTAssertEqual(written["paidHoursDerived"] as? Bool, true)
        XCTAssertEqual((written["standardPaidHours"] as? NSNumber)?.doubleValue ?? -1, 7.25, accuracy: 0.0001)
        XCTAssertNotNil(fields["payrollTimePolicyHistory"], "1.19.0 history is still written")
        XCTAssertNotNil(fields["payrollTimePolicyRevision"], "1.19.0 revision is still bumped")
        // The model reads the write back as a derived policy.
        XCTAssertEqual(OrgPayrollTimePolicy.fromFirestore(written).paidHoursDerived, true)
    }

    func testValidationChecksTheDerivedDay() {
        // The owner's break ends at 10:45 (off the 1.20.2 30-minute step): saved like that, it passes until changed.
        XCTAssertNil(CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(
            ownerPolicy(derived: false), previous: ownerPolicy(derived: false)
        ))
        var tooShort = ownerPolicy(derived: false)
        tooShort.standardDayStart = "10:00"
        tooShort.standardDayEnd = "10:50"
        tooShort.breakWindowStart = "10:00"
        tooShort.breakWindowEnd = "10:45"
        XCTAssertEqual(
            CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(tooShort, previous: tooShort),
            "The working day must give between 1 and 12 paid hours (finish − start − unpaid break)."
        )
    }

    // MARK: Weekday pay (§8)

    func testOwnerWeekdayPayExamples() throws {
        let policy = ownerPolicy(derived: true)
        XCTAssertEqual(try paid(policy, slot: "FULL DAY").hours.totalPaidHours, 7.25, accuracy: 0.001)
        XCTAssertEqual(try paid(policy, slot: "CUSTOM_HOURS", "06:30", "12:00").hours.totalPaidHours, 4.75, accuracy: 0.001)
        XCTAssertEqual(
            try paid(policy, slot: "CUSTOM_HOURS", "11:00", "14:30").hours.totalPaidHours, 3.5, accuracy: 0.001,
            "under a derived policy custom hours are never snapped to a half day"
        )
        let overtime = try paid(policy, slot: "CUSTOM_HOURS", "06:30", "16:30")
        XCTAssertEqual(overtime.hours.standardHours, 7.25, accuracy: 0.001)
        XCTAssertEqual(overtime.hours.outsideHours, 2, accuracy: 0.001)
        XCTAssertEqual(overtime.hours.outsideMultiplier, 1.5, accuracy: 0.001)
        XCTAssertEqual(overtime.hours.totalPaidHours, 10.25, accuracy: 0.001)
    }

    func testAnOldPolicyKeepsTheHalfDaySnap() throws {
        XCTAssertEqual(
            try paid(ownerPolicy(derived: false), slot: "CUSTOM_HOURS", "11:00", "14:30").hours.totalPaidHours, 4, accuracy: 0.001
        )
    }

    // MARK: Booking slots (§4.3)

    func testWeekdaysOfferFullDayAndCustomOnly() {
        XCTAssertEqual(CanonicalBusinessEngine.allowedTimeSlotsOnDay(monday, timeZone: zone), [.fullDay, .custom])
        XCTAssertEqual(CanonicalBusinessEngine.allowedTimeSlotsOnDay(saturday, timeZone: zone), [.custom])
        XCTAssertFalse(CanonicalBusinessEngine.timeSlotAllowedOnDay("AM", dayKey: monday, timeZone: zone))
        XCTAssertTrue(CanonicalBusinessEngine.timeSlotAllowedOnDay("FULL DAY", dayKey: monday, timeZone: zone))
    }

    // MARK: Leave halves (§9)

    func testLeaveHalvesSplitTheDayAtItsExactMiddle() throws {
        let halves = try XCTUnwrap(CanonicalBusinessEngine.leaveHalfDayWindows(policy: ownerPolicy(derived: true)))
        XCTAssertEqual(halves.am, CanonicalMinuteInterval(start: 390, end: 630))
        XCTAssertEqual(halves.pm, CanonicalMinuteInterval(start: 630, end: 870))
        XCTAssertEqual(CanonicalBusinessEngine.leaveHalfDayLabel(timeSlot: "AM", policy: ownerPolicy(derived: true)), "AM 06:30–10:30")
        XCTAssertEqual(CanonicalBusinessEngine.leaveHalfDayLabel(timeSlot: "PM", policy: ownerPolicy(derived: true)), "PM 10:30–14:30")
        XCTAssertEqual(CanonicalBusinessEngine.leaveHalfDayLabel(timeSlot: "FULL DAY", policy: ownerPolicy(derived: true)), "Full day")
        XCTAssertEqual(CanonicalBusinessEngine.leaveSlotClockRange(timeSlot: "AM", policy: ownerPolicy(derived: true)), "06:30–10:30")
        XCTAssertEqual(CanonicalBusinessEngine.leaveSlotClockRange(timeSlot: "PM", policy: ownerPolicy(derived: true)), "10:30–14:30")
    }

    func testTimesheetLeaveLineCarriesTheLeaveHalf() {
        let line = CanonicalTimesheetLeaveLine(id: "l1", leaveId: "L1", dayKey: monday, timeSlot: "AM", label: "Annual leave (AM)")
            .withLeaveTimeRange(policy: ownerPolicy(derived: true))
        XCTAssertEqual(line.timeRange, "06:30–10:30")
        XCTAssertEqual(line.displayLabel, "Annual leave (AM) · 06:30–10:30")
    }

    private func amLeaveCover(bookingStart: String, bookingEnd: String) -> [CanonicalLeaveCoverageRow]? {
        CanonicalBusinessEngine.leaveCoverageRows(CanonicalLeaveCoverageInput(
            timeZone: zone,
            startDayKey: monday,
            endDayKey: monday,
            day: CanonicalStandardDayInput(policy: ownerPolicy(derived: true)),
            includeWeekends: false,
            people: [CanonicalLeavePerson(personKey: "U1", name: "Ann Example", userId: "U1", operativeIds: ["OP1"])],
            leave: [
                CanonicalLeaveRecord(id: "L1", userId: "U1", startDayKey: monday, endDayKey: monday, timeSlot: "AM", approved: true),
            ],
            bookings: [
                CanonicalLeaveBooking(
                    id: "B1", personId: "OP1", kind: "operative", dayKey: monday,
                    timeSlot: "CUSTOM_HOURS", workStartTime: bookingStart, workEndTime: bookingEnd, label: "J1"
                ),
            ]
        ))
    }

    func testAMLeaveCoveredFromTheMiddleOfTheDay() {
        XCTAssertEqual(amLeaveCover(bookingStart: "10:30", bookingEnd: "14:30"), [])
    }

    func testAMLeaveWithAnElevenOClockStartMissesAQuarterHourAndTheLunchNeverNeedsCovering() throws {
        let rows = try XCTUnwrap(amLeaveCover(bookingStart: "11:00", bookingEnd: "14:30"))
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.kind, "leave_cover")
        XCTAssertEqual(row.missingHours, 0.25, accuracy: 0.001)
        XCTAssertEqual(row.missing.map(\.start), [645])
        XCTAssertEqual(row.missing.map(\.end), [660])
    }

    // MARK: Hours shown are the pay rule's, never the clock duration (owner report, PR #163)

    func testWeekendBookingHoursAreThePayRulesNotTheClockDuration() throws {
        var policy = OrgPayrollTimePolicy.default
        policy.saturday.customStandardEnd = "14:00" // Saturday 07:30–14:00 counts as 8h; Sunday every hour ×2 (default).
        let sat = try XCTUnwrap(OrganizationRulebookContext.date(fromDayKey: saturday))
        let sun = try XCTUnwrap(OrganizationRulebookContext.date(fromDayKey: "2026-11-08"))
        let saturdayBooking = LogicFixtures.booking(on: sat, slot: .customHours, start: "07:30", end: "14:00")
        let sundayBooking = LogicFixtures.booking(on: sun, slot: .customHours, start: "07:30", end: "14:00")
        XCTAssertEqual(saturdayBooking.payrollHoursResult(policy: policy).paidHoursLabel, "8h")
        XCTAssertEqual(sundayBooking.payrollHoursResult(policy: policy).paidHoursLabel, "13h (6.5h × 2)")
        XCTAssertEqual(sundayBooking.payrollHoursResult(policy: policy).paidOvertimeHours, 13, accuracy: 0.001)
    }

    func testWeekdayOvertimeLabelAndQuarterHoursAreNotRounded() throws {
        let mon = try XCTUnwrap(OrganizationRulebookContext.date(fromDayKey: monday))
        let booking = LogicFixtures.booking(on: mon, slot: .customHours, start: "06:30", end: "16:30")
        XCTAssertEqual(booking.payrollHoursResult(policy: ownerPolicy(derived: true)).paidHoursLabel, "10.25h (7.25h + 2h × 1.5)")
        XCTAssertEqual(ScheduleCoverageFormat.hours(7.25), "7.25")
        XCTAssertEqual(ScheduleCoverageFormat.hours(8), "8")
        XCTAssertEqual(ScheduleCoverageFormat.hours(3.5), "3.5")
    }

    // MARK: 1.20.2

    func testWorkingHoursTimesAreOnThirtyMinuteSteps() {
        XCTAssertEqual(CanonicalBusinessEngine.payrollPolicyTimeStepMinutes, 30)
        XCTAssertEqual(CanonicalBusinessEngine.payrollPolicyTimeStepMessage, "Working hours use 30-minute steps (e.g. 07:30).")
        XCTAssertTrue(CanonicalBusinessEngine.payrollPolicyTimeOnStep("07:30"))
        XCTAssertFalse(CanonicalBusinessEngine.payrollPolicyTimeOnStep("10:45"))
        let saved = ownerPolicy(derived: false)
        XCTAssertEqual(
            CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(saved),
            "Working hours use 30-minute steps (e.g. 07:30).",
            "with no saved policy the off-step 10:45 is refused"
        )
        var changed = saved
        changed.breakWindowStart = "10:15"
        changed.breakWindowEnd = "11:00"
        XCTAssertEqual(
            CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(changed, previous: saved),
            "Working hours use 30-minute steps (e.g. 07:30).",
            "an off-step time is refused once it is changed"
        )
        var onStep = saved
        onStep.breakWindowEnd = "10:30"
        XCTAssertNil(CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(onStep, previous: saved))
        XCTAssertNil(CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(.default), "break length stays any minutes")
    }

    func testBookingHoursLabelIsThePayRulesHoursWithTheMultiplierSum() {
        func label(_ total: Double, _ standard: Double, _ outside: Double, _ multiplier: Double) -> String {
            CanonicalBusinessEngine.bookingHoursLabel(RulebookBookingHoursInput(
                totalPaidHours: total, standardHours: standard, outsideHours: outside, outsideMultiplier: multiplier
            ))
        }
        XCTAssertEqual(label(8, 8, 0, 2), "8h")
        XCTAssertEqual(label(13, 0, 6.5, 2), "13h (6.5h × 2)")
        XCTAssertEqual(label(11, 8, 2, 1.5), "11h (8h + 2h × 1.5)")
        XCTAssertEqual(label(7.25, 7.25, 0, 1.5), "7.25h")
    }

    func testABookingIsAlreadyBookedOnlyWithTheSameTimes() {
        let morning = RulebookBookingRequest(
            personId: "U1", dayKey: saturday, timeSlot: "CUSTOM_HOURS", locationType: "project", locationId: "J1",
            workStartTime: "07:30", workEndTime: "11:00"
        )
        XCTAssertEqual(CanonicalBusinessEngine.bookingRequestIdentity(morning), "u1|2026-11-07|CUSTOM|project|j1||450|660|")
        var afternoon = morning
        afternoon.workStartTime = "12:00"
        afternoon.workEndTime = "14:00"
        XCTAssertFalse(
            CanonicalBusinessEngine.isSameBookingRequest(morning, afternoon),
            "a second weekend booking at the same place with other times is a new booking, never skipped"
        )
        var sameAgain = morning
        sameAgain.personId = "u1"
        sameAgain.locationId = "j1"
        sameAgain.workStartTime = "7:30"
        XCTAssertTrue(CanonicalBusinessEngine.isSameBookingRequest(morning, sameAgain), "ids without case, clock as minutes")
    }
}
