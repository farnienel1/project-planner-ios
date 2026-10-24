//
//  SignInAuthError.swift
//  Project Planner
//
//  Email/password sign-in presentation only.
//  Password reset, delete-account reauth, and token refresh do not use this.
//

import Foundation

enum SignInAuthError {
    static let accountDoesNotExist = "This account does not exist."

    /// English `invalidCredential` (17004) sentence from Firebase Auth.
    /// Email-enumeration protection uses this for a missing user and a wrong password.
    static let malformedOrExpiredCredential = "The supplied auth credential is malformed or has expired."

    /// `userNotFound` is 17011. `wrongPassword` is 17009 and keeps Firebase's own sentence.
    static func presentedMessage(domain: String, code: Int, localizedDescription: String) -> String {
        guard domain == "FIRAuthErrorDomain" else { return localizedDescription }
        switch code {
        case 17011:
            return accountDoesNotExist
        case 17004 where localizedDescription == malformedOrExpiredCredential:
            return accountDoesNotExist
        default:
            return localizedDescription
        }
    }
}
