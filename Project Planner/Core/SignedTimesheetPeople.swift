//
//  SignedTimesheetPeople.swift
//  Project Planner
//
//  RULEBOOK 1.33.0 §2 (signed timesheets) with platform guardrail 1: deleting or replacing (1.41.0 §5) a booking
//  checks every timesheet of the booked person, under every id they go by — the same people as web
//  `bookedPersonTimesheetUserIds` (`lib/bookings/signedTimesheetDeleteWarning.ts`). Before this, iOS read only the one
//  account `accountForLabourBooking` named (or a manager booking's stored `userId`), so a sheet filed under a former
//  invite id or a same-email account, or a booking stored under an `operatives` row with no account match, gave no
//  warning. App plumbing only: `resolveBookingPerson` and `personIdSet` decide.
//

import Foundation

enum SignedTimesheetPeople {
    /// Every users id the person a booking names goes by: the account `personId` resolves to (a users id, a former
    /// invite id, a same-email id or an `operatives` row on their email — `resolveBookingPerson`), then `personIdSet`
    /// of that account, then the stored id. A booking naming no account on the roster gives just the stored id, so its
    /// own sheets are still found. Empty for a blank id.
    static func timesheetUserIds(
        personId: String,
        users: [AppUser],
        operatives: [CanonicalBusinessEngine.CanonicalBookingPersonOperative]
    ) -> [String] {
        let stored = personId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return [] }
        let input = CanonicalBusinessEngine.CanonicalBookingPersonInput(
            accounts: users.map {
                CanonicalBusinessEngine.CanonicalBookingPersonAccount(
                    id: $0.id, email: $0.email, formerIds: $0.formerUserIds, aliasIds: $0.sameEmailUserIds
                )
            },
            operatives: operatives
        )
        let accountId = CanonicalBusinessEngine.resolveBookingPerson(stored, input)?.accountId
            ?? users.first(where: { $0.id == stored })?.id
        guard let accountId, let account = users.first(where: { $0.id == accountId }) else { return [stored] }
        var seen = Set<String>()
        return (RulebookPeople.ownerIds(for: account, users: users) + [stored])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `timesheetUserIds` over the live roster (`RulebookRosterSnapshot`) and `operatives` rows
    /// (`RulebookCatalogueOperativeSnapshot`), for the delete and Replace paths, which hold no store.
    static func timesheetUserIds(personId: String) -> [String] {
        let operatives = RulebookCatalogueOperativeSnapshot.rows.compactMap { row -> CanonicalBusinessEngine.CanonicalBookingPersonOperative? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return CanonicalBusinessEngine.CanonicalBookingPersonOperative(id: id, email: row["email"] as? String)
        }
        return timesheetUserIds(personId: personId, users: RulebookRosterSnapshot.users, operatives: operatives)
    }
}
