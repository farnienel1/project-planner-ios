import XCTest
@testable import Project_Planner

@MainActor
final class AccountDeletionClientTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "account-deletion-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testConfirmationOtherThanDeleteOrEmptyPasswordIsRejectedBeforeARequest() async {
        let cases = [
            ("delete", "secret"),
            ("Delete", "secret"),
            (" DELETE", "secret"),
            ("DELETE ", "secret"),
            ("", "secret"),
            ("DELETE", ""),
            ("DELETE", "   ")
        ]
        for (confirmation, password) in cases {
            let transport = StubAccountDeletionTransport(statusCode: 200, body: Data(#"{"ok":true}"#.utf8))
            var tokenFetches = 0
            var signedOut = false
            let result = await AccountDeletionClient.perform(
                email: "planner@example.com",
                confirmation: confirmation,
                password: password,
                idToken: {
                    tokenFetches += 1
                    return "token"
                },
                transport: transport,
                userId: "user-1",
                defaults: defaults,
                clearRememberedOrganization: {},
                clearPersistence: { _ in },
                signOut: { signedOut = true }
            )
            XCTAssertEqual(transport.requests.count, 0, "\(confirmation) / \(password.debugDescription)")
            XCTAssertEqual(tokenFetches, 0, confirmation)
            XCTAssertFalse(signedOut)
            guard case .rejectedBeforeRequest = result else {
                XCTFail("expected rejection for \(confirmation.debugDescription)")
                continue
            }
            XCTAssertTrue(result.staysSignedIn)
        }
    }

    func testSoleAdminMapsToOrgNameAndDoesNotSignOut() async {
        defaults.set("org-keep", forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
        let transport = StubAccountDeletionTransport(
            statusCode: 409,
            body: Data(#"{"error":"sole admin","code":"sole_admin","orgId":"org-1","orgName":"North Yard"}"#.utf8)
        )
        var clearerCalls = 0
        var persistenceUserId: String?
        var signedOut = false
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { "token" },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: { clearerCalls += 1 },
            clearPersistence: { persistenceUserId = $0 },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(
            result,
            .soleAdmin("You are the only admin of North Yard. Transfer admin access to someone else, or email info@projectplanner.us if you need this organisation removed.")
        )
        XCTAssertTrue(result.staysSignedIn)
        XCTAssertTrue(result.hidesDeleteButton)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(clearerCalls, 0)
        XCTAssertNil(persistenceUserId)
        XCTAssertEqual(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey), "org-keep")
    }

    func testDeletedResponseClearsRememberedOrganizationBeforeSignOut() async throws {
        defaults.set("org-keep", forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
        defaults.set("North Yard", forKey: AccountDeletionClient.rememberedOrganizationNameDefaultsKey)
        let transport = StubAccountDeletionTransport(statusCode: 200, body: Data(#"{"ok":true}"#.utf8))
        var events: [String] = []
        var keyWhenClearerRan: String?
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { "id-token-1" },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {
                keyWhenClearerRan = self.defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
                events.append("clearLocalOrganizationCache")
            },
            clearPersistence: { events.append("persistence:\($0)") },
            signOut: { events.append("signOut") }
        )
        XCTAssertEqual(result, .deleted)
        XCTAssertNil(result.failureMessage)
        XCTAssertFalse(result.staysSignedIn)
        XCTAssertNil(keyWhenClearerRan)
        XCTAssertNil(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey))
        XCTAssertNil(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationNameDefaultsKey))
        XCTAssertEqual(events, ["clearLocalOrganizationCache", "persistence:user-1", "signOut"])

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, AccountDeletionClient.requestTimeout)
        XCTAssertEqual(request.url?.absoluteString, "https://projectplanner.us/api/account/delete")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer id-token-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["confirmation": "DELETE", "password": "secret"])
    }

    func testSupportAddressIsRefusedLocally() async {
        let transport = StubAccountDeletionTransport(statusCode: 200, body: Data(#"{"ok":true}"#.utf8))
        var tokenFetches = 0
        var signedOut = false
        for email in ["info@projectplanner.us", " INFO@ProjectPlanner.us "] {
            let result = await AccountDeletionClient.perform(
                email: email,
                confirmation: "DELETE",
                password: "secret",
                idToken: {
                    tokenFetches += 1
                    return "token"
                },
                transport: transport,
                userId: "support-user",
                defaults: defaults,
                clearRememberedOrganization: {},
                clearPersistence: { _ in },
                signOut: { signedOut = true }
            )
            XCTAssertEqual(result, .supportAccountRefused(AccountDeletionClient.supportAccountMessage))
            XCTAssertTrue(result.staysSignedIn)
            XCTAssertFalse(result.hidesDeleteButton)
        }
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertEqual(tokenFetches, 0)
        XCTAssertFalse(signedOut)
    }

    func testEmptyPasswordNeverRequests() async {
        let transport = StubAccountDeletionTransport(statusCode: 401, body: Data(#"{"error":"Password is incorrect."}"#.utf8))
        var tokenFetches = 0
        var signedOut = false
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "   ",
            idToken: {
                tokenFetches += 1
                return "token"
            },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertEqual(tokenFetches, 0)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(result, .rejectedBeforeRequest(AccountDeletionClient.confirmationRejectedMessage))
        XCTAssertTrue(result.staysSignedIn)
        if case .passwordNotAccepted = result {
            XCTFail("empty password must not be described as a rejected password")
        }
    }

    func testUnauthorizedWrongPasswordBodySaysThePasswordWasNotAccepted() async throws {
        let transport = StubAccountDeletionTransport(
            statusCode: 401,
            body: Data(#"{"error":"Password is incorrect."}"#.utf8)
        )
        var signedOut = false
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "not-the-password",
            idToken: { "id-token-1" },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .passwordNotAccepted(AccountDeletionClient.passwordNotAcceptedMessage))
        XCTAssertEqual(AccountDeletionClient.passwordNotAcceptedMessage, "That password was not accepted.")
        XCTAssertTrue(result.staysSignedIn)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer id-token-1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["confirmation": "DELETE", "password": "not-the-password"])
    }

    func testWrongPasswordCodeWithoutThatSentenceStillSaysThePasswordWasNotAccepted() async {
        let transport = StubAccountDeletionTransport(
            statusCode: 401,
            body: Data(#"{"code":"wrong_password","error":"nope"}"#.utf8)
        )
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { "id-token-1" },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: {}
        )
        XCTAssertEqual(result, .passwordNotAccepted("That password was not accepted."))
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(result.staysSignedIn)
    }

    func testMissingTokenIsRefusedBeforeTheRequestAndDoesNotBlameThePassword() async {
        let transport = StubAccountDeletionTransport(statusCode: 401, body: Data())
        var signedOut = false

        let thrown = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { throw AccountDeletionClient.TokenError.notSignedIn },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(thrown, .rejectedBeforeRequest(AccountDeletionClient.signInAgainMessage))
        XCTAssertEqual(AccountDeletionClient.signInAgainMessage, "You need to sign in again.")
        XCTAssertTrue(thrown.staysSignedIn)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(transport.requests.count, 0)
        if case .passwordNotAccepted = thrown {
            XCTFail("a missing token must not be described as a rejected password")
        }

        let blank = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { "   " },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(blank, .rejectedBeforeRequest("You need to sign in again."))
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertFalse(signedOut)
    }

    func testUnauthorizedSignInRequiredAfterABearerTokenIsNotThatSentence() async {
        defaults.set("org-keep", forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
        let transport = StubAccountDeletionTransport(
            statusCode: 401,
            body: Data(#"{"error":"Sign in required"}"#.utf8)
        )
        var clearerCalls = 0
        var signedOut = false
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            confirmPassword: {},
            idToken: { "id-token-1" },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: { clearerCalls += 1 },
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .failed(AccountDeletionClient.genericFailureMessage))
        XCTAssertNotEqual(AccountDeletionClient.genericFailureMessage, "Sign in required")
        XCTAssertTrue(result.staysSignedIn)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(clearerCalls, 0)
        XCTAssertEqual(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey), "org-keep")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer id-token-1")
        if case .passwordNotAccepted = result {
            XCTFail("a session 401 must not be described as a rejected password")
        }
        if case .failed(let text) = result {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("sign in required"))
        }
    }

    func testUnauthorizedEmptyBodyDoesNotClaimThePasswordWasWrong() async {
        let transport = StubAccountDeletionTransport(statusCode: 401, body: Data())
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { "id-token-1" },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: {}
        )
        XCTAssertEqual(result, .failed(AccountDeletionClient.genericFailureMessage))
        XCTAssertTrue(result.staysSignedIn)
        if case .passwordNotAccepted = result {
            XCTFail("an empty 401 body is not evidence of a wrong password")
        }
        if case .failed(let text) = result {
            XCTAssertNotEqual(text, "Sign in required")
        }
    }

    func testBadRequestAndForbiddenShowTheServerSentenceAndStaySignedIn() async {
        let missing = AccountDeletionClient.interpret(
            statusCode: 400,
            body: Data(#"{"error":"Type DELETE and enter your password to delete your account."}"#.utf8)
        )
        XCTAssertEqual(
            missing,
            .rejectedBeforeRequest("Type DELETE and enter your password to delete your account.")
        )
        XCTAssertTrue(missing.staysSignedIn)

        let owner = AccountDeletionClient.interpret(
            statusCode: 403,
            body: Data(#"{"error":"The owner account cannot be deleted."}"#.utf8)
        )
        XCTAssertEqual(owner, .supportAccountRefused("The owner account cannot be deleted."))
        XCTAssertTrue(owner.staysSignedIn)
        XCTAssertFalse(owner.hidesDeleteButton)
    }

    func testLocalWrongPasswordNeverRequestsAndDoesNotSignOut() async {
        let transport = StubAccountDeletionTransport(
            statusCode: 401,
            body: Data(#"{"error":"Password is incorrect."}"#.utf8)
        )
        var tokenFetches = 0
        var signedOut = false
        var logged: [Int] = []
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            confirmPassword: { throw AccountDeletionClient.PasswordCheckError.wrongPassword },
            idToken: {
                tokenFetches += 1
                return "id-token-1"
            },
            transport: transport,
            statusLog: { logged.append($0) },
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .passwordNotAccepted("That password was not accepted."))
        XCTAssertTrue(result.staysSignedIn)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertEqual(tokenFetches, 0)
        XCTAssertEqual(logged, [])
    }

    func testUnauthorizedAfterLocalReauthIsNotCalledAWrongPasswordAndDoesNotSignOut() async {
        let transport = StubAccountDeletionTransport(
            statusCode: 401,
            body: Data(#"{"error":"Password is incorrect."}"#.utf8)
        )
        var signedOut = false
        var logged: [Int] = []
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            confirmPassword: {},
            idToken: { "fresh-token" },
            transport: transport,
            statusLog: { logged.append($0) },
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .failed(AccountDeletionClient.genericFailureMessage))
        XCTAssertTrue(result.staysSignedIn)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-token")
        XCTAssertEqual(logged, [401])
        if case .passwordNotAccepted = result {
            XCTFail("a 401 after a successful reauth is not a rejected password")
        }
        if case .failed(let text) = result {
            XCTAssertNotEqual(text, AccountDeletionClient.signInAgainMessage)
            XCTAssertNotEqual(text, "Sign in required")
        }
    }

    func testPasswordCheckCodes() {
        XCTAssertEqual(
            AccountDeletionClient.passwordCheckFailure(authDomain: "FIRAuthErrorDomain", code: 17009),
            .wrongPassword
        )
        XCTAssertEqual(
            AccountDeletionClient.passwordCheckFailure(authDomain: "FIRAuthErrorDomain", code: 17004),
            .wrongPassword
        )
        XCTAssertEqual(
            AccountDeletionClient.passwordCheckFailure(authDomain: "FIRAuthErrorDomain", code: 17021),
            .notSignedIn
        )
        XCTAssertEqual(
            AccountDeletionClient.passwordCheckFailure(authDomain: "FIRAuthErrorDomain", code: 17020),
            .unavailable
        )
        XCTAssertEqual(
            AccountDeletionClient.passwordCheckFailure(authDomain: "NSURLErrorDomain", code: 17009),
            .unavailable
        )
    }

    func testSessionShaped401WithoutALocalTokenUsesTheSessionSentence() {
        let session = AccountDeletionClient.interpret(
            statusCode: 401,
            body: Data(#"{"error":"Sign in required"}"#.utf8)
        )
        XCTAssertEqual(session, .failed(AccountDeletionClient.signInAgainMessage))
        if case .failed(let text) = session {
            XCTAssertNotEqual(text, "Sign in required")
        }
        let password = AccountDeletionClient.interpret(
            statusCode: 401,
            body: Data(#"{"error":"Password is incorrect."}"#.utf8)
        )
        XCTAssertEqual(password, .passwordNotAccepted(AccountDeletionClient.passwordNotAcceptedMessage))
    }

    func testTokenRefreshFailureIsNotAMissingSessionAndDoesNotSignOut() async {
        let transport = StubAccountDeletionTransport(statusCode: 401, body: Data(#"{"error":"Sign in required"}"#.utf8))
        var signedOut = false
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            confirmPassword: {},
            idToken: { throw NSError(domain: "FIRAuthErrorDomain", code: 17020) },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .failed(AccountDeletionClient.genericFailureMessage))
        XCTAssertTrue(result.staysSignedIn)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(transport.requests.count, 0)
        if case .failed(let text) = result {
            XCTAssertNotEqual(text, "Sign in required")
            XCTAssertNotEqual(text, AccountDeletionClient.signInAgainMessage)
        }
    }

    func testReauthNetworkFailureIsNotAMissingSession() async {
        let transport = StubAccountDeletionTransport(statusCode: 200, body: Data(#"{"ok":true}"#.utf8))
        var signedOut = false
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            confirmPassword: { throw AccountDeletionClient.PasswordCheckError.unavailable },
            idToken: { "id-token-1" },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .failed(AccountDeletionClient.genericFailureMessage))
        XCTAssertFalse(signedOut)
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertTrue(result.staysSignedIn)
    }

    func testReauthenticatedTokenIsSentAsBearerToTheHostThatDoesNotRedirect() async throws {
        let token = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.reauth-user.signature"
        let password = "secret"
        let transport = StubAccountDeletionTransport(
            statusCode: 401,
            body: Data(#"{"error":"Sign in required"}"#.utf8)
        )
        var signedOut = false
        let result = await AccountDeletionClient.perform(
            email: "operative@example.com",
            confirmation: "DELETE",
            password: password,
            baseURL: URL(string: "https://www.projectplanner.us"),
            confirmPassword: {},
            idToken: { token },
            tokenUserId: { "reauth-user" },
            transport: transport,
            userId: "reauth-user",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .failed(AccountDeletionClient.genericFailureMessage))
        XCTAssertTrue(result.staysSignedIn)
        XCTAssertFalse(signedOut)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "projectplanner.us")
        XCTAssertEqual(request.url?.absoluteString, "https://projectplanner.us/api/account/delete")
        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(authorization, "Bearer \(token)")
        XCTAssertTrue(authorization.hasPrefix("Bearer "))
        XCTAssertFalse(authorization.contains(password))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body["password"], password)
        XCTAssertNotEqual(body["password"], authorization)
    }

    func testWwwHostIsRewrittenAndOtherHostsAreLeftAlone() {
        let rewritten = AccountDeletionClient.endpointURL(baseURL: URL(string: "https://www.projectplanner.us/")!)
        XCTAssertEqual(rewritten?.absoluteString, "https://projectplanner.us/api/account/delete")
        let apex = AccountDeletionClient.endpointURL(baseURL: URL(string: "https://projectplanner.us")!)
        XCTAssertEqual(apex?.absoluteString, "https://projectplanner.us/api/account/delete")
        let other = AccountDeletionClient.endpointURL(baseURL: URL(string: "https://www.example.com")!)
        XCTAssertEqual(other?.absoluteString, "https://www.example.com/api/account/delete")
    }

    func testRedirectFollowUpIsRefused() {
        var proposed = URLRequest(url: URL(string: "https://projectplanner.us/api/account/delete")!)
        proposed.httpMethod = "GET"
        XCTAssertNil(AccountDeletionClient.followRedirect(proposed: proposed, statusCode: 301))
        XCTAssertNil(AccountDeletionClient.followRedirect(proposed: proposed, statusCode: 302))
    }

    func testUidChangeAfterReauthAbortsWithoutPosting() async {
        let transport = StubAccountDeletionTransport(statusCode: 200, body: Data(#"{"ok":true}"#.utf8))
        var tokenFetches = 0
        var signedOut = false
        let result = await AccountDeletionClient.perform(
            email: "operative@example.com",
            confirmation: "DELETE",
            password: "secret",
            confirmPassword: {},
            idToken: {
                tokenFetches += 1
                return "fresh-token"
            },
            tokenUserId: { "other-user" },
            transport: transport,
            userId: "user-at-tap",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .failed(AccountDeletionClient.genericFailureMessage))
        XCTAssertTrue(result.staysSignedIn)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(tokenFetches, 0)
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testMethodNotAllowedKeepsTheServerBodyAndStaysSignedIn() async {
        defaults.set("org-keep", forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
        let transport = StubAccountDeletionTransport(
            statusCode: 405,
            body: Data(#"{"error":"Method Not Allowed"}"#.utf8)
        )
        var signedOut = false
        let result = await AccountDeletionClient.perform(
            email: "operative@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { "id-token-1" },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .failed("Method Not Allowed"))
        XCTAssertTrue(result.staysSignedIn)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey), "org-keep")

        let empty = AccountDeletionClient.interpret(statusCode: 405, body: Data())
        XCTAssertEqual(empty, .failed(AccountDeletionClient.genericFailureMessage))
        XCTAssertTrue(empty.staysSignedIn)
    }

    func testTransportTimeoutIsNotTheGenericFailureSentence() async {
        defaults.set("org-keep", forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
        let transport = ThrowingAccountDeletionTransport(error: URLError(.timedOut))
        var signedOut = false
        var clearerCalls = 0
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            confirmPassword: {},
            idToken: { "id-token-1" },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: { clearerCalls += 1 },
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .failed(AccountDeletionClient.timedOutMessage))
        XCTAssertEqual(AccountDeletionClient.timedOutMessage, "The delete timed out. Try again.")
        XCTAssertNotEqual(AccountDeletionClient.timedOutMessage, AccountDeletionClient.genericFailureMessage)
        XCTAssertNotEqual(AccountDeletionClient.timedOutMessage, "Method Not Allowed")
        XCTAssertTrue(result.staysSignedIn)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(clearerCalls, 0)
        XCTAssertEqual(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey), "org-keep")

        let other = AccountDeletionClient.transportFailure(URLError(.cancelled))
        XCTAssertEqual(other, .failed(AccountDeletionClient.genericFailureMessage))
        let dropped = AccountDeletionClient.transportFailure(
            NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)
        )
        XCTAssertEqual(dropped, .failed(AccountDeletionClient.timedOutMessage))
    }

    func testServerErrorStaysSignedIn() async {
        defaults.set("org-keep", forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
        let transport = StubAccountDeletionTransport(
            statusCode: 500,
            body: Data(#"{"error":"upstream"}"#.utf8)
        )
        var signedOut = false
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { "id-token-1" },
            transport: transport,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .failed("upstream"))
        XCTAssertTrue(result.staysSignedIn)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey), "org-keep")
        let unavailable = AccountDeletionClient.interpret(statusCode: 503, body: Data())
        XCTAssertEqual(unavailable, .failed(AccountDeletionClient.genericFailureMessage))
        XCTAssertTrue(unavailable.staysSignedIn)
    }

    func testDeletedUserAuthCodesMatchThisSDK() {
        XCTAssertTrue(AccountDeletionClient.sessionEnded(authDomain: "FIRAuthErrorDomain", code: 17011))
        XCTAssertTrue(AccountDeletionClient.sessionEnded(authDomain: "FIRAuthErrorDomain", code: 17004))
        XCTAssertTrue(AccountDeletionClient.sessionEnded(authDomain: "FIRAuthErrorDomain", code: 17021))
        XCTAssertFalse(AccountDeletionClient.sessionEnded(authDomain: "FIRAuthErrorDomain", code: 17020))
        XCTAssertFalse(AccountDeletionClient.sessionEnded(authDomain: "FIRAuthErrorDomain", code: 17009))
        XCTAssertFalse(AccountDeletionClient.sessionEnded(authDomain: "NSURLErrorDomain", code: 17011))
    }

    func testAuthCheckKeepsALiveUserAndTreatsAMissingUserAsGone() {
        XCTAssertEqual(
            AccountDeletionClient.sessionAfterFailure(reload: .missingUser, token: nil),
            .gone
        )
        XCTAssertEqual(
            AccountDeletionClient.sessionAfterFailure(
                reload: .failed(domain: "FIRAuthErrorDomain", code: 17011),
                token: nil
            ),
            .gone
        )
        XCTAssertEqual(
            AccountDeletionClient.sessionAfterFailure(
                reload: .userStillExists,
                token: .failed(domain: "FIRAuthErrorDomain", code: 17021)
            ),
            .stillSignedIn
        )
        XCTAssertEqual(
            AccountDeletionClient.sessionAfterFailure(
                reload: .failed(domain: "FIRAuthErrorDomain", code: 17020),
                token: .failed(domain: "FIRAuthErrorDomain", code: 17011)
            ),
            .gone
        )
        XCTAssertEqual(
            AccountDeletionClient.sessionAfterFailure(
                reload: .failed(domain: "FIRAuthErrorDomain", code: 17020),
                token: .userStillExists
            ),
            .stillSignedIn
        )
        XCTAssertEqual(
            AccountDeletionClient.sessionAfterFailure(
                reload: .failed(domain: "FIRAuthErrorDomain", code: 17020),
                token: .failed(domain: "NSURLErrorDomain", code: URLError.timedOut.rawValue)
            ),
            .stillSignedIn
        )
    }

    func testTimeoutAfterAuthIsGoneSignsOutAndClearsCaches() async {
        defaults.set("org-keep", forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
        defaults.set("North Yard", forKey: AccountDeletionClient.rememberedOrganizationNameDefaultsKey)
        let transport = ThrowingAccountDeletionTransport(error: URLError(.timedOut))
        var events: [String] = []
        var keyWhenClearerRan: String?
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            confirmPassword: {},
            idToken: { "id-token-1" },
            transport: transport,
            sessionAfterFailure: { .gone },
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {
                keyWhenClearerRan = self.defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
                events.append("clearLocalOrganizationCache")
            },
            clearPersistence: { events.append("persistence:\($0)") },
            signOut: { events.append("signOut") }
        )
        XCTAssertEqual(result, .deleted)
        XCTAssertNil(result.failureMessage)
        XCTAssertNotEqual(result, .failed(AccountDeletionClient.timedOutMessage))
        XCTAssertNotEqual(result, .failed(AccountDeletionClient.genericFailureMessage))
        XCTAssertFalse(result.staysSignedIn)
        XCTAssertNil(keyWhenClearerRan)
        XCTAssertNil(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey))
        XCTAssertNil(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationNameDefaultsKey))
        XCTAssertEqual(events, ["clearLocalOrganizationCache", "persistence:user-1", "signOut"])
    }

    func testTimeoutWhileAuthUserStillExistsStaysAFailure() async {
        defaults.set("org-keep", forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
        let transport = ThrowingAccountDeletionTransport(error: URLError(.timedOut))
        var probes = 0
        var signedOut = false
        var clearerCalls = 0
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            confirmPassword: {},
            idToken: { "id-token-1" },
            transport: transport,
            sessionAfterFailure: {
                probes += 1
                return .stillSignedIn
            },
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: { clearerCalls += 1 },
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .failed(AccountDeletionClient.timedOutMessage))
        XCTAssertEqual(result.failureMessage, AccountDeletionClient.timedOutMessage)
        XCTAssertTrue(result.staysSignedIn)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(clearerCalls, 0)
        XCTAssertEqual(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey), "org-keep")
    }

    func testPasswordIncorrectAfterAuthIsGoneSignsOut() async {
        defaults.set("org-keep", forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
        defaults.set("North Yard", forKey: AccountDeletionClient.rememberedOrganizationNameDefaultsKey)
        let transport = StubAccountDeletionTransport(
            statusCode: 401,
            body: Data(#"{"error":"Password is incorrect."}"#.utf8)
        )
        var events: [String] = []
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            confirmPassword: {},
            idToken: { "id-token-1" },
            transport: transport,
            sessionAfterFailure: { .gone },
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: { events.append("clearLocalOrganizationCache") },
            clearPersistence: { events.append("persistence:\($0)") },
            signOut: { events.append("signOut") }
        )
        XCTAssertEqual(result, .deleted)
        XCTAssertNil(result.failureMessage)
        XCTAssertFalse(result.staysSignedIn)
        XCTAssertNil(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey))
        XCTAssertNil(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationNameDefaultsKey))
        XCTAssertEqual(events, ["clearLocalOrganizationCache", "persistence:user-1", "signOut"])
        if case .passwordNotAccepted = result {
            XCTFail("a 401 after Auth is gone is a finished delete")
        }
    }

    func testPasswordIncorrectWithoutLocalReauthAfterAuthIsGoneSignsOut() async {
        let transport = StubAccountDeletionTransport(
            statusCode: 401,
            body: Data(#"{"error":"Password is incorrect."}"#.utf8)
        )
        var signedOut = false
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { "id-token-1" },
            transport: transport,
            sessionAfterFailure: { .gone },
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .deleted)
        XCTAssertNil(result.failureMessage)
        XCTAssertTrue(signedOut)
        XCTAssertFalse(result.staysSignedIn)
    }

    func testGenericFailureAndBadGatewayAfterAuthIsGoneSignOut() async {
        defaults.set("org-keep", forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
        let generic = StubAccountDeletionTransport(statusCode: 500, body: Data())
        var genericSignedOut = false
        let genericResult = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { "id-token-1" },
            transport: generic,
            sessionAfterFailure: { .gone },
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { genericSignedOut = true }
        )
        XCTAssertEqual(genericResult, .deleted)
        XCTAssertNil(genericResult.failureMessage)
        XCTAssertTrue(genericSignedOut)
        XCTAssertNil(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey))

        defaults.set("org-keep", forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
        let gateway = StubAccountDeletionTransport(
            statusCode: 502,
            body: Data(#"{"error":"Bad Gateway"}"#.utf8)
        )
        var gatewaySignedOut = false
        let gatewayResult = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { "id-token-1" },
            transport: gateway,
            sessionAfterFailure: { .gone },
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { gatewaySignedOut = true }
        )
        XCTAssertEqual(gatewayResult, .deleted)
        XCTAssertNil(gatewayResult.failureMessage)
        XCTAssertTrue(gatewaySignedOut)
        XCTAssertNil(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey))
    }

    func testBadGatewayWhileAuthUserStillExistsStaysAFailure() async {
        defaults.set("org-keep", forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
        let transport = StubAccountDeletionTransport(
            statusCode: 502,
            body: Data(#"{"error":"Bad Gateway"}"#.utf8)
        )
        var signedOut = false
        let result = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { "id-token-1" },
            transport: transport,
            sessionAfterFailure: { .stillSignedIn },
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { signedOut = true }
        )
        XCTAssertEqual(result, .failed("Bad Gateway"))
        XCTAssertEqual(result.failureMessage, "Bad Gateway")
        XCTAssertTrue(result.staysSignedIn)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey), "org-keep")
    }

    func testSoleAdminAndNotConfiguredStayFailuresEvenWhenAuthIsGone() async {
        defaults.set("org-keep", forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey)
        var probes = 0
        let session: () async -> AccountDeletionClient.SessionAfterFailure = {
            probes += 1
            return .gone
        }

        let soleAdmin = StubAccountDeletionTransport(
            statusCode: 409,
            body: Data(#"{"error":"sole admin","code":"sole_admin","orgName":"North Yard"}"#.utf8)
        )
        var soleAdminSignedOut = false
        let soleAdminResult = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { "id-token-1" },
            transport: soleAdmin,
            sessionAfterFailure: session,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { soleAdminSignedOut = true }
        )
        XCTAssertEqual(
            soleAdminResult,
            .soleAdmin("You are the only admin of North Yard. Transfer admin access to someone else, or email info@projectplanner.us if you need this organisation removed.")
        )
        XCTAssertEqual(
            soleAdminResult.failureMessage,
            "You are the only admin of North Yard. Transfer admin access to someone else, or email info@projectplanner.us if you need this organisation removed."
        )
        XCTAssertTrue(soleAdminResult.staysSignedIn)
        XCTAssertTrue(soleAdminResult.hidesDeleteButton)
        XCTAssertFalse(soleAdminSignedOut)

        let notConfigured = StubAccountDeletionTransport(
            statusCode: 501,
            body: Data(#"{"error":"The account could not be deleted."}"#.utf8)
        )
        var notConfiguredSignedOut = false
        let notConfiguredResult = await AccountDeletionClient.perform(
            email: "planner@example.com",
            confirmation: "DELETE",
            password: "secret",
            idToken: { "id-token-1" },
            transport: notConfigured,
            sessionAfterFailure: session,
            userId: "user-1",
            defaults: defaults,
            clearRememberedOrganization: {},
            clearPersistence: { _ in },
            signOut: { notConfiguredSignedOut = true }
        )
        XCTAssertEqual(
            notConfiguredResult,
            .serverNotConfigured(AccountDeletionClient.serverNotConfiguredMessage)
        )
        XCTAssertEqual(notConfiguredResult.failureMessage, "The delete could not be completed.")
        XCTAssertTrue(notConfiguredResult.staysSignedIn)
        XCTAssertFalse(notConfiguredResult.hidesDeleteButton)
        XCTAssertFalse(notConfiguredSignedOut)
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(defaults.string(forKey: AccountDeletionClient.rememberedOrganizationDefaultsKey), "org-keep")
    }
}

private final class ThrowingAccountDeletionTransport: AccountDeletionTransport, @unchecked Sendable {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw error
    }
}

private final class StubAccountDeletionTransport: AccountDeletionTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var statusCode: Int
    var body: Data

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url ?? URL(string: "https://www.projectplanner.us/api/account/delete")!
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}
