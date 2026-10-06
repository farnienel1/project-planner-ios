import XCTest

class PPUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-useEmulator", "-resetState"]
    }

    override func tearDownWithError() throws {
        app = nil
        try super.tearDownWithError()
    }

    override func record(_ issue: XCTIssue) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Failure \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.record(issue)
    }

    func launch(role: String? = nil, resetState: Bool = true, extraArguments: [String] = []) {
        if app.state == .runningForeground || app.state == .runningBackground {
            app.terminate()
        }
        var args = ["-uiTesting", "-useEmulator"]
        if resetState {
            args.append("-resetState")
        }
        if let role {
            args.append(contentsOf: ["-autoLoginRole", role])
        }
        args.append(contentsOf: extraArguments)
        app.launchArguments = args
        app.launch()
    }

    func relaunch(role: String? = nil, resetState: Bool = false, extraArguments: [String] = []) {
        app.terminate()
        launch(role: role, resetState: resetState, extraArguments: extraArguments)
    }

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", id))
            .firstMatch
    }

    @discardableResult
    func waitFor(_ id: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let el = element(id)
        XCTAssertTrue(
            el.waitForExistence(timeout: timeout),
            "GAP: accessibility identifier '\(id)' did not appear",
            file: file,
            line: line
        )
        return el
    }

    func tap(_ id: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let el = waitFor(id, timeout: timeout, file: file, line: line)
        if !el.isHittable {
            el.tap()
        } else {
            el.tap()
        }
    }

    func type(_ id: String, _ text: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let el = waitFor(id, timeout: timeout, file: file, line: line)
        el.tap()
        el.typeText(text)
    }

    func assertExists(_ id: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        _ = waitFor(id, timeout: timeout, file: file, line: line)
    }

    func assertNotExists(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let el = element(id)
        let appeared = el.waitForExistence(timeout: 1.5)
        XCTAssertFalse(appeared, "GAP: '\(id)' is visible and should be hidden", file: file, line: line)
    }

    func scrollTo(_ id: String, timeout: TimeInterval = 5) {
        let el = element(id)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if el.exists, el.isHittable { return }
            let scroll = app.scrollViews.firstMatch
            if scroll.exists {
                scroll.swipeUp()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(el.waitForExistence(timeout: 1), "GAP: could not scroll to '\(id)'")
    }

    func goBack() {
        let closers = [PPID.navBack, PPID.mainMenuDone, PPID.moreClose, PPID.sheetDone, PPID.sheetClose]
        for id in closers {
            let el = element(id)
            if el.exists, el.isHittable {
                el.tap()
                return
            }
        }
        let back = app.navigationBars.buttons["Back"]
        if back.exists, back.isHittable {
            back.tap()
            return
        }
        let navButtons = app.navigationBars.buttons
        if navButtons.count > 0 {
            let first = navButtons.element(boundBy: 0)
            if first.exists, first.isHittable, first.label != "More" {
                first.tap()
                return
            }
        }
        let home = element(PPID.tabHome)
        if home.exists, home.isHittable {
            home.tap()
            return
        }
        XCTFail("GAP: could not go back. Missing \(PPID.navBack)")
    }

    func openTab(_ name: String) {
        tap(PPID.tab(name))
    }

    func openMainMenu() {
        tap(PPID.homeMainMenu)
        assertExists(PPID.mainMenu)
    }

    func openMore() {
        tap(PPID.tabMore)
        assertExists(PPID.more)
    }

    func assertSignedInHome(role: String) {
        let home = element(PPID.home)
        if home.waitForExistence(timeout: 15) { return }
        if element(PPID.auth).exists || element(PPID.authEmail).exists {
            XCTFail("GAP: '\(PPID.home)' did not appear for \(role). The login screen is showing, so -autoLoginRole or -useEmulator is not hooked up.")
            return
        }
        XCTFail("GAP: '\(PPID.home)' did not appear within 15s after launch as \(role).")
    }

    func exercise(_ button: PPButton, returnToHome: Bool = true) {
        scrollTo(button.id)
        tap(button.id)
        switch button.kind {
        case .stay:
            assertExists(PPID.home)
        case .destination(let id):
            assertExists(id, timeout: 8)
            goBack()
            if returnToHome {
                if !element(PPID.home).waitForExistence(timeout: 3) {
                    let homeTab = element(PPID.tabHome)
                    if homeTab.exists { homeTab.tap() }
                }
                assertExists(PPID.home, timeout: 8)
            }
        case .customise:
            assertExists(PPID.homeCustomiseDone)
            tap(PPID.homeCustomiseDone)
            assertExists(PPID.homeCustomise)
        case .editTabBar:
            assertExists(PPID.homeEditTabBar)
            let done = element(PPID.homeEditTabBarDone)
            if done.waitForExistence(timeout: 2) {
                done.tap()
            } else {
                goBack()
            }
        case .signOut:
            assertExists(PPID.auth, timeout: 8)
        }
    }

    func exerciseIfPresent(_ button: PPButton) {
        let el = element(button.id)
        guard el.waitForExistence(timeout: 1.5) else { return }
        exercise(button)
    }
}

enum PPButtonKind {
    case stay
    case destination(String)
    case customise
    case editTabBar
    case signOut
}

struct PPButton {
    let id: String
    let kind: PPButtonKind
}
