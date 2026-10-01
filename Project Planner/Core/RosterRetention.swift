//
//  RosterRetention.swift
//  Project Planner
//
//  The last roster that was actually on screen, kept on this phone.
//  A Firestore query that comes back short must not be able to blank Managers or Operatives.
//

import Foundation

enum RosterRetention {
    private static let usersPrefix = "pp.roster.users.v1."
    private static let tombstonePrefix = "pp.roster.tombstones.v1."

    static func users(for organizationId: String) -> [AppUser] {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty,
              let data = UserDefaults.standard.data(forKey: usersPrefix + orgId) else {
            return []
        }
        do {
            let decoded = try JSONDecoder().decode([AppUser].self, from: data)
            let buried = tombstones(for: orgId)
            return decoded.filter { user in
                !buried.contains(user.id) && user.isStoredUserDocument
            }
        } catch {
            print("🔥🔥🔥 DEBUG: ROSTER_CACHE unreadable for \(orgId): \(error.localizedDescription)")
            return []
        }
    }

    static func save(_ users: [AppUser], organizationId: String, allowEmpty: Bool = false) {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty else { return }
        let buried = tombstones(for: orgId)
        let kept = users.filter { user in
            !buried.contains(user.id) && user.isStoredUserDocument
        }
        // An empty save is refused unless this load confirmed the organisation has nobody left.
        // Sign-out and a failed fetch must not erase the people stored on this phone.
        guard !kept.isEmpty || allowEmpty else { return }
        if kept.isEmpty {
            UserDefaults.standard.removeObject(forKey: usersPrefix + orgId)
            return
        }
        do {
            let data = try JSONEncoder().encode(kept)
            UserDefaults.standard.set(data, forKey: usersPrefix + orgId)
        } catch {
            print("🔥🔥🔥 DEBUG: ROSTER_CACHE save failed for \(orgId): \(error.localizedDescription)")
        }
    }

    static func isTombstoned(_ userId: String, organizationId: String) -> Bool {
        tombstones(for: normalizedOrganizationId(organizationId)).contains(userId)
    }

    /// An in-app delete. This is the only local way a person is removed without the server confirming the document is gone.
    static func tombstone(_ userIds: [String], organizationId: String) {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty else { return }
        var buried = tombstones(for: orgId)
        for id in userIds {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { buried.insert(trimmed) }
        }
        UserDefaults.standard.set(Array(buried), forKey: tombstonePrefix + orgId)
    }

    private static func tombstones(for organizationId: String) -> Set<String> {
        let stored = UserDefaults.standard.stringArray(forKey: tombstonePrefix + organizationId) ?? []
        return Set(stored)
    }
}
