import XCTest

final class VariationsTests: PPUITestCase {
    private var variations: VariationsScreen { VariationsScreen(test: self) }

    func test_VAR01_createVariationWithRequiredFields() {
        launch(role: "admin")
        assertSignedInHome(role: "admin")
        openTab("Projects")
        tap("projects.row.TEST")
        tap(PPID.projectDetailVariations)
        variations.assertVisible()
        variations.startCreate()
        variations.fill(heading: "TEST-VO extra works", hours: "2")
        variations.save()
        variations.assertVisible()
        assertExists(PPID.variationsVONumber)
    }

    func test_VAR02_submittedVariationIsReadOnly() {
        launch(role: "admin")
        assertSignedInHome(role: "admin")
        openTab("Projects")
        tap("projects.row.TEST")
        tap(PPID.projectDetailVariations)
        tap("variations.row.submitted")
        assertExists(PPID.variationsStatus)
        assertNotExists(PPID.variationsSave)
    }

    func test_VAR03_operativeCannotEditVariations() {
        launch(role: "operative")
        assertSignedInHome(role: "operative")
        tap(PPID.homeQuickAction("op-projects"))
        let row = element("projects.row.TEST")
        if row.waitForExistence(timeout: 3) {
            row.tap()
        }
        assertNotExists(PPID.projectDetailVariations)
        assertNotExists(PPID.variationsAdd)
    }
}
