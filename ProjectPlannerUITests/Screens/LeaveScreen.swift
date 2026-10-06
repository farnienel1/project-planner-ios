import Foundation

struct LeaveScreen {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.leave, timeout: 8) }

    func requestLeave() {
        test.tap(PPID.leaveRequest)
        test.tap(PPID.leaveStart)
        test.tap(PPID.leaveEnd)
        test.tap(PPID.leaveSubmit)
    }

    func approveFirstPending() {
        test.tap(PPID.leavePendingRow)
        test.tap(PPID.leaveApprove)
    }
}
