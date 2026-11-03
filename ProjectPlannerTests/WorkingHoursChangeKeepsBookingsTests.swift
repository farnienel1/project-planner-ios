import XCTest
@testable import Project_Planner

/// RULEBOOK 1.13.1 §4.3 / §8: a working-hours change writes the policy only. Stored bookings are never rewritten; each
/// is paid by `CanonicalBusinessEngine` `payrollHoursResult` at the rules in effect on its day. iOS used to rewrite every
/// booking on the effective day (`PayrollPolicyBookingRecalibrator`, with a Swift-side weekend window
/// `defaultWeekendBookingChoice`); web has no such rewrite and the rulebook has no function for one. This source scan
/// keeps that code from coming back (ported from branch `claude/inspiring-davinci-ovb8ih`, replacing PR #154).
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
}
