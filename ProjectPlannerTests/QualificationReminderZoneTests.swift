//
//  QualificationReminderZoneTests.swift
//  ProjectPlannerTests
//
//  Owner C13 (23 Nov), RULEBOOK §1 (one business time zone): local qualification expiry reminders — 3 months,
//  1 month, 1 week and 1 day before, at 09:00 — are worked out on the organisation's day and fire at 09:00
//  organisation time, never the phone's zone. The expiry day comes from the packed script
//  (`dayKeyInOrganizationZone`).
//

import XCTest
@testable import Project_Planner

@MainActor
final class QualificationReminderZoneTests: XCTestCase {
    private func instant(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func schedule(_ expiryIso: String, now: String = "2026-01-01T00:00:00Z", zone: String) -> [String: Date] {
        let fires = NotificationService.qualificationReminderSchedule(
            expiry: instant(expiryIso), now: instant(now), timeZoneIdentifier: zone
        )
        return Dictionary(uniqueKeysWithValues: fires.map { ($0.suffix, $0.fireAt) })
    }

    func testLondonRemindersFireAtNineLondonTimeOnTheRightDays() {
        // 15 Mar 2027 is GMT; 15 Dec 2026 GMT; 15 Feb, 8 Mar and 14 Mar GMT.
        let fires = schedule("2027-03-15T00:00:00Z", zone: "Europe/London")
        XCTAssertEqual(fires["3m"], instant("2026-12-15T09:00:00Z"))
        XCTAssertEqual(fires["1m"], instant("2027-02-15T09:00:00Z"))
        XCTAssertEqual(fires["1w"], instant("2027-03-08T09:00:00Z"))
        XCTAssertEqual(fires["1d"], instant("2027-03-14T09:00:00Z"))
    }

    func testTheExpiryDayIsTheOrganisationDayNotUTCOrThePhone() {
        // 23:30 UTC on 30 Jun is 00:30 BST on 1 Jul in London: the expiry day is 1 Jul, so "1 day before" is
        // 30 Jun at 09:00 BST (08:00 UTC).
        let fires = schedule("2027-06-30T23:30:00Z", zone: "Europe/London")
        XCTAssertEqual(fires["1d"], instant("2027-06-30T08:00:00Z"))
        XCTAssertEqual(fires["1w"], instant("2027-06-24T08:00:00Z"))
    }

    func testAnAucklandOrganisationUsesAucklandNineAM() {
        // 11:00 UTC on 10 Jan is 00:00 NZDT on 11 Jan: "1 day before" is 10 Jan at 09:00 NZDT = 9 Jan 20:00 UTC.
        let fires = schedule("2027-01-10T11:00:00Z", zone: "Pacific/Auckland")
        XCTAssertEqual(fires["1d"], instant("2027-01-09T20:00:00Z"))
        XCTAssertEqual(fires["1m"], instant("2026-12-10T20:00:00Z"))
    }

    func testRemindersAlreadyPastAreLeftOut() {
        let fires = schedule("2027-03-15T00:00:00Z", now: "2027-03-10T00:00:00Z", zone: "Europe/London")
        XCTAssertEqual(Set(fires.keys), ["1d"])
        XCTAssertTrue(schedule("2027-03-15T00:00:00Z", now: "2027-03-15T00:00:00Z", zone: "Europe/London").isEmpty)
    }

    func testTheExpiryTextShowsTheOrganisationDay() {
        let expiry = instant("2027-06-30T23:30:00Z")
        let london = NotificationService.qualificationExpiryDateText(expiry, timeZoneIdentifier: "Europe/London")
        let newYork = NotificationService.qualificationExpiryDateText(expiry, timeZoneIdentifier: "America/New_York")
        XCTAssertNotEqual(london, newYork, "1 Jul in London is 30 Jun in New York")
    }

    func testTheSchedulerNoLongerUsesThePhoneCalendar() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project Planner/Core/NotificationService.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(source.contains("Calendar.current"), "qualification reminders must use the organisation zone")
        XCTAssertTrue(source.contains("qualificationReminderSchedule(expiry: item.expiry"))
    }
}
