import XCTest

/// iPhone 1.31 + 1.32 test session, Part A (docs/test-sessions/1.31-1.32.md), run on seeded TEST data with no
/// Firebase. Each check asserts what it can by accessibility identifier and always keeps a screenshot, so the
/// result can be reviewed without opening the app. Run by `.github/workflows/screen-checks.yml`.
final class Release1320ScreenChecksTests: PPUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = true
    }

    // MARK: Helpers

    private func start(_ role: String, dark: Bool = false) {
        var extra = ["-seedDemoData"]
        if dark { extra.append(contentsOf: ["-AppleInterfaceStyle", "Dark"]) }
        launch(role: role, extraArguments: extra)
        assertSignedInHome(role: role)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openSettings(role: String) {
        if role == "operative" {
            tap(PPID.homeQuickAction("op-settings"))
        } else {
            openTab("Settings")
        }
        SettingsScreen(test: self).assertVisible()
    }

    private func assertRulesVersion(role: String) {
        openSettings(role: role)
        scrollTo("settings.rulesVersion", timeout: 15)
        let label = element("settings.rulesVersion")
        XCTAssertTrue(label.label.contains("1.32.1"), "A1/A2: Settings shows '\(label.label)', expected 'Rules 1.32.1'")
        shot("A\(role == "operative" ? 2 : 1) \(role) Settings rules version")
    }

    // MARK: Admin

    func test_A01_adminSettingsShowsRulesVersion() {
        start("admin")
        assertRulesVersion(role: "admin")
    }

    func test_A03_adminSettingsShowsPayePaydayBanner() {
        start("admin")
        openSettings(role: "admin")
        scrollTo("settings.payePaydayBanner", timeout: 10)
        shot("A3 admin Settings payday banner")
        element("settings.payePaydayBanner").tap()
        scrollTo("payePayday.picker", timeout: 10)
        XCTAssertTrue(element("payePayday.picker").exists, "A3: the payday banner did not open Payment runs & timesheets")
        shot("A3 admin banner opens Payment runs")
    }

    func test_A04_adminPaydayPickIsAnUnsavedChange() {
        start("admin")
        openSettings(role: "admin")
        SettingsScreen(test: self).openOrganisationHub()
        SettingsScreen(test: self).openPaymentRuns()
        scrollTo("payePayday.picker", timeout: 10)
        shot("A4 admin payday picker before")
        element("payePayday.picker").tap()
        let day25 = app.buttons["Day 25"].firstMatch
        if day25.waitForExistence(timeout: 3) {
            day25.tap()
        } else {
            XCTFail("A4: the payday picker did not offer 'Day 25'")
        }
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Press Save")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 3), "A4: no 'Press Save to apply it…' line after picking a day")
        shot("A4 admin payday picked, not saved")
    }

    func test_A05_adminOvertimeHubShowsPaydayBanner() {
        start("admin")
        openMore()
        MoreSheet(test: self).tapRow("invoicing")
        let tile = element("invoicing.overtime")
        let card = element("invoicing.overtimeCard")
        if tile.waitForExistence(timeout: 5) {
            tile.tap()
        } else if card.waitForExistence(timeout: 3) {
            card.tap()
        } else {
            XCTFail("A5: no Overtime, Expenses & Price Work entry on Timesheets")
        }
        assertExists("overtime.hub.payePaydayBanner", timeout: 8)
        shot("A5 admin Overtime hub payday banner")
    }

    func test_A06_adminHomeHasWeeklyReport() {
        start("admin")
        let tile = element(PPID.homeQuickAction("staff-weekly"))
        XCTAssertTrue(tile.waitForExistence(timeout: 6), "A6: admin Home has no Weekly report tile")
        shot("A6 admin Home quick actions")
    }

    func test_A15_adminDarkMode() {
        start("admin", dark: true)
        shot("A15 admin Home dark")
        openSettings(role: "admin")
        shot("A15 admin Settings dark")
        scrollTo("settings.rulesVersion", timeout: 15)
        shot("A15 admin Settings bottom dark")
    }

    // MARK: Manager

    func test_A07_managerHomeHasNoWeeklyReport() {
        start("manager")
        assertNotExists(PPID.homeQuickAction("staff-weekly"))
        shot("A7 manager Home quick actions")
    }

    func test_A07b_managerSettingsShowsRulesVersion() {
        start("manager")
        assertRulesVersion(role: "manager")
    }

    // MARK: Operative

    func test_A02_operativeSettingsShowsRulesVersion() {
        start("operative")
        assertRulesVersion(role: "operative")
    }
}
