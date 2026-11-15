import XCTest
@testable import Project_Planner

/// RULEBOOK 1.49.0 (owner decisions 15 Nov): a weekend full day pays one day rate, weekend "Counts as" follows
/// Monday–Friday by default, and the unpaid break is allowed for in "counts as". Everything through
/// `CanonicalBusinessEngine` (`payrollHoursResult` with its `standardPartDayHours` / `overtimePartDayHours`,
/// `payForHours`, `weekendCountsAsHours`, `validatePayrollTimePolicy`). Expected values were checked in node against the
/// packed script this branch mirrors and match web `lib/weekly-report/weekendDayRate149.test.ts`.
@MainActor
final class Rulebook1490Tests: XCTestCase {
    private let org = "TEST-org-149"

    override func setUp() {
        super.setUp()
        OrganizationRulebookContext.update(from: Organization(firestoreDocumentId: org, name: "TEST-Company 149"))
    }

    override func tearDown() {
        OrganizationRulebookContext.update(from: nil)
        super.tearDown()
    }

    /// 07:00–16:00, 30 min unpaid 12:00–12:30 (8.5h day), ×1.5; Saturday and Sunday 07:30–14:00 counts as 8 (paid break).
    private var ownerPolicy: OrgPayrollTimePolicy {
        var policy = OrgPayrollTimePolicy.default
        policy.standardDayStart = "07:00"
        policy.standardDayEnd = "16:00"
        policy.unpaidBreakMinutes = 30
        policy.breakPaid = false
        policy.breakWindowStart = "12:00"
        policy.breakWindowEnd = "12:30"
        policy.standardPaidHours = 8.5
        policy.paidHoursDerived = true
        policy.weekdayOutsideStandardMultiplier = 1.5
        let weekend = OrgWeekendDayPayrollSettings(
            allHoursAtMultiplierMode: false,
            allHoursMultiplier: 2,
            useCustomStandardDayWindow: true,
            customStandardStart: "07:30",
            customStandardEnd: "14:00",
            countsAsHours: 8,
            outsideStandardWindowMultiplier: 1.5,
            breakPaid: true
        )
        policy.saturday = weekend
        policy.sunday = weekend
        policy.sundaySameAsSaturday = false
        return policy
    }

    private func booking(_ dayKey: String, _ start: String, _ end: String, ot: Double? = nil) -> (Booking, Date) {
        let day = OrganizationRulebookContext.date(fromDayKey: dayKey)!
        return (Booking(
            operativeId: UUID(),
            projectId: UUID(),
            date: day,
            timeSlot: .customHours,
            bookedBy: "TEST-Admin",
            workStartTime: start,
            workEndTime: end,
            otMultiplierOverride: ot
        ), day)
    }

    /// One booking's pay as the collector prices it: the standard line on `standardPartDayHours`, the overtime line on
    /// `overtimePartDayHours` (both from the rulebook), each through `payForHours`.
    private func pay(_ entry: (Booking, Date), rate: ResolvedPayrollRate, policy: OrgPayrollTimePolicy) throws -> (standard: Double, overtime: Double, days: Double) {
        let hours = try XCTUnwrap(PayrollHoursEngine.canonicalResult(booking: entry.0, day: entry.1, policy: policy))
        let standardDivisor = try XCTUnwrap(hours.standardPartDayHours)
        let overtimeDivisor = try XCTUnwrap(hours.overtimePartDayHours)
        let standard = try XCTUnwrap(rate.payForHoursIfCalculated(max(0, hours.standardHours), standardDayHours: standardDivisor))
        var overtime = 0.0
        if hours.outsideHours > CanonicalBusinessEngine.timesheetOvertimeLineMinHours {
            overtime = try XCTUnwrap(rate.payForHoursIfCalculated(
                hours.outsideHours, standardDayHours: overtimeDivisor, otMultiplier: hours.outsideMultiplier
            ))
        }
        return (standard, overtime, max(0, hours.standardHours) / standardDivisor)
    }

    func testTheOwnersReferenceFortnightIs3141Point76() throws {
        let policy = ownerPolicy
        let before = ResolvedPayrollRate(basis: .dayRate, dayRate: 250, hourlyRate: nil)
        let after = ResolvedPayrollRate(basis: .dayRate, dayRate: 240, hourlyRate: nil)
        let weekdays = [
            booking("2026-11-02", "07:00", "16:00"),
            booking("2026-11-03", "07:00", "16:00"),
            booking("2026-11-04", "07:00", "16:00"),
            booking("2026-11-05", "07:00", "21:00"),
            booking("2026-11-06", "07:00", "23:00"),
            booking("2026-11-09", "07:00", "22:30", ot: 2),
            booking("2026-11-10", "07:00", "16:00"),
        ]
        var weekdayTotal = 0.0
        for entry in weekdays {
            let line = try pay(entry, rate: before, policy: policy)
            weekdayTotal += line.standard + line.overtime
        }
        XCTAssertEqual(CanonicalBusinessEngine.roundPennies(weekdayTotal), 2661.76, accuracy: 0.001)

        let saturday = try pay(booking("2026-11-14", "07:30", "14:00"), rate: after, policy: policy)
        let sunday = try pay(booking("2026-11-15", "07:30", "14:00"), rate: after, policy: policy)
        XCTAssertEqual(saturday.standard, 240, accuracy: 0.001)
        XCTAssertEqual(sunday.standard, 240, accuracy: 0.001)
        XCTAssertEqual(saturday.overtime, 0)
        XCTAssertEqual(saturday.days, 1, accuracy: 0.0001, "a full Saturday window reads 1.00 day")
        XCTAssertEqual(sunday.days, 1, accuracy: 0.0001)
        XCTAssertEqual(
            CanonicalBusinessEngine.roundPennies(weekdayTotal + saturday.standard + sunday.standard), 3141.76, accuracy: 0.001
        )
    }

