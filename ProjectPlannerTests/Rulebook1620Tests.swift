import XCTest
@testable import Project_Planner

/// RULEBOOK 1.62.0 §4.3 (owner request 17 Nov) on iOS through `CanonicalBusinessEngine`: "How the hours add up" —
/// `bookingHoursBreakdownDays` — the same text as web (`lib/canonical/bookingHoursBreakdown.test.ts`). Wording only:
/// Normal + Overtime = Total = the pay rule's total = the Save button (`saveHoursLabel`).
@MainActor
final class Rulebook1620Tests: XCTestCase {
    private let zone = "Europe/London"
    private let tuesday = "2026-11-17"
    private let wednesday = "2026-11-18"
    private let saturday = "2026-11-21"
    private let sunday = "2026-11-22"

    /// The reference organisation: 07:00–16:00, 30 min unpaid break 11:30–12:00, overtime ×1.5; Saturday every hour
    /// ×1.5; Sunday every hour ×2 with its own unpaid break.
    private var policy: [String: Any] {
        [
            "standardDayStart": "07:00", "standardDayEnd": "16:00", "unpaidBreakMinutes": 30,
            "breakWindowStart": "11:30", "breakWindowEnd": "12:00", "weekdayOutsideStandardMultiplier": 1.5,
            "saturday": [
                "allHoursAtMultiplierMode": true, "allHoursMultiplier": 1.5, "definedWindowStart": "07:30",
                "definedWindowEnd": "14:00", "countsAsStandardHours": 8, "outsideWindowMultiplier": 2, "sameAsSaturday": false,
            ],
            "sunday": ["allHoursAtMultiplierMode": true, "allHoursMultiplier": 2, "sameAsSaturday": false, "breakPaid": false],
        ]
    }

    private func breakdown(
        _ days: [String], start: String?, end: String?, slot: String = "CUSTOM_HOURS",
        breakRemoved: Bool = false, rate: Double? = nil
    ) throws -> RulebookHoursBreakdown {
        let booking = CanonicalBusinessEngine.hoursBreakdownBooking(
            timeSlot: slot, start: start, end: end, isBreakRemoved: breakRemoved, otMultiplierOverride: rate
        )
        let answer = try XCTUnwrap(RulebookHoursBreakdown(json: CanonicalBusinessEngine.callJSON(
            "bookingHoursBreakdownDays", arguments: [policy, days, booking, zone]
        )))
        for group in answer.groups {
            let shown = group.rows.filter { $0.kind != "total" }.reduce(0.0) { $0 + $1.hours }
            XCTAssertEqual(shown, group.totalPaidHours, accuracy: 0.001, "Normal + Overtime = Total")
            XCTAssertEqual(group.normalPaidHours + group.overtimePaidHours, group.totalPaidHours, accuracy: 0.001)
            XCTAssertEqual(group.rows.last?.kind, "total")
            if let save = CanonicalBusinessEngine.saveHoursLabel(group.totalPaidHours) {
                XCTAssertTrue(save.contains(String(group.rows.last?.value.dropLast() ?? "")), save)
            }
        }
        return answer
    }

    private func view(_ group: RulebookHoursBreakdownGroup) -> [[String]] {
        group.rows.map { [$0.label] + $0.details + [$0.value] }
    }

    func testThePackedScriptExportsTheBreakdown() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 62, 0]), "rulebook \(stamp.version) predates 1.62.0")
        let names = Set(CanonicalBusinessEngine.exportNames())
        XCTAssertTrue(names.contains("bookingHoursBreakdownRows"))
        XCTAssertTrue(names.contains("bookingHoursBreakdownDays"))
    }

    func testReferenceWeekdayWithOvertime() throws {
        let answer = try breakdown([tuesday], start: "06:00", end: "17:30")
        XCTAssertEqual(answer.summary, "06:00–17:30 · 12.25 paid hours")
        let group = try XCTUnwrap(answer.groups.first)
        XCTAssertEqual(group.headerDetail, "Tuesday, full day")
        XCTAssertEqual(view(group), [
            ["Normal hours", "07:00–16:00, less 30 min break", "8.5h"],
            ["Overtime", "06:00–07:00 and 16:00–17:30", "2.5h at ×1.5", "3.75h"],
            ["Total paid hours", "12.25h"],
        ])
        XCTAssertEqual(group.rows[1].accessibilityLabel, "Overtime, 06:00 to 07:00 and 16:00 to 17:30, 2.5 hours at 1.5 times, 3.75 hours")
    }

    func testReferenceNoOvertimeBreakOffSaturdayAndOwnRate() throws {
        XCTAssertEqual(view(try XCTUnwrap(try breakdown([tuesday], start: "07:00", end: "16:00").groups.first)), [
            ["Normal hours", "07:00–16:00, less 30 min break", "8.5h"], ["Total paid hours", "8.5h"],
        ])
        XCTAssertEqual(view(try XCTUnwrap(try breakdown([tuesday], start: "06:00", end: "17:30", breakRemoved: true).groups.first)), [
            ["Normal hours", "07:00–16:00", "9h"],
            ["Overtime", "06:00–07:00 and 16:00–17:30", "2.5h at ×1.5", "3.75h"],
            ["Total paid hours", "12.75h"],
        ])
        let sat = try XCTUnwrap(try breakdown([saturday], start: "08:00", end: "13:00").groups.first)
        XCTAssertEqual(sat.headerDetail, "Saturday, every hour is overtime")
        XCTAssertEqual(view(sat), [["Overtime", "08:00–13:00", "5h at ×1.5", "7.5h"], ["Total paid hours", "7.5h"]])
        XCTAssertEqual(view(try XCTUnwrap(try breakdown([tuesday], start: "06:00", end: "17:30", rate: 2).groups.first)), [
            ["Normal hours", "07:00–16:00, less 30 min break", "8.5h"],
            ["Overtime", "06:00–07:00 and 16:00–17:30", "2.5h at ×2", "5h"],
            ["Total paid hours", "13.5h"],
        ])
    }

    func testBreakInMultipliedHoursHalfDayAndOvernight() throws {
        XCTAssertEqual(view(try XCTUnwrap(try breakdown([sunday], start: "07:30", end: "14:00").groups.first)), [
            ["Overtime", "07:30–14:00", "6.5h at ×2 − 0.5h break", "12.5h"], ["Total paid hours", "12.5h"],
        ])
        let am = try XCTUnwrap(try breakdown([tuesday], start: nil, end: nil, slot: "AM").groups.first)
        XCTAssertEqual(am.headerDetail, "Tuesday, half day (AM)")
        XCTAssertEqual(view(am), [["Normal hours", "07:00–11:30", "4.25h"], ["Total paid hours", "4.25h"]])
        XCTAssertEqual(view(try XCTUnwrap(try breakdown([tuesday], start: "22:00", end: "06:00").groups.first)), [
            ["Overtime", "22:00–06:00", "8h at ×1.5", "12h"], ["Total paid hours", "12h"],
        ])
    }

    func testDaysThatReadTheSameShareOneCard() throws {
        let same = try breakdown([wednesday, tuesday], start: "06:00", end: "17:30")
        XCTAssertEqual(same.groups.count, 1)
        XCTAssertEqual(same.groups.first?.headerDetail, "Tuesday/Wednesday, full day")
        let mixed = try breakdown([saturday, sunday], start: "08:00", end: "13:00")
        XCTAssertEqual(mixed.groups.count, 2)
        XCTAssertEqual(mixed.summaryHours, "paid hours vary by day")
    }
}
