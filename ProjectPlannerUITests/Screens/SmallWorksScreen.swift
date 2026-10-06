import Foundation

struct SmallWorksScreen {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.smallWorks, timeout: 8) }

    func startCreate() { test.tap(PPID.smallWorksAdd) }

    func fillRequired(reference: String, site: String) {
        test.type(PPID.smallWorksReference, reference)
        test.type(PPID.smallWorksSiteName, site)
    }

    func save() { test.tap(PPID.smallWorksSave) }

    func openStatus() { test.tap(PPID.smallWorksStatus) }
}
