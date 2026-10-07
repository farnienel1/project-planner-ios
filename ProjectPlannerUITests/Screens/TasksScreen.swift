import Foundation

struct TasksScreen {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.tasks, timeout: 8) }

    func create(title: String) {
        test.tap(PPID.tasksAdd)
        test.type(PPID.tasksTitle, title)
        test.tap(PPID.tasksDueDate)
        test.tap(PPID.tasksAssignee)
        test.tap(PPID.tasksSave)
    }

    func completeFirst() { test.tap(PPID.tasksComplete) }
}
