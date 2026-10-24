//
//  WarningsSortPreference.swift
//  Project Planner
//
//  Oldest / Newest for the Warnings list. Per signed-in user on this device only.
//

import Foundation

enum WarningsSortPreference {
    static func storageKey(userId: String) -> String {
        "warningsSortDirection:\(userId.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// The direction to show. Oldest only when this user has never stored a choice.
    /// Nil when the script does not answer — do not invent a direction or write one.
    static func direction(userId: String, defaults: UserDefaults = .standard) -> String? {
        let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            return CanonicalBusinessEngine.parseWarningsSortDirection(nil)
        }
        let key = storageKey(userId: id)
        if defaults.object(forKey: key) != nil {
            return CanonicalBusinessEngine.parseWarningsSortDirection(defaults.string(forKey: key))
        }
        return CanonicalBusinessEngine.parseWarningsSortDirection(nil)
    }

    /// Writes this user's choice. Nil when the script does not answer, or when it rewrites the
    /// string — a guessed oldest is not stored over a choice they already made.
    @discardableResult
    static func save(userId: String, direction: String, defaults: UserDefaults = .standard) -> String? {
        let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let trimmed = direction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = CanonicalBusinessEngine.parseWarningsSortDirection(trimmed) else { return nil }
        guard parsed == trimmed else { return nil }
        defaults.set(parsed, forKey: storageKey(userId: id))
        return parsed
    }
}
