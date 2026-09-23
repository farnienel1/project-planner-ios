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
        let selectedEmails = Set(selected.map { $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        var roster = operativeStore.allManagers.filter {
            !$0.email.isEmpty && !selectedIds.contains($0.id) && !selectedEmails.contains($0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) && $0.isActive
        }
        let rosterEmails = Set(roster.map { $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })

        for user in userStore.organizationUsers where user.isActive && user.passwordSet {
            guard user.isSuperAdmin || user.permissions.adminAccess || user.role == .admin else { continue }
            let email = user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if rosterEmails.contains(email) || selectedEmails.contains(email) { continue }
            if let existing = operativeStore.allManagers.first(where: {
                $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == email && $0.isActive
            }), !selectedIds.contains(existing.id) {
                roster.append(existing)
                continue
            }
            roster.append(
                Manager(
                    id: stableManagerId(email: email),
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

    /// Stable id so admins who are not on the manager roster keep the same identity across picker refreshes and saves.
    static func stableManagerId(email: String) -> UUID {
        let seed = "pp.manager.\(email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
        var bytes = [UInt8](repeating: 0, count: 16)
        let data = Array(seed.utf8)
        for (index, byte) in data.enumerated() {
            bytes[index % 16] ^= byte
            bytes[(index &* 7) % 16] &+= byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
