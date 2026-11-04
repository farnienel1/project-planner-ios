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
        guard let userId = currentUser?.uid else { return listedOrganizationMemberships }
        let previous = listedOrganizationMemberships
        let known = knownOrganizationMembershipsBeforeScan()
        if !known.isEmpty {
            listedOrganizationMemberships = known
        }
        var byId: [String: (data: [String: Any], role: String)] = [:]
        var memberFailed = false
        var creatorFailed = false
        var membershipFailed = false

        do {
            let memberField = FieldPath(["members", userId])
            let memberSnapshot = try await sessionProbeQuery(
                db.collection("organizations").whereField(memberField, isNotEqualTo: ""),
                timeoutSeconds: 8
            )
            for doc in memberSnapshot.documents {
                guard let role = Self.listedMemberRole(in: doc.data(), userId: userId) else { continue }
                byId[doc.documentID] = (doc.data(), role)
            }
        } catch {
            memberFailed = true
            print("🔥🔥🔥 DEBUG: [OrgMembership] members query incomplete: \(error.localizedDescription)")
        }

        do {
            let creatorSnapshot = try await sessionProbeQuery(
                db.collection("organizations").whereField("creatorUserId", isEqualTo: userId),
                timeoutSeconds: 8
            )
            for doc in creatorSnapshot.documents where byId[doc.documentID] == nil {
                byId[doc.documentID] = (doc.data(), "admin")
            }
        } catch {
            creatorFailed = true
            print("🔥🔥🔥 DEBUG: [OrgMembership] creator query incomplete: \(error.localizedDescription)")
        }

        do {
            let membershipSnapshot = try await sessionProbeQuery(
                orgMembershipsCollection(userId: userId),
                timeoutSeconds: 8
            )
            for doc in membershipSnapshot.documents {
                let role = (doc.data()["role"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = (role?.isEmpty == false) ? role! : "member"
                if byId[doc.documentID] == nil {
                    byId[doc.documentID] = ([:], resolved)
                }
            }
        } catch {
            membershipFailed = true
            print("🔥🔥🔥 DEBUG: [OrgMembership] orgMemberships read incomplete: \(error.localizedDescription)")
        }

        let incomplete = memberFailed || creatorFailed || membershipFailed
        // A finished members or creator query can omit a company this phone already knows.
        // The script still returns the remembered id and the user-document id.
        let ids = CanonicalBusinessEngine.sessionMembershipIds(
            discoveredIds: Array(byId.keys),
            previousIds: previous.map(\.id),
            rememberedOrganizationId: cachedOrganizationIdString(),
            documentOrganizationId: sharedUserOrganizationId,
            explicitOrganizationId: organizationSwitchTargetId ?? sessionOrganizationId,
            discoveryIncomplete: incomplete
        )
        guard let ids else { return previous }

        let rows: [OrgMembershipSummary] = ids.map { organizationId in
            if let match = byId.first(where: { organizationIdsMatch($0.key, organizationId) }) {
                return OrganizationTrialPolicy.membershipSummary(
                    organizationId: match.key,
                    orgData: match.value.data,
                    roleInOrg: match.value.role
                )
            }
            if let existing = previous.first(where: { organizationIdsMatch($0.id, organizationId) }) {
                return existing
            }
            let knownName = CanonicalBusinessEngine.coalesceOrganizationName([
                organizationIdsMatch(currentOrganization?.firestoreDocumentId, organizationId)
                    ? currentOrganization?.name
                    : nil,
                cachedOrganizationName(matching: organizationId)
            ]) ?? ""
            return OrgMembershipSummary(
                id: organizationId,
                name: CanonicalBusinessEngine.displayOrganizationName(knownName) ?? "Organisation",
                roleInOrg: "member",
                isTrial: false,
                trialAccessBlocked: false,
                subscriptionHasAccess: true,
                createdAt: nil
            )
        }
        let activeId = sessionOrganizationId.isEmpty
            ? currentOrganization?.firestoreDocumentId
            : sessionOrganizationId
        let sorted = rows.sorted { lhs, rhs in
            let leftActive = organizationIdsMatch(lhs.id, activeId)
            let rightActive = organizationIdsMatch(rhs.id, activeId)
            if leftActive != rightActive { return leftActive }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        listedOrganizationMemberships = sorted
        return sorted
    }

    /// Remembered company and the user-document company, before the members or creator scan.
    @MainActor
    func knownOrganizationMembershipsBeforeScan() -> [OrgMembershipSummary] {
        OrganizationSwitcherCatalog.knownCompaniesBeforeScan(
            previous: listedOrganizationMemberships,
            rememberedOrganizationId: cachedOrganizationIdString(),
            documentOrganizationId: sharedUserOrganizationId,
            explicitOrganizationId: organizationSwitchTargetId ?? (sessionOrganizationId.isEmpty ? nil : sessionOrganizationId),
            currentOrganizationId: currentOrganization?.firestoreDocumentId,
            currentOrganizationName: currentOrganization?.name,
            cachedNameForRemembered: cachedOrganizationIdString().flatMap { cachedOrganizationName(matching: $0) }
        )
    }

    /// RULEBOOK 1.10.0 §14: `orgMembershipWriteFields({ organizationId, stored, next, writer, now })` against the stored
    /// membership, written as one partial update (or a create when none is stored). `writer` `admin` writes role,
    /// permissions, super admin and the active flag; `self` only accepts. Returns whether anything was written.
    /// Never a flat merge of the users document (the rules refuse a self-write that changes role or permissions).
    @discardableResult
    func writeOrgMembership(
        userId: String,
        organizationId: String,
        next: [String: Any],
        writer: String,
        createIfMissing: Bool = false
    ) async throws -> Bool {
        let orgId = normalizedOrganizationId(organizationId)
        guard !userId.isEmpty, !orgId.isEmpty else { return false }
        let ref = orgMembershipsCollection(userId: userId).document(orgId)
        let snap: DocumentSnapshot
        do {
            snap = try await ref.getDocument(source: .server)
        } catch {
            // RULEBOOK 1.12.2 §11: an admin reads a membership in their organisation, but older deployed rules let only
            // the person read it. A refused read must not stop a user type change: write the role and the nested
            // permissions as a merge (no read needed), which every rules version accepts from an admin.
            guard isFirestorePermissionDenied(error), writer == "admin" else { throw error }
            var merged: [String: Any] = [:]
            if let role = next["role"] as? String { merged["role"] = role }
            if let permissions = next["permissions"] as? [String: Bool], !permissions.isEmpty { merged["permissions"] = permissions }
            guard !merged.isEmpty else { throw error }
            try await ref.setData(merged, merge: true)
            return true
        }
        if !snap.exists && !createIfMissing { return false }
        let stored: Any = snap.exists ? Self.firestoreJSON(snap.data() ?? [:]) : NSNull()
        let nowMarker = "__serverNow__"
        guard let write = CanonicalBusinessEngine.callJSON(
            "orgMembershipWriteFields",
            arguments: [["organizationId": orgId, "stored": stored, "next": next, "writer": writer, "now": nowMarker]]
        ) else {
            throw CanonicalWriteUnavailableError(function: "orgMembershipWriteFields")
        }
        guard let row = write as? [String: Any],
              var fields = row["fields"] as? [String: Any] else { return false }
        for (key, value) in fields where (value as? String) == nowMarker { fields[key] = FieldValue.serverTimestamp() }
        if (row["mode"] as? String) == "create" {
            try await ref.setData(fields)
            return true
        }
        for key in row["remove"] as? [String] ?? [] { fields[key] = FieldValue.delete() }
        guard !fields.isEmpty else { return false }
        try await ref.updateData(fields)
        return true
    }

    /// Writes `accountActive` only when that membership document already exists (`orgMembershipWriteFields`, admin).
    /// Returns whether the membership document was updated. Never creates a stub.
    @discardableResult
    func patchMembershipAccountActiveIfExists(
        userId: String,
        organizationId: String,
        accountActive: Bool
    ) async -> Bool {
        do {
            return try await writeOrgMembership(
                userId: userId,
                organizationId: organizationId,
                next: ["accountActive": accountActive],
                writer: "admin"
            )
        } catch {
            print("🔥🔥🔥 DEBUG: [OrgMembership] accountActive patch skipped: \(error.localizedDescription)")
            return false
        }
    }

    /// RULEBOOK 1.10.0 §14: the membership as `parseOrgMembershipDocument` reads it (nested `permissions`, else the
    /// legacy flat keys, else the defaults). Nil when the script did not answer.
    static func orgMembership(organizationId: String, data: [String: Any]) -> (role: String, isSuperAdmin: Bool, accountActive: Bool, permissions: [String: Bool])? {
        guard let row = CanonicalBusinessEngine.callJSON("parseOrgMembershipDocument", arguments: [organizationId, firestoreJSON(data)]) as? [String: Any],
              let permissions = row["permissions"] as? [String: Bool] else { return nil }
        return (
            row["role"] as? String ?? "member",
            row["isSuperAdmin"] as? Bool ?? false,
            row["accountActive"] as? Bool ?? true,
            permissions
        )
    }

    /// `parseOrgMembershipDocument` permissions as `UserPermissions` (keys `ORG_MEMBERSHIP_PERMISSION_KEYS`).
    static func userPermissions(fromMembership flags: [String: Bool], fallback: UserPermissions) -> UserPermissions {
        var out = fallback
        out.adminAccess = flags["adminAccess"] ?? out.adminAccess
        out.manager = flags["manager"] ?? out.manager
        out.operatives = flags["operatives"] ?? out.operatives
        out.skills = flags["skills"] ?? out.skills
        out.qualifications = flags["qualifications"] ?? out.qualifications
        out.materials = flags["materials"] ?? out.materials
        out.projects = flags["projects"] ?? out.projects
        out.smallWorks = flags["smallWorks"] ?? out.smallWorks
        out.operativeMode = flags["operativeMode"] ?? out.operativeMode
        out.siteAudit = flags["siteAudit"] ?? out.siteAudit
        out.subContractors = flags["subContractors"] ?? out.subContractors
        out.wholesalersOrderHistory = flags["wholesalersOrderHistory"] ?? out.wholesalersOrderHistory
        out.annualLeaveSelfBook = flags["annualLeaveSelfBook"] ?? out.annualLeaveSelfBook
        // RULEBOOK 1.28.0: `timesheetSelfSign` is one of `ORG_MEMBERSHIP_PERMISSION_KEYS`.
        out.timesheetSelfSign = flags["timesheetSelfSign"] ?? out.timesheetSelfSign
        out.weeklyReports = flags["weeklyReports"] ?? out.weeklyReports
        out.dailyOverview = flags["dailyOverview"] ?? out.dailyOverview
        return out
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

        let members = orgData["members"] as? [String: Any] ?? [:]
        let creatorUserId = orgData["creatorUserId"] as? String
        let listedRole = (members[userId] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let roleInOrg = (listedRole?.isEmpty == false ? listedRole : nil) ?? (creatorUserId == userId ? "admin" : nil)
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

        if CanonicalBusinessEngine.hasAccess(billing: OrganizationBillingMap.payload(from: orgData)) == false {
            throw OrganizationSwitchError.subscriptionLapsed
        }

        let userDocRef = db.collection("users").document(userId)
        let userDoc = try await userDocRef.getDocument()
        let userData = userDoc.data() ?? [:]
        let sharedOrgId = normalizedOrganizationId(organizationIdFromFirestore(userData["organizationId"]) ?? "")
        if !sharedOrgId.isEmpty {
            sharedUserOrganizationId = sharedOrgId
        }
        // RULEBOOK 1.10.0 §14: switching writes nothing onto a membership (no `snapshotCurrentUserOntoMembership`): the
        // membership is written only by an admin of that company (`orgMembershipWriteFields`), and it is read with
        // `parseOrgMembershipDocument` when this phone opens that company.
        let destinationAccountActive = await loadDeviceSessionProfile(
            userId: userId,
            organizationId: trimmedId,
            roleInOrg: roleInOrg,
            userEmail: userEmail,
            creatorUserId: creatorUserId,
            sharedUserData: userData
        )

        let choice = CanonicalBusinessEngine.chooseSessionOrganization(
            explicitOrganizationId: trimmedId,
            rememberedOrganizationId: cachedOrganizationIdString(),
            documentOrganizationId: sharedUserOrganizationId,
            probes: [trimmedId: "allowed"]
        )
        guard let choice, !choice.organizationId.isEmpty else {
            throw OrganizationSwitchError.organizationNotFound
        }
        let chosenId = normalizedOrganizationId(choice.organizationId)
        guard organizationIdsMatch(chosenId, trimmedId) else {
            throw OrganizationSwitchError.organizationNotFound
        }
        persistRememberedOrganizationId = !(choice.persistOrganizationId ?? "").isEmpty
        sessionOrganizationId = chosenId

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
            // RULEBOOK §13: a forced sign-out removes this device's push token too (while the company is still
            // known, so same-email copies are found) — the one sign-out path, as `AppSignOut` uses.
            await signOutRemovingPushToken(reason: .trialBlocked)
            currentOrganization = nil
            sessionOrganizationId = ""
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
        await signOutRemovingPushToken(reason: .trialBlocked)
        currentOrganization = nil
        sessionOrganizationId = ""
        return true
    }

    @MainActor
    func buildOrganizationFromDocument(orgId: String, data: [String: Any]) -> Organization {
        let orgSettings = Self.organizationSettingsFromOrgDocument(data)
        organizationHasFirestoreMyScheduleOptions = Self.organizationHasMyScheduleOptionsInDocument(data)
        var organization = Organization.make(fromFirestoreId: orgId, data: data, settings: orgSettings)
        Self.applyPayrollPolicyFields(from: data, to: &organization)
        return organizationKeepingKnownName(organization)
    }

    /// Explicit switch, then `cached_organizationId`, then `users/{uid}.organizationId`.
    /// Publishes the provisional company before probes so a booking snapshot for it is applied.
    /// Nil from the script is not replaced with another company.
    @MainActor
    @discardableResult
    func applySessionOrganizationChoice(
        userId: String,
        documentOrganizationId: String?,
        explicitOrganizationId: String?
    ) async -> CanonicalBusinessEngine.CanonicalSessionOrganizationChoice? {
        prepareRememberedOrganizationOwner(for: userId)
        let remembered = cachedOrganizationIdString()
        let provisional = CanonicalBusinessEngine.provisionalOrganizationId(
            explicitOrganizationId: explicitOrganizationId,
            rememberedOrganizationId: remembered,
            documentOrganizationId: documentOrganizationId
        ) ?? ""
        if !provisional.isEmpty {
            publishSessionOrganizationIfNeeded(provisional)
        }

        var probes: [String: String] = [:]
        for raw in [explicitOrganizationId, remembered, documentOrganizationId] {
            let organizationId = normalizedOrganizationId(raw ?? "")
            guard !organizationId.isEmpty else { continue }
            if probes.keys.contains(where: { organizationIdsMatch($0, organizationId) }) { continue }
            probes[organizationId] = await probeSessionOrganizationAccess(
                userId: userId,
                organizationId: organizationId
            )
        }

        guard let choice = CanonicalBusinessEngine.chooseSessionOrganization(
            explicitOrganizationId: explicitOrganizationId,
            rememberedOrganizationId: remembered,
            documentOrganizationId: documentOrganizationId,
            probes: probes
        ) else {
            return nil
        }
        guard !choice.organizationId.isEmpty else { return choice }
        persistRememberedOrganizationId = !(choice.persistOrganizationId ?? "").isEmpty
        if let persist = choice.persistOrganizationId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !persist.isEmpty {
            storeOrganizationIdLocally(persist)
        }
        publishSessionOrganizationIfNeeded(choice.organizationId)
        return choice
    }

    /// Timeout, permission-denied, missing, and failed reads are `unknown`, not `denied`.
    @MainActor
    func probeSessionOrganizationAccess(userId: String, organizationId: String) async -> String {
        let orgId = normalizedOrganizationId(organizationId)
        guard !userId.isEmpty, !orgId.isEmpty else {
            return CanonicalBusinessEngine.accessProbeFromReadError() ?? "unknown"
        }
        var orgRead = "failed"
        var listed = false
        var isCreator = false
        var membershipRead = "failed"

        do {
            let snap = try await sessionProbeDocument(db.collection("organizations").document(orgId))
            if snap.exists, let data = snap.data() {
                orgRead = "loaded"
                applyOrganizationDocumentBilling(from: data, organizationId: orgId)
                listed = Self.listedMemberRole(in: data, userId: userId) != nil
                let creator = (data["creatorUserId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                isCreator = !creator.isEmpty && creator == userId
            } else {
                orgRead = "missing"
            }
        } catch {
            orgRead = "failed"
        }

        do {
            let snap = try await sessionProbeDocument(
                orgMembershipsCollection(userId: userId).document(orgId)
            )
            if snap.exists {
                let status = (snap.data()?["status"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? ""
                membershipRead = status == "pending" ? "pending" : "active"
            } else {
                membershipRead = "missing"
            }
        } catch {
            membershipRead = "failed"
        }

        return CanonicalBusinessEngine.orgAccessProbeFromReads(
            orgRead: orgRead,
            membershipRead: membershipRead,
            listed: listed,
            isCreator: isCreator
        ) ?? CanonicalBusinessEngine.accessProbeFromReadError() ?? "unknown"
    }

    private static func listedMemberRole(in data: [String: Any], userId: String) -> String? {
        let members = data["members"] as? [String: Any] ?? [:]
        guard let raw = members[userId] as? String else { return nil }
        let role = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return role.isEmpty ? nil : role
    }

    private enum SessionProbeTimeout: Error {
        case timedOut
    }

    private func sessionProbeDocument(
        _ ref: DocumentReference,
        timeoutSeconds: Double = 2.5
    ) async throws -> DocumentSnapshot {
        try await withThrowingTaskGroup(of: DocumentSnapshot.self) { group in
            group.addTask { try await ref.getDocument(source: .server) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw SessionProbeTimeout.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw SessionProbeTimeout.timedOut }
            return value
        }
    }

    private func sessionProbeQuery(
        _ query: Query,
        timeoutSeconds: Double
    ) async throws -> QuerySnapshot {
        try await withThrowingTaskGroup(of: QuerySnapshot.self) { group in
            group.addTask { try await query.getDocuments(source: .server) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw SessionProbeTimeout.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw SessionProbeTimeout.timedOut }
            return value
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
        let membershipSnap: DocumentSnapshot
        do {
            membershipSnap = try await getDocumentWithServerTimeoutAndCacheFallback(
                orgMembershipsCollection(userId: userId).document(orgId),
                timeoutSeconds: 4
            )
        } catch {
            print("🔥🔥🔥 DEBUG: Device session membership read failed — keeping the signed-in profile")
            deviceSessionProfile = nil
            userRole = base.role
            return base.isActive
        }
        let isCreator = creatorUserId == userId
        let accountActive = firestoreAccountActive(from: membershipSnap.data())

        var profile: AppUser
        if let data = membershipSnap.data(), membershipSnap.exists {
            profile = Self.parseAppUserDocument(userId: userId, data: data)
            profile.organizationId = orgId
            profile.isActive = accountActive
            // RULEBOOK 1.10.0 §14: role flags from `parseOrgMembershipDocument` (nested `permissions`, else flat).
            if let membership = Self.orgMembership(organizationId: orgId, data: data) {
                profile.permissions = Self.userPermissions(fromMembership: membership.permissions, fallback: profile.permissions)
                profile.isSuperAdmin = membership.isSuperAdmin
                profile.isActive = membership.accountActive
            }
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
        // RULEBOOK 1.30.2 `organizationSelfManageFlags`: Annual Leave Management and Timesheet self-sign for THIS
        // organisation — the membership here (or the creator), never the users document of another company.
        profile = profile.applyingOrganizationSelfManageFlags(
            organizationId: orgId,
            userDocument: sharedUserData,
            membership: membershipSnap.exists ? membershipSnap.data() : nil,
            creatorUserId: creatorUserId
        )
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
        let access = await probeSessionOrganizationAccess(userId: user.id, organizationId: sessionOrg)
        if access == "denied" {
            return user
        }
        let orgDoc: DocumentSnapshot
        do {
            orgDoc = try await getDocumentWithServerTimeoutAndCacheFallback(
                db.collection("organizations").document(sessionOrg),
                timeoutSeconds: 4
            )
        } catch {
            return user
        }
        guard orgDoc.exists else { return user }
        let orgData = orgDoc.data() ?? [:]
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
        guard var session = deviceSessionProfile else {
            // The membership read failed: keep this person's rights, but RULEBOOK 1.30.2 `organizationSelfManageFlags`
            // never carries the home company's self-manage toggles here (off until the membership read arrives,
            // both on for this company's creator) — as web `applyDeviceOrgMembership` does.
            return user.applyingOrganizationSelfManageFlags(
                organizationId: sessionOrg,
                userDocument: nil,
                membership: nil,
                creatorUserId: creator
            )
        }
        // RULEBOOK §12: the photo is personal; its upload time comes with it so avatars refresh in this company too.
        session.profilePhotoURL = user.profilePhotoURL
        session.profilePhotoUpdatedAt = user.profilePhotoUpdatedAt
        deviceSessionProfile = session
        return session
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
                    adminAccess: false,
                    manager: false,
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
