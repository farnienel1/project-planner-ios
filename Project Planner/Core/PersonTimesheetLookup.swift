//
//  PersonTimesheetLookup.swift
//  Project Planner
//
//  Guardrail 1 (web `lib/timesheets/personTimesheetDocs.ts`, branch `w-timesheet-lookups`): a person's timesheet
//  documents under every id they go by. The ids are the rulebook's `personIdSet` (`RulebookPeople.ownerIds`: own id,
//  `formerUserIds`, `sameEmailUserIds`, same-email users documents). A document belongs to the person when its stored
//  `userId` is one of them, or — for a sheet an older build stored without `userId` — when its document id names one of
//  them (`CanonicalBusinessEngine.timesheetDocumentSubjectId`, RULEBOOK 1.31.0). Ids compare without case. No pay,
//  period or status rule here: the rows go on to the existing readers.
//

import Foundation

enum PersonTimesheetLookup {
    /// Firestore `in` chunk for the alias ids (both apps use 10).
    static let idChunk = 10

    private static func key(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The person a timesheet document is filed under: its stored `userId`, else the id its document id names.
    static func documentOwnerId(documentId: String, data: [String: Any]) -> String {
        let stored = (data["userId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        return CanonicalBusinessEngine.timesheetDocumentSubjectId(documentId) ?? ""
    }

    /// The ids once each (without case), the first one kept first.
    static func uniqueIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(key(trimmed)).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// `ids` after the first, in chunks of `idChunk` (the `userId in` queries).
    static func aliasChunks(_ ids: [String]) -> [[String]] {
        let aliases = Array(uniqueIds(ids).dropFirst())
        return stride(from: 0, to: aliases.count, by: idChunk).map { Array(aliases[$0..<min($0 + idChunk, aliases.count)]) }
    }

    /// The timesheet documents (ids starting `timesheet_`) of `documents` that belong to the person with `ids`, once
    /// each by document id. A stored `userId` always decides, so another person's sheet is never borrowed.
    static func documentsForPerson(
        ids: [String],
        documents: [(documentId: String, data: [String: Any])]
    ) -> [(documentId: String, data: [String: Any])] {
        let keys = Set(ids.map(key).filter { !$0.isEmpty })
        var seen = Set<String>()
        var out: [(documentId: String, data: [String: Any])] = []
        for entry in documents {
            guard entry.documentId.hasPrefix("timesheet_"), !seen.contains(entry.documentId) else { continue }
            let owner = key(documentOwnerId(documentId: entry.documentId, data: entry.data))
            guard !owner.isEmpty, keys.contains(owner) else { continue }
            seen.insert(entry.documentId)
            out.append(entry)
        }
        return out
    }

    /// The person (from `candidates`) a stored timesheet owner id belongs to, under every id they go by; nil when none.
    /// An exact id match wins over an alias, so two documents of one person keep their own sheets (web
    /// `timesheetOwnerResolver`). `idsOf` gives a candidate's ids (`RulebookPeople.ownerIds`).
    static func ownerResolver(
        candidates: [AppUser],
        idsOf: (AppUser) -> [String]
    ) -> (String) -> AppUser? {
        var exact: [String: AppUser] = [:]
        var alias: [String: AppUser] = [:]
        for member in candidates { exact[key(member.id)] = member }
        for member in candidates {
            for id in idsOf(member) {
                let k = key(id)
                if !k.isEmpty, exact[k] == nil, alias[k] == nil { alias[k] = member }
            }
        }
        return { stored in
            let k = key(stored)
            guard !k.isEmpty else { return nil }
            return exact[k] ?? alias[k]
        }
    }

    /// Web `unresolvedTimesheetPerson`: an exported sheet whose stored person is nobody in the organisation is listed for
    /// admins as "Unknown person · <hint>" (`UNKNOWN_BOOKING_PERSON_LABEL`, `bookingPersonIdHint`), never dropped. Its
    /// id is the stored id; it has no profile to open.
    static func unresolvedPerson(storedUserId: String, organizationId: String) -> AppUser {
        let hint = (CanonicalBusinessEngine.callJSON("bookingPersonIdHint", arguments: [storedUserId]) as? String)
            ?? String(storedUserId.prefix(8)).uppercased()
        return AppUser(
            id: storedUserId,
            email: "",
            organizationId: organizationId,
            role: .operative,
            createdAt: Date(timeIntervalSince1970: 0),
            firstName: CanonicalBusinessEngine.unknownBookingPersonLabel,
            surname: hint.isEmpty ? "" : "· \(hint)",
            isActive: false,
            passwordSet: false
        )
    }
}
