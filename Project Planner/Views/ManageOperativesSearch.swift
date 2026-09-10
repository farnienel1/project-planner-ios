//
//  ManageOperativesSearch.swift
//  Project Planner
//
//  Shared live search matching for Manage Operatives / Manage Users lists.
//

import Foundation

enum ManageOperativesSearch {
    /// Letter-by-letter filter: every whitespace-separated token must match
    /// first name, surname, full name, email, or phone.
    static func matches(user: AppUser, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let haystacks = searchableFields(for: user)
        let tokens = trimmed
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            haystacks.contains { $0.contains(token) }
        }
    }

    /// Lower score = better match (prefix beats substring).
    static func rank(user: AppUser, query: String) -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return 100 }

        let first = user.firstName.lowercased()
        let last = user.surname.lowercased()
        let full = user.fullName.lowercased()
        let email = user.email.lowercased()

        if full.hasPrefix(trimmed) || first.hasPrefix(trimmed) { return 0 }
        if last.hasPrefix(trimmed) { return 1 }
        if full.contains(trimmed) { return 2 }
        if email.hasPrefix(trimmed) { return 3 }
        if email.contains(trimmed) { return 4 }
        return 5
    }

    static func sorted(_ users: [AppUser], query: String) -> [AppUser] {
        users.sorted { lhs, rhs in
            let lr = rank(user: lhs, query: query)
            let rr = rank(user: rhs, query: query)
            if lr != rr { return lr < rr }
            let ln = lhs.fullName.isEmpty ? lhs.email : lhs.fullName
            let rn = rhs.fullName.isEmpty ? rhs.email : rhs.fullName
            return ln.localizedCaseInsensitiveCompare(rn) == .orderedAscending
        }
    }

    private static func searchableFields(for user: AppUser) -> [String] {
        var fields = [
            user.firstName,
            user.surname,
            user.fullName,
            user.email,
        ]
        if let mobile = user.mobileNumber {
            fields.append(mobile)
        }
        return fields
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}
