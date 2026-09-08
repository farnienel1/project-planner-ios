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
    /// Loads only organisations the signed-in user belongs to.
    /// Must never scan the full `organizations` collection — that jetsams the Simulator
    /// once the project has more than a handful of orgs.
    @MainActor
    func fetchOrganizationsForCurrentUser() async -> [OrgMembershipSummary] {
        guard let userId = currentUser?.uid else { return [] }

        do {
            var byId: [String: (data: [String: Any], role: String)] = [:]

            // Orgs where this uid is present in the members map.
            let memberField = FieldPath(["members", userId])
            let memberSnapshot = try await db.collection("organizations")
                .whereField(memberField, isNotEqualTo: "")
                .getDocuments(source: FirestoreSource.server)
            for doc in memberSnapshot.documents {
                let data = doc.data()
                let members = data["members"] as? [String: String] ?? [:]
                let role = members[userId] ?? "member"
                byId[doc.documentID] = (data, role)
            }

            // Orgs this user created (may not yet be listed under members).
            let creatorSnapshot = try await db.collection("organizations")
                .whereField("creatorUserId", isEqualTo: userId)
                .getDocuments(source: FirestoreSource.server)
            for doc in creatorSnapshot.documents {
                if byId[doc.documentID] != nil { continue }
                let data = doc.data()
                byId[doc.documentID] = (data, "admin")
            }

            let results: [OrgMembershipSummary] = byId.map { orgId, value in
                OrganizationTrialPolicy.membershipSummary(
                    organizationId: orgId,
                    orgData: value.data,
                    roleInOrg: value.role
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
        let resolvedName = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let orgSettings = Self.organizationSettingsFromOrgDocument(data)
        organizationHasFirestoreMyScheduleOptions = Self.organizationHasMyScheduleOptionsInDocument(data)
        var organization = Organization(
            id: UUID(uuidString: orgId) ?? UUID(),
            firestoreDocumentId: orgId,
            name: (resolvedName?.isEmpty == false) ? resolvedName! : "Organisation",
            settings: orgSettings,
            officeAddressLine1: data["officeAddressLine1"] as? String,
            officeCity: data["officeCity"] as? String,
            officePostcode: data["officePostcode"] as? String,
            countryCode: (data["countryCode"] as? String)?.uppercased() ?? "GB",
            defaultLatitude: data["defaultLatitude"] as? Double,
            defaultLongitude: data["defaultLongitude"] as? Double,
            companyLogoURL: data["companyLogoURL"] as? String,
            creatorUserId: data["creatorUserId"] as? String
        )
        Self.applyPayrollPolicyFields(from: data, to: &organization)
        return organization
    }
}
