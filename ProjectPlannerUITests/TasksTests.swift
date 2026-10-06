import XCTest

final class TasksTests: PPUITestCase {
    private var tasks: TasksScreen { TasksScreen(test: self) }

    func test_TASK01_createAndCompleteTask() {
        launch(role: "manager")
        assertSignedInHome(role: "manager")
        tap(PPID.homeQuickAction("staff-tasks"))
        tasks.assertVisible()
        let title = "TEST-Task \(Int(Date().timeIntervalSince1970) % 100000)"
        tasks.create(title: title)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        tasks.completeFirst()
    }

    func test_TASK02_dueTodayOpensFilteredList() {
        launch(role: "admin")
        assertSignedInHome(role: "admin")
        tap(PPID.homeTasksDueToday)
        tasks.assertVisible()
    }
}
