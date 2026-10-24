//
//  AuthFormValidation.swift
//  Project Planner
//
//  Checks for the unsigned sign-in and password-reset forms.
//  Firebase Auth still receives the password. This does not say whether an account exists.
//

import Foundation

enum AuthFormValidation {
    static let emailRequiredMessage = "Please enter your email address."
    static let emailInvalidMessage = "Please add a valid email address."
    static let passwordRequiredMessage = "Please enter your password."

    /// After trim: required, at most 254 characters, and one `local@domain.tld` with no whitespace.
    static func emailMessage(for raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return emailRequiredMessage
        }
        if trimmed.count > 254 || !matchesEmailPattern(trimmed) {
            return emailInvalidMessage
        }
        return nil
    }

    /// Login only. Required after trim. No minimum and no maximum length.
    static func loginPasswordMessage(for raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return passwordRequiredMessage
        }
        return nil
    }

    /// Email message first, then the login password message, omitting checks that pass.
    static func loginMessages(email: String, password: String) -> [String] {
        var messages: [String] = []
        if let emailMessage = emailMessage(for: email) {
            messages.append(emailMessage)
        }
        if let passwordMessage = loginPasswordMessage(for: password) {
            messages.append(passwordMessage)
        }
        return messages
    }

    private static func matchesEmailPattern(_ trimmed: String) -> Bool {
        trimmed.range(
            of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#,
            options: .regularExpression
        ) != nil
    }
}
