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
        // A slow simulator can swallow the first tap while the More list settles (Pro Max, AU02 on #202):
        // wait longer, and tap the row once more if Add User has not opened.
        if element("addUser.cancel").waitForExistence(timeout: 12) { return }
        if row.exists, row.isHittable { row.tap() }
        assertExists("addUser.cancel", timeout: 12)
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
        // The Operatives tab tap can be lost while Home is still settling after launch (AU09 on #249: the screen
        // never opened, so `operatives.add` never appeared). Tap the tab once more before failing.
        let add = element("operatives.add")
        if !add.waitForExistence(timeout: 8), tab.exists, tab.isHittable {
            tab.tap()
        }
        tap("operatives.add", timeout: 8)
        assertExists("addUser.cancel", timeout: 8)
    }

    /// The wizard step the tracker reads ("Step 2 of 4" → 2), or nil when the tracker is not on screen.
    private func currentStep() -> Int? {
        let tracker = element("addUser.stepTracker")
        guard tracker.exists else { return nil }
        let words = tracker.label.split(separator: " ")
        guard words.count >= 2, words[0] == "Step" else { return nil }
        return Int(words[1])
    }

    private func waitForStep(_ step: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if currentStep() == step { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    /// Taps Next and checks the wizard really moved one step on. A cold CI simulator can take 30s+ to settle
    /// (first test of a run on the SE), so Next waits for the button to stop moving before it taps.
    ///
    /// Before, the tap was fire-and-forget: on the Pro Max leg (AU09 on #259, run 44197731455) the step 2 → 3 tap
    /// was sent with Next enabled and not moving, and it had no effect — the wizard did not reach step 3. Why the
    /// tap was dropped is not known (the screenshots could not be read). The miss only showed 15s later as
    /// "permissionToggle.chevronDown did not appear" and "could not scroll to addUser.annualLeaveAllowance" (both
    /// are step 3 only). Now the step tracker is read before and after: a tap that left the step unchanged is tapped
    /// again — only after re-checking the wizard is still on that step, so a late first tap can never let the retry
    /// land on the next step's button (Create User on step 4) — and every retry is recorded (`recordRetry`). Any
    /// other result fails here, naming the step.
    private func next(file: StaticString = #filePath, line: UInt = #line) {
        let button = waitFor("addUser.creating", timeout: 10, file: file, line: line)
        waitUntilSettled(button)
        XCTAssertTrue(button.isEnabled, "Next is disabled where it should be enabled", file: file, line: line)
        guard let from = currentStep() else {
            XCTFail("GAP: 'addUser.stepTracker' did not say which step the wizard is on", file: file, line: line)
            return
        }
        let target = from + 1
        let attempts = 3
        for attempt in 1...attempts {
            if attempt > 1 {
                waitUntilSettled(button)
                // A late first tap may have moved the wizard while we waited: never retry from another step.
                let before = currentStep()
                if before == target { return }
                guard before == from else {
                    attachHierarchy("Next went from step \(from) to \(before.map { "\($0)" } ?? "none")")
                    XCTFail("Next moved the wizard from step \(from) to \(before.map { "\($0)" } ?? "no step"), not step \(target)", file: file, line: line)
                    return
                }
                guard button.isEnabled else {
                    XCTFail("Next turned disabled on step \(from)", file: file, line: line)
                    return
                }
                recordRetry("Retry tap \(attempt) of \(attempts) on Next: step \(from) did not move to \(target)")
            }
            button.tap()
            if waitForStep(target, timeout: 10) { return }
            let now = currentStep()
            guard now == from else {
                attachHierarchy("Next went from step \(from) to \(now.map { "\($0)" } ?? "none")")
                XCTFail("Next moved the wizard from step \(from) to \(now.map { "\($0)" } ?? "no step"), not step \(target)", file: file, line: line)
                return
            }
        }
        attachHierarchy("Next stayed on step \(from)")
        XCTFail("Next did not move the wizard from step \(from) after \(attempts) taps", file: file, line: line)
    }

    /// The accessibility tree as text, kept with the result bundle, so a failure here says what was on screen.
    private func attachHierarchy(_ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "\(deviceName) \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Dismisses the keyboard and waits for it to finish going: the form grows and the footer slides down as it
    /// goes, so the next tap must not land mid-move.
    private func dismissKeyboard() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        for key in ["return", "Return", "done", "Done"] where keyboard.buttons[key].exists {
            keyboard.buttons[key].tap()
            break
        }
        let goneBy = Date().addingTimeInterval(5)
        while keyboard.exists && Date() < goneBy { Thread.sleep(forTimeInterval: 0.25) }
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
        let employmentPill = waitFor("addUser.employmentType.\(employment)")
        waitUntilSettled(employmentPill)
        employmentPill.tap()
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
            // Wait for the sheet to finish closing, so the next tap reaches the form, not the sheet.
            let done = element("lineManagersMultiSelect.done")
            let closeBy = Date().addingTimeInterval(10)
            while done.exists && Date() < closeBy { Thread.sleep(forTimeInterval: 0.25) }
            assertExists("addUser.chevronRight", timeout: 5)
            assertNotExists("addUser.blockingMessage")
        }
        shot("\(tag) 2 Details line manager chosen")
        next()

        // Step 3: Access
        assertExists("permissionToggle.chevronDown", timeout: 15)
        if expectsIncluded {
            assertExists("permissionToggle.included", timeout: 10)
        }
        shot("\(tag) 3 Access modules")
        scrollTo("addUser.annualLeaveAllowance", timeout: 15)
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
