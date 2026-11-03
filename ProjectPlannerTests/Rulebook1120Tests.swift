import XCTest
@testable import Project_Planner

/// RULEBOOK 1.12.0 / 1.12.1 behaviour on iOS, each case taken from web `lib/canonical/canonical.test.ts`
/// ("1.12.0 …" tests) and run through `CanonicalBusinessEngine`.
@MainActor
final class Rulebook1120Tests: XCTestCase {
    // MARK: Leave year (§4.4)

    func testTheLeaveYearIsTwelveMonthsAndAMismatchIsRefused() {
        XCTAssertEqual(CanonicalBusinessEngine.leaveYearEndMonth(startMonth: 1), 12)
        XCTAssertEqual(CanonicalBusinessEngine.leaveYearEndMonth(startMonth: 4), 3)
        XCTAssertEqual(CanonicalBusinessEngine.leaveYearStartMonth(endingIn: 3), 4)
        XCTAssertEqual(CanonicalBusinessEngine.leaveYearStartMonth(endingIn: 12), 1)
        XCTAssertNil(CanonicalBusinessEngine.leaveYearMonthsError(startMonth: 4, endMonth: 3))
        XCTAssertNil(CanonicalBusinessEngine.leaveYearMonthsError(startMonth: 1, endMonth: 12))
        let message = CanonicalBusinessEngine.leaveYearMonthsMessage
        XCTAssertNotNil(message)
        XCTAssertEqual(CanonicalBusinessEngine.leaveYearMonthsError(startMonth: 4, endMonth: 12), message)
        XCTAssertEqual(CanonicalBusinessEngine.leaveYearMonthsError(startMonth: 1, endMonth: 1), message)
        XCTAssertNil(CanonicalBusinessEngine.annualLeaveDefaultsError(startMonth: 4, endMonth: 3))
        XCTAssertNotNil(CanonicalBusinessEngine.annualLeaveDefaultsError(startMonth: 13, endMonth: 12))
    }

    // MARK: Invitations (§11, §16)

    func testOnlyAnOperativeOnlyInvitationPassesForAManagerInviter() throws {
        XCTAssertEqual(CanonicalBusinessEngine.invitationIsOperativeOnly(
            ["role": "operative", "permissions": ["operativeMode": true, "siteAudit": true, "projects": true]]
        ), true)
        XCTAssertEqual(CanonicalBusinessEngine.invitationIsOperativeOnly(["permissions": ["operativeMode": true]]), true)
        XCTAssertEqual(CanonicalBusinessEngine.invitationIsOperativeOnly(
            ["role": "admin", "permissions": ["adminAccess": true]]
        ), false)
        XCTAssertEqual(CanonicalBusinessEngine.invitationIsOperativeOnly(
            ["permissions": ["adminAccess": true, "operativeMode": true]]
        ), false)
        XCTAssertEqual(CanonicalBusinessEngine.invitationIsOperativeOnly(
            ["role": "operative", "permissions": ["operativeMode": true, "operatives": true]]
        ), false)
        XCTAssertEqual(CanonicalBusinessEngine.invitationIsOperativeOnly(
            ["role": "manager", "permissions": ["manager": true]]
        ), false)

        let managerInvite: [String: Any] = ["role": "manager", "permissions": ["manager": true]]
        XCTAssertThrowsError(try InvitationDocument.requireAllowed(managerInvite, inviterIsAdmin: false))
        XCTAssertNoThrow(try InvitationDocument.requireAllowed(managerInvite, inviterIsAdmin: true))
        XCTAssertNoThrow(try InvitationDocument.requireAllowed(managerInvite, inviterIsAdmin: nil), "unknown inviter: the rules decide")
        XCTAssertNoThrow(try InvitationDocument.requireAllowed(
            ["role": "operative", "permissions": ["operativeMode": true]],
            inviterIsAdmin: false
        ))
    }

    // MARK: Unpaid break (§8)

    private func paidHours(_ start: String, _ end: String) throws -> Double {
        let day = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: "2026-11-04"))
        let booking = LogicFixtures.booking(on: day, slot: .customHours, start: start, end: end)
        return PayrollHoursEngine.compute(booking: booking, day: day, policy: .default).totalPaidHours
    }

    func testOnlyTheCoveredPartOfTheBreakComesOffAndABookingInsideItPaysNothing() throws {
        XCTAssertEqual(try paidHours("12:00", "12:30"), 0, accuracy: 1e-9)
        XCTAssertEqual(try paidHours("12:05", "12:25"), 0, accuracy: 1e-9)
        XCTAssertEqual(try paidHours("11:50", "12:20"), 10.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(try paidHours("11:00", "12:10"), 1, accuracy: 1e-9)
        XCTAssertEqual(try paidHours("07:30", "16:00"), 8, accuracy: 1e-9)
    }

    // MARK: Pay guard (§4.3)

    func testADayRateWithAPaidDayBelowOneHourPaysNothing() {
        let day = ResolvedPayrollRate(basis: .dayRate, dayRate: 200, hourlyRate: nil)
        XCTAssertEqual(day.payForHours(8, standardDayHours: 0), 0)
        XCTAssertEqual(day.payForHours(8, standardDayHours: 8), 200, accuracy: 1e-9)
        let hourly = ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: 20)
        XCTAssertEqual(hourly.payForHours(8, standardDayHours: 0), 160, accuracy: 1e-9)
    }

    // MARK: Day keys east of UTC+12 (§1)

    func testANewZealandLeaveWeekCountsItsOwnDays() {
        let week = CanonicalBusinessEngine.callJSON(
            "leaveRecordDayKeys",
            arguments: [["startDayKey": "2026-11-09", "endDayKey": "2026-11-13"], "Pacific/Auckland"]
        ) as? [String]
        XCTAssertEqual(week, ["2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13"])
        let weekend = CanonicalBusinessEngine.callJSON(
            "leaveRecordDayKeys",
            arguments: [["startDayKey": "2026-11-06", "endDayKey": "2026-11-09"], "Pacific/Auckland"]
        ) as? [String]
        XCTAssertEqual(weekend, ["2026-11-06", "2026-11-09"])
    }
}
