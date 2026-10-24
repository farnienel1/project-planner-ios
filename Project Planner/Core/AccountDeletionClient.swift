//
//  AccountDeletionClient.swift
//  Project Planner
//
//  POST /api/account/delete. This file maps the response. It does not delete
//  company records, anonymise them again, or promote another admin.
//

import FirebaseAuth
import Foundation

protocol AccountDeletionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionAccountDeletionTransport: AccountDeletionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        let deadline = request.timeoutInterval > 0
            ? request.timeoutInterval
            : AccountDeletionClient.requestTimeout
        configuration.timeoutIntervalForRequest = deadline
        configuration.timeoutIntervalForResource = deadline
        configuration.waitsForConnectivity = false
        // Async `data(for:)` does not finish reliably when the session itself has a delegate.
        // The redirect decision is a task delegate on a session whose delegate is nil.
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request, delegate: AccountDeletionNoRedirectDelegate())
    }
}

/// `www` POST is a 308. Following it can replay the call without the bearer token.
/// Refusing the follow-up must end the task with the redirect response, not leave it open.
private final class AccountDeletionNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            AccountDeletionClient.followRedirect(proposed: request, statusCode: response.statusCode)
        )
    }
}

enum AccountDeletionClient {
    static let requiredConfirmation = "DELETE"
    static let protectedEmail = "info@projectplanner.us"
    static let rememberedOrganizationDefaultsKey = "cached_organizationId"
    static let rememberedOrganizationNameDefaultsKey = "cached_organizationName"

    static let confirmationRejectedMessage = "Type DELETE and enter your current password."
    static let serverRejectedMessage = "That request was not accepted."
    static let passwordNotAcceptedMessage = "That password was not accepted."
    static let signInAgainMessage = "You need to sign in again."
    static let supportAccountMessage = "info@projectplanner.us cannot delete this account."
    static let rateLimitedMessage = "Try again later."
    static let serverNotConfiguredMessage = "The delete could not be completed."
    static let genericFailureMessage = "The account could not be deleted."
    static let timedOutMessage = "The delete timed out. Try again."
    /// Shorter than URLSession's 60s default, which is what kept the button spinning.
    static let requestTimeout: TimeInterval = 20

    enum TokenError: Error {
        case notSignedIn
    }

    /// Local email/password reauth, before any HTTP call. Wrong password stays on this screen.
    enum PasswordCheckError: Error, Equatable {
        case wrongPassword
        case notSignedIn
        /// Reauth did not finish. The session is still there.
        case unavailable
    }

    /// Firebase Auth: `wrongPassword` 17009 and `invalidCredential` 17004 are the password.
    /// `requiresRecentLogin` 17014, `invalidUserToken` 17017, `userTokenExpired` 17021,
    /// and `sessionExpired` 17051 are a missing login.
    /// Network and other codes are not a missing login.
    static func passwordCheckFailure(authDomain: String, code: Int) -> PasswordCheckError {
        guard authDomain == "FIRAuthErrorDomain" else { return .unavailable }
        switch code {
        case 17009, 17004:
            return .wrongPassword
        case 17014, 17017, 17021, 17051:
            return .notSignedIn
        default:
            return .unavailable
        }
    }

    enum Result: Equatable {
        case rejectedBeforeRequest(String)
        case supportAccountRefused(String)
        case deleted
        case soleAdmin(String)
        case passwordNotAccepted(String)
        case rateLimited(String)
        case serverNotConfigured(String)
        case failed(String)

        /// Only `.deleted` ends the session. A timeout, 502, generic failure, or 401
        /// password rejection is promoted to `.deleted` when Auth is already gone.
        var staysSignedIn: Bool {
            if case .deleted = self { return false }
            return true
        }

        /// Red text under the form. `.deleted` has none.
        var failureMessage: String? {
            switch self {
            case .deleted:
                return nil
            case .rejectedBeforeRequest(let text),
                 .supportAccountRefused(let text),
                 .soleAdmin(let text),
                 .passwordNotAccepted(let text),
                 .rateLimited(let text),
                 .serverNotConfigured(let text),
                 .failed(let text):
                return text
            }
        }

        var hidesDeleteButton: Bool {
            if case .soleAdmin = self { return true }
            return false
        }
    }

    /// Result of `reload()` or `getIDToken(forcingRefresh:)` after an ambiguous delete response.
    enum AuthCheck: Equatable {
        case missingUser
        case userStillExists
        case failed(domain: String, code: Int)
    }

