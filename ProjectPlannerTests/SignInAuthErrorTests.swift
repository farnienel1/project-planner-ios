import XCTest
@testable import Project_Planner

final class SignInAuthErrorTests: XCTestCase {
    func testUserNotFoundSaysTheAccountDoesNotExist() {
        let message = SignInAuthError.presentedMessage(
            domain: "FIRAuthErrorDomain",
            code: 17011,
            localizedDescription: "There is no user record corresponding to this identifier. The user may have been deleted."
        )
        XCTAssertEqual(message, "This account does not exist.")
    }

    func testMalformedCredentialSentenceSaysTheAccountDoesNotExist() {
        let message = SignInAuthError.presentedMessage(
            domain: "FIRAuthErrorDomain",
            code: 17004,
            localizedDescription: "The supplied auth credential is malformed or has expired."
        )
        XCTAssertEqual(message, "This account does not exist.")
    }

    func testWrongPasswordCodeKeepsFirebaseSentence() {
        let firebase = "The password is invalid or the user does not have a password."
        let message = SignInAuthError.presentedMessage(
            domain: "FIRAuthErrorDomain",
            code: 17009,
            localizedDescription: firebase
        )
        XCTAssertEqual(message, firebase)
        XCTAssertNotEqual(message, SignInAuthError.accountDoesNotExist)
    }

    func testDifferentInvalidCredentialWordingIsLeftAlone() {
        let other = "The credential is invalid."
        let message = SignInAuthError.presentedMessage(
            domain: "FIRAuthErrorDomain",
            code: 17004,
            localizedDescription: other
        )
        XCTAssertEqual(message, other)
    }

    func testMalformedSentenceOutsideAuthDomainIsLeftAlone() {
        let sentence = "The supplied auth credential is malformed or has expired."
        let message = SignInAuthError.presentedMessage(
            domain: "NSURLErrorDomain",
            code: 17004,
            localizedDescription: sentence
        )
        XCTAssertEqual(message, sentence)
    }
}
