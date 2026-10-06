import XCTest

final class LibraryTests: PPUITestCase {
    private var library: LibraryScreen { LibraryScreen(test: self) }

    func test_LIB01_createClient() {
        launch(role: "admin", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "admin")
        openMainMenu()
        MainMenuSheet(test: self).tapRow("clients")
        library.assertClients()
        let name = "TEST-Client \(Int(Date().timeIntervalSince1970) % 100000)"
        library.addClient(name: name)
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
    }

    func test_LIB02_clientSearchNoMatch() {
        launch(role: "admin", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "admin")
        openMainMenu()
        MainMenuSheet(test: self).tapRow("clients")
        library.searchClients("TEST-no-such-client-zz")
        assertExists(PPID.projectsEmpty)
    }

    func test_LIB03_jobTypesOpen() {
        launch(role: "admin", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "admin")
        openMainMenu()
        MainMenuSheet(test: self).tapRow("job_types")
        assertExists(PPID.libraryJobTypes)
    }

    func test_LIB04_materialsOpen() {
        launch(role: "admin", extraArguments: ["-seedDemoData"])
        assertSignedInHome(role: "admin")
        openMainMenu()
        MainMenuSheet(test: self).tapRow("material_catalogue")
        assertExists(PPID.libraryMaterials)
    }
}
