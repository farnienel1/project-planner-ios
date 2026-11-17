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

    // MARK: - Review of #259

    typealias Document = (documentId: String, data: [String: Any])

    /// Web `mapInBatches`: runs `work` on `items` at most `size` at a time (review of #259, S2), results in input order.
    static func mapInBatches<T, R>(_ items: [T], size: Int, _ work: @escaping (T) async -> R) async -> [R] {
        var out: [R] = []
        out.reserveCapacity(items.count)
        var start = 0
        let step = max(1, size)
        while start < items.count {
            let batch = Array(items[start..<min(start + step, items.count)])
            let results = await withTaskGroup(of: (Int, ResultBox<R>).self) { group -> [R] in
                for (index, item) in batch.enumerated() {
                    group.addTask { (index, ResultBox(await work(item))) }
                }
                var slots = [R?](repeating: nil, count: batch.count)
                for await (index, box) in group { slots[index] = box.value }
                return slots.compactMap { $0 }
            }
            out += results
            start += step
        }
        return out
    }

    /// A result carried out of a task group (the rows are plain Firestore data).
    nonisolated final class ResultBox<R>: @unchecked Sendable {
        let value: R
        init(_ value: R) { self.value = value }
    }

    /// Review of #259 (S1, S2, N1; web `personTimesheetDocs`): reads one person's timesheet documents with the queries
    /// given — the own id (`ids[0]`, `userId ==`), the other ids in chunks of `idChunk` (`userId in`, a refused chunk
    /// asked id by id), and, when `byDocumentPrefix` is given (never for an operative: the rules refuse it), each id's
    /// document-id prefix — up to 8 at a time. Firestore matches ids exactly as stored (case-sensitive), so each id is
    /// asked as `personIdSet` lists it. A refused query is skipped and reported to `warn`, never at the cost of the
    /// rows already read. Returns only the person's documents (`documentsForPerson`).
    static func gather(
        ids: [String],
        byUserIds: @escaping ([String]) async throws -> [Document],
        byDocumentPrefix: ((String) async throws -> [Document])?,
        warn: @escaping (String) -> Void = { _ in }
    ) async -> [Document] {
        let unique = uniqueIds(ids)
        guard let own = unique.first else { return [] }
        var jobs: [() async -> [Document]] = []
        jobs.append {
            do { return try await byUserIds([own]) } catch { warn("own userId query refused"); return [] }
        }
        for chunk in aliasChunks(unique) {
            jobs.append {
                do { return try await byUserIds(chunk) } catch {
                    var rows: [Document] = []
                    for id in chunk {
                        do { rows += try await byUserIds([id]) } catch { warn("alias userId query refused") }
                    }
                    return rows
                }
            }
        }
        if let byDocumentPrefix {
            for id in unique {
                jobs.append {
                    do { return try await byDocumentPrefix(id) } catch { warn("document-id query refused"); return [] }
                }
            }
        }
        let results = await mapInBatches(jobs, size: 8) { await $0() }
        return documentsForPerson(ids: unique, documents: results.flatMap { $0 })
    }

    /// Review of #259 (B1, S7): whether the period screens — which read and save only `timesheet_{uid}_{start}` and its
    /// revisions (`timesheetDocumentId`, `parseTimesheetRevisionDocId`) — would open exactly this stored document for
    /// `ownId`. Ids compare exactly (a document id is case-sensitive). A row with no known document (this device's own
    /// copy) opens as before.
    static func opensStoredDocument(documentId: String?, ownId: String, startDayKey: String) -> Bool {
        guard let documentId, !documentId.isEmpty else { return true }
        guard let standard = CanonicalBusinessEngine.timesheetDocumentId(userId: ownId, startDayKey: startDayKey) else { return false }
        let base = CanonicalBusinessEngine.parseTimesheetRevisionDocId(documentId)?.baseDocumentId ?? documentId
        return base == standard
    }

    /// Who an exported sheet is listed under (web `exportedSheetOwnerResolver`).
    struct ExportedOwner {
        let user: AppUser
        /// A stored id nobody in the organisation goes by (a deleted person): "Unknown person · <hint>".
        let unresolved: Bool
    }

    /// Review of #259 (owner data, Raccord MEP; web `exportedSheetOwnerResolver`): the stored person id of a sheet is
    /// matched to a listed person under every id they go by (exact id first); several users documents of ONE person
    /// (`personIdSet`: a second record on the same email, a former invite id) are one person, listed under the active,
    /// signed-up record; an id nobody in the organisation goes by is one "Unknown person" stand-in per id when
    /// `includeUnresolved` (admins, once the roster has loaded); otherwise nil.
    static func exportedOwnerResolver(
        users: [AppUser],
        roster: [AppUser],
        idsOf: @escaping (AppUser) -> [String],
        includeUnresolved: Bool,
        organizationId: String
    ) -> (String) -> ExportedOwner? {
        let fullRoster = roster.isEmpty ? users : roster
        let ownerOf = ownerResolver(candidates: users, idsOf: idsOf)
        let rosterOwnerOf = ownerResolver(candidates: fullRoster, idsOf: idsOf)
        func rank(_ member: AppUser) -> Int { (member.isActive ? 0 : 2) + (member.passwordSet ? 0 : 1) }
        var primaryById: [String: AppUser] = [:]
        for member in users where primaryById[key(member.id)] == nil {
            let ids = Set(idsOf(member).map(key) + [key(member.id)])
            let records = users.filter { ids.contains(key($0.id)) }
            let primary = records.min { rank($0) < rank($1) } ?? member
            for record in records { primaryById[key(record.id)] = primary }
            if primaryById[key(member.id)] == nil { primaryById[key(member.id)] = primary }
        }
        var unknown: [String: AppUser] = [:]
        return { stored in
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let member = ownerOf(trimmed) {
                return ExportedOwner(user: primaryById[key(member.id)] ?? member, unresolved: false)
            }
            guard includeUnresolved, rosterOwnerOf(trimmed) == nil else { return nil }
            if let stand = unknown[key(trimmed)] { return ExportedOwner(user: stand, unresolved: true) }
            let stand = unresolvedPerson(storedUserId: trimmed, organizationId: organizationId)
            unknown[key(trimmed)] = stand
            return ExportedOwner(user: stand, unresolved: true)
        }
    }

    /// One pay run of one person on the Exported list, before decoding (review of #259, S4 / N5).
    struct ExportedPlanItem {
        /// The shown version as a timesheet row (`versionRow`, with `__documentId` and `__subjectId`).
        let row: [String: Any]
        let documentId: String?
        /// The id the sheet is filed under (its stored `userId`, else the id its document id names).
        let subjectId: String
        /// The version chain the row came from ([] for a row that is not a timesheet version).
        let chain: [TimesheetVersionInfo]
        /// The shown version is the last one read in its chain.
        let shownIsLastRead: Bool
        let earlier: [TimesheetVersionInfo]
    }

    /// Review of #259: the rows of one person's cloud documents — per pay run its latest EXPORTED version (RULEBOOK
    /// 1.55.0, `timesheetVersionsForPeriod`), plus exported rows that are not versions. Rows filed under `ownId` come
    /// last (N5), so a screen keying one row per pay run keeps the sheet filed under the person's own id.
    static func exportedPlan(rows: [[String: Any]], ownId: String) -> [ExportedPlanItem] {
        let chains = CanonicalBusinessEngine.timesheetVersionsForPeriod(rows.compactMap { row in
            (row["__documentId"] as? String).map { id in (documentId: id, data: row.filter { !$0.key.hasPrefix("__") }) }
        }) ?? []
        var items: [ExportedPlanItem] = []
        var chained = Set<String>()
        for chain in chains {
            for version in chain { chained.insert(version.documentId) }
            guard let shownIndex = chain.lastIndex(where: { $0.exported }) else { continue }
            let shown = chain[shownIndex]
            var row = FirebaseBackend.versionRow(shown, chain: chain)
            let subject = documentOwnerId(documentId: shown.documentId, data: shown.data)
            row["__subjectId"] = subject
            items.append(ExportedPlanItem(
                row: row,
                documentId: shown.documentId,
                subjectId: subject,
                chain: chain,
                shownIsLastRead: shownIndex == chain.count - 1,
                earlier: CanonicalBusinessEngine.timesheetEarlierVersions(Array(chain[...shownIndex]))
            ))
        }
        for row in rows {
            let documentId = row["__documentId"] as? String
            if let documentId, chained.contains(documentId) { continue }
            let subject = (row["__subjectId"] as? String)
                ?? documentOwnerId(documentId: documentId ?? "", data: row.filter { !$0.key.hasPrefix("__") })
            items.append(ExportedPlanItem(row: row, documentId: documentId, subjectId: subject, chain: [], shownIsLastRead: true, earlier: []))
        }
        let own = key(ownId)
        return items.enumerated().sorted { lhs, rhs in
            let l = key(lhs.element.subjectId) == own ? 1 : 0
            let r = key(rhs.element.subjectId) == own ? 1 : 0
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Review of #259 (S4): whether an exported-only read may refresh this device's copy of the pay run — only when
    /// the copy held is not a later version (an open revision on top of the shown one is never overwritten).
    static func mayReplaceLocalCopy(heldVersionDocumentId: String?, shownDocumentId: String?) -> Bool {
        let held = CanonicalBusinessEngine.parseTimesheetRevisionDocId(heldVersionDocumentId)?.revision ?? 0
        let shown = CanonicalBusinessEngine.parseTimesheetRevisionDocId(shownDocumentId)?.revision ?? 0
        return held <= shown
    }
}

