//
//  UserStore+Ghosts.swift
//  Project Planner
//
//  Rulebook 1.34.0 §11: adding a ghost operative and giving one app access. The documents written are exactly the
//  rulebook's plans (`ghostCreateWrites`, `ghostUpgradeWrites`); this file only sends them to Firestore and adds
//  the SDK server time where the plan names it. Deleting a ghost is the ordinary `deleteUser` (`userDeleteWrites`
//  with `ghost`), which already writes `operative_deleted`.
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

extension UserStore {
    /// Creates a ghost from the Add user draft (`ghostCreateError` first, then `ghostCreateWrites`), then tells the
    /// admins (`operative_created`, company activity). Online only. False with `errorMessage` set when refused.
    func createGhost(draft: [String: Any], displayName: String) async -> Bool {
        guard let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId else {
            errorMessage = "Organization not loaded. Please wait a moment and try again."
            return false
        }
        guard let actorUid = Auth.auth().currentUser?.uid else {
            errorMessage = "Sign in again to add this person."
            return false
        }
        guard GhostRulebook.canCreateGhost(currentUser) else {
            errorMessage = CanonicalBusinessEngine.ghostText(
                "GHOST_CREATE_REFUSED_MESSAGE",
                fallback: "Only admins and managers with the Operatives permission can add a ghost."
            )
            return false
        }
        let roster = LineManagerRulebook.roster(organizationUsers)
        switch CanonicalBusinessEngine.ghostCreateError(draft: draft, roster: roster) {
        case .none:
            errorMessage = "Couldn't add this person: the rules did not load. Try again."
            return false
        case .some(.some(let message)):
            errorMessage = message
            return false
        case .some(.none):
            break
        }
        let ghostId = UUID().uuidString
        guard let plan = CanonicalBusinessEngine.ghostCreateWrites(
            organizationId: organizationId,
            ghostId: ghostId,
            draft: draft,
            actorUserId: actorUid,
            privatePay: SecuritySwitchContext.privatePay,
            roster: roster
        ) else {
            errorMessage = "Couldn't add this person: the rules did not load. Try again."
            return false
        }
        let db = Firestore.firestore()
        func fields(_ write: RulebookGhostWrite) -> [String: Any] {
            var out = write.fields
            for key in write.serverTimestampFields { out[key] = FieldValue.serverTimestamp() }
            return out
        }
        do {
            // `users/{ghostId}` first: the pay profile's rules read it (rulebook `ghostCreateWrites`).
            try await db.document(plan.user.path).setData(fields(plan.user))
            if let payProfile = plan.payProfile {
                try await db.document(payProfile.path).setData(fields(payProfile))
            }
        } catch {
            errorMessage = "Couldn't add this person: \(error.localizedDescription)"
            return false
        }
        // RULEBOOK 1.34.0 §11, §13: the admins are told with the existing `operative_created` notice.
        await notificationService?.notifyOperativeInvited(userId: ghostId, name: displayName)
        await loadOrganizationUsers(forceRefresh: true)
        return true
    }

    /// Give app access (admins only): `ghostUpgradeRefusal` with the email, the same live-claim check as Add user
    /// (`inviteEmailHasLiveClaim`), then `ghostUpgradeWrites` in one batch, then the usual set-up email
    /// (`sendInvitationEmail`). Returns the invitation id on success, else the message.
    func giveGhostAppAccess(_ ghost: AppUser, email: String) async -> (invitationId: String?, error: String?) {
        guard let viewer = currentUser else { return (nil, "Sign in again.") }
        guard let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId,
              let backend = firebaseBackend else {
            return (nil, "Organization not loaded. Please wait a moment and try again.")
        }
        guard let actorUid = Auth.auth().currentUser?.uid else { return (nil, "Sign in again.") }
        let viewerRow = GhostRulebook.viewer(viewer)
        let ghostRow = GhostRulebook.storedGhostRow(ghost)
        switch CanonicalBusinessEngine.ghostUpgradeRefusal(viewer: viewerRow, ghost: ghostRow, email: email) {
        case .none:
            return (nil, "Couldn't check this: the rules did not load. Try again.")
        case .some(.some(let code)):
            return (nil, CanonicalBusinessEngine.ghostUpgradeRefusalMessage(code))
        case .some(.none):
            break
        }
        do {
            let claimInput = try await backend.inviteEmailClaimInput(email: email, organizationId: organizationId)
            guard let blocked = CanonicalBusinessEngine.inviteEmailHasLiveClaim(claimInput) else {
                return (nil, "Could not check whether this email is already in the organisation. Try again.")
            }
            if blocked {
                return (nil, "A user with the email address '\(email)' already exists in this organization. Each email address can only be used once per organization.")
            }
        } catch {
            return (nil, "Could not check whether this email is already in the organisation. Try again.")
        }
        let invitationId = UUID().uuidString
        let invitedBy = Auth.auth().currentUser?.email ?? viewer.email
        guard let plan = CanonicalBusinessEngine.ghostUpgradeWrites(
            viewer: viewerRow,
            organizationId: organizationId,
            ghostId: ghost.id,
            ghost: ghostRow,
            email: email,
            invitationId: invitationId,
            invitedBy: invitedBy,
            nowMs: (Date().timeIntervalSince1970 * 1000).rounded(),
            actorUserId: actorUid
        ) else {
            return (nil, "Couldn't give app access: the rules did not load. Try again.")
        }
        let db = Firestore.firestore()
        let batch = db.batch()
        var userFields: [AnyHashable: Any] = [:]
        for (key, value) in plan.userSet { userFields[key] = value }
        for key in plan.userRemove { userFields[key] = FieldValue.delete() }
        userFields["updatedAt"] = FieldValue.serverTimestamp()
        batch.updateData(userFields, forDocument: db.document(plan.userPath))
        var invitation = plan.invitationFields
        invitation["createdAt"] = Timestamp(date: Date())
        batch.setData(invitation, forDocument: db.document(plan.invitationPath))
        batch.setData(plan.claimFields, forDocument: db.document(plan.claimPath))
        do {
            try await batch.commit()
        } catch {
            return (nil, "Couldn't give app access: \(error.localizedDescription)")
        }
        // The usual set-up email, as for any invitation (the person accepts on the web link).
        await backend.sendInvitationEmail(
            email: plan.claimPath.components(separatedBy: "/").last ?? email,
            firstName: ghost.firstName,
            surname: ghost.surname,
            invitationId: invitationId
        )
        await loadOrganizationUsers(forceRefresh: true)
        return (invitationId, nil)
    }
}
