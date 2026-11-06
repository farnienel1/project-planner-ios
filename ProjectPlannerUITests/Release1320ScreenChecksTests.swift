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

    /// More → a row by its title. The tab bar is customisable, so Settings and Timesheets are reached from the More
    /// sheet, which every role has. Its rows all carry `mainMenu.moreRow`, so the row is told apart by its label.
    private func openMenuRow(title: String) {
        openMore()
        let row = app.buttons
            .matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "mainMenu.moreRow", title))
            .firstMatch
        let deadline = Date().addingTimeInterval(10)
        while !(row.exists && row.isHittable) && Date() < deadline {
            app.swipeUp()
        }
        XCTAssertTrue(row.exists, "More has no '\(title)' row")
        if row.exists { row.tap() }
    }

    private func openSettings(role: String) {
        openMenuRow(title: "Settings")
        let shown = element("settings.back").waitForExistence(timeout: 8)
            || element("settings.rulesVersion").waitForExistence(timeout: 2)
            || element("settings.personFill").waitForExistence(timeout: 2)
        XCTAssertTrue(shown, "Settings did not open for \(role)")
    }

    /// Settings → the PAYE payday banner → Payment runs & timesheets (admins, org with no payday set).
    private func openPaymentRunsFromBanner() {
        openSettings(role: "admin")
        scrollTo("settings.payePaydayBanner", timeout: 10)
        element("settings.payePaydayBanner").tap()
    }

    private func assertRulesVersion(role: String) {
        openSettings(role: role)
        scrollTo("settings.rulesVersion", timeout: 15)
        let label = element("settings.rulesVersion")
        // The exact version is RulebookParityTests' job (stamp == docs/RULEBOOK.md); here: the line shows "Rules x.y.z".
        XCTAssertNotNil(
            label.label.range(of: #"^Rules \d+\.\d+\.\d+"#, options: .regularExpression),
            "A1/A2: Settings shows '\(label.label)', expected 'Rules <version>'"
        )
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
        openPaymentRunsFromBanner()
        scrollTo("payePayday.picker", timeout: 10)
        shot("A4 admin payday picker before")
        element("payePayday.picker").tap()
        // The picker opens a 31-day menu; "Day 1" is always on screen, "Day 25" may need scrolling.
        let day1 = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Day 1")).firstMatch
        if day1.waitForExistence(timeout: 3) {
            day1.tap()
        } else {
            XCTFail("A4: the payday picker did not offer 'Day 1'")
        }
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Press Save")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 3), "A4: no 'Press Save to apply it…' line after picking a day")
        shot("A4 admin payday picked, not saved")
    }

    func test_A05_adminOvertimeHubShowsPaydayBanner() {
        start("admin")
        openMenuRow(title: "Timesheets")
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

    /// Owner, 6 Nov: Timesheets is a full page with Done at the top left, which goes back to Home.
    func test_A16_adminTimesheetsFullScreenWithDone() {
        start("admin")
        openMenuRow(title: "Timesheets")
        assertExists("invoicing.done", timeout: 8)
        shot("A16 admin Timesheets full screen")
        element("invoicing.done").tap()
        assertExists(PPID.home, timeout: 8)
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
