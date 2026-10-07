import XCTest

final class PermissionsTests: PPUITestCase {
    func test_PERM01_operativeCannotSeeStaffOnlySurfaces() {
        launch(role: "operative", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "operative")
        for id in RoleSurfaces.hiddenIdentifiers(role: "operative") where id.hasPrefix("home.") || id.hasPrefix("tab.") {
            assertNotExists(id)
        }
        openMainMenu()
        for id in RoleSurfaces.hiddenIdentifiers(role: "operative") where id.hasPrefix("mainMenu.") {
            assertNotExists(id)
        }
        MainMenuSheet(test: self).close()
        openMore()
        for id in RoleSurfaces.hiddenIdentifiers(role: "operative") where id.hasPrefix("more.") {
            assertNotExists(id)
        }
        MoreSheet(test: self).close()
        tap(PPID.homeQuickAction("op-settings"))
        assertExists(PPID.settings)
        assertNotExists(PPID.settingsOrganisationHub)
        assertNotExists(PPID.settingsPaymentRuns)
    }

    func test_PERM02_managerCannotSeeAdminOnlySurfaces() {
        launch(role: "manager", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "manager")
        assertNotExists(PPID.homeQuickAction("staff-managers"))
        assertNotExists(PPID.homeQuickAction("staff-map"))
        assertNotExists(PPID.homeOverviewSettings)
        openMainMenu()
        for id in RoleSurfaces.hiddenIdentifiers(role: "manager") where id.hasPrefix("mainMenu.") {
            assertNotExists(id)
        }
        MainMenuSheet(test: self).close()
        openTab("Settings")
        assertExists(PPID.settings)
        assertNotExists(PPID.settingsOrganisationHub)
        assertNotExists(PPID.settingsPaymentRuns)
    }

    func test_PERM03_adminSeesOrganisationAndUserManagement() {
        launch(role: "admin", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "admin")
        openMainMenu()
        assertExists(PPID.mainMenuRow("add_user"))
        assertExists(PPID.mainMenuRow("manage_users"))
        assertExists(PPID.mainMenuRow("managers"))
        assertExists(PPID.mainMenuRow("job_types"))
        assertExists(PPID.mainMenuRow("site_map"))
        MainMenuSheet(test: self).close()
        openTab("Settings")
        assertExists(PPID.settingsOrganisationHub)
    }
}
