import XCTest

/// Add New User restyle (docs/design/add-user-ui/add-user-ui-spec.md §5), on seeded TEST data with no Firebase.
/// Walks all four steps for an Administrator, a Manager (self-employed) and an Operative (PAYE), in light and dark,
/// one Dynamic Type XXL run, and the manager-adding-operative mode. Every step keeps a screenshot named
/// "<device> AU<n> <who> <step>". Create User is never tapped, so nothing is written. Checks what it can by
/// accessibility identifier: Next is blocked until a line manager is chosen and the rulebook message shows in the
/// Line manager card; locked-on modules show "Included". Run by `.github/workflows/screen-checks.yml`.
final class AddUserScreenChecksTests: PPUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = true
    }

    // MARK: Helpers

    private var deviceName: String {
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "iPhone"
    }

    private func start(_ role: String, dark: Bool = false, extraLarge: Bool = false) {
        var extra = ["-seedDemoData"]
        if dark { extra.append(contentsOf: ["-AppleInterfaceStyle", "Dark"]) }
        if extraLarge { extra.append(contentsOf: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXL"]) }
        launch(role: role, extraArguments: extra)
        assertSignedInHome(role: role)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(deviceName) \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Admin: More → "Add user" (AddUserView `.admin`). The old Main menu sheet (`mainMenu.screen`) is gone; every
    /// More row carries `mainMenu.moreRow`, so the row is picked by its label, as the release screen checks do.
    private func openAddUserFromMainMenu() {
        openMore()
        let row = app.buttons
            .matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "mainMenu.moreRow", "Add user"))
            .firstMatch
        let deadline = Date().addingTimeInterval(10)
        while !(row.exists && row.isHittable && isFullyOnScreen(row)) && Date() < deadline {
            app.swipeUp()
        }
        XCTAssertTrue(row.exists, "More has no 'Add user' row")
        guard row.exists else { return }
        waitUntilSettled(row)
        row.tap()
        assertExists("addUser.cancel", timeout: 8)
    }

    /// Manager with the Operatives permission: Operatives → + (AddUserView `.managerAddingOperative`).
    private func openAddOperative() {
        let tab = element(PPID.tab("Operatives"))
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
        } else {
            openMore()
            let row = app.buttons
                .matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "mainMenu.moreRow", "Operatives"))
                .firstMatch
            let deadline = Date().addingTimeInterval(10)
            while !(row.exists && row.isHittable) && Date() < deadline { app.swipeUp() }
            XCTAssertTrue(row.exists, "More has no 'Operatives' row")
            if row.exists { row.tap() }
        }
        tap("operatives.add", timeout: 8)
        assertExists("addUser.cancel", timeout: 8)
    }

    private func next() {
        let button = waitFor("addUser.creating")
        XCTAssertTrue(button.isEnabled, "Next is disabled where it should be enabled")
        button.tap()
    }

    private func dismissKeyboard() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        for key in ["return", "Return", "done", "Done"] where keyboard.buttons[key].exists {
            keyboard.buttons[key].tap()
            return
        }
    }

    /// Steps 1 → 4. `accountType` nil keeps the preselected / locked type. `employment` is "paye" or "self_employed".
    private func walk(_ number: Int, who: String, accountType: String?, employment: String, expectsIncluded: Bool) {
        let tag = "AU\(number) \(who)"

        // Step 1: Account type
        if let accountType { tap("addUser.accountType.\(accountType)") }
        assertExists("addUser.stepTracker")
        shot("\(tag) 1 Type")
        next()

        // Step 2: User details (line manager missing first)
        type("addUser.enterFirstName", "TEST")
        type("addUser.enterSurname", who.replacingOccurrences(of: " ", with: ""))
        type("addUser.enterEmailAddress", "test-au\(number)@example.test")
        dismissKeyboard()
        tap("addUser.employmentType.\(employment)")
        shot("\(tag) 2 Details top")
        scrollTo("addUser.chevronRight", timeout: 8)
        let blocked = element("addUser.blockingMessage")
        if blocked.waitForExistence(timeout: 3) {
            XCTAssertFalse(element("addUser.creating").isEnabled, "\(tag): Next is enabled with no line manager")
            shot("\(tag) 2 Details line manager missing")
            tap("addUser.chevronRight")
            let candidate = app.buttons
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "lineManagersMultiSelect.row."))
                .firstMatch
            if candidate.waitForExistence(timeout: 5) {
                candidate.tap()
            } else {
                XCTFail("\(tag): the Line managers sheet listed nobody")
            }
            tap("lineManagersMultiSelect.done")
            assertExists("addUser.chevronRight", timeout: 5)
            assertNotExists("addUser.blockingMessage")
        }
        shot("\(tag) 2 Details line manager chosen")
        next()

        // Step 3: Access
        assertExists("permissionToggle.chevronDown", timeout: 5)
        if expectsIncluded {
            assertExists("permissionToggle.included")
        }
        shot("\(tag) 3 Access modules")
        scrollTo("addUser.annualLeaveAllowance", timeout: 8)
        shot("\(tag) 3 Access annual leave")
        next()

        // Step 4: Review (Create User is not tapped)
        assertExists("addUser.creating")
        shot("\(tag) 4 Review top")
        app.swipeUp()
        shot("\(tag) 4 Review permissions")
    }

    // MARK: Admin adds each type (light)

    func test_AU01_administrator() {
        start("admin")
        openAddUserFromMainMenu()
        walk(1, who: "admin Administrator SE", accountType: "admin", employment: "self_employed", expectsIncluded: true)
    }

    func test_AU02_managerSelfEmployed() {
        start("admin")
        openAddUserFromMainMenu()
        walk(2, who: "admin Manager SE", accountType: "manager", employment: "self_employed", expectsIncluded: true)
    }

    func test_AU03_operativePaye() {
        start("admin")
        openAddUserFromMainMenu()
        walk(3, who: "admin Operative PAYE", accountType: "operative", employment: "paye", expectsIncluded: false)
    }

    // MARK: Dark

    func test_AU04_administratorDark() {
        start("admin", dark: true)
        openAddUserFromMainMenu()
        walk(4, who: "admin Administrator SE dark", accountType: "admin", employment: "self_employed", expectsIncluded: true)
    }

    func test_AU05_managerSelfEmployedDark() {
        start("admin", dark: true)
        openAddUserFromMainMenu()
        walk(5, who: "admin Manager SE dark", accountType: "manager", employment: "self_employed", expectsIncluded: true)
    }

    func test_AU06_operativePayeDark() {
        start("admin", dark: true)
        openAddUserFromMainMenu()
        walk(6, who: "admin Operative PAYE dark", accountType: "operative", employment: "paye", expectsIncluded: false)
    }

    // MARK: Dynamic Type XXL

    func test_AU07_managerSelfEmployedExtraLarge() {
        start("admin", extraLarge: true)
        openAddUserFromMainMenu()
        walk(7, who: "admin Manager SE XXL", accountType: "manager", employment: "self_employed", expectsIncluded: true)
    }

    // MARK: Manager with Operatives adds an operative

    func test_AU08_managerAddsOperative() {
        start("manager")
        openAddOperative()
        assertNotExists("addUser.accountType.admin")
        walk(8, who: "manager adds Operative PAYE", accountType: nil, employment: "paye", expectsIncluded: false)
    }

    func test_AU09_managerAddsOperativeDark() {
        start("manager", dark: true)
        openAddOperative()
        walk(9, who: "manager adds Operative PAYE dark", accountType: nil, employment: "paye", expectsIncluded: false)
    }
}
