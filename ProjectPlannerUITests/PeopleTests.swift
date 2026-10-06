import XCTest

final class PeopleTests: PPUITestCase {
    private var people: PeopleScreen { PeopleScreen(test: self) }

    func test_PPL01_addUserRequiresFields() {
        launch(role: "admin", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "admin")
        openMainMenu()
        MainMenuSheet(test: self).tapRow("add_user")
        people.assertAddUser()
        people.saveEmpty()
        people.assertValidation()
    }

    func test_PPL02_manageUsersOpens() {
        launch(role: "admin", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "admin")
        openMainMenu()
        MainMenuSheet(test: self).tapRow("manage_users")
        assertExists(PPID.peopleManageUsers)
    }

    func test_PPL03_operativeListOpens() {
        launch(role: "admin", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "admin")
        openTab("Operatives")
        people.assertOperatives()
    }

    func test_PPL04_subcontractorsOpen() {
        launch(role: "admin", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "admin")
        openMainMenu()
        MainMenuSheet(test: self).tapRow("subcontractors")
        people.assertSubcontractors()
    }
}
