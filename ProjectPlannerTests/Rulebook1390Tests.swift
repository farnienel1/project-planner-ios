import XCTest
@testable import Project_Planner

/// RULEBOOK 1.39.0 §4.3 (owner request 11 Nov) on iOS through `CanonicalBusinessEngine`: the words that explain a
/// booking's hours (`bookingHoursExplanation`, the `explanation` on `weekendBookingBreakdown` rows) and what "missing
/// hours" compare against (`bookingShortfall`). Wording only — the figures are the pay rule's. Expected values were
/// checked in node against the packed `canonical-business.js` (sha256 2c9d7a20…419eb25).
@MainActor
final class Rulebook1390Tests: XCTestCase {
    private let zone = "Europe/London"
    // Saturday 7 Nov 2026, Sunday 8 Nov, Monday 9 Nov.
    private let saturday = "2026-11-07"
    private let sunday = "2026-11-08"
    private let monday = "2026-11-09"

    /// The owner's organisation: Saturday 07:30–14:00 counts as 8h, outside at 2×; Sunday every hour at 2× (default).
    private var ownerPolicy: OrgPayrollTimePolicy {
        var policy = OrgPayrollTimePolicy.default
        policy.saturday.customStandardEnd = "14:00"
        return policy
    }

    func testThePackedScriptExportsTheExplanation() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 39, 0]), "rulebook \(stamp.version) predates 1.39.0")
        let names = Set(CanonicalBusinessEngine.exportNames())
        XCTAssertTrue(names.contains("bookingHoursExplanation"))
        XCTAssertTrue(names.contains("bookingShortfall"))
    }

    /// Owner screenshot: Quick Add, Saturday 07:30–10:30 = 3.69h — now says why.
    func testOwnerSaturdayPartDayIsExplainedProRata() throws {
        let row = try XCTUnwrap(CanonicalBusinessEngine.bookingHoursExplanation(
            policy: ownerPolicy, dayKey: saturday, start: "07:30", end: "10:30", isBreakRemoved: false, timeZone: zone
        ))
        XCTAssertTrue(row.rule.hasPrefix("Saturday full day: 07:30–14:00 counts as 8h, hours outside it at 2×"), row.rule)
        XCTAssertEqual(row.steps, ["Booked 07:30–10:30 = 3h of the 6.5h window → 8h × 3 ÷ 6.5 = 3.69h"])
        XCTAssertEqual(row.totalPaidHours, 3.69, accuracy: 0.001)
        XCTAssertEqual(row.fullDayHours ?? 0, 8, accuracy: 0.001)
    }

    /// Owner screenshots: Saturday / Sunday 07:30–16:00 = 8h + 2h × 2 = 12h.
    func testOwnerFullDayPlusOutsideHours() throws {
        let row = try XCTUnwrap(CanonicalBusinessEngine.bookingHoursExplanation(
            policy: ownerPolicy, dayKey: saturday, start: "07:30", end: "16:00", isBreakRemoved: false, timeZone: zone
        ))
        XCTAssertEqual(row.steps, ["07:30–14:00 = 8h (full day)", "+ 14:00–16:00 = 2h × 2 = 4h", "→ 12h"])
        XCTAssertEqual(row.totalPaidHours, 12, accuracy: 0.001)
    }

    func testMultiplierOnlyDayAndWeekday() throws {
        let sun = try XCTUnwrap(CanonicalBusinessEngine.bookingHoursExplanation(
            policy: ownerPolicy, dayKey: sunday, start: "07:30", end: "10:30", isBreakRemoved: false, timeZone: zone
        ))
        XCTAssertTrue(sun.rule.hasPrefix("Sunday every hour at 2×"), sun.rule)
        XCTAssertEqual(sun.steps, ["07:30–10:30 = 3h × 2 = 6h"])
        XCTAssertNil(sun.fullDayHours)

        let mon = try XCTUnwrap(CanonicalBusinessEngine.bookingHoursExplanation(
            policy: ownerPolicy, dayKey: monday, start: "07:30", end: "16:00", isBreakRemoved: false, timeZone: zone
        ))
        XCTAssertEqual(mon.rule, "Monday full day: 07:30–16:00 − 30 min unpaid break (12:00–12:30) = 8h, hours outside it at 1.5×")
        XCTAssertEqual(mon.steps, ["07:30–16:00 = 8.5h", "− 0.5h unpaid break", "→ 8h"])
    }

    /// "Missing to standard day" names what it compares against; nothing on a day paid every hour at a multiplier.
    func testShortfallNamesTheDaysOwnFullDay() throws {
        let short = try XCTUnwrap(CanonicalBusinessEngine.bookingShortfall(
            policy: ownerPolicy, dayKey: saturday, bookedHours: 3.69, timeZone: zone
        ))
        XCTAssertEqual(short.label, "Short of a full Saturday (8h)")
        XCTAssertEqual(short.value, "4.31h")
        XCTAssertEqual(short.missingHours, 4.31, accuracy: 0.001)
        XCTAssertNil(CanonicalBusinessEngine.bookingShortfall(policy: ownerPolicy, dayKey: saturday, bookedHours: 12, timeZone: zone))
        XCTAssertNil(CanonicalBusinessEngine.bookingShortfall(policy: ownerPolicy, dayKey: sunday, bookedHours: 6, timeZone: zone))
        XCTAssertEqual(
            CanonicalBusinessEngine.bookingShortfall(policy: ownerPolicy, dayKey: monday, bookedHours: 4, timeZone: zone)?.label,
            "Short of a full Monday (8h)"
        )
    }

    /// Weekend rows carry the explanation; the figures (`line`, `paidHoursEquivalent`) are exactly as before 1.39.0.
    func testBreakdownRowsCarryTheExplanationAndKeepTheirFigures() throws {
        let rows = try XCTUnwrap(CanonicalBusinessEngine.weekendBookingBreakdown(
            policy: ownerPolicy, dayKeys: [saturday, sunday], start: "07:30", end: "14:00", isBreakRemoved: false, timeZone: zone
        ))
        XCTAssertEqual(rows.map(\.line), [
            "Saturday 07:30–14:00 = 8h (counts as a full day)",
            "Sunday 07:30–14:00 = 6.5h × 2 = 13h",
        ])
        XCTAssertEqual(rows.map(\.paidHoursEquivalent), [8, 13])
        XCTAssertEqual(rows.map(\.explanationSteps), [["07:30–14:00 = 8h (full day)"], ["07:30–14:00 = 6.5h × 2 = 13h"]])
        let sections = CanonicalBusinessEngine.collapsedBreakdownSections(rows)
        XCTAssertEqual(sections.map(\.line), CanonicalBusinessEngine.collapsedBreakdownLines(rows))
        XCTAssertEqual(sections.first?.detail.last, "07:30–14:00 = 8h (full day)")
        XCTAssertTrue(sections.first?.detail.first?.hasPrefix("Saturday full day:") ?? false)
    }

    func testIdenticalDaysShareOneSectionWithTheirExplanation() throws {
        var same = OrgPayrollTimePolicy.default
        same.sunday = .defaultSaturday
        same.sundaySameAsSaturday = true
        let rows = try XCTUnwrap(CanonicalBusinessEngine.weekendBookingBreakdown(
            policy: same, dayKeys: [saturday, sunday], start: "07:30", end: "13:00", isBreakRemoved: false, timeZone: zone
        ))
        let sections = CanonicalBusinessEngine.collapsedBreakdownSections(rows)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.line, "Saturday/Sunday 07:30–13:00 = 8h (counts as a full day)")
        XCTAssertTrue(sections.first?.detail.first?.hasPrefix("Saturday/Sunday full day: 07:30–13:00 counts as 8h") ?? false)
    }
}
