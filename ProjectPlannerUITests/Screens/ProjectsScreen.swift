import Foundation

struct ProjectsScreen {
    let test: PPUITestCase

    func assertVisible() { test.assertExists(PPID.projects, timeout: 8) }

    func startCreate() { test.tap(PPID.projectsAdd) }

    func save() { test.tap(PPID.projectsSave) }

    func assertValidationShown() { test.assertExists(PPID.projectsValidation) }

    func fillRequired(reference: String, site: String) {
        let expand = test.element(PPID.projectsExpandAddress)
        if expand.waitForExistence(timeout: 2) {
            expand.tap()
        }
        test.type(PPID.projectsReference, reference)
        test.type(PPID.projectsSiteName, site)
        test.scrollTo(PPID.projectsAddress1)
        test.type(PPID.projectsAddress1, "1 Test Street")
        test.type(PPID.projectsTown, "London")
        test.type(PPID.projectsPostcode, "SW1A 1AA")
        test.scrollTo(PPID.projectsClient)
        test.tap(PPID.projectsClient)
        test.scrollTo(PPID.projectsManagers)
        test.tap(PPID.projectsManagers)
    }

    func editEndDate() {
        test.tap(PPID.projectDetailEdit)
        test.tap(PPID.projectDetailEndDate)
        test.tap(PPID.projectDetailSave)
        test.assertExists(PPID.projectDetail)
    }
}
