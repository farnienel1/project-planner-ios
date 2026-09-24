//
//  FirebaseBackend+OrganizationMembership.swift
//  Project Planner
//
//  Multi-organisation membership listing, switching, and trial access enforcement.
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

extension FirebaseBackend {
    /// Organisations this uid belongs to (members map or creator). Never scans the full collection.
    @MainActor
    func loadOrganizationMembershipDocuments(userId: String) async throws -> [(id: String, data: [String: Any], role: String)] {
        var byId: [String: (data: [String: Any], role: String)] = [:]

        let memberField = FieldPath(["members", userId])
        let memberSnapshot = try await db.collection("organizations")
            .whereField(memberField, isNotEqualTo: "")
            .getDocuments(source: FirestoreSource.server)
        for doc in memberSnapshot.documents {
            let data = doc.data()
            let members = data["members"] as? [String: String] ?? [:]
            byId[doc.documentID] = (data, members[userId] ?? "member")
        }

        let creatorSnapshot = try await db.collection("organizations")
            .whereField("creatorUserId", isEqualTo: userId)
            .getDocuments(source: FirestoreSource.server)
        for doc in creatorSnapshot.documents {
            if byId[doc.documentID] != nil { continue }
            byId[doc.documentID] = (doc.data(), "admin")
        }

        return byId.map { (id: $0.key, data: $0.value.data, role: $0.value.role) }
    }

    /// Loads only organisations the signed-in user belongs to.
    /// Must never scan the full `organizations` collection — that jetsams the Simulator
    /// once the project has more than a handful of orgs.
    @MainActor
    func fetchOrganizationsForCurrentUser() async -> [OrgMembershipSummary] {
        guard let userId = currentUser?.uid else { return [] }

        do {
            let memberships = try await loadOrganizationMembershipDocuments(userId: userId)
            let results: [OrgMembershipSummary] = memberships.map { item in
                OrganizationTrialPolicy.membershipSummary(
                    organizationId: item.id,
                    orgData: item.data,
                    roleInOrg: item.role
                )
            }

            let activeId = currentOrganization?.firestoreDocumentId
            return results.sorted { lhs, rhs in
                if lhs.id == activeId { return true }
                if rhs.id == activeId { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } catch {
            print("🔥🔥🔥 DEBUG: [OrgMembership] Failed to list organisations: \(error.localizedDescription)")
            return []
        }
    }

    @MainActor
    func switchActiveOrganization(to organizationId: String) async throws {
        guard let userId = currentUser?.uid,
              let userEmail = currentUser?.email else {
            throw OrganizationSwitchError.notAuthenticated
        }

        let trimmedId = normalizedOrganizationId(organizationId)
        guard !trimmedId.isEmpty else {
            throw OrganizationSwitchError.organizationNotFound
        }

        let orgDoc = try await db.collection("organizations").document(trimmedId).getDocument(source: FirestoreSource.server)
        guard orgDoc.exists, let orgData = orgDoc.data() else {
            throw OrganizationSwitchError.organizationNotFound
        }

        let members = orgData["members"] as? [String: String] ?? [:]
        let creatorUserId = orgData["creatorUserId"] as? String
        let roleInOrg = members[userId] ?? (creatorUserId == userId ? "admin" : nil)
        guard let roleInOrg else {
            throw OrganizationSwitchError.notAMember
        }

        let memberships = await fetchOrganizationsForCurrentUser()
        if let blockMessage = OrganizationTrialPolicy.loginBlockMessage(
            organizationId: trimmedId,
            orgData: orgData,
            memberships: memberships
        ) {
            throw OrganizationSwitchError.trialBlocked(blockMessage)
        }

        let userDocRef = db.collection("users").document(userId)
        let userDoc = try await userDocRef.getDocument()

        if userDoc.exists {
            try await userDocRef.updateData([
                "organizationId": trimmedId,
                "role": roleInOrg,
                "updatedAt": Timestamp(date: Date()),
            ])
        } else {
            try await userDocRef.setData([
                "email": userEmail,
                "organizationId": trimmedId,
                "role": roleInOrg,
                "isActive": true,
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date()),
            ])
        }

        if members[userId] == nil {
            var membersUpdate = members
            membersUpdate[userId] = roleInOrg
            try await db.collection("organizations").document(trimmedId).updateData([
                "members": membersUpdate,
                "updatedAt": Timestamp(date: Date()),
            ])
        }

        let organization = buildOrganizationFromDocument(orgId: trimmedId, data: orgData)
        currentOrganization = organization
        userRole = UserRole(rawValue: roleInOrg) ?? .basic
        errorMessage = nil
        storeOrganizationLocally(organization)
        hasBootstrappedOrgDataLoad = false
        isBootstrappingOrgDataLoad = false
        launchQuietUntil = nil
        broadcastOrganizationDidLoadIfNeeded(force: true)
    }

    @MainActor
    func rejectTrialBlockedOrganizationIfNeeded(organizationId: String, orgData: [String: Any]) async -> Bool {
        // Fast path: locked org does not need a memberships query.
        if OrganizationTrialPolicy.isAccessBlocked(orgData) {
            errorMessage = OrganizationTrialPolicy.blockedMessage(from: orgData)
            currentOrganization = nil
            clearLocalOrganizationCache()
            try? auth.signOut()
            return true
        }

        // Multi-trial rule only applies to trial orgs — skip the memberships fetch otherwise.
        guard OrganizationTrialPolicy.isTrialOrganization(orgData) else {
            return false
        }

        let memberships = await fetchOrganizationsForCurrentUser()
        guard let message = OrganizationTrialPolicy.loginBlockMessage(
            organizationId: organizationId,
            orgData: orgData,
            memberships: memberships
        ) else {
            return false
        }

        errorMessage = message
        currentOrganization = nil
        clearLocalOrganizationCache()
        try? auth.signOut()
        return true
    }

    @MainActor
    func buildOrganizationFromDocument(orgId: String, data: [String: Any]) -> Organization {
        let orgSettings = Self.organizationSettingsFromOrgDocument(data)
        organizationHasFirestoreMyScheduleOptions = Self.organizationHasMyScheduleOptionsInDocument(data)
        var organization = Organization.make(fromFirestoreId: orgId, data: data, settings: orgSettings)
        Self.applyPayrollPolicyFields(from: data, to: &organization)
        return organization
    }
}