    enum SessionAfterFailure: Equatable {
        case stillSignedIn
        case gone
    }

    static func soleAdminMessage(orgName: String) -> String {
        let trimmed = orgName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "your organisation" : trimmed
        return "You are the only admin of \(name). Transfer admin access to someone else, or email info@projectplanner.us if you need this organisation removed."
    }

    /// `www.projectplanner.us` answers this path with 301 to `projectplanner.us`.
    /// URLSession follows that with a GET and no Authorization header, so the route
    /// never sees the ID token. The request uses the host that does not redirect.
    static func endpointURL(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if components.host?.lowercased() == "www.projectplanner.us" {
            components.host = "projectplanner.us"
        }
        guard let rootURL = components.url else { return nil }
        var root = rootURL.absoluteString
        while root.hasSuffix("/") {
            root.removeLast()
        }
        return URL(string: root + "/api/account/delete")
    }

    /// Never follow. The proposed request for the www 301 is a GET with no bearer token.
    static func followRedirect(proposed: URLRequest, statusCode: Int) -> URLRequest? {
        guard (300..<400).contains(statusCode), proposed.url != nil else { return nil }
        return nil
    }

    /// The tap uid and the user the token will be minted for must be the same person.
    static func userMismatch(expectedUserId: String?, tokenUserId: String?) -> Result? {
        let expected = expectedUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let actual = tokenUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !expected.isEmpty, !actual.isEmpty, expected != actual else { return nil }
        return .failed(genericFailureMessage)
    }

    static func isProtectedSupportEmail(_ email: String?) -> Bool {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed == protectedEmail
    }

    /// Removes the phone's remembered company. Same-user sign-out does not do this.
    static func clearRememberedOrganizationKey(in defaults: UserDefaults) {
        defaults.removeObject(forKey: rememberedOrganizationDefaultsKey)
        defaults.removeObject(forKey: rememberedOrganizationNameDefaultsKey)
    }

