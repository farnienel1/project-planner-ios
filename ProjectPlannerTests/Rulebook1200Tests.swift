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

    func testThePackedScriptIsRulebook1204OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 20, 4]), "rulebook \(stamp.version) predates 1.20.4")
        let names = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "derivedWeekdayPaidHours", "weekdayPaidHours", "withDerivedWeekdayPaidHours", "weekdayPaidDayPreview",
            "leaveHalfDayWindows", "leaveHalfDayLabel", "leaveComparableInterval", "allowedTimeSlotsOnDay",
            "bookingHoursLabel", "bookingRequestIdentity", "isSameBookingRequest", "payrollPolicyTimeOnStep",
            "payrollBreakTimeOnStep", "payrollBreakMinutesOnStep", "weekendDayPreview", "payrollMultipliedHours",
            "multipliedHoursText", "parseMultipliedHoursText", "payrollOutsideClockHours",
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
        // The tile hours come from the rulebook's `scheduleCellHours` (the Swift `paidOvertimeHours` copy is gone).
        let sundayCell = try XCTUnwrap(CanonicalBusinessEngine.scheduleCellHours(sundayBooking.payrollHoursResult(policy: policy).scheduleCellHoursInput))
        XCTAssertEqual(sundayCell.overtimeHours, 13, accuracy: 0.001)
        XCTAssertEqual(sundayCell.paidHours, 13, accuracy: 0.001)
        let saturdayCell = try XCTUnwrap(CanonicalBusinessEngine.scheduleCellHours(saturdayBooking.payrollHoursResult(policy: policy).scheduleCellHoursInput))
        XCTAssertEqual(saturdayCell.overtimeHours, 0, accuracy: 0.001)
        XCTAssertEqual(saturdayCell.paidHours, 8, accuracy: 0.001)
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

    /// RULEBOOK 1.20.2 / 1.20.3 §4.3: day start and finish on 30 minutes; lunch-break times and length on 15 minutes
    /// (10:00–10:45, 45 min is valid); an off-step value saved earlier passes until changed.
    func testWorkingHoursDayTimesOnThirtyMinutesAndBreakOnFifteen() {
        XCTAssertEqual(CanonicalBusinessEngine.payrollPolicyTimeStepMinutes, 30)
        XCTAssertEqual(CanonicalBusinessEngine.payrollBreakTimeStepMinutes, 15)
        XCTAssertEqual(CanonicalBusinessEngine.payrollPolicyTimeStepMessage, "Working hours use 30-minute steps (e.g. 07:30).")
        XCTAssertEqual(
            CanonicalBusinessEngine.payrollBreakTimeStepMessage,
            "Lunch break times and length use 15-minute steps (e.g. 10:45)."
        )
        XCTAssertTrue(CanonicalBusinessEngine.payrollPolicyTimeOnStep("07:30"))
        XCTAssertFalse(CanonicalBusinessEngine.payrollPolicyTimeOnStep("10:45"))
        XCTAssertTrue(CanonicalBusinessEngine.payrollBreakTimeOnStep("10:45"))
        XCTAssertFalse(CanonicalBusinessEngine.payrollBreakTimeOnStep("10:50"))
        XCTAssertTrue(CanonicalBusinessEngine.payrollBreakMinutesOnStep(45))
        XCTAssertFalse(CanonicalBusinessEngine.payrollBreakMinutesOnStep(20))

        let saved = ownerPolicy(derived: false)
        XCTAssertNil(CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(saved), "10:00–10:45, 45 min is valid")
        var dayOff = saved
        dayOff.standardDayStart = "06:45"
        XCTAssertEqual(
            CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(dayOff, previous: saved),
            "Working hours use 30-minute steps (e.g. 07:30)."
        )
        XCTAssertNil(CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(dayOff, previous: dayOff), "saved off-step passes")
        var breakOff = saved
        breakOff.breakWindowEnd = "10:50"
        XCTAssertEqual(
            CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(breakOff, previous: saved),
            "Lunch break times and length use 15-minute steps (e.g. 10:45)."
        )
        XCTAssertNil(CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(breakOff, previous: breakOff))
        var lengthOff = saved
        lengthOff.unpaidBreakMinutes = 40
        XCTAssertEqual(
            CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(lengthOff, previous: saved),
            "Lunch break times and length use 15-minute steps (e.g. 10:45)."
        )
        XCTAssertNil(CanonicalBusinessEngine.validateDerivedPayrollTimePolicy(lengthOff, previous: lengthOff))
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

    /// Owner check (3 Nov): the Working hours weekend preview follows Paid ↔ Unpaid. Saturday 07:30–14:00 counting 8h,
    /// break 12:00–12:30: paid 8h, unpaid 7.5h; Sunday every hour ×2: paid 13h, unpaid less (the packed rule's figure). The preview is memoised by
    /// the whole draft policy, so a changed weekend break is a new answer.
    func testWeekendPreviewFollowsTheWeekendBreakPaidOrUnpaid() throws {
        func totals(saturdayPaid: Bool, sundayPaid: Bool) throws -> [Double] {
            var policy = OrgPayrollTimePolicy.default
            policy.saturday.customStandardEnd = "14:00"
            policy.saturday.breakPaid = saturdayPaid
            policy.sunday.breakPaid = sundayPaid
            let rows = try XCTUnwrap(CanonicalBusinessEngine.weekendBookingBreakdown(
                policy: policy, dayKeys: [saturday, "2026-11-08"], start: "07:30", end: "14:00", isBreakRemoved: false, timeZone: zone
            ))
            return rows.map(\.paidHoursEquivalent)
        }
        let paid = try totals(saturdayPaid: true, sundayPaid: true)
        let unpaid = try totals(saturdayPaid: false, sundayPaid: false)
        XCTAssertEqual(paid, [8, 13])
        XCTAssertEqual(unpaid.first ?? -1, 7.5, accuracy: 0.001)
        // Sunday's unpaid figure is the packed rule's (1.20.3 changes whether the break is multiplied); only assert that
        // the preview moved when the break became unpaid.
        XCTAssertLessThan(unpaid.last ?? 99, paid.last ?? 0)
    }

    // MARK: 1.20.3 / 1.20.4 — an unpaid break is never multiplied; pay lines show clock hours and the break

    private func weekendPolicy(sundayBreakPaid: Bool, saturdayWindowEnd: String = "14:00", saturdayCountsAs: Double = 8, saturdayBreakPaid: Bool = true) -> OrgPayrollTimePolicy {
        var policy = OrgPayrollTimePolicy.default
        policy.saturday.customStandardEnd = saturdayWindowEnd
        policy.saturday.countsAsHours = saturdayCountsAs
        policy.saturday.breakPaid = saturdayBreakPaid
        policy.sunday.breakPaid = sundayBreakPaid
        return policy
    }

    private func weekendBooking(_ dayKey: String) throws -> Booking {
        let day = try XCTUnwrap(OrganizationRulebookContext.date(fromDayKey: dayKey))
        return LogicFixtures.booking(on: day, slot: .customHours, start: "07:30", end: "14:00")
    }

    func testSundayEveryHourAtTwoUnpaidBreakIsTwelveAndAHalf() throws {
        let result = try weekendBooking("2026-11-08").payrollHoursResult(policy: weekendPolicy(sundayBreakPaid: false))
        XCTAssertEqual(result.totalPaidHours, 12.5, accuracy: 0.001)
        let multiplied = try XCTUnwrap(result.multipliedHours)
        XCTAssertEqual(multiplied.clockHours, 6.5, accuracy: 0.001)
        XCTAssertEqual(multiplied.breakHours, 0.5, accuracy: 0.001)
        XCTAssertEqual(multiplied.text, "6.5h × 2 − 0.5h break = 12.5h")
        XCTAssertEqual(result.paidHoursLabel, "12.5h (6.5h × 2 − 0.5h break)")
        XCTAssertEqual(
            TimesheetPayrollCollector.overtimeDetails(multiplied: multiplied, otHours: result.outsideHours),
            "OT 6.5h × 2 − 0.5h break = 12.5h",
            "never the back-calculated 6.25h"
        )
    }

    func testSaturdayOutsideWindowBreakComesOffAfterTheMultiplier() throws {
        // Window 07:30–11:00 counts as 4h, outside ×2, booked 07:30–14:00, unpaid break 12:00–12:30.
        let policy = weekendPolicy(sundayBreakPaid: true, saturdayWindowEnd: "11:00", saturdayCountsAs: 4, saturdayBreakPaid: false)
        let result = try weekendBooking(saturday).payrollHoursResult(policy: policy)
        XCTAssertEqual(result.totalPaidHours, 9.5, accuracy: 0.001)
        XCTAssertEqual(result.multipliedHours?.text, "3h × 2 − 0.5h break = 5.5h")
        XCTAssertEqual(result.paidHoursLabel, "9.5h (4h + 3h × 2 − 0.5h break)")
        let rows = try XCTUnwrap(CanonicalBusinessEngine.weekendBookingBreakdown(
            policy: policy, dayKeys: [saturday], start: "07:30", end: "14:00", isBreakRemoved: false, timeZone: zone
        ))
        XCTAssertEqual(rows.map(\.line), ["Saturday 07:30–14:00 = 4h + 3h × 2 − 0.5h unpaid break = 9.5h"])
    }

    func testPayAmountsAreUnchangedByTheNewWording() throws {
        let result = try weekendBooking("2026-11-08").payrollHoursResult(policy: weekendPolicy(sundayBreakPaid: false))
        let hourly = ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: 20)
        let day = ResolvedPayrollRate(basis: .dayRate, dayRate: 200, hourlyRate: nil)
        XCTAssertEqual(hourly.payForHours(result.outsideHours, standardDayHours: 8, otMultiplier: result.outsideMultiplier), 250, accuracy: 0.001)
        XCTAssertEqual(day.payForHours(result.outsideHours, standardDayHours: 8, otMultiplier: result.outsideMultiplier), 312.5, accuracy: 0.001)
    }

    func testSignedLinesReadTheirStoredTextBack() throws {
        let parsed = try XCTUnwrap(CanonicalBusinessEngine.parseMultipliedHoursText("OT 6.5h × 2 − 0.5h break = 12.5h"))
        XCTAssertEqual(parsed.clockHours, 6.5, accuracy: 0.001)
        XCTAssertEqual(parsed.multiplier, 2, accuracy: 0.001)
        XCTAssertEqual(parsed.breakHours, 0.5, accuracy: 0.001)
        XCTAssertNil(CanonicalBusinessEngine.parseMultipliedHoursText("OT 7h"))
        XCTAssertEqual(CanonicalBusinessEngine.multipliedHoursText(clockHours: 6.5, multiplier: 2, breakHours: 0), "6.5h × 2 = 13h")
        XCTAssertEqual(
            CanonicalBusinessEngine.payLineHoursText(details: "OT 6.5h × 2 − 0.5h break = 12.5h", paidHours: 6.25, isOvertimeLine: true),
            "6.5h × 2 − 0.5h break = 12.5h"
        )
        XCTAssertEqual(CanonicalBusinessEngine.payLineHoursText(details: "07:30–16:00", paidHours: 7.25, isOvertimeLine: false), "7.25h")
    }

    func testWorkingHoursWeekendPreviewComesFromTheScript() throws {
        var policy = weekendPolicy(sundayBreakPaid: false)
        let sunday = try XCTUnwrap(CanonicalBusinessEngine.weekendDayPreview(policy: policy, weekday: "sunday", timeZone: zone))
        XCTAssertEqual(sunday.start, "07:30")
        XCTAssertEqual(sunday.end, "16:00")
        XCTAssertEqual(sunday.summary, "Every hour at ×2 · Unpaid break 12:00–12:30, 30 min — 30 min taken off · 16.5h paid")
        let saturday = try XCTUnwrap(CanonicalBusinessEngine.weekendDayPreview(policy: policy, weekday: "saturday", timeZone: zone))
        XCTAssertEqual(saturday.summary, "07:30–14:00 counts as 8h · Paid break 12:00–12:30, 30 min · 8h paid")
        policy.saturday.breakPaid = false
        let unpaid = try XCTUnwrap(CanonicalBusinessEngine.weekendDayPreview(policy: policy, weekday: "saturday", timeZone: zone))
        XCTAssertEqual(
            unpaid.summary,
            "07:30–14:00 counts as 8h · Unpaid break 12:00–12:30, 30 min — 30 min taken off · 7.5h paid",
            "switching the draft's break to Unpaid changes the preview at once"
        )
    }

    func testTotalBookedHoursIsTheSlotIntervalLength() throws {
        let day = try XCTUnwrap(OrganizationRulebookContext.date(fromDayKey: monday))
        XCTAssertEqual(LogicFixtures.booking(on: day, slot: .customHours, start: "22:00", end: "02:00").totalBookedHours(policy: .default), 4, accuracy: 0.001)
        XCTAssertEqual(LogicFixtures.booking(on: day, slot: .customHours, start: "07:30", end: "14:00").totalBookedHours(policy: .default), 6.5, accuracy: 0.001)
        XCTAssertEqual(LogicFixtures.booking(on: day, slot: .fullDay).totalBookedHours(policy: .default), 8.5, accuracy: 0.001)
    }
}
