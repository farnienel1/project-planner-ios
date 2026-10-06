import Foundation

struct MoreSheet {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.more) }

    func close() { test.tap(PPID.moreClose) }

    func tapRow(_ id: String) {
        if id == "sign_out" {
            test.tap("mainMenu.signOut")
            return
        }
        test.scrollTo(PPID.moreRow(id))
        test.tap(PPID.moreRow(id))
    }
}
