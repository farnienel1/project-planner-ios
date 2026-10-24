import XCTest

final class AuthTests: PPUITestCase {
    private var auth: AuthScreen { AuthScreen(test: self) }

    func test_AUTH01_adminReachesHome() {
        launch(role: "admin")
        assertSignedInHome(role: "admin")
    }

    func test_AUTH02_managerReachesHome() {
        launch(role: "manager")
        assertSignedInHome(role: "manager")
    }

    func test_AUTH03_operativeReachesHome() {
        launch(role: "operative")
        assertSignedInHome(role: "operative")
    }

    func test_AUTH04_wrongPasswordShowsError() {
        launch()
        auth.signIn(email: PPCredentials.adminEmail, password: "not-the-password")
        auth.assertCredentialError()
        auth.assertVisible()
    }

    func test_AUTH05_emptyEmailAndPasswordShowError() {
        launch()
        auth.submitEmpty()
    }

    func test_AUTH06_signOutThenSignIn() {
        launch(role: "manager")
        assertSignedInHome(role: "manager")
        openMore()
        MoreSheet(test: self).tapRow("sign_out")
        auth.assertVisible()
        auth.signIn(email: PPCredentials.managerEmail, password: PPCredentials.managerPassword)
        assertSignedInHome(role: "manager")
    }

    func test_AUTH07_resetPasswordScreenOpens() {
        launch()
        auth.openForgotPassword()
        assertExists(PPID.authResetEmail)
        assertExists(PPID.authResetSend)
    }

    func test_AUTH08_sessionPersistsAfterRelaunch() {
        launch(role: "operative")
        assertSignedInHome(role: "operative")
        relaunch(role: nil, resetState: false)
        assertSignedInHome(role: "operative")
    }

    func test_AUTH09_avatarShowsName() {
        launch(role: "admin")
        assertSignedInHome(role: "admin")
        HomeScreen(test: self).openAvatar()
        ProfileScreen(test: self).assertNameShown()
    }
}

struct AuthScreen {
    let test: PPUITestCase

    func assertVisible() {
        test.assertExists(PPID.authEmail, timeout: 8)
    }

    func signIn(email: String, password: String) {
        test.type(PPID.authEmail, email)
        test.type(PPID.authPassword, password)
        test.tap(PPID.authSignIn, timeout: 8)
    }

    /// Empty sign-in stays tappable so both required messages are shown.
    func submitEmpty() {
        test.tap(PPID.authSignIn, timeout: 8)
        let emailError = test.app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Please enter your email address.")
        ).firstMatch
        let passwordError = test.app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Please enter your password.")
        ).firstMatch
        XCTAssertTrue(emailError.waitForExistence(timeout: 4), "Empty sign-in should show the email required message")
        XCTAssertTrue(passwordError.waitForExistence(timeout: 4), "Empty sign-in should show the password required message")
    }

    func openForgotPassword() {
        test.tap(PPID.authForgotPassword)
    }

    func assertCredentialError() {
        let error = test.app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'sign in failed' OR label CONTAINS[c] 'password' OR label CONTAINS[c] 'email address' OR label CONTAINS[c] 'does not exist'")
        ).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 12), "GAP: sign-in error did not appear")
    }
}
