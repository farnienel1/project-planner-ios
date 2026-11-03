import XCTest
@testable import Project_Planner

/// RULEBOOK 1.13.1 §4.3 / §8: a working-hours change writes the policy only. Stored bookings are never rewritten;
/// each is paid by `payrollHoursResult` at the rules in effect on its day. iOS used to rewrite every booking on the
/// effective day (`PayrollPolicyBookingRecalibrator`, with a Swift-side weekend window `defaultWeekendBookingChoice`);
/// web has no such rewrite and the rulebook has no function for one.
/// Expected hours were checked in node against the packed `canonical-business.js`.
@MainActor
final class WorkingHoursChangeKeepsBookingsTests: XCTestCase {
    private var appSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project Planner")
    }

    private func appSwiftSources() throws -> [(name: String, text: String)] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appSourceRoot, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    func testNoSwiftRewritesBookingsOnAWorkingHoursChange() throws {
        let sources = try appSwiftSources()
        XCTAssertFalse(sources.isEmpty, "app sources not found at \(appSourceRoot.path)")
        for file in sources {
            XCTAssertFalse(file.text.contains("PayrollPolicyBookingRecalibrator"), "\(file.name) rewrites bookings on a policy change")
            XCTAssertFalse(file.text.contains("defaultWeekendBookingChoice"), "\(file.name) keeps a Swift weekend window; use customHoursPrefill")
        }
        let workingHours = try XCTUnwrap(sources.first { $0.name == "OrganisationWorkingHoursView.swift" })
        XCTAssertFalse(workingHours.text.contains("updateBooking("), "Working hours must not write bookings")
        XCTAssertFalse(workingHours.text.contains("saveBooking("), "Working hours must not write manager bookings")
    }

    func testAStoredWeekendFullDayAndHalfDayArePaidAtTheNewRulesWithoutARewrite() throws {
        let saturday = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: "2026-11-07"))
        let fullDay = LogicFixtures.booking(on: saturday, slot: .fullDay)
        let morning = LogicFixtures.booking(on: saturday, slot: .morning)
        let storedFullDay = fullDay
        let storedMorning = morning

        let prior = OrgPayrollTimePolicy.default
        var next = prior
        next.saturday.countsAsHours = 6

        // Set-window Saturday: a stored FULL DAY pays the window at its "counts as" hours, an AM half of them.
        XCTAssertEqual(PayrollHoursEngine.compute(booking: fullDay, day: saturday, policy: prior).totalPaidHours, 8, accuracy: 1e-9)
        XCTAssertEqual(PayrollHoursEngine.compute(booking: morning, day: saturday, policy: prior).totalPaidHours, 4, accuracy: 1e-9)
        XCTAssertEqual(PayrollHoursEngine.compute(booking: fullDay, day: saturday, policy: next).totalPaidHours, 6, accuracy: 1e-9)
        XCTAssertEqual(PayrollHoursEngine.compute(booking: morning, day: saturday, policy: next).totalPaidHours, 3, accuracy: 1e-9)

        // The rows keep their stored slot and (absent) clock times.
        XCTAssertEqual(fullDay, storedFullDay)
        XCTAssertEqual(morning, storedMorning)
        XCTAssertEqual(fullDay.timeSlot, .fullDay)
        XCTAssertNil(fullDay.workStartTime)
        XCTAssertEqual(morning.timeSlot, .morning)
    }

    func testANewWeekendBookingPrefillsFromTheRulebook() throws {
        let saturday = try XCTUnwrap(CanonicalBusinessEngine.date(fromDayKey: "2026-11-07"))
        let choice = OperativeDayBookingChoice.weekendCustomHours(on: saturday, policy: .default)
        let prefill = CanonicalBusinessEngine.customHoursPrefill(on: saturday, policy: .default)
        XCTAssertEqual(choice.timeSlot, .customHours)
        XCTAssertEqual(choice.workStartTime, prefill.start)
        XCTAssertEqual(choice.workEndTime, prefill.end)
        XCTAssertEqual(prefill.start, "07:30")
        XCTAssertEqual(prefill.end, "13:00")
    }
}
