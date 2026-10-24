import XCTest
@testable import Project_Planner

@MainActor
final class WelcomeInvitationEmailTests: XCTestCase {
    private let invitationId = "550e8400-e29b-41d4-a716-446655440000"
    private var setupURL: String {
        "https://www.projectplanner.us/setup-password.html?token=\(invitationId)"
    }

    func testWelcomeBodiesIncludeNameOrganisationSetupURLAndRecipient() {
        let service = ResendEmailService()
        let html = service.welcomeInvitationEmailHTML(
            firstName: "Morgan",
            companyName: "Acme Construction Ltd",
            invitationCode: invitationId,
            email: "morgan@acme.test"
        )
        let passwordBody = service.createPasswordSetupEmailBody(
            firstName: "Morgan",
            surname: "Lee",
            invitationCode: invitationId,
            email: "morgan@acme.test",
            companyName: "Acme Construction Ltd"
        )
        let signUpBody = service.createSignUpEmailWithVerificationBody(
            firstName: "Morgan",
            surname: "Lee",
            invitationCode: invitationId,
            email: "morgan@acme.test",
            companyName: "Acme Construction Ltd"
        )

        XCTAssertEqual(passwordBody, html)
        XCTAssertEqual(signUpBody, html)
        XCTAssertTrue(html.contains("Welcome aboard, Morgan."))
        XCTAssertTrue(html.contains("Acme Construction Ltd has invited you"))
        XCTAssertTrue(html.contains("href=\"\(setupURL)\""))
        XCTAssertTrue(html.contains(setupURL))
        XCTAssertTrue(html.contains("This email was sent to morgan@acme.test"))
        XCTAssertTrue(html.contains("https://www.projectplanner.us/email-assets/pp-email-logo.png"))
        XCTAssertTrue(html.contains("https://www.projectplanner.us/email-assets/pp-email-icon.png"))
        XCTAssertFalse(html.contains("#007AFF"))
        XCTAssertFalse(html.contains("{{FirstName}}"))
        XCTAssertFalse(html.contains("{{CompanyName}}"))
        XCTAssertFalse(html.contains("{{SetupLink}}"))
        XCTAssertFalse(html.contains("{{RecipientEmail}}"))
        XCTAssertFalse(html.contains("font-family: Arial, sans-serif; max-width: 600px"))
    }

    func testMissingFirstNameBecomesThereAndBlankCompanyStillReplacesToken() {
        let service = ResendEmailService()
        let html = service.welcomeInvitationEmailHTML(
            firstName: "  ",
            companyName: "   ",
            invitationCode: invitationId,
            email: "  ada@example.com "
        )
        XCTAssertTrue(html.contains("Welcome aboard, there."))
        XCTAssertFalse(html.contains("{{CompanyName}}"))
        XCTAssertFalse(html.contains("{{FirstName}}"))
        XCTAssertTrue(html.contains("This email was sent to ada@example.com"))
        XCTAssertTrue(html.contains(setupURL))
        XCTAssertFalse(html.contains("#007AFF"))
    }

    func testWelcomeBodyEscapesNameAndOrganisation() {
        let service = ResendEmailService()
        let html = service.welcomeInvitationEmailHTML(
            firstName: "<script>alert(1)</script>",
            companyName: "Acme & Co",
            invitationCode: invitationId,
            email: "user@example.com"
        )
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("Acme &amp; Co"))
        XCTAssertFalse(html.contains("#007AFF"))
    }
}