    /// Validates, calls the API, and on 200 clears the remembered organisation before sign-out.
    static func perform(
        email: String?,
        confirmation: String,
        password: String,
        baseURL: URL? = nil,
        confirmPassword: (() async throws -> Void)? = nil,
        idToken: () async throws -> String,
        tokenUserId: () -> String? = { nil },
        transport: AccountDeletionTransport? = nil,
        statusLog: (Int) -> Void = { status in
            print("account/delete HTTP \(status)")
        },
        sessionAfterFailure: () async -> SessionAfterFailure = { .stillSignedIn },
        userId: String?,
        defaults: UserDefaults = .standard,
        clearRememberedOrganization: () -> Void,
        clearPersistence: (String) async -> Void,
        signOut: () -> Void
    ) async -> Result {
        if let blocked = preflight(email: email, confirmation: confirmation, password: password) {
            return blocked
        }

        if let confirmPassword {
            do {
                try await confirmPassword()
            } catch let error as PasswordCheckError {
                switch error {
                case .wrongPassword:
                    return .passwordNotAccepted(passwordNotAcceptedMessage)
                case .notSignedIn:
                    return .rejectedBeforeRequest(signInAgainMessage)
                case .unavailable:
                    return .failed(genericFailureMessage)
                }
            } catch {
                return .failed(genericFailureMessage)
            }
        }

        if let blocked = userMismatch(expectedUserId: userId, tokenUserId: tokenUserId()) {
            return blocked
        }

        let token: String
        do {
            token = try await idToken()
        } catch is TokenError {
            return .rejectedBeforeRequest(signInAgainMessage)
        } catch {
            return .failed(genericFailureMessage)
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            return .rejectedBeforeRequest(signInAgainMessage)
        }

        let resolvedBase = baseURL ?? URL(string: AppBranding.webAppBaseURL)
        guard let resolvedBase, let url = endpointURL(baseURL: resolvedBase) else {
            return .failed(genericFailureMessage)
        }
        let resolvedTransport = transport ?? URLSessionAccountDeletionTransport()

        guard let body = try? JSONSerialization.data(withJSONObject: [
            "confirmation": requiredConfirmation,
            "password": password
        ]) else {
            return .failed(genericFailureMessage)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await resolvedTransport.data(for: request)
        } catch {
            return await promoteIfAuthIsGone(
                transportFailure(error),
                statusCode: nil,
                sessionAfterFailure: sessionAfterFailure,
                userId: userId,
                defaults: defaults,
                clearRememberedOrganization: clearRememberedOrganization,
                clearPersistence: clearPersistence,
                signOut: signOut
            )
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        statusLog(status)
        let result = interpret(
            statusCode: status,
            body: data,
            passwordConfirmedLocally: confirmPassword != nil,
            bearerTokenAttached: true
        )
        if case .deleted = result {
            await finishDeletedLogin(
                userId: userId,
                defaults: defaults,
                clearRememberedOrganization: clearRememberedOrganization,
                clearPersistence: clearPersistence,
                signOut: signOut
            )
            return result
        }
        return await promoteIfAuthIsGone(
            result,
            statusCode: status,
            sessionAfterFailure: sessionAfterFailure,
            userId: userId,
            defaults: defaults,
            clearRememberedOrganization: clearRememberedOrganization,
            clearPersistence: clearPersistence,
            signOut: signOut
        )
    }

    /// Timeout, 502, "The account could not be deleted.", "The delete timed out. Try again.",
    /// and a 401 password rejection can mean the server already removed the Auth user.
    /// 409 sole_admin and 501 stay failures. A live Auth user stays a failure too.
    static func promoteIfAuthIsGone(
        _ result: Result,
        statusCode: Int?,
        sessionAfterFailure: () async -> SessionAfterFailure,
        userId: String?,
        defaults: UserDefaults,
        clearRememberedOrganization: () -> Void,
        clearPersistence: (String) async -> Void,
        signOut: () -> Void
    ) async -> Result {
        guard ambiguousDeleteFailure(result, statusCode: statusCode) else {
            return result
        }
        if await sessionAfterFailure() == .gone {
            await finishDeletedLogin(
                userId: userId,
                defaults: defaults,
                clearRememberedOrganization: clearRememberedOrganization,
                clearPersistence: clearPersistence,
                signOut: signOut
            )
            return .deleted
        }
        return result
    }

    /// `AuthErrorCode` in this project's firebase-ios-sdk checkout:
    /// `userNotFound` 17011, `invalidCredential` 17004, `userTokenExpired` 17021.
    /// `networkError` 17020 is not evidence the account is gone.
    /// This is the post-delete probe. The password reauth check still treats 17004 as a wrong password.
    static func sessionEnded(authDomain: String, code: Int) -> Bool {
        guard authDomain == AuthErrorDomain else { return false }
        switch code {
        case AuthErrorCode.userNotFound.rawValue,
             AuthErrorCode.invalidCredential.rawValue,
             AuthErrorCode.userTokenExpired.rawValue:
            return true
        default:
            return false
        }
    }

    /// A successful reload means the user still exists, even if a later token error is one of the gone codes.
    /// A reload that did not prove the user exists can still be gone when the token refresh fails with those codes.
    static func sessionAfterFailure(reload: AuthCheck, token: AuthCheck?) -> SessionAfterFailure {
        switch reload {
        case .missingUser:
            return .gone
        case .userStillExists:
            return .stillSignedIn
        case .failed(let domain, let code):
            if sessionEnded(authDomain: domain, code: code) {
                return .gone
            }
            guard let token else { return .stillSignedIn }
            switch token {
            case .missingUser:
                return .gone
            case .failed(let tokenDomain, let tokenCode) where sessionEnded(authDomain: tokenDomain, code: tokenCode):
                return .gone
            case .userStillExists, .failed:
                return .stillSignedIn
            }
        }
    }

    static func ambiguousDeleteFailure(_ result: Result, statusCode: Int?) -> Bool {
        switch result {
        case .soleAdmin, .serverNotConfigured, .rejectedBeforeRequest, .supportAccountRefused, .rateLimited, .deleted:
            return false
        case .passwordNotAccepted:
            return true
        case .failed(let message):
            if statusCode == 501 { return false }
            if statusCode == 502 { return true }
            return message == genericFailureMessage || message == timedOutMessage
        }
    }

    /// Clears the remembered organisation while the uid is still known, then persistence, then sign-out.
    static func finishDeletedLogin(
        userId: String?,
        defaults: UserDefaults,
        clearRememberedOrganization: () -> Void,
        clearPersistence: (String) async -> Void,
        signOut: () -> Void
    ) async {
        clearRememberedOrganizationKey(in: defaults)
        clearRememberedOrganization()
        if let userId {
            let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                await clearPersistence(trimmed)
            }
        }
        signOut()
    }

    /// A stuck task used to surface the same sentence as an empty 405.
    static func transportFailure(_ error: Error) -> Result {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == URLError.Code.timedOut.rawValue {
            return .failed(timedOutMessage)
        }
        return .failed(genericFailureMessage)
    }

