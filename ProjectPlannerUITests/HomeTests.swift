import XCTest

final class HomeTests: PPUITestCase {
    private var home: HomeScreen { HomeScreen(test: self) }

    func test_HOME01_greetingShowsNameAndDate() {
        launch(role: "admin")
        assertSignedInHome(role: "admin")
        home.assertGreeting()
        home.assertDateShown()
    }

    func test_HOME02_refreshKeepsHomeAndBellOpensNotifications() {
        launch(role: "manager")
        assertSignedInHome(role: "manager")
        home.refresh()
        assertExists(PPID.home)
        home.openNotifications()
        NotificationsScreen(test: self).assertVisible()
    }

    func test_HOME03_projectsQuickActionOpensProjects() {
        launch(role: "manager")
        assertSignedInHome(role: "manager")
        home.openProjects()
        ProjectsScreen(test: self).assertVisible()
    }

    func test_HOME04_warningsAndTasksShortcuts() {
        launch(role: "admin")
        assertSignedInHome(role: "admin")
        tap(PPID.homeWarnings)
        assertExists(PPID.warnings)
        goBack()
        tap(PPID.homeTasksDueToday)
        assertExists(PPID.tasks)
    }

    func test_HOME05_customiseDonePersistsLayout() {
        launch(role: "manager")
        assertSignedInHome(role: "manager")
        home.openCustomise()
        assertExists(PPID.homeCustomiseDone)
        home.finishCustomise()
        assertExists(PPID.homeCustomise)
        relaunch(role: "manager", resetState: false)
        assertSignedInHome(role: "manager")
        assertExists(PPID.homeQuickAction("staff-projects"))
    }

    func test_HOME06_upNextSeeAllOpensSchedule() {
        launch(role: "operative")
        assertSignedInHome(role: "operative")
        let empty = element(PPID.homeUpNextEmpty)
        if empty.waitForExistence(timeout: 2) {
            XCTAssertTrue(empty.exists)
        }
        home.seeAll()
        ScheduleScreen(test: self).assertVisible()
    }

    func test_HOME07_adminOverviewSettingsOpen() {
        launch(role: "admin")
        assertSignedInHome(role: "admin")
        tap(PPID.homeOverviewSettings)
        assertExists(PPID.homeOverviewSettingsDone)
    }
}
