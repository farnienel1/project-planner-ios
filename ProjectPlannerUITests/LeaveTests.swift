import XCTest

final class LeaveTests: PPUITestCase {
    private var leave: LeaveScreen { LeaveScreen(test: self) }

    func test_LV01_operativeRequestsLeave() {
        launch(role: "operative", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "operative")
        tap(PPID.homeQuickAction("op-leave"))
        leave.assertVisible()
        leave.requestLeave()
        assertExists(PPID.leaveStatus)
    }

    func test_LV04_managerApprovesLeave() {
        launch(role: "operative", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "operative")
        tap(PPID.homeQuickAction("op-leave"))
        leave.requestLeave()
        relaunch(role: "manager", resetState: false, extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "manager")
        tap(PPID.homeQuickAction("staff-leave"))
        leave.approveFirstPending()
        relaunch(role: "operative", resetState: false, extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "operative")
        tap(PPID.homeQuickAction("op-leave"))
        let status = waitFor(PPID.leaveStatus).label
        XCTAssertTrue(status.localizedCaseInsensitiveContains("approv"), "Leave status was '\(status)'")
    }

    func test_LV02_balanceShown() {
        launch(role: "operative", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "operative")
        tap(PPID.homeQuickAction("op-leave"))
        assertExists(PPID.leaveBalance)
    }

    func test_LV03_managerRejectsLeave() {
        launch(role: "manager", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "manager")
        tap(PPID.homeQuickAction("staff-leave"))
        tap(PPID.leavePendingRow)
        tap(PPID.leaveReject)
        assertExists(PPID.leaveStatus)
    }
}