    static func preflight(email: String?, confirmation: String, password: String) -> Result? {
        if isProtectedSupportEmail(email) {
            return .supportAccountRefused(supportAccountMessage)
        }
        let passwordIsEmpty = password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if confirmation != requiredConfirmation || passwordIsEmpty {
            return .rejectedBeforeRequest(confirmationRejectedMessage)
        }
        return nil
    }

    static func interpret(
        statusCode: Int,
        body: Data,
        passwordConfirmedLocally: Bool = false,
        bearerTokenAttached: Bool = false
    ) -> Result {
        let payload = jsonObject(body)
        switch statusCode {
        case 200:
            if payload?["ok"] as? Bool == true {
                return .deleted
            }
            return .failed(serverMessage(in: payload, fallback: genericFailureMessage))
        case 400:
            return .rejectedBeforeRequest(serverMessage(in: payload, fallback: serverRejectedMessage))
        case 401:
            return unauthorized(
                payload,
                passwordConfirmedLocally: passwordConfirmedLocally,
                bearerTokenAttached: bearerTokenAttached
            )
        case 403:
            return .supportAccountRefused(serverMessage(in: payload, fallback: supportAccountMessage))
        case 409:
            if (payload?["code"] as? String) == "sole_admin" {
                let orgName = payload?["orgName"] as? String ?? ""
                return .soleAdmin(soleAdminMessage(orgName: orgName))
            }
            return .failed(serverMessage(in: payload, fallback: genericFailureMessage))
        case 429:
            return .rateLimited(rateLimitedMessage)
        case 500...599:
            if statusCode == 501 {
                return .serverNotConfigured(serverNotConfiguredMessage)
            }
            return .failed(serverMessage(in: payload, fallback: genericFailureMessage))
        default:
            return .failed(serverMessage(in: payload, fallback: genericFailureMessage))
        }
    }

    /// 401 is a wrong password or a session the server did not accept.
    /// A bearer token from the signed-in user is not reported as "Sign in required".
    /// A password Firebase just accepted is not reported as a wrong password.
    private static func unauthorized(
        _ payload: [String: Any]?,
        passwordConfirmedLocally: Bool,
        bearerTokenAttached: Bool
    ) -> Result {
        if meansWrongPassword(payload) {
            if passwordConfirmedLocally {
                return .failed(genericFailureMessage)
            }
            return .passwordNotAccepted(passwordNotAcceptedMessage)
        }
        let sessionShaped = meansMissingSession(payload) || errorString(in: payload).isEmpty
        if sessionShaped {
            if passwordConfirmedLocally || bearerTokenAttached {
                return .failed(genericFailureMessage)
            }
            return .failed(signInAgainMessage)
        }
        return .failed(errorString(in: payload))
    }

    /// Web `POST /api/account/delete` uses `{ "error": "Password is incorrect." }` with no code.
    /// `requireFirebaseUser` uses `{ "error": "Sign in required" }` when it rejects the bearer token.
    /// A code is accepted when a later response adds one.
    private static func meansWrongPassword(_ payload: [String: Any]?) -> Bool {
        let code = errorString(named: "code", in: payload).lowercased()
        if wrongPasswordCodes.contains(code) {
            return true
        }
        let error = errorString(in: payload).lowercased()
        return error == "password is incorrect." || error == "password is incorrect"
    }

    private static let wrongPasswordCodes: Set<String> = [
        "wrong_password",
        "password_incorrect",
        "incorrect_password",
        "invalid_password"
    ]

    /// Session-shaped 401. The raw "Sign in required" sentence is never shown.
    private static func meansMissingSession(_ payload: [String: Any]?) -> Bool {
        let code = errorString(named: "code", in: payload).lowercased()
        if missingSessionCodes.contains(code) {
            return true
        }
        let error = errorString(in: payload).lowercased()
        return missingSessionPhrases.contains(error)
    }

    private static let missingSessionCodes: Set<String> = [
        "sign_in_required",
        "signin_required",
        "unauthenticated",
        "session_expired",
        "auth_required"
    ]

    private static let missingSessionPhrases: Set<String> = [
        "sign in required",
        "sign in required."
    ]

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func serverMessage(in payload: [String: Any]?, fallback: String) -> String {
        let error = errorString(in: payload)
        return error.isEmpty ? fallback : error
    }

    private static func errorString(in payload: [String: Any]?) -> String {
        errorString(named: "error", in: payload)
    }

    private static func errorString(named key: String, in payload: [String: Any]?) -> String {
        (payload?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
