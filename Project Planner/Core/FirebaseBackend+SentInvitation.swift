//
//  FirebaseBackend+SentInvitation.swift
//  Project Planner
//
//  RULEBOOK 1.33.0 §11 (`canChangeLineManager`): the invitation the signed-in person sent to an email in this
//  organisation, for an Operatives-toggle manager who may still set the line manager of their own unaccepted invite
//  (web `lib/orgSetup/openInvitation.ts`). The query goes through `InvitationDocument.fetch` with the constraints of
//  `invitationListConstraints` (this organisation, the email as typed and lower case, and each value the caller's
//  `invitedBy` may be stored under: users id, sign-in email, profile email) — the only `invitations` list the security
//  rules accept from an operatives manager. App plumbing only; the rulebook decides.
//

import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

extension FirebaseBackend {
    /// `{ accepted, invitedBy }` for `canChangeLineManager`, or nil when the caller sent no invitation to `email` here
    /// (or it could not be read). Every row the lookups return was sent by the caller (each query names `invitedBy`),
    /// so `invitedBy` is reported as the caller's users id, which `canChangeLineManager` compares with the actor's ids.
    func loadSentInvitation(
        organizationId: String,
        uid: String,
        email: String,
        profileEmail: String? = nil
    ) async -> (accepted: Bool, invitedBy: String)? {
        let orgId = normalizedOrganizationId(organizationId)
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orgId.isEmpty, !uid.isEmpty, !address.isEmpty else { return nil }
        let lookups = InvitationDocument.lookups(
            organizationId: orgId,
            email: address,
            callerIsAdmin: false,
            senders: InvitationDocument.senderValues(
                authUid: uid,
                authEmail: Auth.auth().currentUser?.email,
                profileEmail: profileEmail
            )
        )
        guard !lookups.isEmpty else { return nil }
        do {
            let result = try await InvitationDocument.fetch(lookups, db: db)
            let rows = result.rows.map { $0.data() }
            guard !rows.isEmpty else { return nil }
            // Any open (not used) invitation from this person counts; otherwise it has been accepted.
            let open = rows.contains { ($0["isUsed"] as? Bool) != true }
            return (accepted: !open, invitedBy: uid)
        } catch {
            NSLog("SENT_INVITATION_READ_FAILED error=%@", error.localizedDescription)
            return nil
        }
    }
}
