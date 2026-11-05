//
//  InvitationLookup.swift
//  Project Planner
//
//  RULEBOOK 1.31.1 §11, §16 (fourth review B-1, fifth review S-D / S-E): the `invitations` queries the security rules
//  accept. Every list names `organizationId` and `email` (an email-only query is refused for everyone), and an
//  operatives manager's list also names `invitedBy` — they may list only the invitations they sent. `invitedBy` is the
//  sender's users id (web) or sign-in email (iOS), compared by the rules without case, so an operatives manager asks
//  once per form they may have been stored under, as web `userStore.deleteUser` does.
//
//  Query plumbing for the rules' shape, not a business rule: no rulebook function owns invitation query constraints
//  (reported to the web agent). The writes stay `invitationCreateFields` / `invitationUsedWriteFields` / `userDeleteWrites`.
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

/// One `invitations` query: `organizationId` == and `email` ==, plus `invitedBy` == when set.
nonisolated struct InvitationLookup: Equatable, Hashable, Sendable {
    let organizationId: String
    let email: String
    let invitedBy: String?
}

extension InvitationDocument {
    /// The `invitedBy` a new invitation stores (RULEBOOK 1.31.1 hand-off item 3: iOS keeps the sender's email): the
    /// profile email, else the sign-in email, else the users id. Never a made-up sender (the rules refuse an operatives
    /// manager's invitation that does not name them).
    nonisolated static func senderField(profileEmail: String?, authEmail: String?, authUid: String?) -> String {
        for candidate in [profileEmail, authEmail, authUid] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return ""
    }

    /// Every form the signed-in sender's `invitedBy` may be stored under: users id, sign-in email (as given and lower
    /// case) and profile email. Blank values dropped, duplicates removed, order kept.
    nonisolated static func senderValues(authUid: String?, authEmail: String?, profileEmail: String?) -> [String] {
        let trimmedAuthEmail = authEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = [
            authUid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            trimmedAuthEmail,
            trimmedAuthEmail.lowercased(),
            profileEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        ]
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The queries for the invitations on `email` in `organizationId`. The email is asked as stored by
    /// `invitationCreateFields` (lower case) and, for older rows, as typed. A caller who is not an admin
    /// (`callerIsAdmin` false — an operatives manager) gets one query per sender form; an admin one per email form.
    /// Empty when the organisation or email is blank, or a non-admin has no sender id (the rules would refuse it).
    nonisolated static func lookups(
        organizationId: String,
        email: String,
        callerIsAdmin: Bool,
        senders: [String]
    ) -> [InvitationLookup] {
        let org = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !org.isEmpty, !raw.isEmpty else { return [] }
        let emails = raw.lowercased() == raw ? [raw] : [raw.lowercased(), raw]
        if callerIsAdmin {
            return emails.map { InvitationLookup(organizationId: org, email: $0, invitedBy: nil) }
        }
        let senderForms = senders.filter { !$0.isEmpty }
        return emails.flatMap { address in
            senderForms.map { InvitationLookup(organizationId: org, email: address, invitedBy: $0) }
        }
    }

    /// `lookups` for the signed-in account: an admin (and not only an operatives manager) lists every invitation on the
    /// email; anyone else names themself as the sender.
    @MainActor
    static func lookupsForSignedInUser(organizationId: String, email: String, userStore: UserStore) -> [InvitationLookup] {
        let me = userStore.currentUser
        let callerIsAdmin = (me?.isRosterAdmin ?? false) && !userStore.actorManagesOperativesOnly
        let auth = Auth.auth().currentUser
        return lookups(
            organizationId: organizationId,
            email: email,
            callerIsAdmin: callerIsAdmin,
            senders: senderValues(authUid: auth?.uid, authEmail: auth?.email, profileEmail: me?.email)
        )
    }

    /// Runs `lookups` and returns each invitation once. A refused or failed query is skipped (web `.catch(() => null)`);
    /// when every query failed the last error is thrown, so a caller that must not continue on a failed read can stop.
    @MainActor
    static func fetch(
        _ lookups: [InvitationLookup],
        db: Firestore,
        source: FirestoreSource = .default
    ) async throws -> [QueryDocumentSnapshot] {
        var rows: [QueryDocumentSnapshot] = []
        var seen = Set<String>()
        var failures = 0
        var lastError: Error?
        for lookup in lookups {
            var query: Query = db.collection("invitations")
                .whereField("organizationId", isEqualTo: lookup.organizationId)
                .whereField("email", isEqualTo: lookup.email)
            if let sender = lookup.invitedBy {
                query = query.whereField("invitedBy", isEqualTo: sender)
            }
            do {
                let snapshot = try await query.getDocuments(source: source)
                for document in snapshot.documents where seen.insert(document.documentID).inserted {
                    rows.append(document)
                }
            } catch {
                failures += 1
                lastError = error
            }
        }
        if failures > 0, failures == lookups.count, let lastError { throw lastError }
        return rows
    }

    /// Marks the earlier invitations for `email` used before a resend, through `invitationUsedWriteFields` (partial
    /// update). Only the queries the rules accept are asked; a refused mark is skipped (a link sent by someone else
    /// stays theirs to close).
    @MainActor
    static func markEarlierInvitationsUsed(organizationId: String, email: String, userStore: UserStore) async throws {
        let db = Firestore.firestore()
        let lookups = lookupsForSignedInUser(organizationId: organizationId, email: email, userStore: userStore)
        let existing = try await fetch(lookups, db: db)
        for document in existing where (document.data()["isUsed"] as? Bool) != true {
            try? await document.reference.updateData(usedFields())
        }
    }
}
