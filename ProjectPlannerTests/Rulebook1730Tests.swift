//
//  Rulebook1730Tests.swift
//  ProjectPlannerTests
//
//  RULEBOOK 1.73.0 (owner 23 Nov): one qualification expiry rule (gap 1), "Half-day unbooked" (batch 3 item 3), the
//  Daily Overview weekend label (item 31) and Book labour for a manager with no level flag (gap 3). Swift only maps its
//  models into the packed script (`CanonicalBusinessEngine`) and reads the answer back.
//

import XCTest
@testable import Project_Planner

@MainActor
final class Rulebook1730Tests: XCTestCase {
    private let zone = "Europe/London"

    func testThePackedScriptIsRulebook1730OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 73, 0]), "rulebook \(stamp.version) predates 1.73.0")
    }

    // MARK: Gap 1 — qualification expiry

    private func operative(
        qualifications: [Qualification],
        expiry: [String: Date]
    ) -> Operative {
        var row = LogicFixtures.operative(id: UUID(), email: "ada@example.com")
        row.qualifications = Set(qualifications)
        row.qualificationExpiryDates = expiry
        return row
    }

    func testTheWarningsInputReadsTheExpiryUnderAnotherSpellingAndOnlyForAssignedQualifications() {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let row = operative(
            qualifications: [Qualification(id: "Q-CSCS", name: "CSCS")],
            expiry: ["q-cscs": date, "UNASSIGNED": date]
        )
        let expiries = row.rulebookAssignedQualificationExpiries
        XCTAssertEqual(expiries.count, 1)
        XCTAssertEqual(expiries.first?["qualificationId"] as? String, "Q-CSCS")
        let iso = expiries.first?["expiryIso"] as? String
        XCTAssertEqual(iso.flatMap { CanonicalBusinessEngine.date(fromIso: $0) }, date,
                       "milliseconds in, the same instant out (never read as seconds)")
        XCTAssertEqual((row.rulebookQualificationRow["expiries"] as? [[String: Any]])?.count, 1)
    }

    func testTheAssignmentEndDateIsNeverAnExpiryForTheWarnings() {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let row = operative(
            qualifications: [Qualification(id: "Q1", name: "IPAF", hasEndDate: true, endDate: date)],
            expiry: [:]
        )
        XCTAssertTrue(row.rulebookAssignedQualificationExpiries.isEmpty)
    }

    func testWithQualificationExpiryLeavesOneSpellingOfTheId() throws {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let later = Date(timeIntervalSince1970: 1_950_000_000)
        let map = try XCTUnwrap(CanonicalBusinessEngine.withQualificationExpiry(
            dates: ["q1": date, "Q2": date],
            qualificationId: "Q1",
            date: later
        ))
        XCTAssertEqual(map, ["Q1": later, "Q2": date])
        let cleared = try XCTUnwrap(CanonicalBusinessEngine.withQualificationExpiry(
            dates: ["q1": date, "Q2": date],
            qualificationId: "Q1",
            date: nil
        ))
        XCTAssertEqual(cleared, ["Q2": date])
    }

    func testPersonQualificationsReadsActiveRowsFirst() throws {
        let early = Date(timeIntervalSince1970: 1_900_000_000)
        let late = Date(timeIntervalSince1970: 1_950_000_000)
        var inactive = operative(qualifications: [Qualification(id: "Q1", name: "CSCS")], expiry: ["Q1": late])
        inactive.isActive = false
        inactive.firestoreDocumentId = "op-old"
        var active = operative(qualifications: [Qualification(id: "Q1", name: "CSCS")], expiry: ["Q1": early])
        active.firestoreDocumentId = "op-live"
        let rows = try XCTUnwrap(CanonicalBusinessEngine.personQualifications(rows: [inactive, active], preferredRowId: nil))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.expiry, early, "the warnings read active rows only, so the profile does too")
        XCTAssertEqual(rows.first?.operativeId, "op-live")
    }

    // MARK: Batch 3 item 3 — "Half-day unbooked"

    func testTheHalfDayCardTitleIsTheRulebookConstant() {
        XCTAssertEqual(CanonicalBusinessEngine.leaveCoverWarningTitle, "Half-day unbooked")
        XCTAssertEqual(CanonicalBusinessEngine.leaveClashWarningTitle, "Booked during annual leave")
    }

    // MARK: Item 31 — Daily Overview weekend label

    private func state(saturdayWindow: Bool) throws -> [String: Any] {
        var policy = OrgPayrollTimePolicy.default
        policy.saturday.allHoursAtMultiplierMode = !saturdayWindow
        policy.saturday.useCustomStandardDayWindow = saturdayWindow
        policy.saturday.customStandardStart = "07:30"
        policy.saturday.customStandardEnd = "14:00"
        let document: [String: Any] = ["payrollTimePolicy": policy.asFirestoreDictionary()]
        return try XCTUnwrap(CanonicalBusinessEngine.payrollPolicyState(document: document, todayKey: "2026-11-23", timeZone: zone))
    }

    func testASetWindowSaturdayReadsWeekendWindowHoursWithItsWindow() throws {
        let label = try XCTUnwrap(CanonicalBusinessEngine.dailyOverviewStandardHoursLabel(
            policyState: try state(saturdayWindow: true), dayKey: "2026-11-21", timeZone: zone
        ))
        XCTAssertEqual(label.label, "Weekend window hrs")
        XCTAssertEqual(label.hint, "07:30–14:00 counts as a full day")
    }

    func testWeekdaysEveryHourDaysAndUnloadedSettingsReadStandardHours() throws {
        let weekday = try XCTUnwrap(CanonicalBusinessEngine.dailyOverviewStandardHoursLabel(
            policyState: try state(saturdayWindow: true), dayKey: "2026-11-23", timeZone: zone
        ))
        XCTAssertEqual(weekday, RulebookStandardHoursLabel(label: "Standard hrs", hint: nil))
        let everyHour = try XCTUnwrap(CanonicalBusinessEngine.dailyOverviewStandardHoursLabel(
            policyState: try state(saturdayWindow: false), dayKey: "2026-11-21", timeZone: zone
        ))
        XCTAssertEqual(everyHour.label, "Standard hrs")
        XCTAssertNil(everyHour.hint)
        let unloaded = try XCTUnwrap(CanonicalBusinessEngine.dailyOverviewStandardHoursLabel(
            policyState: nil, dayKey: "2026-11-21", timeZone: zone
        ))
        XCTAssertEqual(unloaded, RulebookStandardHoursLabel(label: "Standard hrs", hint: nil))
        XCTAssertEqual(CanonicalBusinessEngine.dailyOverviewStandardHoursText, "Standard hrs")
    }

    // MARK: Gap 3 — Book labour for a manager with no level flag

    func testAManagerWithNoLevelFlagMayScheduleAndAnOperativeMayNot() {
        var noFlag = LogicFixtures.selfEmployedUser(id: "u-legacy", email: "legacy@example.com")
        noFlag.permissions.adminAccess = false
        noFlag.permissions.manager = false
        noFlag.permissions.operativeMode = false
        noFlag.role = .basic
        XCTAssertTrue(CanonicalBusinessEngine.canScheduleOperatives(noFlag.permissionSubject),
                      "a no-flag user is manager level (RULEBOOK §11 1.23.1) and gets Book labour")
        var operative = noFlag
        operative.permissions.operativeMode = true
        operative.role = .operative
        XCTAssertFalse(CanonicalBusinessEngine.canScheduleOperatives(operative.permissionSubject))
    }
}
