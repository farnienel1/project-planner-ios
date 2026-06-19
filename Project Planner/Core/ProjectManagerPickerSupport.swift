//
//  ProjectManagerPickerSupport.swift
//  Project Planner
//
//  Project / small-works manager picker including admins and super admins.
//

import Foundation

enum ProjectManagerPickerSupport {
    /// Managers available to assign, including roster managers and admin app users not yet on the roster.
    static func availableManagers(
        operativeStore: OperativeStore,
        userStore: UserStore,
        excluding selected: [Manager]
    ) -> [Manager] {
        let selectedIds = Set(selected.map(\.id))
        var roster = operativeStore.allManagers.filter { !selectedIds.contains($0.id) && $0.isActive }
        let rosterEmails = Set(roster.map { $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })

        for user in userStore.organizationUsers where user.isActive && user.passwordSet {
            guard user.isSuperAdmin || user.permissions.adminAccess || user.role == .admin else { continue }
            let email = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if rosterEmails.contains(email) { continue }
            if let existing = operativeStore.allManagers.first(where: {
                $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == email && $0.isActive
            }), !selectedIds.contains(existing.id) {
                roster.append(existing)
                continue
            }
            roster.append(
                Manager(
                    firstName: user.firstName.isEmpty ? user.email : user.firstName,
                    lastName: user.surname,
                    email: user.email,
                    mobileNumber: user.mobileNumber ?? "",
                    isActive: true
                )
            )
        }

        return roster.sorted {
            $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
        }
    }

    /// Ensures each selected manager exists on the operative roster before persisting project manager ids.
    static func resolveManagersForSave(
        _ managers: [Manager],
        operativeStore: OperativeStore
    ) async -> [Manager] {
        var resolved: [Manager] = []
        for manager in managers {
            let email = manager.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = operativeStore.allManagers.first(where: {
                $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == email
            }) {
                resolved.append(existing)
                continue
            }
            await operativeStore.addManager(manager)
            if let saved = operativeStore.allManagers.first(where: {
                $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == email
            }) {
                resolved.append(saved)
            } else {
                resolved.append(manager)
            }
        }
        return resolved
    }
}
