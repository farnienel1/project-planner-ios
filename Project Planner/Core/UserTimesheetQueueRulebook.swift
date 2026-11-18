//
//  UserTimesheetQueueRulebook.swift
//  Project Planner
//
//  RULEBOOK 1.66.0 §8 (owner decision 17 Nov): User Timesheets → Awaiting sign-off and Signed off and the Timesheets
//  landing counts show every stored timesheet, however old, and agree exactly with web. Who is listed, one row per person per
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

    /// Web User Timesheets' load error, word for word.
    static let loadFailedMessage = "Timesheets did not finish loading. Check the connection and try again."

    /// True once the packed script exports `userTimesheetQueue`.
    static var isAvailable: Bool {
        CanonicalBusinessEngine.exportKind(functionName) == "function"
    }

    /// Every id `user` goes by — the rulebook's `personIdSet` over the whole roster (own id, former invite ids,
    /// same-email ids and every users document on their email), through `CanonicalBusinessEngine` as web
    /// `timesheetMemberIds`. Falls back to the stored ids when the script did not answer.
    static func ids(of user: AppUser, roster: [AppUser]) -> [String] {
        var seen = Set<String>()
        return RulebookPeople.ownerIds(for: user, users: roster)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// `ids` followed by the other letter-case spellings of each UUID-shaped id (web `timesheetQueueCaseVariants`): an
    /// iPhone stores `UUID.uuidString` upper case, web lower case, and Firestore `in` matches exactly. Other ids are kept
    /// as stored (a mixed-case id stored in another spelling is not found — a known limit, RULEBOOK §8).
    static func withCaseVariants(_ ids: [String]) -> [String] {
        var seen = Set(ids)
        var out = ids
        for id in ids where UUID(uuidString: id) != nil {
            for variant in [id.uppercased(), id.lowercased()] where seen.insert(variant).inserted {
                out.append(variant)
            }
        }
        return out
    }

    /// Every sheet cached on this device under any id of `users` (and its other letter-case spellings).
    @MainActor static func cachedSheets(for users: [AppUser], roster: [AppUser]) -> [StoredSheet] {
        var seen = Set<String>()
        var out: [StoredSheet] = []
        for userId in withCaseVariants(users.flatMap { ids(of: $0, roster: roster) }) where seen.insert(userId).inserted {
            for start in TimesheetDraftStore.discoverStoredWeekStarts(userId: userId) {
                out.append(StoredSheet(userId: userId, weekStart: start))
            }
        }
        return out
    }

    /// The roster member a stored `userId` belongs to (exact id, else an id they go by — web `timesheetOwnerResolver`).
    /// Built once per input: `personIdSet` runs once per candidate, never once per sheet.
    @MainActor static func ownerLookup(candidates: [AppUser], roster: [AppUser]) -> (String) -> AppUser? {
        var exact: [String: AppUser] = [:]
        var alias: [String: AppUser] = [:]
        for user in candidates where exact[user.id.lowercased()] == nil { exact[user.id.lowercased()] = user }
        for user in candidates {
            for id in ids(of: user, roster: roster) {
                let key = id.lowercased()
                if exact[key] == nil && alias[key] == nil { alias[key] = user }
            }
        }
        return { userId in
            let key = userId.lowercased()
            return exact[key] ?? alias[key]
        }
    }

    /// The input of `userTimesheetQueue`, or nil when a day key cannot be worked out.
    @MainActor static func payload(
        viewer: AppUser,
        roster: [AppUser],
        sheets: [StoredSheet],
        settings: OrganizationInvoicingSettings,
        subjects: [AppUser]? = nil
    ) -> [String: Any] {
        let owner = ownerLookup(candidates: subjects ?? roster, roster: roster)
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
            // RULEBOOK 1.66.0 §8: no `hasActivity` flag — the rule works it out with `timesheetSheetHasActivity` from the
            // status fields and these (entries, late extras and the signed snapshot are passed as placeholders: the rule
            // only asks whether they are there), the same rule web's `timesheetDraftHasActivity` calls.
            var data = TimesheetDraftStore.statusPayload(for: draft)
            data["managerNote"] = draft.managerNote
            data["expenseEntries"] = draft.expenseEntries.map { _ in [String: Any]() }
            data["priceWorkEntries"] = draft.priceWorkEntries.map { _ in [String: Any]() }
            data["lateExtras"] = (draft.lateExtras ?? []).map { _ in [String: Any]() }
            data["weeklyReportOverride"] = draft.weeklyReportOverride == nil ? NSNull() : ([String: Any]() as Any)
            var row: [String: Any] = [
                "userId": sheet.userId,
                "startDayKey": startKey,
                "endDayKey": endKey,
                "data": data,
                "documentId": documentId,
            ]
            // RULEBOOK 1.47.0 / 1.54.0 / 1.66.0: the sheet's booking change folded with its late extras, only for a signed,
            // unexported sheet, over the last six pay runs (the window web's hub and list use); an older run, or one whose
            // bookings are not loaded, reads as not changed and its waiting late extras still decide
            // (`SignedTimesheetChangeContext.queueChange`). Late extras are decided by that Swift summary of the real rows;
            // the placeholder rows in `data` below only feed `timesheetSheetHasActivity` (known limit: if the context is
            // not attached, the rule reads no waiting late extra from them).
            if !TimesheetApprovalPolicy.isExported(draft),
               let user = owner(sheet.userId),
               let change = SignedTimesheetChangeContext.shared.queueChange(draft: draft, user: user, period: period, settings: settings) {
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
        let sheets = cachedSheets(for: subjects, roster: roster)
        let input = payload(viewer: viewer, roster: roster, sheets: sheets, settings: settings, subjects: subjects)
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

    /// Fetches every stored sheet of `users` (under every id they go by, and the other letter-case spellings of UUID-shaped
    /// ids) into this device's cache — one `userId in` query per 10 ids
    /// (`FirebaseBackend.listTimesheetStates(organizationId:userIds:)`). Every list load reads every stored sheet of
    /// these people (cost grows with history; not yet timed with large organisations).
    static func refreshFromCloud(
        users: [AppUser],
        roster: [AppUser],
        firebaseBackend: FirebaseBackend,
        organizationId: String,
        /// Admins only (web `loadTimesheetQueueSheets` `recentRunStartDayKeys`): the last six pay runs are also read by
        /// `weekStartKey`, so a sheet stored under another spelling of an id, or with no `userId`, stays listed.
        recentRunSettings: OrganizationInvoicingSettings? = nil
    ) async throws {
        // `personIdSet` runs in the packed script, on the main actor like every other rule this file calls.
        let userIds = await MainActor.run { withCaseVariants(users.flatMap { ids(of: $0, roster: roster) }) }
        // A failed load throws (the caller shows it); only per-id permission refusals are skipped inside the query.
        let grouped = try await firebaseBackend.listTimesheetStates(organizationId: organizationId, userIds: userIds)
        var recent: [String: [[String: Any]]] = [:]
        if let recentRunSettings {
            let startDayKeys = await MainActor.run {
                recentPayRuns(settings: recentRunSettings).compactMap { CanonicalBusinessEngine.dayKeyInOrganizationZone($0.start) }
            }
            recent = try await firebaseBackend.listRecentRunTimesheetStates(
                organizationId: organizationId, userIds: userIds, startDayKeys: startDayKeys
            )
        }
        // One copy per stored document (web dedupes by document id); the `userId in` copy first.
        var documentSeen = Set<String>()
        for (userId, rows) in Array(grouped) + Array(recent) {
            for row in rows {
                if let documentId = row["__documentId"] as? String, !documentId.isEmpty {
                    guard documentSeen.insert(documentId).inserted else { continue }
                }
                _ = TimesheetDraftStore.ingestCloudRow(row, userId: userId, organizationId: organizationId)
            }
        }
    }

    /// The current pay run and the five before it (web `recentPayRuns`, `RECENT_PAY_RUN_COUNT` 6): the booking-change
    /// window and the admin `weekStartKey` pass.
    static func recentPayRuns(settings: OrganizationInvoicingSettings) -> [WeekRange] {
        [TimesheetPayrollPolicy.payPeriodContaining(settings: settings)]
            + TimesheetPayrollPolicy.previousPayPeriods(count: SignedTimesheetChangeContext.hubScanRuns - 1, settings: settings)
    }
}
