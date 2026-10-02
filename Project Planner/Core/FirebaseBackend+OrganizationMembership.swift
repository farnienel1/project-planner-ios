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

    private func orgMembershipsCollection(userId: String) -> CollectionReference {
        db.collection("users").document(userId).collection("orgMemberships")
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

    /// Copies the live `users/{uid}` document onto `orgMemberships/{orgId}`, including
    /// `accountActive` from `isActive`. Does not invent a second user document.
    func snapshotCurrentUserOntoMembership(
        userId: String,
        organizationId: String,
        userData: [String: Any]
    ) async throws {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty else { return }
        var snapshot = userData
        snapshot["accountActive"] = firestoreUserIsActive(from: userData)
        snapshot["organizationId"] = orgId
        snapshot["updatedAt"] = Timestamp(date: Date())
        try await orgMembershipsCollection(userId: userId).document(orgId).setData(snapshot, merge: true)
    }

    /// Writes `accountActive` only when that membership document already exists.
    /// Returns whether the membership document was updated. Never creates a stub.
    @discardableResult
    func patchMembershipAccountActiveIfExists(
        userId: String,
        organizationId: String,
        accountActive: Bool
    ) async -> Bool {
        let orgId = normalizedOrganizationId(organizationId)
        guard !userId.isEmpty, !orgId.isEmpty else { return false }
        let ref = orgMembershipsCollection(userId: userId).document(orgId)
        do {
            let snap = try await ref.getDocument(source: .server)
            guard snap.exists else { return false }
            try await ref.updateData([
                "accountActive": accountActive,
                "updatedAt": Timestamp(date: Date())
            ])
            return true
        } catch {
            print("🔥🔥🔥 DEBUG: [OrgMembership] accountActive patch skipped: \(error.localizedDescription)")
            return false
        }
    }

    /// Restores the destination membership onto `users/{uid}` and copies `accountActive`
    /// onto `isActive` (missing `accountActive` means active). Returns that flag.
    @discardableResult
    func applyDestinationMembershipOntoUser(
        userId: String,
        organizationId: String,
        roleInOrg: String,
        userEmail: String
    ) async throws -> Bool {
        let orgId = normalizedOrganizationId(organizationId)
        let userDocRef = db.collection("users").document(userId)
        let membershipSnap = try await orgMembershipsCollection(userId: userId).document(orgId).getDocument(source: .server)
        let accountActive = firestoreAccountActive(from: membershipSnap.data())

        if membershipSnap.exists, var dest = membershipSnap.data() {
            dest.removeValue(forKey: "accountActive")
            dest["organizationId"] = orgId
            dest["role"] = roleInOrg
            dest["isActive"] = accountActive
            dest["updatedAt"] = Timestamp(date: Date())
            if dest["email"] == nil {
                dest["email"] = userEmail
            }
            try await userDocRef.setData(dest, merge: true)
        } else {
            try await userDocRef.setData(
                [
                    "email": userEmail,
                    "organizationId": orgId,
                    "role": roleInOrg,
                    "isActive": accountActive,
                    "updatedAt": Timestamp(date: Date())
                ],
                merge: true
            )
        }
        return accountActive
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
        let userData = userDoc.data() ?? [:]
        let sharedOrgId = normalizedOrganizationId(organizationIdFromFirestore(userData["organizationId"]) ?? "")
        if !sharedOrgId.isEmpty {
            sharedUserOrganizationId = sharedOrgId
        }
        // Snapshot the company this phone is leaving. Do not copy that profile onto users/{uid},
        // because that document is the other platform's current company.
        let leavingOrgId = normalizedOrganizationId(currentOrganization?.firestoreDocumentId ?? "")
        if !leavingOrgId.isEmpty,
           !organizationIdsMatch(leavingOrgId, trimmedId) {
            if let sessionProfile = deviceSessionProfile,
               organizationIdsMatch(sessionProfile.organizationId, leavingOrgId) {
                try await snapshotCurrentUserOntoMembership(
                    userId: userId,
                    organizationId: leavingOrgId,
                    userData: membershipPayload(from: sessionProfile)
                )
            } else if userDoc.exists, organizationIdsMatch(sharedOrgId, leavingOrgId) {
                try await snapshotCurrentUserOntoMembership(
                    userId: userId,
                    organizationId: leavingOrgId,
                    userData: userData
                )
            }
        }

        let destinationAccountActive = await loadDeviceSessionProfile(
            userId: userId,
            organizationId: trimmedId,
            roleInOrg: roleInOrg,
            userEmail: userEmail,
            creatorUserId: creatorUserId,
            sharedUserData: userData
        )

        if members[userId] == nil {
            var membersUpdate = members
            membersUpdate[userId] = roleInOrg
            try await db.collection("organizations").document(trimmedId).updateData([
                "members": membersUpdate,
                "updatedAt": Timestamp(date: Date()),
            ])
        }

        stopScheduleLiveListeners()
        let organization = buildOrganizationFromDocument(orgId: trimmedId, data: orgData)
        currentOrganization = organization
        errorMessage = nil
        storeOrganizationLocally(organization)
        hasBootstrappedOrgDataLoad = false
        isBootstrappingOrgDataLoad = false
        launchQuietUntil = nil
        if destinationAccountActive {
            broadcastOrganizationDidLoadIfNeeded(force: true)
        }
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

    /// Phone session wins when this person still belongs to the company saved on the device.
    @MainActor
    func preferredSessionOrganizationId(userId: String, sharedOrganizationId: String?) async -> String? {
        let device = normalizedOrganizationId(cachedOrganizationIdString() ?? "")
        if !device.isEmpty, await userBelongsToOrganization(userId: userId, organizationId: device) {
            return device
        }
        let shared = normalizedOrganizationId(sharedOrganizationId ?? "")
        return shared.isEmpty ? nil : shared
    }

    @MainActor
    func userBelongsToOrganization(userId: String, organizationId: String) async -> Bool {
        let orgId = normalizedOrganizationId(organizationId)
        guard !userId.isEmpty, !orgId.isEmpty else { return false }
        do {
            let doc = try await db.collection("organizations").document(orgId).getDocument(source: .server)
            guard doc.exists, let data = doc.data() else { return false }
            let members = data["members"] as? [String: String] ?? [:]
            if members[userId] != nil { return true }
            return (data["creatorUserId"] as? String) == userId
        } catch {
            // Offline: keep the company already stored on this phone.
            return organizationIdsMatch(orgId, cachedOrganizationIdString())
        }
    }

    /// Loads this phone's rights for `organizationId` into memory. Does not write `users/{uid}`.
    @MainActor
    @discardableResult
    func loadDeviceSessionProfile(
        userId: String,
        organizationId: String,
        roleInOrg: String,
        userEmail: String,
        creatorUserId: String?,
        sharedUserData: [String: Any]
    ) async -> Bool {
        let orgId = normalizedOrganizationId(organizationId)
        let base = Self.parseAppUserDocument(userId: userId, data: sharedUserData)
        if organizationIdsMatch(sharedUserOrganizationId, orgId) {
            deviceSessionProfile = nil
            userRole = base.role
            return base.isActive
        }
        let membershipSnap = try? await orgMembershipsCollection(userId: userId).document(orgId).getDocument(source: .server)
        let isCreator = creatorUserId == userId
        let accountActive = firestoreAccountActive(from: membershipSnap?.data())

        var profile: AppUser
        if let data = membershipSnap?.data(), membershipSnap?.exists == true {
            profile = Self.parseAppUserDocument(userId: userId, data: data)
            profile.organizationId = orgId
            profile.isActive = accountActive
        } else {
            let shaped = Self.sessionPermissions(forMembersRole: roleInOrg, isCreator: isCreator)
            profile = base
            profile.organizationId = orgId
            profile.role = shaped.role
            profile.permissions = shaped.permissions
            profile.isSuperAdmin = shaped.isSuperAdmin
            profile.isActive = true
        }
        profile.id = userId
        profile.email = base.email.isEmpty ? userEmail : base.email
        profile.firstName = base.firstName
        profile.surname = base.surname
        profile.mobileNumber = base.mobileNumber
        profile.profilePhotoURL = base.profilePhotoURL
        if !organizationIdsMatch(sharedUserOrganizationId, orgId) {
            deviceSessionProfile = profile
        } else {
            deviceSessionProfile = nil
        }
        userRole = profile.role
        return profile.isActive
    }

    /// Applies the phone's company onto a profile loaded from `users/{uid}` without writing that document.
    @MainActor
    func applyDeviceSessionIfNeeded(to user: AppUser) async -> AppUser {
        let shared = normalizedOrganizationId(user.organizationId)
        if !shared.isEmpty {
            sharedUserOrganizationId = shared
        }
        let sessionOrg = normalizedOrganizationId(
            currentOrganization?.firestoreDocumentId ?? cachedOrganizationIdString() ?? ""
        )
        guard !sessionOrg.isEmpty, !organizationIdsMatch(sessionOrg, shared) else {
            deviceSessionProfile = nil
            return user
        }
        guard await userBelongsToOrganization(userId: user.id, organizationId: sessionOrg) else {
            return user
        }
        let orgDoc = try? await db.collection("organizations").document(sessionOrg).getDocument(source: .server)
        let orgData = orgDoc?.data() ?? [:]
        let members = orgData["members"] as? [String: String] ?? [:]
        let creator = orgData["creatorUserId"] as? String
        let role = members[user.id] ?? (creator == user.id ? "admin" : "member")
        var sharedData: [String: Any] = [
            "email": user.email,
            "firstName": user.firstName,
            "surname": user.surname,
            "organizationId": shared,
            "role": user.role.rawValue,
            "isActive": user.isActive
        ]
        if let mobile = user.mobileNumber { sharedData["mobileNumber"] = mobile }
        if let photo = user.profilePhotoURL { sharedData["profilePhotoURL"] = photo }
        _ = await loadDeviceSessionProfile(
            userId: user.id,
            organizationId: sessionOrg,
            roleInOrg: role,
            userEmail: user.email,
            creatorUserId: creator,
            sharedUserData: sharedData
        )
        return deviceSessionProfile ?? user
    }

    private func membershipPayload(from user: AppUser) -> [String: Any] {
        var data: [String: Any] = [
            "email": user.email,
            "organizationId": user.organizationId,
            "role": user.role.rawValue,
            "firstName": user.firstName,
            "surname": user.surname,
            "lastName": user.surname,
            "isActive": user.isActive,
            "passwordSet": user.passwordSet,
            "adminAccess": user.permissions.adminAccess,
            "manager": user.permissions.manager,
            "operatives": user.permissions.operatives,
            "skills": false,
            "qualifications": user.permissions.qualifications,
            "materials": user.permissions.operativeMode ? user.permissions.materials : true,
            "projects": user.permissions.projects,
            "smallWorks": user.permissions.smallWorks,
            "operativeMode": user.permissions.operativeMode,
            "annualLeaveSelfBook": user.permissions.annualLeaveSelfBook,
            "weeklyReports": user.permissions.weeklyReports,
            "dailyOverview": user.permissions.dailyOverview,
            "subContractors": user.permissions.subContractors,
            "siteAudit": user.permissions.operativeMode ? user.permissions.siteAudit : true,
            "wholesalersOrderHistory": user.permissions.wholesalersOrderHistory,
            "isSuperAdmin": user.isSuperAdmin,
            "accountActive": user.isActive
        ]
        if let mobile = user.mobileNumber, !mobile.isEmpty {
            data["mobileNumber"] = mobile
        }
        return data
    }

    /// No membership snapshot yet: use the members-map role only. Do not copy toggles from another company.
    private static func sessionPermissions(forMembersRole role: String, isCreator: Bool) -> (role: UserRole, permissions: UserPermissions, isSuperAdmin: Bool) {
        if isCreator {
            return (
                .admin,
                UserPermissions(
                    adminAccess: true,
                    manager: true,
                    operatives: true,
                    qualifications: true,
                    materials: true,
                    projects: true,
                    smallWorks: true,
                    operativeMode: false,
                    siteAudit: true
                ),
                true
            )
        }
        let token = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if token.contains("admin") {
            return (
                .admin,
                UserPermissions(
                    adminAccess: true,
                    manager: true,
                    materials: true,
                    operativeMode: false,
                    siteAudit: true
                ),
                false
            )
        }
        if token.contains("operative") {
            return (
                .operative,
                UserPermissions(
                    manager: false,
                    adminAccess: false,
                    materials: false,
                    operativeMode: true,
                    siteAudit: true,
                    wholesalersOrderHistory: false
                ),
                false
            )
        }
        if token.contains("manager") {
            return (
                .manager,
                UserPermissions(
                    adminAccess: false,
                    manager: true,
                    materials: true,
                    operativeMode: false,
                    siteAudit: true
                ),
                false
            )
        }
        return (
            .viewer,
            UserPermissions(
                adminAccess: false,
                manager: false,
                materials: false,
                operativeMode: false,
                siteAudit: false,
                wholesalersOrderHistory: false
            ),
            false
        )
    }
}
