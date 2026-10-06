import XCTest

final class SiteAuditTests: PPUITestCase {
    private var audit: SiteAuditScreen { SiteAuditScreen(test: self) }

    func test_AUD01_startAuditAddNoteSave() {
        launch(role: "manager", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "manager")
        openMainMenu()
        MainMenuSheet(test: self).tapRow("site_audit")
        audit.assertVisible()
        audit.startAndSaveNote()
        audit.assertVisible()
    }

    func test_AUD02_siteMapOpensForAdmin() {
        launch(role: "admin", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "admin")
        openMainMenu()
        MainMenuSheet(test: self).tapRow("site_map")
        assertExists(PPID.siteMap)
    }

    func test_AUD03_operativeSiteAuditWhenEnabled() {
        launch(role: "operative", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "operative")
        exerciseIfPresent(PPButton(id: PPID.homeQuickAction("op-audit"), kind: .destination(PPID.siteAudit)))
        let tile = element(PPID.homeQuickAction("op-audit"))
        if !tile.exists {
            XCTFail("GAP: operative site audit tile is hidden. It follows permissions.siteAudit.")
        }
    }
}
