//
//  UserTimesheetQueueRulebook.swift
//  Project Planner
//
//  RULEBOOK 1.62.0 §8 (owner decision 17 Nov): User Timesheets → Awaiting sign-off and the Timesheets landing counts
//  show every stored timesheet waiting, however old, and agree exactly with web. Who is listed, one row per person per
//  pay run, PAYE runs left out, the latest revision and the bucket are the rulebook's `userTimesheetQueue` (web
//  `lib/canonical/userTimesheetQueue.ts`), called through `CanonicalBusinessEngine`; this file only shapes the roster and
//  the sheets this device holds into its input and reads its rows back.
//

import Foundation

enum UserTimesheetQueueRulebook {
    static let functionName = "userTimesheetQueue"

    /// One row of the queue: a person (the roster member the row opens) and one pay run.
    struct Row: Equatable {
        let key: String
        let personId: String
        /// The `userId` the sheet is stored (and cached on this device) under — the person's own id or one they go by.
        let sheetUserId: String
        let startDayKey: String
        let endDayKey: String
        /// `unsigned`, `awaiting`, `signed` or `exported` (`timesheetListBucket`).
        let bucket: String
        /// The cached sheet's week start (the key `TimesheetDraftStore` holds it under).
        let weekStart: Date
    }

    /// A sheet this device holds: the id it is cached under and its stored start.
    struct StoredSheet {
        let userId: String
        let weekStart: Date
    }

    /// True once the packed script exports `userTimesheetQueue`.
    static var isAvailable: Bool {
        CanonicalBusinessEngine.exportKind(functionName) == "function"
    }

    /// Every id `user` goes by: their id, former invite ids and same-email ids (the rulebook folds more from the roster).
    static func ids(of user: AppUser) -> [String] {
        var seen = Set<String>()
        return ([user.id] + user.formerUserIds + user.sameEmailUserIds).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Every sheet cached on this device under any id of `users`.
    @MainActor static func cachedSheets(for users: [AppUser]) -> [StoredSheet] {
        var seen = Set<String>()
        var out: [StoredSheet] = []
        for userId in users.flatMap(ids(of:)) where seen.insert(userId).inserted {
            for start in TimesheetDraftStore.discoverStoredWeekStarts(userId: userId) {
                out.append(StoredSheet(userId: userId, weekStart: start))
            }
        }
        return out
    }

    /// The roster member a stored `userId` belongs to (exact id, else an id they go by).
    @MainActor static func owner(of userId: String, roster: [AppUser]) -> AppUser? {
        let key = userId.lowercased()
        return roster.first { $0.id.lowercased() == key }
            ?? roster.first { ids(of: $0).contains { $0.lowercased() == key } }
    }

    /// The input of `userTimesheetQueue`, or nil when a day key cannot be worked out.
    @MainActor static func payload(
        viewer: AppUser,
        roster: [AppUser],
        sheets: [StoredSheet],
        settings: OrganizationInvoicingSettings
    ) -> [String: Any] {
        var input = UserTimesheetAccessRulebook.payload(viewer: viewer, members: roster)
        let byId = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let baseMembers = (input["members"] as? [[String: Any]]) ?? []
        input["members"] = baseMembers.map { member -> [String: Any] in
            guard let id = member["id"] as? String, let user = byId[id] else { return member }
            var row = member
            for (key, value) in CanonicalBusinessEngine.timesheetPerson(user) where key != "isActive" {
                row[key] = value
            }
            row["formerUserIds"] = user.formerUserIds
            row["sameEmailUserIds"] = user.sameEmailUserIds
            row["timesheetSelfSigned"] = !TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user)
            return row
        }
        input["sheets"] = sheets.map { sheet -> [String: Any] in
            let draft = TimesheetDraftStore.load(userId: sheet.userId, weekStart: sheet.weekStart)
            let storedEnd = TimesheetDraftStore.storedPeriodEnd(userId: sheet.userId, weekStart: sheet.weekStart)
            let period = TimesheetPayrollPolicy.periodMatchingStoredStart(sheet.weekStart, storedEnd: storedEnd, settings: settings)
            let startKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(sheet.weekStart) ?? ""
            let endKey = CanonicalBusinessEngine.dayKeyInOrganizationZone(period.end) ?? ""
            var documentId = draft.versionDocumentId ?? ""
            if documentId.isEmpty {
                documentId = CanonicalBusinessEngine.timesheetDocumentId(userId: sheet.userId, startDayKey: startKey) ?? ""
            }
            let hasActivity = draft.operativeSignedAt != nil
                || draft.managerSignedAt != nil
                || draft.exportedAt != nil
                || !draft.expenseEntries.isEmpty
                || !draft.priceWorkEntries.isEmpty
                || !draft.managerNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            var row: [String: Any] = [
                "userId": sheet.userId,
                "startDayKey": startKey,
                "endDayKey": endKey,
                "data": TimesheetDraftStore.statusPayload(for: draft),
                "documentId": documentId,
                "hasActivity": hasActivity,
            ]
            // RULEBOOK 1.47.0: the sheet's booking change, only for a signed, unexported sheet; a run whose bookings are
            // not loaded reads as not changed (`SignedTimesheetChangeContext` answers without the bookings then).
            if !TimesheetApprovalPolicy.isExported(draft),
               let user = owner(of: sheet.userId, roster: roster),
               let change = SignedTimesheetChangeContext.shared.change(draft: draft, user: user, period: period) {
                row["bookingsChange"] = [
                    "reopened": change.reopened,
                    "waitingFor": change.waitingFor ?? NSNull(),
                ] as [String: Any]
            }
            return row
        }
        input["timeZone"] = OrganizationRulebookContext.timeZoneIdentifier
        return input
    }

    /// `userTimesheetQueue` over the sheets this device holds. Nil when the script did not answer.
    @MainActor static func rows(
        viewer: AppUser,
        roster: [AppUser],
        subjects: [AppUser],
        settings: OrganizationInvoicingSettings
    ) -> [Row]? {
        guard isAvailable else { return nil }
        let sheets = cachedSheets(for: subjects)
        let input = payload(viewer: viewer, roster: roster, sheets: sheets, settings: settings)
        guard let raw = CanonicalBusinessEngine.objectRows(function: functionName, payload: input) else { return nil }
        return raw.compactMap { row -> Row? in
            guard let personId = row["personId"] as? String,
                  let index = (row["sheetIndex"] as? NSNumber)?.intValue,
                  sheets.indices.contains(index) else { return nil }
            return Row(
                key: (row["key"] as? String) ?? "",
                personId: personId,
                sheetUserId: sheets[index].userId,
                startDayKey: (row["startDayKey"] as? String) ?? "",
                endDayKey: (row["endDayKey"] as? String) ?? "",
                bucket: (row["bucket"] as? String) ?? "",
                weekStart: sheets[index].weekStart
            )
        }
    }

    /// Fetches every stored sheet of `users` (under every id they go by) into this device's cache — one `userId in`
    /// query per 10 ids (`FirebaseBackend.listTimesheetStates(organizationId:userIds:)`).
    static func refreshFromCloud(users: [AppUser], firebaseBackend: FirebaseBackend, organizationId: String) async {
        let userIds = users.flatMap(ids(of:))
        guard let grouped = try? await firebaseBackend.listTimesheetStates(organizationId: organizationId, userIds: userIds) else { return }
        for (userId, rows) in grouped {
            for row in rows {
                _ = TimesheetDraftStore.ingestCloudRow(row, userId: userId, organizationId: organizationId)
            }
        }
    }
}
