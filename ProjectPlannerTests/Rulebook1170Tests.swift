import XCTest
@testable import Project_Planner

/// RULEBOOK 1.17.0 behaviour on iOS through `CanonicalBusinessEngine`. Every expected value was checked in node against
/// the packed `canonical-business.js` (sha256 5390bfde…85b0d5).
@MainActor
final class Rulebook1170Tests: XCTestCase {
    private let zone = "Europe/London"
    private let saturdayWindowNote =
        "Saturday is paid on the hours you enter: 07:30\u{2013}13:00 counts as 8h, hours outside it at 2×. Change it in Working hours."
    private let sundayAllHoursNote = "Sunday is paid on the hours you enter, every hour at 2×. Change it in Working hours."
    private let weekendWindowNote =
        "Saturday/Sunday is paid on the hours you enter: 07:30\u{2013}13:00 counts as 8h, hours outside it at 2×. Change it in Working hours."

    /// Sunday follows Saturday's set window.
    private var sameWeekendPolicy: OrgPayrollTimePolicy {
        var policy = OrgPayrollTimePolicy.default
        policy.sunday = .defaultSaturday
        policy.sundaySameAsSaturday = true
        return policy
    }

    private func day(_ key: String) throws -> Date {
        try XCTUnwrap(OrganizationRulebookContext.date(fromDayKey: key))
    }

    func testThePackedScriptIsRulebook1170OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 3)
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 17, 0]), "rulebook \(stamp.version) predates 1.17.0")
        let names = Set(CanonicalBusinessEngine.exportNames())
        XCTAssertTrue(names.contains("weekendBookingNotes"))
        XCTAssertTrue(names.contains("isPushTokenPlaceholderUserId"))
    }

    // MARK: Weekend booking notes for a selection (1.17.0 §4.3)

    func testDifferentWeekendRulesGiveTheSaturdayThenTheSundayLine() {
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingNotes(policy: .default, dayKeys: ["2026-11-08", "2026-11-07"], timeZone: zone),
            [saturdayWindowNote, sundayAllHoursNote]
        )
    }

    func testTheSameWeekendRuleGivesOneSaturdaySundayLine() {
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingNotes(policy: sameWeekendPolicy, dayKeys: ["2026-11-07", "2026-11-08"], timeZone: zone),
            [weekendWindowNote]
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingNotes(
                policy: sameWeekendPolicy,
                dayKeys: ["2026-11-14", "2026-11-07", "2026-11-08", "2026-11-15"],
                timeZone: zone
            ),
            [weekendWindowNote],
            "two weekends under one rule: one line, never repeated"
        )
    }

    func testOneWeekendDayKeepsItsOwnNoteAndWeekdaysHaveNone() {
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingNotes(policy: .default, dayKeys: ["2026-11-07"], timeZone: zone),
            [saturdayWindowNote]
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingNotes(policy: .default, dayKeys: ["2026-11-04"], timeZone: zone),
            []
        )
    }

    func testThePolicyStateReadsEachDayUnderTheRulesInEffectOnIt() {
        // A change scheduled from Sunday 8 Nov makes Sunday follow Saturday's window: one line, although today's
        // rules (Sunday every hour at 2×) would have given two.
        let fromSunday = CanonicalBusinessEngine.payrollPolicyDocument(
            current: .default,
            prior: nil,
            effectiveFromDayKey: nil,
            scheduledPolicy: sameWeekendPolicy,
            scheduledEffectiveFromDayKey: "2026-11-08"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingNotes(
                policyDocument: fromSunday, dayKeys: ["2026-11-07", "2026-11-08"], todayKey: "2026-11-03", timeZone: zone
            ),
            [weekendWindowNote]
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingNotes(
                policyDocument: fromSunday, dayKeys: ["2026-10-31", "2026-11-01"], todayKey: "2026-11-03", timeZone: zone
            ),
            [saturdayWindowNote, sundayAllHoursNote],
            "the weekend before the change keeps the rules then in effect"
        )

        // A Saturday window change from Tuesday 10 Nov: two Saturdays either side give one line each.
        var later = OrgPayrollTimePolicy.default
        later.saturday.customStandardStart = "08:00"
        later.saturday.customStandardEnd = "14:00"
        let fromTuesday = CanonicalBusinessEngine.payrollPolicyDocument(
            current: .default,
            prior: nil,
            effectiveFromDayKey: nil,
            scheduledPolicy: later,
            scheduledEffectiveFromDayKey: "2026-11-10"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.weekendBookingNotes(
                policyDocument: fromTuesday, dayKeys: ["2026-11-14", "2026-11-07"], todayKey: "2026-11-03", timeZone: zone
            ),
            [
                saturdayWindowNote,
                "Saturday is paid on the hours you enter: 08:00\u{2013}14:00 counts as 8h, hours outside it at 2×. Change it in Working hours.",
            ]
        )
        // Each booked day keeps its own prefill (`weekendCustomHoursDefault`).
        let laterSaturday = CanonicalBusinessEngine.weekendCustomHoursDefault(policy: later, dayKey: "2026-11-14", timeZone: zone)
        XCTAssertEqual(laterSaturday?.start, "08:00")
        XCTAssertEqual(laterSaturday?.end, "14:00")
    }

    func testOnePairOfTimesOpensOnTheFirstSelectedSaturday() throws {
        let sunday8 = try day("2026-11-08")
        let saturday14 = try day("2026-11-14")
        let saturday7 = try day("2026-11-07")
        XCTAssertEqual(CanonicalBusinessEngine.singlePairPrefillDay([saturday14, sunday8]), saturday14)
        XCTAssertEqual(CanonicalBusinessEngine.singlePairPrefillDay([saturday14, sunday8, saturday7]), saturday7)
        XCTAssertEqual(CanonicalBusinessEngine.singlePairPrefillDay([sunday8]), sunday8)
        let wednesday = try day("2026-11-04")
        let thursday = try day("2026-11-05")
        XCTAssertEqual(CanonicalBusinessEngine.singlePairPrefillDay([thursday, wednesday]), wednesday)
        XCTAssertNil(CanonicalBusinessEngine.singlePairPrefillDay([]))
    }

    // MARK: Push tokens (1.17.0 §13)

    func testAnInvitePlaceholderIdIsNeverAPushTokenOwner() {
        XCTAssertEqual(
            CanonicalBusinessEngine.callJSON("isPushTokenPlaceholderUserId", arguments: ["3F2504E0-4F89-11D3-9A0C-0305E82C3301"]) as? Bool,
            true
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.callJSON("isPushTokenPlaceholderUserId", arguments: ["aBcD1234efGH5678ijKL9012mnOP"]) as? Bool,
            false,
            "a Firebase Auth uid owns its tokens"
        )
    }
}
