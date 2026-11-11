import XCTest
@testable import Project_Planner

/// RULEBOOK 1.39.0 §4.3 (owner request 11 Nov) on iOS through `CanonicalBusinessEngine`: the words that explain a
/// booking's hours (`bookingHoursExplanation`, the `explanation` on `weekendBookingBreakdown` rows) and what "missing
/// hours" compare against (`bookingShortfall`). Wording only — the figures are the pay rule's. Expected values were
/// checked in node against the packed `canonical-business.js` (sha256 5f1eae2f…2e8ef1e).
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
        // 1.39.0 (owner answer 11 Nov): the break is named from that day's own working hours (paid here).
        XCTAssertEqual(row.steps.count, 3)
        XCTAssertTrue(row.steps[0].hasPrefix("07:30–14:00 = 8h (full day"), row.steps[0])
        XCTAssertEqual(Array(row.steps.dropFirst()), ["+ 14:00–16:00 = 2h × 2 = 4h", "→ 12h"])
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
        // 1.39.0: the unpaid break is named on the part it falls in, not a separate line.
        XCTAssertEqual(mon.steps, ["07:30–16:00 = 8h (day, less 30 min unpaid break)"])
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
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].explanationSteps.first?.hasPrefix("07:30–14:00 = 8h (full day") ?? false)
        XCTAssertEqual(rows[1].explanationSteps, ["07:30–14:00 = 6.5h × 2 = 13h"])
        let sections = CanonicalBusinessEngine.collapsedBreakdownSections(rows)
        XCTAssertEqual(sections.map(\.line), CanonicalBusinessEngine.collapsedBreakdownLines(rows))
        XCTAssertTrue(sections.first?.detail.last?.hasPrefix("07:30–14:00 = 8h (full day") ?? false)
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

    // MARK: 1.39.0 labels and the My Schedule clash marker (owner answers 11 Nov)

    func testThePackedScriptExportsTheLabelsAndClashMarker() {
        let names = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "overtimeTotalText", "overtimeIncludedText", "bookedWithOvertimeText", "bookingHoursCountText",
            "saveHoursLabel", "bookingBreakText", "bookingHoursTiles", "myScheduleClashMarkers",
        ] {
            XCTAssertTrue(names.contains(name), name)
        }
    }

    func testLabelWordingIsTheRulebooks() {
        XCTAssertEqual(CanonicalBusinessEngine.overtimeTotalText(clockHours: 12, multiplier: 1.5), "12h OT × 1.5 = 18h")
        XCTAssertNil(CanonicalBusinessEngine.overtimeTotalText(clockHours: 0, multiplier: 1.5))
        XCTAssertEqual(CanonicalBusinessEngine.overtimeIncludedText(clockHours: 6, multiplier: 1.5), "incl. 6h OT × 1.5 = 9h")
        XCTAssertEqual(
            CanonicalBusinessEngine.bookedWithOvertimeText(bookedHours: 60.5, clockHours: 12, multiplier: 1.5),
            "60.5h booked (incl. 12h OT × 1.5)"
        )
        XCTAssertEqual(CanonicalBusinessEngine.bookingHoursCountText(17.5), "17.5 hours")
        XCTAssertEqual(CanonicalBusinessEngine.saveHoursLabel(17.5), "Save · 17.5 hours")
    }

    /// Edit booking tiles (owner option A): standard with the break on it, overtime, no break tile; the break text
    /// follows the day's own working hours. Figures are the pay rule's (`payrollHoursResult`).
    func testEditBookingTilesAndBreakText() throws {
        let day = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: monday))
        let tiles = CanonicalBusinessEngine.bookingHoursTiles(
            on: day, start: "07:30", end: "18:00", isBreakRemoved: false, fallbackPolicy: ownerPolicy, timeZone: zone
        )
        XCTAssertEqual(tiles.map(\.kind), ["standard", "overtime"])
        XCTAssertEqual(tiles.first?.label, "Standard (−0.5 break)")
        XCTAssertEqual(tiles.last?.label, "OT")
        XCTAssertFalse(tiles.contains { $0.label.lowercased().contains("unpaid break") })
        let removed = CanonicalBusinessEngine.bookingHoursTiles(
            on: day, start: "07:30", end: "16:00", isBreakRemoved: true, fallbackPolicy: ownerPolicy, timeZone: zone
        )
        XCTAssertEqual(removed.map(\.label), ["Standard"])
        let breakText = try XCTUnwrap(CanonicalBusinessEngine.bookingBreakText(on: day, fallbackPolicy: ownerPolicy, timeZone: zone))
        XCTAssertTrue(breakText.label.hasSuffix("min unpaid break \(breakText.window)"), breakText.label)
        XCTAssertTrue(breakText.deducted.contains("mins deducted \(breakText.window)"), breakText.deducted)
        XCTAssertFalse(breakText.deducted.contains("around midday"))
    }

    /// The clash marker is the Warnings rule: red while not approved (never grey when the approvals are not loaded),
    /// grey once every pair is approved, "Open Warnings" only for a viewer who may open Warnings.
    func testMyScheduleClashMarkerFollowsTheWarningsRule() {
        func input(decisions: Any, canOpen: Bool) -> [String: Any] {
            [
                "operativeBookings": [
                    ["id": "A", "operativeId": "op1", "dayKey": monday, "timeSlot": "CUSTOM_HOURS", "workStartTime": "07:00", "workEndTime": "12:00", "status": "Confirmed", "placeLabel": "J1"],
                    ["id": "B", "operativeId": "op1", "dayKey": monday, "timeSlot": "CUSTOM_HOURS", "workStartTime": "11:00", "workEndTime": "15:00", "status": "Confirmed", "placeLabel": "J2"],
                ],
                "people": ["accounts": [] as [Any], "operatives": [["id": "op1", "email": "a@x.test"]]] as [String: Any],
                "managerIds": [] as [String],
                "decisions": decisions,
                "canOpenWarnings": canOpen,
            ]
        }
        let unloaded = CanonicalBusinessEngine.myScheduleClashMarkers(input(decisions: NSNull(), canOpen: false))
        XCTAssertEqual(unloaded["A"]?.state, "clash")
        XCTAssertNil(unloaded["A"]?.actionLabel)
        XCTAssertTrue(unloaded["A"]?.message.hasSuffix("Ask your manager to review this clash.") ?? false)
        let staff = CanonicalBusinessEngine.myScheduleClashMarkers(
            input(decisions: ["approvedKeys": [] as [String], "acceptedClashes": [] as [Any]] as [String: Any], canOpen: true)
        )
        XCTAssertEqual(staff["B"]?.actionLabel, "Open Warnings")
        let approved = CanonicalBusinessEngine.myScheduleClashMarkers(input(
            decisions: ["approvedKeys": [] as [String], "acceptedClashes": [["id": "x", "bookingAId": "A", "bookingBId": "B"]]] as [String: Any],
            canOpen: true
        ))
        XCTAssertEqual(approved["A"]?.state, "approved")
        XCTAssertEqual(approved["A"]?.title, "Clash approved")
        XCTAssertNil(approved["A"]?.actionLabel)
    }
}
