import XCTest

final class ProjectsTests: PPUITestCase {
    private var projects: ProjectsScreen { ProjectsScreen(test: self) }

    func test_PROJ01_emptyRequiredFieldsThenSave() {
        launch(role: "manager")
        assertSignedInHome(role: "manager")
        openTab("Projects")
        projects.assertVisible()
        projects.startCreate()
        projects.save()
        projects.assertValidationShown()
        let stamp = Self.stamp()
        projects.fillRequired(reference: "TEST-P\(stamp)", site: "TEST-Site \(stamp)")
        projects.save()
        projects.assertVisible()
        XCTAssertTrue(app.staticTexts["TEST-Site \(stamp)"].waitForExistence(timeout: 5))
    }

    func test_PROJ02_operativeSeesProjectsList() {
        launch(role: "operative")
        assertSignedInHome(role: "operative")
        tap(PPID.homeQuickAction("op-projects"))
        projects.assertVisible()
    }

    func test_PROJ03_managerEditsProjectEndDate() {
        launch(role: "manager")
        assertSignedInHome(role: "manager")
        openTab("Projects")
        projects.assertVisible()
        tap("projects.row.TEST")
        assertExists(PPID.projectDetail)
        projects.editEndDate()
    }

    func test_PROJ04_searchWithNoMatchShowsEmpty() {
        launch(role: "admin")
        assertSignedInHome(role: "admin")
        openTab("Projects")
        projects.assertVisible()
        type(PPID.projectsSearch, "TEST-no-such-project-zz")
        assertExists(PPID.projectsEmpty)
    }

    func test_PROJ05_projectSectionsLoad() {
        launch(role: "admin")
        assertSignedInHome(role: "admin")
        openTab("Projects")
        tap("projects.row.TEST")
        assertExists(PPID.projectDetail)
        tap(PPID.projectDetailTasks)
        assertExists(PPID.tasks)
        goBack()
        tap(PPID.projectDetailSchedule)
        assertExists(PPID.schedule)
        goBack()
        tap(PPID.projectDetailDocuments)
        goBack()
        tap(PPID.projectDetailHealthSafety)
    }

    /// Owner request 10 Nov: the My Projects ⚙ picker filters its rows by All / Active / Upcoming / Completed
    /// (`worksInTab`), and Cancel leaves the list unchanged.
    func test_PROJ06_myProjectsPickerFilters() {
        launch(role: "manager")
        assertSignedInHome(role: "manager")
        openTab("Projects")
        projects.assertVisible()
        tap("projects.filter.mine")
        tap("projects.myList.picker")
        assertExists("myWorksPicker.filter.all")
        for tab in ["active", "upcoming", "completed", "all"] {
            tap("myWorksPicker.filter.\(tab)")
            XCTAssertTrue(element("myWorksPicker.filter.\(tab)").isSelected, "\(tab) chip is selected")
        }
        tap("myWorksPicker.cancel")
        projects.assertVisible()
    }

    private static func stamp() -> String {
        String(Int(Date().timeIntervalSince1970) % 100000)
    }
}
