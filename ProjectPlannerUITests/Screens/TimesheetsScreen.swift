import XCTest

struct TimesheetsScreen {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.timesheets, timeout: 8) }

    func submitHours(_ hours: String) {
        test.tap(PPID.timesheetsAdd)
        test.type(PPID.timesheetsHours, hours)
        test.tap(PPID.timesheetsSubmit)
    }

    func approveFirstPending() {
        test.tap(PPID.timesheetsPendingRow)
        test.tap(PPID.timesheetsApprove)
    }

    func assertStatusContains(_ text: String) {
        let label = test.waitFor(PPID.timesheetsStatus).label
        XCTAssertTrue(label.localizedCaseInsensitiveContains(text), "Timesheet status was '\(label)'")
    }
}
