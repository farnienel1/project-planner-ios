import Foundation

struct MainMenuSheet {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.mainMenu) }

    func close() { test.tap(PPID.mainMenuDone) }

    func tapRow(_ id: String) {
        test.scrollTo(PPID.mainMenuRow(id))
        test.tap(PPID.mainMenuRow(id))
    }
}
