import XCTest

final class TimesheetsTests: PPUITestCase {
    private var timesheets: TimesheetsScreen { TimesheetsScreen(test: self) }

    func test_TS01_operativeSubmitsTimesheet() {
        launch(role: "operative", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "operative")
        openMore()
        MoreSheet(test: self).tapRow("invoicing")
        timesheets.assertVisible()
        timesheets.submitHours("8")
        timesheets.assertStatusContains("submit")
    }

    func test_TS04_managerApprovesOperativeTimesheet() {
        launch(role: "operative", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "operative")
        openMore()
        MoreSheet(test: self).tapRow("invoicing")
        timesheets.submitHours("7.5")
        relaunch(role: "manager", resetState: false, extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "manager")
        openMore()
        MoreSheet(test: self).tapRow("invoicing")
        timesheets.approveFirstPending()
        relaunch(role: "operative", resetState: false, extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "operative")
        openMore()
        MoreSheet(test: self).tapRow("invoicing")
        timesheets.assertStatusContains("approv")
    }

    func test_TS02_managerRejectsTimesheet() {
        launch(role: "manager", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "manager")
        openMore()
        MoreSheet(test: self).tapRow("invoicing")
        timesheets.assertVisible()
        tap(PPID.timesheetsPendingRow)
        tap(PPID.timesheetsReject)
        timesheets.assertStatusContains("reject")
    }

    func test_TS03_approvedTimesheetIsNotEditable() {
        launch(role: "operative", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "operative")
        openMore()
        MoreSheet(test: self).tapRow("invoicing")
        tap("timesheets.row.approved")
        assertNotExists(PPID.timesheetsSubmit)
    }
}
