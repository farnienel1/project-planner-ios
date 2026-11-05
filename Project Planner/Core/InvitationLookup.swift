//
//  InvitationLookup.swift
//  Project Planner
//
//  RULEBOOK 1.31.1 §11, §16 (fourth review B-1, fifth review S-D / S-E): the `invitations` queries the security rules
//  accept. Every list names `organizationId` and `email` (an email-only query is refused for everyone), and an
//  operatives manager's list also names `invitedBy` — they may list only the invitations they sent. `invitedBy` is the
//  sender's users id (web) or sign-in email (iOS), compared by the rules without case against the caller's Auth uid or
//  token email, so an operatives manager asks once per form they may have been stored under, as web
//  `userStore.deleteUser` does.
//
//  A resend creates the new invitation first and only then closes the earlier links (skipping the new one), so a
//  refused create never leaves the person without a working link. Closed and refused marks are counted and shown.
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

/// No sign-in email and no users id to name as the sender: the rules (`invitationSentByCaller`) would refuse the write.
nonisolated struct InvitationSenderMissingError: LocalizedError, Equatable {
    var errorDescription: String? {
        "Couldn't send the invitation: your sign-in could not be read. Sign out, sign in again and try again."
    }
}

/// What closing the earlier links of a resend did.
nonisolated struct InvitationCloseResult: Equatable, Sendable {
    /// Earlier links marked used.
    var closed = 0
    /// Earlier links the rules refused to close (permission denied).
    var refused = 0
    /// Earlier links whose mark failed for another reason (network, …).
    var failed = 0
    /// The earlier links could not be listed at all (not a permission denial).
    var lookupFailed = false
    /// The caller listed only the links they sent (an operatives manager); links others sent were not checked.
    var ownLinksOnly = false
}

/// What the invitation queries returned.
nonisolated struct InvitationFetchResult {
    var rows: [QueryDocumentSnapshot] = []
    /// Queries the rules refused (permission denied), skipped.
    var deniedQueries = 0
}

extension InvitationDocument {
    /// The `invitedBy` a new invitation stores (RULEBOOK 1.31.1 hand-off item 3: iOS keeps the sender's email). The
    /// rules compare it with the caller's Auth token email or uid, so it is the sign-in email, else the users id — never
    /// the profile email (it may differ from the sign-in email) and never blank.
    nonisolated static func senderField(authEmail: String?, authUid: String?) throws -> String {
        for candidate in [authEmail, authUid] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        throw InvitationSenderMissingError()
    }

    /// `senderField` for the signed-in Auth account.
    @MainActor
    static func signedInSenderField() throws -> String {
        let auth = Auth.auth().currentUser
        return try senderField(authEmail: auth?.email, authUid: auth?.uid)
    }

    /// Every form the signed-in sender's `invitedBy` may be stored under (read only): users id, sign-in email (as given
    /// and lower case) and the profile email (older iOS invitations stored it). Blank values dropped, duplicates
    /// removed, order kept.
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

    /// Whether the signed-in account lists every invitation on an email (an admin who is not only an operatives
    /// manager). Anyone else names themself as the sender.
    @MainActor
    static func signedInCallerIsAdmin(userStore: UserStore) -> Bool {
        (userStore.currentUser?.isRosterAdmin ?? false) && !userStore.actorManagesOperativesOnly
    }

    /// `lookups` for the signed-in account.
    @MainActor
    static func lookupsForSignedInUser(organizationId: String, email: String, userStore: UserStore) -> [InvitationLookup] {
        let auth = Auth.auth().currentUser
        return lookups(
            organizationId: organizationId,
            email: email,
            callerIsAdmin: signedInCallerIsAdmin(userStore: userStore),
            senders: senderValues(authUid: auth?.uid, authEmail: auth?.email, profileEmail: userStore.currentUser?.email)
        )
    }

    /// A Firestore permission denial (`FirebaseBackend.isPermissionDenied`).
    nonisolated static func isPermissionDenied(_ error: Error) -> Bool {
        FirebaseBackend.isPermissionDenied(error)
    }

