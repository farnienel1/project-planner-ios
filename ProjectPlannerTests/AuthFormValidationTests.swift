import XCTest
@testable import Project_Planner

final class AuthFormValidationTests: XCTestCase {
    func testEmptyEmailAsksForTheAddress() {
        XCTAssertEqual(AuthFormValidation.emailMessage(for: ""), AuthFormValidation.emailRequiredMessage)
        XCTAssertEqual(AuthFormValidation.emailMessage(for: " \n\t"), AuthFormValidation.emailRequiredMessage)
    }

    func testMissingAtIsInvalid() {
        XCTAssertEqual(AuthFormValidation.emailMessage(for: "userexample.com"), AuthFormValidation.emailInvalidMessage)
    }

    func testMissingDotIsInvalid() {
        XCTAssertEqual(AuthFormValidation.emailMessage(for: "user@example"), AuthFormValidation.emailInvalidMessage)
    }

    func testInternalSpacesAreInvalid() {
        XCTAssertEqual(AuthFormValidation.emailMessage(for: "user name@example.com"), AuthFormValidation.emailInvalidMessage)
        XCTAssertEqual(AuthFormValidation.emailMessage(for: "user@example .com"), AuthFormValidation.emailInvalidMessage)
    }

    func testTypicalEmailIsAcceptedAfterTrim() {
        XCTAssertNil(AuthFormValidation.emailMessage(for: "  planner@example.com  "))
    }

    func test254CharacterEmailMatchingThePatternIsAccepted() {
        let email = "a@" + String(repeating: "b", count: 250) + ".c"
        XCTAssertEqual(email.count, 254)
        XCTAssertNil(AuthFormValidation.emailMessage(for: email))
    }

    func test255CharacterEmailIsRejected() {
        let email = "a@" + String(repeating: "b", count: 251) + ".c"
        XCTAssertEqual(email.count, 255)
        XCTAssertEqual(AuthFormValidation.emailMessage(for: email), AuthFormValidation.emailInvalidMessage)
    }

    func testEmptyLoginShowsBothRequiredMessages() {
        XCTAssertEqual(
            AuthFormValidation.loginMessages(email: "  ", password: ""),
            [
                AuthFormValidation.emailRequiredMessage,
                AuthFormValidation.passwordRequiredMessage
            ]
        )
    }

    func testLoginPasswordIsRequiredAfterTrimAndHasNoMinimumLength() {
        XCTAssertEqual(AuthFormValidation.loginPasswordMessage(for: "   "), AuthFormValidation.passwordRequiredMessage)
        XCTAssertNil(AuthFormValidation.loginPasswordMessage(for: "x"))
        XCTAssertEqual(
            AuthFormValidation.loginMessages(email: "not-an-email", password: "secret"),
            [AuthFormValidation.emailInvalidMessage]
        )
    }
}
