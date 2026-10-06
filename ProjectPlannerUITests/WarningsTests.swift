import XCTest

final class WarningsTests: PPUITestCase {
    private var warnings: WarningsScreen { WarningsScreen(test: self) }

    func test_WARN01_managerIssuesWarning() {
        launch(role: "manager", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "manager")
        tap(PPID.homeWarnings)
        warnings.assertVisible()
        warnings.issueToFirstOperative()
        assertExists(PPID.warnings)
    }

    func test_WARN02_operativeSeesWarning() {
        launch(role: "operative", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "operative")
        tap(PPID.homeWarnings)
        warnings.assertVisible()
    }

    func test_WARN03_operativeCannotIssueWarning() {
        launch(role: "operative", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "operative")
        assertNotExists(PPID.warningsAdd)
        assertNotExists(PPID.warningsIssue)
    }
}
