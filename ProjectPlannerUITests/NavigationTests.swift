import XCTest

final class NavigationTests: PPUITestCase {
    func test_NAV01_adminTapsEveryHomeMenuAndMoreButton() {
        exerciseEverySurface(role: "admin")
    }

    func test_NAV02_managerTapsEveryHomeMenuAndMoreButton() {
        exerciseEverySurface(role: "manager")
    }

    func test_NAV03_operativeTapsEveryHomeMenuAndMoreButton() {
        exerciseEverySurface(role: "operative")
    }

    private func exerciseEverySurface(role: String) {
        launch(role: role)
        assertSignedInHome(role: role)

        for button in RoleSurfaces.homeChrome(role: role) {
            exercise(button)
        }
        let quick = RoleSurfaces.homeQuickActions(role: role)
        quick.required.forEach { exercise($0) }
        quick.optional.forEach { exerciseIfPresent($0) }

        openMainMenu()
        MainMenuSheet(test: self).assertVisible()
        let menu = RoleSurfaces.menuRows(role: role)
        for button in menu.required {
            exercise(button)
            openMainMenu()
        }
        for button in menu.optional {
            if element(button.id).waitForExistence(timeout: 1) {
                exercise(button)
                openMainMenu()
            }
        }
        MainMenuSheet(test: self).close()
        assertExists(PPID.home)

        openMore()
        MoreSheet(test: self).assertVisible()
        for button in menu.required.map(RoleSurfaces.moreCopy) {
            exercise(button)
            openMore()
        }
        for button in menu.optional.map(RoleSurfaces.moreCopy) {
            if element(button.id).waitForExistence(timeout: 1) {
                exercise(button)
                openMore()
            }
        }
        let quickCreate = RoleSurfaces.moreQuickCreate(role: role)
        quickCreate.required.forEach { button in
            exercise(button)
            openMore()
        }
        quickCreate.optional.forEach { button in
            if element(button.id).waitForExistence(timeout: 1) {
                exercise(button)
                openMore()
            }
        }
        exercise(RoleSurfaces.signOut(on: "more"), returnToHome: false)
    }
}
