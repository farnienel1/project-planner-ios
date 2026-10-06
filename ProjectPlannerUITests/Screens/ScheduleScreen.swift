import Foundation

struct ScheduleScreen {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.schedule, timeout: 8) }

    func bookFullDay() {
        test.tap(PPID.scheduleAdd)
        test.tap(PPID.scheduleOperative)
        test.tap(PPID.scheduleProject)
        test.tap(PPID.scheduleFullDay)
        test.tap(PPID.scheduleSave)
    }

    func bookPartDay() {
        test.tap(PPID.scheduleAdd)
        test.tap(PPID.scheduleOperative)
        test.tap(PPID.scheduleProject)
        test.tap(PPID.schedulePartDay)
        test.tap(PPID.scheduleSave)
    }
}
