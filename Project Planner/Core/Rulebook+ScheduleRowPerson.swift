//
//  Rulebook+ScheduleRowPerson.swift
//  Project Planner
//
//  RULEBOOK 1.44.0 §21 (owner decision 14 Nov, question H option 1): a booking whose person cannot be resolved is never
//  hidden from a job's scheduling week. Typed wrapper for web `lib/canonical/unresolvedBookingPeople.ts`
//  (`scheduleRowPerson`, `UNRESOLVED_BOOKING_PERSON_CHIP`), called through `CanonicalBusinessEngine.callJSON`.
//

import Foundation

/// `scheduleRowPerson(personId, { accounts, operatives })`: the row a booked id gets on the scheduling week.
nonisolated struct RulebookScheduleRowPerson: Codable, Equatable, Sendable {
    var key: String
    var accountId: String?
    var operativeId: String?
    /// True when the id names no account and no catalogue row.
    var unresolved: Bool
    /// "Unknown person · 6A9632BA" for an unresolved id; nil otherwise.
    var label: String?
    var idHint: String?
}

extension CanonicalBusinessEngine {
    /// `scheduleRowPerson(personId, input)`. Nil when the script did not answer.
    nonisolated static func scheduleRowPerson(
        _ personId: String,
        _ input: CanonicalBookingPersonInput
    ) -> RulebookScheduleRowPerson? {
        guard let json = RulebookJSON.object(input) else { return nil }
        return RulebookJSON.decode(RulebookScheduleRowPerson.self, from: callJSON("scheduleRowPerson", arguments: [personId, json]))
    }

    /// `UNRESOLVED_BOOKING_PERSON_CHIP` ("Not linked to a person"): the amber chip in place of the role pill.
    nonisolated static var unresolvedBookingPersonChip: String {
        constant("UNRESOLVED_BOOKING_PERSON_CHIP", as: String.self) ?? "Not linked to a person"
    }

    /// `UNKNOWN_BOOKING_PERSON_LABEL` ("Unknown person").
    nonisolated static var unknownBookingPersonLabel: String {
        constant("UNKNOWN_BOOKING_PERSON_LABEL", as: String.self) ?? "Unknown person"
    }
}
