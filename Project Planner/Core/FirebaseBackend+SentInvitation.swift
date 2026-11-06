//
//  FirebaseBackend+SentInvitation.swift
//  Project Planner
//
//  RULEBOOK 1.33.0 §11 (`canChangeLineManager`): the invitation the signed-in person sent to an email in this
//  organisation, for an Operatives-toggle manager who may still set the line manager of their own unaccepted invite
//  (web `lib/orgSetup/openInvitation.ts`). Lists only invitations the caller sent (`invitedBy == uid`), which is what
//  the security rules allow a list of. App plumbing only; the rulebook decides.
//

import Foundation
@preconcurrency import FirebaseFirestore

extension FirebaseBackend {
    /// `{ accepted, invitedBy }` for `canChangeLineManager`, or nil when the caller sent no invitation to `email` here
    /// (or it could not be read).
    func loadSentInvitation(organizationId: String, uid: String, email: String) async -> (accepted: Bool, invitedBy: String)? {
        let orgId = normalizedOrganizationId(organizationId)
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !orgId.isEmpty, !uid.isEmpty, !address.isEmpty else { return nil }
        do {
            let snapshot = try await db.collection("invitations")
                .whereField("invitedBy", isEqualTo: uid)
                .whereField("email", isEqualTo: address)
                .getDocuments()
            let rows = snapshot.documents.map { $0.data() }.filter {
                normalizedOrganizationId(($0["organizationId"] as? String) ?? "") == orgId
            }
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
