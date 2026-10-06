import XCTest

final class SettingsTests: PPUITestCase {
    private var settings: SettingsScreen { SettingsScreen(test: self) }

    func test_SET01_adminOpensOrganisationSettings() {
        launch(role: "admin", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "admin")
        openTab("Settings")
        settings.assertVisible()
        settings.openOrganisationHub()
        settings.openWorkingHours()
        assertExists(PPID.settingsWorkingHours)
        goBack()
        settings.openAnnualLeave()
        assertExists(PPID.settingsAnnualLeave)
        goBack()
        settings.openScheduleOptions()
        assertExists(PPID.settingsScheduleOptions)
        goBack()
        settings.openWarnings()
        assertExists(PPID.settingsWarnings)
        goBack()
        settings.openPaymentRuns()
        assertExists(PPID.settingsPaymentRuns)
    }

    func test_SET02_helpShowsSupportEmail() {
        launch(role: "admin", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "admin")
        openMainMenu()
        MainMenuSheet(test: self).tapRow("help")
        assertExists(PPID.help)
        let identified = element(PPID.helpSupportEmail)
        let visible = app.staticTexts["info@projectplanner.us"]
        let shown = identified.waitForExistence(timeout: 2) || visible.waitForExistence(timeout: 2)
        XCTAssertTrue(shown, "Help & support does not show info@projectplanner.us")
    }

    func test_SET03_operativeSettingsHideOrganisationHub() {
        launch(role: "operative", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "operative")
        tap(PPID.homeQuickAction("op-settings"))
        settings.assertVisible()
        assertNotExists(PPID.settingsOrganisationHub)
        assertNotExists(PPID.settingsPaymentRuns)
    }
}
