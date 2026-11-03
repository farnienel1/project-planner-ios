import XCTest
@testable import Project_Planner

/// RULEBOOK 1.18.0 behaviour on iOS through `CanonicalBusinessEngine`. Every expected value was checked in node against
/// the packed `canonical-business.js` (sha256 68b96e0f…83a38a8).
@MainActor
final class Rulebook1180Tests: XCTestCase {
    private let zone = "Europe/London"
    // Saturday 7 Nov 2026, Sunday 8 Nov, Monday 9 Nov, Tuesday 10 Nov.
    private let saturday = "2026-11-07"
    private let sunday = "2026-11-08"
    private let monday = "2026-11-09"
    private let tuesday = "2026-11-10"

    /// The owner's example: Saturday window 07:30–14:00 counts as 8h, Sunday every hour at 2× (the default Sunday).
    private var ownerPolicy: OrgPayrollTimePolicy {
        var policy = OrgPayrollTimePolicy.default
        policy.saturday.customStandardEnd = "14:00"
        return policy
    }

    private func document(
        _ current: OrgPayrollTimePolicy,
        scheduled: OrgPayrollTimePolicy? = nil,
        from: String? = nil
    ) -> [String: Any] {
        CanonicalBusinessEngine.payrollPolicyDocument(
            current: current,
            prior: nil,
            effectiveFromDayKey: nil,
            scheduledPolicy: scheduled,
            scheduledEffectiveFromDayKey: from
        )
    }

