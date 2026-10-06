import XCTest

final class SmallWorksTests: PPUITestCase {
    private var screen: SmallWorksScreen { SmallWorksScreen(test: self) }

    func test_SW01_createSmallWorksJob() {
        launch(role: "manager")
        assertSignedInHome(role: "manager")
        openTab("Smallworks")
        screen.assertVisible()
        screen.startCreate()
        let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
        screen.fillRequired(reference: "TEST-SW\(stamp)", site: "TEST-Small \(stamp)")
        screen.save()
        screen.assertVisible()
        XCTAssertTrue(app.staticTexts["TEST-Small \(stamp)"].waitForExistence(timeout: 5))
    }

    func test_SW02_changeStatus() {
        launch(role: "manager")
        assertSignedInHome(role: "manager")
        openTab("Smallworks")
        screen.assertVisible()
        tap("smallWorks.row.TEST")
        screen.openStatus()
        assertExists(PPID.smallWorksStatus)
    }

    func test_SW03_operativeSeesSmallWorks() {
        launch(role: "operative")
        assertSignedInHome(role: "operative")
        tap(PPID.homeQuickAction("op-small"))
        screen.assertVisible()
    }
}
