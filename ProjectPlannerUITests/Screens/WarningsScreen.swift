import Foundation

struct WarningsScreen {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.warnings, timeout: 8) }

    func issueToFirstOperative() {
        test.tap(PPID.warningsAdd)
        test.tap(PPID.warningsOperative)
        test.tap(PPID.warningsType)
        test.tap(PPID.warningsIssue)
    }
}