    /// Runs `lookups` and returns each invitation once. A query the rules refuse (permission denied) is skipped and
    /// counted; any other error is thrown.
    @MainActor
    static func fetch(
        _ lookups: [InvitationLookup],
        db: Firestore,
        source: FirestoreSource = .default
    ) async throws -> InvitationFetchResult {
        var result = InvitationFetchResult()
        var seen = Set<String>()
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
                    result.rows.append(document)
                }
            } catch let error where isPermissionDenied(error) {
                result.deniedQueries += 1
            }
        }
        return result
    }

    /// The earlier links a resend closes: not yet used, and never the invitation just created. Order kept.
    nonisolated static func closableInvitationIds(_ rows: [(id: String, isUsed: Bool)], excluding newInvitationId: String) -> [String] {
        rows.filter { !$0.isUsed && $0.id.caseInsensitiveCompare(newInvitationId) != .orderedSame }.map(\.id)
    }

    /// Resend order: create the new invitation first, then close the earlier links (skipping the new one). A failed
    /// create throws before anything is closed, so the earlier links keep working.
    @MainActor
    static func resend(
        create: () async throws -> String,
        closeEarlier: (_ newInvitationId: String) async -> InvitationCloseResult
    ) async throws -> (invitationId: String, closed: InvitationCloseResult) {
        let invitationId = try await create()
        let closed = await closeEarlier(invitationId)
        return (invitationId, closed)
    }

    /// Marks the earlier invitations for `email` used after a resend, through `invitationUsedWriteFields` (partial
    /// update), skipping `newInvitationId`. Only the queries the rules accept are asked. Never throws: a refused or
    /// failed mark is counted, and a failed listing is reported (`lookupFailed`), so the new link is still sent.
    @MainActor
    static func closeEarlierInvitations(
        organizationId: String,
        email: String,
        excluding newInvitationId: String,
        userStore: UserStore
    ) async -> InvitationCloseResult {
        var result = InvitationCloseResult()
        result.ownLinksOnly = !signedInCallerIsAdmin(userStore: userStore)
        let db = Firestore.firestore()
        let lookups = lookupsForSignedInUser(organizationId: organizationId, email: email, userStore: userStore)
        let rows: [QueryDocumentSnapshot]
        do {
            rows = try await fetch(lookups, db: db).rows
        } catch {
            result.lookupFailed = true
            return result
        }
        let ids = closableInvitationIds(
            rows.map { (id: $0.documentID, isUsed: ($0.data()["isUsed"] as? Bool) == true) },
            excluding: newInvitationId
        )
        let byId = Dictionary(rows.map { ($0.documentID, $0.reference) }, uniquingKeysWith: { first, _ in first })
        for id in ids {
            guard let reference = byId[id] else { continue }
            do {
                try await reference.updateData(usedFields())
                result.closed += 1
            } catch let error where isPermissionDenied(error) {
                result.refused += 1
            } catch {
                result.failed += 1
            }
        }
        return result
    }

    /// The line shown after a resend: how many earlier links were closed, any that could not be, and — for an
    /// operatives manager — that links others sent (an admin, say) may still work.
    nonisolated static func closeSummary(_ result: InvitationCloseResult) -> String {
        func links(_ count: Int) -> String { count == 1 ? "1 earlier link" : "\(count) earlier links" }
        var parts: [String] = []
        if result.lookupFailed {
            parts.append("Couldn't check for earlier links; they may still work.")
        } else {
            parts.append(result.closed == 0 ? "No earlier links to close." : "Closed \(links(result.closed)).")
        }
        if result.refused > 0 {
            parts.append("\(links(result.refused)) could not be closed (not yours to close).")
        }
        if result.failed > 0 {
            parts.append("\(links(result.failed)) could not be closed; try again.")
        }
        if result.ownLinksOnly {
            parts.append("Links sent by others (for example an admin) may still work.")
        }
        return parts.joined(separator: " ")
    }
}