    func testSameAsMondayToFridayPaysOneDayAndHourlyPaysTheWeekdayDay() throws {
        var policy = ownerPolicy
        policy.saturday.countsAsFollowsWeekday = true
        policy.saturday.breakPaid = false
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsHours(policy.saturday, policy: policy), 8.5, accuracy: 0.0001)
        let day = try pay(booking("2026-11-14", "07:30", "14:00"), rate: ResolvedPayrollRate(basis: .dayRate, dayRate: 240, hourlyRate: nil), policy: policy)
        XCTAssertEqual(day.standard, 240, accuracy: 0.001)
        XCTAssertEqual(day.days, 1, accuracy: 0.0001)
        let hourly = try pay(booking("2026-11-14", "07:30", "14:00"), rate: ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: 30), policy: policy)
        XCTAssertEqual(hourly.standard, 255, accuracy: 0.001)
    }

    func testCountsAsHasOneReaderAndOneFallback() {
        var unset = ownerPolicy.saturday
        unset.countsAsHours = nil
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsHours(unset, policy: ownerPolicy), 8, "the rulebook fallback is 8, never the weekday day")
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsHours(ownerPolicy.saturday, policy: ownerPolicy), 8)
    }

    func testSettingsRoundTripTheSameAsMondayToFridayFlag() throws {
        var policy = ownerPolicy
        policy.saturday.countsAsFollowsWeekday = true
        let stored = policy.asFirestoreDictionary()
        let saturday = try XCTUnwrap(stored["saturday"] as? [String: Any])
        XCTAssertEqual(saturday["countsAsFollowsWeekday"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(saturday["countsAsHours"] as? Double), 8.5, accuracy: 0.0001, "the derived value is written for older builds")
        let sunday = try XCTUnwrap(stored["sunday"] as? [String: Any])
        XCTAssertNil(sunday["countsAsFollowsWeekday"], "left out when off, as web")
        let back = OrgPayrollTimePolicy.fromFirestore(stored)
        XCTAssertEqual(back.saturday.countsAsFollowsWeekday, true)
        XCTAssertNil(back.sunday.countsAsFollowsWeekday)
        // The script reads it too (`parsePayrollPolicy`), so the save write fields keep it.
        let json = try XCTUnwrap(CanonicalBusinessEngine.payrollPolicyJSON(policy))
        XCTAssertEqual((json["saturday"] as? [String: Any])?["countsAsFollowsWeekday"] as? Bool, true)
        let derived = try XCTUnwrap(CanonicalBusinessEngine.withDerivedWeekdayPaidHours(policy))
        XCTAssertEqual(derived.saturday.countsAsFollowsWeekday, true)
    }

    func testTheCapAndTheHalfHourStepAreCheckedWithPrevious() {
        var tooMany = ownerPolicy
        tooMany.saturday.countsAsHours = 9
        XCTAssertEqual(
            CanonicalBusinessEngine.validatePayrollTimePolicy(tooMany, previous: ownerPolicy),
            "Saturday counts-as hours can't be more than the Monday–Friday paid day (8.5h)."
        )
        var offStep = ownerPolicy
        offStep.saturday.countsAsHours = 7.3
        XCTAssertEqual(
            CanonicalBusinessEngine.validatePayrollTimePolicy(offStep, previous: ownerPolicy),
            "Saturday counts-as hours use half-hour steps (e.g. 7.5)."
        )
        // A stored number left unchanged (with the weekday day unchanged) passes.
        XCTAssertNil(CanonicalBusinessEngine.validatePayrollTimePolicy(tooMany, previous: tooMany))
        // "Same as Monday–Friday" is never refused.
        var following = ownerPolicy
        following.saturday.countsAsFollowsWeekday = true
        following.saturday.countsAsHours = 9
        XCTAssertNil(CanonicalBusinessEngine.validatePayrollTimePolicy(following, previous: ownerPolicy))
    }

    func testTheStepperAndNotesComeFromTheRulebook() throws {
        let policy = ownerPolicy
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsMax(policy), 8.5)
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsStep(7.25, direction: 1, policy: policy), 7.5)
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsStep(7.25, direction: -1, policy: policy), 7)
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsCopy(.saturday)?.sameAsWeekdayLabel, "Same as Monday–Friday")
        XCTAssertEqual(CanonicalBusinessEngine.weekendCountsAsCopy(.saturday)?.label, "Counts as")
        XCTAssertNotNil(CanonicalBusinessEngine.weekdayDayRateNote(policy))
        XCTAssertNotNil(CanonicalBusinessEngine.weekendDayRateNote(policy, day: .saturday))
        var everyHour = policy
        everyHour.sunday.allHoursAtMultiplierMode = true
        XCTAssertNil(CanonicalBusinessEngine.weekendDayRateNote(everyHour, day: .sunday), "none on an every-hour day")
    }

    func testANewOrganisationStartsOnSameAsMondayToFriday() throws {
        let policy = try XCTUnwrap(CanonicalBusinessEngine.newOrganizationPayrollPolicy())
        XCTAssertEqual(policy.saturday.countsAsFollowsWeekday, true)
        XCTAssertEqual(policy.sunday.countsAsFollowsWeekday, true)
    }
}