    func testThePackedScriptIsRulebook1180OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 3)
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 18, 0]), "rulebook \(stamp.version) predates 1.18.0")
        let names = Set(CanonicalBusinessEngine.exportNames())
        XCTAssertTrue(names.contains("customHoursPrefillForDays"))
        XCTAssertTrue(names.contains("weekendBookingBreakdown"))
    }

    // MARK: weekendBookingBreakdown (1.18.0 §4.3)

    func testTheOwnersWeekendExampleGivesOneRowPerDay() throws {
        let rows = try XCTUnwrap(CanonicalBusinessEngine.weekendBookingBreakdown(
            policy: ownerPolicy, dayKeys: [sunday, saturday], start: "07:30", end: "14:00", isBreakRemoved: false, timeZone: zone
        ))
        XCTAssertEqual(rows.map(\.line), [
            "Saturday 07:30–14:00 = 8h (counts as a full day)",
            "Sunday 07:30–14:00 = 6.5h × 2 = 13h",
        ], "one row per day, in date order")
        XCTAssertEqual(rows.map(\.dayKey), [saturday, sunday])
        XCTAssertEqual(rows[0].workedHours, 6.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(rows[0].countsAsHours), 8, accuracy: 0.001)
        XCTAssertEqual(rows[0].standardHours, 8, accuracy: 0.001)
        XCTAssertEqual(rows[0].overtimeHours, 0, accuracy: 0.001)
        XCTAssertEqual(rows[0].paidHoursEquivalent, 8, accuracy: 0.001)
        XCTAssertNil(rows[1].countsAsHours, "an all-hours day has no window credit")
        XCTAssertEqual(rows[1].standardHours, 0, accuracy: 0.001)
        XCTAssertEqual(rows[1].overtimeHours, 6.5, accuracy: 0.001)
        XCTAssertEqual(rows[1].multiplier, 2, accuracy: 0.001)
        XCTAssertEqual(rows[1].paidHoursEquivalent, 13, accuracy: 0.001)
    }

    func testThePolicyStateGivesTheSameRowsAndReadsEachDayUnderItsOwnRules() throws {
        let rows = try XCTUnwrap(CanonicalBusinessEngine.weekendBookingBreakdown(
            policyDocument: document(ownerPolicy), dayKeys: [saturday, sunday], start: "07:30", end: "14:00",
            isBreakRemoved: false, todayKey: "2026-11-03", timeZone: zone
        ))
        XCTAssertEqual(rows.map(\.line), [
            "Saturday 07:30–14:00 = 8h (counts as a full day)",
            "Sunday 07:30–14:00 = 6.5h × 2 = 13h",
        ])

        // A Saturday window change to 08:00–14:00 from Tuesday 10 Nov: the Saturday after it pays 07:30–08:00 at 2×.
        var later = ownerPolicy
        later.saturday.customStandardStart = "08:00"
        let scheduled = document(ownerPolicy, scheduled: later, from: tuesday)
        let split = try XCTUnwrap(CanonicalBusinessEngine.weekendBookingBreakdown(
            policyDocument: scheduled, dayKeys: [saturday, "2026-11-14"], start: "07:30", end: "14:00",
            isBreakRemoved: false, todayKey: "2026-11-03", timeZone: zone
        ))
        XCTAssertEqual(split.map(\.line), [
            "Saturday 07:30–14:00 = 8h (counts as a full day)",
            "Saturday 07:30–14:00 = 8h + 0.5h × 2 = 9h",
        ])
        XCTAssertEqual(CanonicalBusinessEngine.collapsedBreakdownLines(split).count, 2, "different figures are never merged")
    }

    func testIdenticalWeekendDaysCollapseToOneSaturdaySundayRow() throws {
        var same = OrgPayrollTimePolicy.default
        same.sunday = .defaultSaturday
        same.sundaySameAsSaturday = true
        let rows = try XCTUnwrap(CanonicalBusinessEngine.weekendBookingBreakdown(
            policy: same, dayKeys: [saturday, sunday], start: "07:30", end: "13:00", isBreakRemoved: false, timeZone: zone
        ))
        XCTAssertEqual(rows.map(\.line), [
            "Saturday 07:30–13:00 = 8h (counts as a full day)",
            "Sunday 07:30–13:00 = 8h (counts as a full day)",
        ])
        XCTAssertEqual(
            CanonicalBusinessEngine.collapsedBreakdownLines(rows),
            ["Saturday/Sunday 07:30–13:00 = 8h (counts as a full day)"]
        )
        let owner = try XCTUnwrap(CanonicalBusinessEngine.weekendBookingBreakdown(
            policy: ownerPolicy, dayKeys: [saturday, sunday], start: "07:30", end: "14:00", isBreakRemoved: false, timeZone: zone
        ))
        XCTAssertEqual(CanonicalBusinessEngine.collapsedBreakdownLines(owner), [
            "Saturday 07:30–14:00 = 8h (counts as a full day)",
            "Sunday 07:30–14:00 = 6.5h × 2 = 13h",
        ])
    }

    func testHoursOutsideTheWindowAndInvalidInputs() throws {
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingBreakdown(
                policy: ownerPolicy, dayKeys: [saturday], start: "07:00", end: "15:00", isBreakRemoved: false, timeZone: zone
            )?.map(\.line),
            ["Saturday 07:00–15:00 = 8h + 1.5h × 2 = 11h"]
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingBreakdown(
                policy: ownerPolicy, dayKeys: [saturday, saturday, "x"], start: "07:30", end: "14:00", isBreakRemoved: false, timeZone: zone
            )?.map(\.line),
            ["Saturday 07:30–14:00 = 8h (counts as a full day)"],
            "duplicate and invalid day keys are dropped"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingBreakdown(
                policy: ownerPolicy, dayKeys: [saturday], start: "07:30", end: "07:30", isBreakRemoved: false, timeZone: zone
            )?.count,
            0
        )
    }

    func testAWeekdayOnlySelectionKeepsTheUsualBreakdown() throws {
        let monday9 = try XCTUnwrap(OrganizationRulebookContext.date(fromDayKey: monday))
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingBreakdown(
                on: [monday9], start: "07:30", end: "16:00", isBreakRemoved: false, fallbackPolicy: ownerPolicy
            ),
            [],
            "screens keep their standard / overtime summary on weekdays"
        )
        XCTAssertTrue(CanonicalBusinessEngine.isWeekendDayKey(saturday, timeZone: zone))
        XCTAssertFalse(CanonicalBusinessEngine.isWeekendDayKey(monday, timeZone: zone))
    }

    // MARK: customHoursPrefillForDays (1.18.0 §4.3)

    func testThePrefillFollowsTheSelectionKind() {
        XCTAssertEqual(
            CanonicalBusinessEngine.customHoursPrefillForDays(policy: ownerPolicy, dayKeys: [sunday, saturday], timeZone: zone),
            RulebookCustomHoursPrefill(start: "07:30", end: "14:00", kind: .weekend)
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.customHoursPrefillForDays(policy: ownerPolicy, dayKeys: [tuesday, monday], timeZone: zone),
            RulebookCustomHoursPrefill(start: "07:30", end: "16:00", kind: .weekday)
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.customHoursPrefillForDays(policy: ownerPolicy, dayKeys: [saturday, monday], timeZone: zone)?.kind,
            RulebookCustomHoursPrefill.Kind.mixed
        )
        XCTAssertNil(CanonicalBusinessEngine.customHoursPrefillForDays(policy: ownerPolicy, dayKeys: [], timeZone: zone))
        XCTAssertNil(CanonicalBusinessEngine.customHoursPrefillForDays(policy: ownerPolicy, dayKeys: ["bad"], timeZone: zone))
    }

    func testSundaysWindowWhenSaturdayPaysEveryHourAtAMultiplier() {
        var policy = OrgPayrollTimePolicy.default
        policy.saturday = .defaultSunday
        policy.saturday.customStandardStart = "07:30"
        policy.saturday.customStandardEnd = "16:00"
        policy.sunday = .defaultSaturday
        policy.sunday.customStandardStart = "08:00"
        policy.sunday.customStandardEnd = "12:00"
        XCTAssertEqual(
            CanonicalBusinessEngine.customHoursPrefillForDays(policy: policy, dayKeys: [saturday, sunday], timeZone: zone),
            RulebookCustomHoursPrefill(start: "08:00", end: "12:00", kind: .weekend)
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.customHoursPrefillForDays(policy: policy, dayKeys: [saturday], timeZone: zone),
            RulebookCustomHoursPrefill(start: "07:30", end: "16:00", kind: .weekend),
            "no set window: the standard day"
        )
    }

    func testThePrefillUsesTheStandardDayInEffectOnTheFirstSelectedDay() {
        var later = ownerPolicy
        later.standardDayStart = "08:00"
        later.standardDayEnd = "16:30"
        let scheduled = document(ownerPolicy, scheduled: later, from: monday)
        XCTAssertEqual(
            CanonicalBusinessEngine.customHoursPrefillForDays(
                policyDocument: scheduled, dayKeys: ["2026-11-06"], todayKey: "2026-11-03", timeZone: zone
            ),
            RulebookCustomHoursPrefill(start: "07:30", end: "16:00", kind: .weekday)
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.customHoursPrefillForDays(
                policyDocument: scheduled, dayKeys: [tuesday, monday], todayKey: "2026-11-03", timeZone: zone
            ),
            RulebookCustomHoursPrefill(start: "08:00", end: "16:30", kind: .weekday)
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.customHoursPrefillForDays(
                policyDocument: document(ownerPolicy), dayKeys: [sunday, saturday], todayKey: "2026-11-03", timeZone: zone
            ),
            RulebookCustomHoursPrefill(start: "07:30", end: "14:00", kind: .weekend)
        )
    }

    /// The owner bug: weekend days ticked, then unticked and weekdays ticked — the times must leave weekend hours at once,
    /// and a manual edit must survive adding another day of the same kind.
    func testAKindChangeResetsTheTimesAndTheSameKindLeavesThemAlone() {
        func prefill(_ keys: [String]) -> RulebookCustomHoursPrefill? {
            CanonicalBusinessEngine.customHoursPrefillForDays(policy: ownerPolicy, dayKeys: keys, timeZone: zone)
        }
        var tracker = CustomHoursKindTracker(seed: prefill([monday]))
        XCTAssertNil(tracker.prefillToApply(prefill([tuesday])), "a weekday picker opened on a weekday keeps its times")

        XCTAssertEqual(tracker.prefillToApply(prefill([saturday])), RulebookCustomHoursPrefill(start: "07:30", end: "14:00", kind: .weekend))
        XCTAssertNil(tracker.prefillToApply(prefill([saturday, sunday])), "adding Sunday keeps the weekend times")
        XCTAssertNil(tracker.prefillToApply(prefill([])), "no day selected changes nothing")
        XCTAssertEqual(
            tracker.prefillToApply(prefill([monday])),
            RulebookCustomHoursPrefill(start: "07:30", end: "16:00", kind: .weekday),
            "weekend days unticked, a weekday ticked: back to the standard day straight away"
        )
        XCTAssertNil(tracker.prefillToApply(prefill([monday, tuesday])), "a manual edit survives adding another weekday")
        XCTAssertNil(tracker.prefillToApply(prefill([saturday, monday])), "a refused mix never applies")
        XCTAssertEqual(tracker.prefillToApply(prefill([sunday]))?.kind, .weekend)

        var fresh = CustomHoursKindTracker()
        XCTAssertEqual(fresh.prefillToApply(prefill([saturday]))?.kind, .weekend, "an unseeded picker applies its first answer")
    }
}
