//
//  LineManagerSupport.swift
//  Project Planner
//
//  Multiple line managers with legacy single-id migration.
//

import Foundation

extension AppUser {
    /// All assigned line manager user ids (deduped, non-empty).
    var lineManagerUserIds: [String] {
        var ids = assignedManagerUserIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if ids.isEmpty,
           let legacy = assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacy.isEmpty {
            ids = [legacy]
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// True when this user has at least one assigned line manager and is not marked “no line manager”.
    var hasLineManager: Bool { !hasNoLineManager && !lineManagerUserIds.isEmpty }

    /// Primary line manager (first assigned) — backward compatible with single-id field.
    var primaryLineManagerUserId: String? { lineManagerUserIds.first }

    mutating func setLineManagerUserIds(_ ids: [String]) {
        let normalized = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        assignedManagerUserIds = normalized.filter { seen.insert($0).inserted }
        assignedManagerUserId = assignedManagerUserIds.first
        if !assignedManagerUserIds.isEmpty {
            hasNoLineManager = false
        }
    }

    mutating func setNoLineManager(_ enabled: Bool) {
        hasNoLineManager = enabled
        if enabled {
            assignedManagerUserIds = []
            assignedManagerUserId = nil
        }
    }

    /// `CanonicalBusinessEngine.lineManagerIds(user:roster:)` from the packed script (RULEBOOK §8): `assignedManagerUserIds`, else the
    /// legacy single id, none when `hasNoLineManager`; with the live roster only active managers count, an old
    /// invite id is resolved to its roster row, and the person never counts under any of their ids.
    var canonicalLineManagerIds: [String] {
        RulebookRosterSnapshot.lineManagerIds(self) ?? (hasNoLineManager ? [] : lineManagerUserIds)
    }

    func isLineManager(_ managerUserId: String) -> Bool {
        let wanted = managerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        let ids = canonicalLineManagerIds
        if ids.contains(wanted) { return true }
        // `lineManagerIds` names roster rows; the roster may keep this person under another document id.
        guard let row = RulebookRosterSnapshot.users.first(where: {
            $0.id == wanted || $0.sameEmailUserIds.contains(wanted) || $0.formerUserIds.contains(wanted)
        }) else { return false }
        return ids.contains(row.id)
    }
}

enum LineManagerRouting {
    static func recipients(for user: AppUser) -> [String] {
        user.lineManagerUserIds
    }

    static func requiresCounterSign(for user: AppUser) -> Bool {
        user.hasLineManager
    }
}
