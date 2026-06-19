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

    var hasLineManager: Bool { !lineManagerUserIds.isEmpty }

    /// Primary line manager (first assigned) — backward compatible with single-id field.
    var primaryLineManagerUserId: String? { lineManagerUserIds.first }

    mutating func setLineManagerUserIds(_ ids: [String]) {
        let normalized = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        assignedManagerUserIds = normalized.filter { seen.insert($0).inserted }
        assignedManagerUserId = assignedManagerUserIds.first
    }

    func isLineManager(_ managerUserId: String) -> Bool {
        lineManagerUserIds.contains(managerUserId)
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
