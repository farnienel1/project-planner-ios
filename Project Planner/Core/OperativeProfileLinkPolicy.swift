//
//  OperativeProfileLinkPolicy.swift
//  Project Planner
//
//  When this phone may create an `operatives` row for an app account (qualifications need one), and which existing
//  row is that person's. Found while tracing "Unknown person" booking ids in Data health: rows were created with a
//  random id whenever the phone's list (possibly only a cache copy) had no row on the email, and an operative's own
//  phone re-linked another row's email by a name match. Neither may happen again:
//  - a row is matched only by the person's ids and email — `OperativeStore.operativeRow(for:in:)` (`personDedupeKey`)
//    and `bookingIdsForAccount` (the ids the rulebook says this account goes by) — never by name;
//  - a row is created only once the `operatives` list has had a server snapshot, so "no row" is a fact;
//  - an operative-level account never creates or re-links a row (only staff do, through Manage Users).
//

import Foundation

@MainActor
enum OperativeProfileLinkPolicy {
    enum Decision: Equatable {
        /// The person's existing row.
        case existing(UUID)
        /// No row is this person's, the list is the server's, and the actor may create one.
        case create
        /// The `operatives` list has not come from the server yet: no row is created from a cache copy.
        case refuseListNotLoaded
        /// The actor is operative level (or unknown): only staff create or link rows.
        case refuseNotStaff
        /// No email and no id to match on, or the rulebook did not answer: nothing is guessed.
        case refuseCannotMatch
    }

    static let listNotLoadedMessage = "The people list is still loading. Try again in a moment."
    static let notStaffMessage = "Your account is not linked to an operative profile yet. Ask an admin to link it in Manage Users."
    static let cannotMatchMessage = "Could not check this person's operative profile. Check their email and try again."

    static func message(for decision: Decision) -> String? {
        switch decision {
        case .existing, .create: return nil
        case .refuseListNotLoaded: return listNotLoadedMessage
        case .refuseNotStaff: return notStaffMessage
        case .refuseCannotMatch: return cannotMatchMessage
        }
    }

    /// The row in `operatives` that is `subject`'s, by the rulebook's person matching only (never a name).
    /// `bookingIds`: `bookingIdsForAccount` for the subject (nil when the script did not answer).
    static func existingRow(for subject: AppUser, in operatives: [Operative], bookingIds: [String]?) -> Operative? {
        if let row = OperativeStore.operativeRow(for: subject, in: operatives) { return row }
        let ids = Set((bookingIds ?? []).map { $0.lowercased() })
        guard !ids.isEmpty else { return nil }
        return operatives.first { row in
            ids.contains(row.documentId.lowercased())
                || (row.linkedUserId.map { ids.contains($0.lowercased()) } ?? false)
        }
    }

    /// What to do for `subject` when `actor` needs their `operatives` row.
    /// `actorLevel`: the actor's `permissionLevelOf` (nil when unknown). `listConfirmedByServer`:
    /// `OperativeStore.operativesConfirmedByServer`.
    static func decide(
        subject: AppUser,
        actorLevel: RulebookPermissionLevel?,
        operatives: [Operative],
        bookingIds: [String]?,
        listConfirmedByServer: Bool
    ) -> Decision {
        if let row = existingRow(for: subject, in: operatives, bookingIds: bookingIds) { return .existing(row.id) }
        guard let actorLevel, actorLevel != .operative else { return .refuseNotStaff }
        guard listConfirmedByServer else { return .refuseListNotLoaded }
        let email = subject.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, bookingIds != nil else { return .refuseCannotMatch }
        // RULEBOOK 1.34.0 §11: a ghost is a users document only; it never gets an `operatives` row.
        guard !subject.isGhost else { return .refuseCannotMatch }
        return .create
    }

    /// `bookingIdsForAccount` for `subject` against the phone's `operatives` rows. Nil when the script did not answer.
    static func bookingIds(for subject: AppUser, operatives: [Operative]) -> [String]? {
        CanonicalBusinessEngine.bookingIdsForAccount(
            CanonicalBusinessEngine.CanonicalBookingPersonAccount(
                id: subject.id,
                email: subject.email,
                formerIds: subject.formerUserIds,
                aliasIds: subject.sameEmailUserIds
            ),
            operatives: operatives.map {
                CanonicalBusinessEngine.CanonicalBookingPersonOperative(id: $0.documentId, email: $0.email)
            }
        )
    }
}
