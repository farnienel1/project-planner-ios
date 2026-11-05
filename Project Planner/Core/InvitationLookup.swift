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
//  RULEBOOK 1.32.0: the query constraints come from `invitationListConstraints` (this organisation, the email as typed
//  and lower case, and for an operatives manager each sender value), and a refused read is skipped only per
//  `invitationReadErrorIsSkippable` (permission-denied). The writes stay `invitationCreateFields` /
//  `invitationUsedWriteFields` / `userDeleteWrites`.
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

/// One `invitations` query: the equality constraints `invitationListConstraints` returned for it, in order.
nonisolated struct InvitationLookup: Equatable, Hashable, Sendable {
    let constraints: [InvitationQueryConstraint]

    /// The value this query asks for `field` (`organizationId`, `email`, `invitedBy`), or nil when it does not name it.
    func value(of field: String) -> String? {
        constraints.first { $0.field == field }?.value
    }
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

    /// The sender ids the signed-in account's `invitedBy` may be stored under (read only), handed to
    /// `invitationListConstraints`, which also asks the lower-case form of each email: users id, sign-in email and the
    /// profile email (older iOS invitations stored it). Blank values dropped, duplicates removed, order kept.
    nonisolated static func senderValues(authUid: String?, authEmail: String?, profileEmail: String?) -> [String] {
        let candidates = [authUid, authEmail, profileEmail].map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The queries for the invitations on `email` (as stored or typed, not pre-lowered) in `organizationId`, from
    /// `invitationListConstraints`: an admin (`callerIsAdmin`) gets one per email form; anyone else (an operatives
    /// manager) one per email form and sender value. Empty when the organisation or email is blank, or a non-admin has
    /// no sender id (the rules would refuse it).
    nonisolated static func lookups(
        organizationId: String,
        email: String,
        callerIsAdmin: Bool,
        senders: [String]
    ) -> [InvitationLookup] {
        CanonicalBusinessEngine.invitationListConstraints(
            organizationId: organizationId,
            email: email,
            actorManagesOperatives: !callerIsAdmin,
            senderIds: senders
        )
        .filter { !$0.isEmpty }
        .map { InvitationLookup(constraints: $0) }
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

    /// A Firestore permission denial on a write (`FirebaseBackend.isPermissionDenied`): a refused mark is counted.
    nonisolated static func isPermissionDenied(_ error: Error) -> Bool {
        FirebaseBackend.isPermissionDenied(error)
    }

    /// `invitationReadErrorIsSkippable` on the error's Firestore code: an invitation read in a clean-up is skipped only
    /// when the rules refused it; any other failure stops the clean-up.
    nonisolated static func readErrorIsSkippable(_ error: Error) -> Bool {
        CanonicalBusinessEngine.invitationReadErrorIsSkippable(code: FirestoreErrorCodeName.of(error))
    }

    /// Runs `lookups` and returns each invitation once. A query the rules refuse is skipped and counted
    /// (`readErrorIsSkippable`); any other error is thrown.
    @MainActor
    static func fetch(
        _ lookups: [InvitationLookup],
        db: Firestore,
        source: FirestoreSource = .default
    ) async throws -> InvitationFetchResult {
        var result = InvitationFetchResult()
        var seen = Set<String>()
        for lookup in lookups {
            guard !lookup.constraints.isEmpty else { continue }
            var query: Query = db.collection("invitations")
            for constraint in lookup.constraints {
                query = query.whereField(constraint.field, isEqualTo: constraint.value)
            }
            do {
                let snapshot = try await query.getDocuments(source: source)
                for document in snapshot.documents where seen.insert(document.documentID).inserted {
                    result.rows.append(document)
                }
            } catch let error where readErrorIsSkippable(error) {
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
