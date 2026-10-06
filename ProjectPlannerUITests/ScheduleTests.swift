import XCTest

final class ScheduleTests: PPUITestCase {
    private var schedule: ScheduleScreen { ScheduleScreen(test: self) }

    func test_SCH01_scheduleOperativeFullDay() {
        launch(role: "manager")
        assertSignedInHome(role: "manager")
        tap(PPID.homeQuickAction("staff-schedule"))
        schedule.assertVisible()
        schedule.bookFullDay()
        schedule.assertVisible()
    }

    func test_SCH02_partDayBooking() {
        launch(role: "manager")
        assertSignedInHome(role: "manager")
        tap(PPID.homeQuickAction("staff-schedule"))
        schedule.bookPartDay()
        schedule.assertVisible()
    }

    func test_SCH03_operativeSeesMySchedule() {
        launch(role: "operative")
        assertSignedInHome(role: "operative")
        tap(PPID.homeQuickAction("op-schedule"))
        schedule.assertVisible()
    }

    func test_SCH04_dailyOverviewAndWeeklyReportOpen() {
        launch(role: "admin")
        assertSignedInHome(role: "admin")
        exerciseIfPresent(PPButton(id: PPID.homeQuickAction("staff-daily"), kind: .destination(PPID.dailyOverview)))
        exerciseIfPresent(PPButton(id: PPID.homeQuickAction("staff-weekly"), kind: .destination(PPID.weeklyReport)))
        let daily = element(PPID.homeQuickAction("staff-daily"))
        let weekly = element(PPID.homeQuickAction("staff-weekly"))
        if !daily.exists && !weekly.exists {
            XCTFail("GAP: neither daily overview nor weekly report is on Home. Those tiles follow permissions.dailyOverview and permissions.weeklyReports.")
        }
    }
}
