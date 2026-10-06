import XCTest

struct HomeScreen {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.home, timeout: 12) }

    func assertGreeting() {
        let greeting = test.app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Hi,")
        ).firstMatch
        XCTAssertTrue(greeting.waitForExistence(timeout: 8), "GAP: home greeting did not appear")
    }

    func assertDateShown() {
        let date = test.app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", ".*(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday).*")
        ).firstMatch
        XCTAssertTrue(date.waitForExistence(timeout: 8), "GAP: home date did not appear")
    }

    func refresh() { test.tap(PPID.homeRefresh) }
    func openNotifications() { test.tap(PPID.homeNotifications) }
    func openAvatar() { test.tap(PPID.homeAvatar) }
    func openProjects() { test.tap(PPID.homeQuickAction("staff-projects")) }
    func openCustomise() { test.tap(PPID.homeCustomise) }
    func finishCustomise() { test.tap(PPID.homeCustomiseDone) }
    func seeAll() { test.tap(PPID.homeSeeAll) }
}
