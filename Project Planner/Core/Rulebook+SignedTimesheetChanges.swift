//
//  Rulebook+SignedTimesheetChanges.swift
//  Project Planner
//
//  RULEBOOK 1.47.0 §8 (owner decision 15 Nov, answer 4.2 = (a)): a signed timesheet reopens when its bookings change.
//  Typed wrappers for web `lib/canonical/timesheetBookingChanges.ts` (`signedTimesheetBookingChanges`,
//  `signedTimesheetBookingRecord`, `signedTimesheetActions`, the texts) and the plumbing that hands the script the
//  stored sheet, the collector's live lines and the stored booking documents. Swift compares nothing: no fingerprint,
//  booking id, status or hours test lives here (AGENTS.md Rule 0). Web glue: `lib/timesheets/timesheetBookingChanges.ts`.
//

import Foundation

/// One booking as the person signed it (`operativeSignedBookings[]`, 1.47.0 owner field).
nonisolated struct TimesheetSignedBookingRow: Codable, Hashable, Sendable {
    var bookingId: String
    /// `bookings` or `managerSiteBookings`.
    var collection: String
    /// `overtimeBookingFingerprint` of the booking when signed ('' when unknown).
    var fingerprint: String
    /// The booking's person id as stored when signed (labour `operativeId`, manager site `userId`); '' when unknown.
    var personId: String
    /// `signedTimesheetBookingPlace` of the booking when signed ('' when unknown).
    var place: String

    init(bookingId: String, collection: String, fingerprint: String, personId: String, place: String) {
        self.bookingId = bookingId
        self.collection = collection
        self.fingerprint = fingerprint
        self.personId = personId
        self.place = place
    }

    /// A stored row (Firestore map or script answer). Nil without a booking id.
    init?(stored value: Any?) {
        guard let row = value as? [String: Any] else { return nil }
        func text(_ key: String) -> String {
            if let string = row[key] as? String { return string }
            if let number = row[key] as? NSNumber { return number.stringValue }
            return ""
        }
        let bookingId = text("bookingId")
        guard !bookingId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(
            bookingId: bookingId,
            collection: text("collection"),
            fingerprint: text("fingerprint"),
            personId: text("personId"),
            place: text("place")
        )
    }

    /// The stored shape: every field a string (web writes exactly these five).
    var storedMap: [String: Any] {
        ["bookingId": bookingId, "collection": collection, "fingerprint": fingerprint, "personId": personId, "place": place]
    }
}

/// RULEBOOK 1.47.0 §8 `signedTimesheetBookingChanges(...)` → whether a signed sheet's bookings changed and who must act.
nonisolated struct RulebookSignedTimesheetChange: Equatable, Hashable, Sendable {
    let changed: Bool
    let exported: Bool
    let reopened: Bool
    /// `person` | `lineManager`; nil when not reopened.
    let waitingFor: String?
    /// `fingerprint` | `bookingIds` | `none`.
    let basis: String
    let changedBookingIds: [String]
    let addedBookingIds: [String]
    let removedBookingIds: [String]
    /// `SIGNED_TIMESHEET_CHANGED_MESSAGE` when the person must sign again, else nil.
    let message: String?
    /// The reviewer's note (counter-sign blocked, counter-sign again, or the exported warning), else nil.
    let reviewerMessage: String?
    /// RULEBOOK 1.54.0 §8 `timesheetChangesWithLateExtras`: late extras wait for the line manager.
    let lateExtrasWaiting: Bool
    /// RULEBOOK 1.54.0: the bookings themselves changed (1.47.0). False when only late extras wait — nothing is signed
    /// again or re-priced, and the signed snapshot's figures stand.
    let bookingsChanged: Bool
    /// RULEBOOK 1.57.0 §8: bookings the person signed (current record) that are still live but missing from the signed
    /// snapshot — the line manager never counter-signed them. Kept apart from `addedBookingIds`.
    let snapshotGapBookingIds: [String]
    /// RULEBOOK 1.57.0 §8: the only change is that snapshot gap. Reports keep the signed figures for it (J1,
    /// `signedTimesheetChangeForReports`); the sheet itself is still flagged (counter-sign again / revision due).
    let snapshotGapOnly: Bool
    /// RULEBOOK 1.76.0 (owner answer 23 Nov, b): signed price work or expenses changed after sign-off (Make changes); the
    /// line manager signs it off again — nobody else signs, and it is not a late extra.
    let signedEntriesChanged: Bool

    init?(json: Any?) {
        guard let row = json as? [String: Any], let changed = row["changed"] as? Bool else { return nil }
        self.changed = changed
        self.exported = row["exported"] as? Bool ?? false
        self.reopened = row["reopened"] as? Bool ?? false
        self.waitingFor = row["waitingFor"] as? String
        self.basis = row["basis"] as? String ?? "none"
        self.changedBookingIds = row["changedBookingIds"] as? [String] ?? []
        self.addedBookingIds = row["addedBookingIds"] as? [String] ?? []
        self.removedBookingIds = row["removedBookingIds"] as? [String] ?? []
        self.message = row["message"] as? String
        self.reviewerMessage = row["reviewerMessage"] as? String
        self.lateExtrasWaiting = row["lateExtrasWaiting"] as? Bool ?? false
        self.bookingsChanged = row["bookingsChanged"] as? Bool ?? changed
        self.snapshotGapBookingIds = row["snapshotGapBookingIds"] as? [String] ?? []
        self.snapshotGapOnly = row["snapshotGapOnly"] as? Bool ?? false
        self.signedEntriesChanged = row["signedEntriesChanged"] as? Bool ?? false
    }

    /// The whole answer as script JSON (every field the rulebook returns), for rules that take a change back
    /// (`signedTimesheetChangeForReports`).
    var scriptJSON: [String: Any] {
        [
            "changed": changed,
            "exported": exported,
            "reopened": reopened,
            "waitingFor": RulebookJSON.orNull(waitingFor),
            "basis": basis,
            "changedBookingIds": changedBookingIds,
            "addedBookingIds": addedBookingIds,
            "removedBookingIds": removedBookingIds,
            "message": RulebookJSON.orNull(message),
            "reviewerMessage": RulebookJSON.orNull(reviewerMessage),
            "lateExtrasWaiting": lateExtrasWaiting,
            "bookingsChanged": bookingsChanged,
            "snapshotGapBookingIds": snapshotGapBookingIds,
            "snapshotGapOnly": snapshotGapOnly,
            "signedEntriesChanged": signedEntriesChanged,
        ]
    }

    /// RULEBOOK 1.57.0: the `change` a report rule takes (`weeklyReportPayRows` sheets, `payrunSnapshotRows`
    /// `bookingsChange`) — the fields web `loadTimesheetFeed` / `payrunSnapshotData` pass. The rule applies
    /// `signedTimesheetChangeForReports` itself.
    var reportArgument: [String: Any] {
        [
            "reopened": reopened,
            "changed": changed,
            "exported": exported,
            "waitingFor": RulebookJSON.orNull(waitingFor),
            "snapshotGapOnly": snapshotGapOnly,
            "lateExtrasWaiting": lateExtrasWaiting,
            // RULEBOOK 1.77.0 (point 6): the report says "Awaiting re-sign — showing last signed figures" when only
            // late extras or signed price work / expenses wait (`timesheetReportKeepsSignedFigures`).
            "bookingsChanged": bookingsChanged,
        ]
    }

    /// RULEBOOK 1.54.0: only late extras wait (no booking change) — the reviewer decides them; nobody signs again.
    /// 1.76.0: not when signed price work or expenses changed after sign-off (`signedEntriesOnly`).
    var lateExtrasOnly: Bool { reopened && lateExtrasWaiting && !bookingsChanged && !signedEntriesChanged }
    /// RULEBOOK 1.76.0: only signed price work or expenses changed after sign-off (no booking change) — the line manager
    /// signs it off again; the signed labour stands.
    var signedEntriesOnly: Bool { reopened && signedEntriesChanged && !bookingsChanged }

    /// The person must review and sign again (the yellow triangle and popup on My Timesheets).
    var waitingForPerson: Bool { reopened && waitingFor == "person" }
    /// The person has signed the changed bookings; the line manager counter-signs again.
    var waitingForLineManager: Bool { reopened && waitingFor == "lineManager" }

    /// The `change` argument of `timesheetListBucket` / `signedTimesheetActions` (`{ reopened, waitingFor }`).
    var bucketArgument: [String: Any] {
        ["reopened": reopened, "waitingFor": RulebookJSON.orNull(waitingFor)]
    }
}

/// RULEBOOK 1.47.0 §8 `signedTimesheetActions(change)`.
nonisolated struct RulebookSignedTimesheetActions: Equatable, Hashable, Sendable {
    let personMaySignAgain: Bool
    let lineManagerMayCounterSign: Bool
    let mayExport: Bool
    let mayGenerateInvoice: Bool
    let rebuildSnapshot: Bool

    init(personMaySignAgain: Bool, lineManagerMayCounterSign: Bool, mayExport: Bool, mayGenerateInvoice: Bool, rebuildSnapshot: Bool) {
        self.personMaySignAgain = personMaySignAgain
        self.lineManagerMayCounterSign = lineManagerMayCounterSign
        self.mayExport = mayExport
        self.mayGenerateInvoice = mayGenerateInvoice
        self.rebuildSnapshot = rebuildSnapshot
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any],
              let mayExport = row["mayExport"] as? Bool else { return nil }
        self.init(
            personMaySignAgain: row["personMaySignAgain"] as? Bool ?? false,
            lineManagerMayCounterSign: row["lineManagerMayCounterSign"] as? Bool ?? false,
            mayExport: mayExport,
            mayGenerateInvoice: row["mayGenerateInvoice"] as? Bool ?? false,
            rebuildSnapshot: row["rebuildSnapshot"] as? Bool ?? false
        )
    }

    /// When the script did not answer for a reopened sheet: nothing is exported, invoiced or counter-signed (fail closed).
    static let closed = RulebookSignedTimesheetActions(
        personMaySignAgain: false, lineManagerMayCounterSign: false, mayExport: false, mayGenerateInvoice: false, rebuildSnapshot: false
    )
}

extension CanonicalBusinessEngine {
    // MARK: Texts (read from the script, never retyped as the rule)

    private nonisolated static func signedTimesheetText(_ name: String, fallback: String) -> String {
        constant(name, as: String.self) ?? fallback
    }

    /// `SIGNED_TIMESHEET_CHANGED_MESSAGE` — the owner's popup.
    nonisolated static var signedTimesheetChangedMessage: String {
        signedTimesheetText(
            "SIGNED_TIMESHEET_CHANGED_MESSAGE",
            fallback: "One or more bookings have changed since you signed your timesheet. Please review and sign again, or speak to your line manager if something isn't correct."
        )
    }

    /// `SIGNED_TIMESHEET_CHANGED_LABEL` — the triangle's accessibility label.
    nonisolated static var signedTimesheetChangedLabel: String {
        signedTimesheetText("SIGNED_TIMESHEET_CHANGED_LABEL", fallback: "Bookings changed since you signed")
    }

    /// `SIGNED_TIMESHEET_CHANGED_STATUS` — the row's status chip.
    nonisolated static var signedTimesheetChangedStatus: String {
        signedTimesheetText("SIGNED_TIMESHEET_CHANGED_STATUS", fallback: "Bookings changed — sign again")
    }

    /// `SIGNED_TIMESHEET_EXPORT_SKIPPED_MESSAGE` — why Export left a sheet out.
    nonisolated static var signedTimesheetExportSkippedMessage: String {
        signedTimesheetText(
            "SIGNED_TIMESHEET_EXPORT_SKIPPED_MESSAGE",
            fallback: "Not exported — bookings changed since it was signed; it is back with the person to sign again."
        )
    }

    // MARK: Rules

    /// RULEBOOK 1.47.0 §8 `signedTimesheetBookingChanges({ sheet, liveLines, liveBookings, tombstonedBookingIds,
    /// personIds, liveLoaded, selfSigned })`. Inputs are plain JSON (`SignedTimesheetChangeInputs`). Nil when the script
    /// did not answer.
    nonisolated static func signedTimesheetBookingChanges(
        sheet: [String: Any],
        liveLines: [[String: Any]],
        liveBookings: [[String: Any]]?,
        tombstonedBookingIds: [[String: Any]]? = nil,
        personIds: [String]?,
        liveLoaded: Bool,
        selfSigned: Bool,
        lateExtras: RulebookLateExtrasSummary? = nil
    ) -> RulebookSignedTimesheetChange? {
        var input: [String: Any] = [
            "sheet": sheet,
            "liveLines": liveLines,
            "liveLoaded": liveLoaded,
            "selfSigned": selfSigned,
        ]
        input["liveBookings"] = liveBookings.map { $0 as Any } ?? NSNull()
        input["tombstonedBookingIds"] = tombstonedBookingIds.map { $0 as Any } ?? NSNull()
        input["personIds"] = personIds.map { $0 as Any } ?? NSNull()
        let raw = callJSON("signedTimesheetBookingChanges", arguments: [input])
        // RULEBOOK 1.54.0 §8 `timesheetChangesWithLateExtras(bookingChange, late)`: one answer for the bookings and the
        // late extras (lists, counts, the export guard, the Payrun Snapshot). A sheet without late extras is unchanged.
        if let lateExtras, raw != nil {
            return timesheetChangesWithLateExtras(bookingChange: raw, late: lateExtras)
        }
        return RulebookSignedTimesheetChange(json: raw)
    }

    /// RULEBOOK 1.57.0 §8 `signedTimesheetChangeForReports(change)` (J1, `SNAPSHOT_GAP_REPORTS`): the change a report
    /// uses (the weekly report feed's "is this signed sheet still approved?", `timesheetRevisionReportState`). A change
    /// that is only a snapshot gap counts as none (the signed figures stand) — or, with late extras waiting, as a
    /// late-extras-only change. Nil for nil, for "no change for reports", and when the script did not answer (then the
    /// change is kept as given: a report never reads a changed sheet as approved because the script was silent).
    nonisolated static func signedTimesheetChangeForReports(_ change: RulebookSignedTimesheetChange?) -> RulebookSignedTimesheetChange? {
        guard let change else { return nil }
        guard let raw = callJSON("signedTimesheetChangeForReports", arguments: [change.scriptJSON]) else { return change }
        if raw is NSNull { return nil }
        return RulebookSignedTimesheetChange(json: raw) ?? change
    }

    /// RULEBOOK 1.47.0 §8 `signedTimesheetBookingRecord(liveLines, liveBookings)`: what the person signs, stored as
    /// `operativeSignedBookings`. Nil when the script did not answer (then nothing is signed).
    nonisolated static func signedTimesheetBookingRecord(
        liveLines: [[String: Any]],
        liveBookings: [[String: Any]]
    ) -> [TimesheetSignedBookingRow]? {
        guard let rows = callJSON("signedTimesheetBookingRecord", arguments: [liveLines, liveBookings]) as? [Any] else { return nil }
        return rows.compactMap { TimesheetSignedBookingRow(stored: $0) }
    }

    /// RULEBOOK 1.47.0 §8 `signedTimesheetBookingPlace(doc)`: where a booking is ('' when unknown).
    nonisolated static func signedTimesheetBookingPlace(_ document: [String: Any]) -> String {
        callJSON("signedTimesheetBookingPlace", arguments: [document]) as? String ?? ""
    }

    /// RULEBOOK 1.47.0 §8 `signedTimesheetActions(change)`. A sheet that is not reopened is open for every action; when
    /// the script did not answer for a reopened sheet nothing is exported, invoiced or counter-signed.
    nonisolated static func signedTimesheetActions(_ change: RulebookSignedTimesheetChange?) -> RulebookSignedTimesheetActions {
        let argument: Any = change.map { $0.bucketArgument as Any } ?? NSNull()
        if let actions = RulebookSignedTimesheetActions(json: callJSON("signedTimesheetActions", arguments: [argument])) {
            return actions
        }
        if change?.reopened == true { return .closed }
        return RulebookSignedTimesheetActions(
            personMaySignAgain: false, lineManagerMayCounterSign: true, mayExport: true, mayGenerateInvoice: true, rebuildSnapshot: false
        )
    }

    /// RULEBOOK 1.47.0 §8 `timesheetListBucket(fields, hasLineManager, change)`: reopened + person → `unsigned`, reopened
    /// + line manager → `awaiting`, exported stays `exported`. Nil when the script did not answer.
    nonisolated static func timesheetListBucket(
        _ fields: CanonicalTimesheetStatusFields,
        hasLineManager: Bool,
        change: RulebookSignedTimesheetChange?
    ) -> String? {
        guard let change else { return timesheetListBucket(fields, hasLineManager: hasLineManager) }
        guard let fieldsJSON = RulebookJSON.object(fields) else { return nil }
        return callJSON("timesheetListBucket", arguments: [fieldsJSON, hasLineManager, change.bucketArgument]) as? String
    }
}

/// RULEBOOK 1.47.0 §8: the script's inputs built from iOS models. A mapping only — nothing here compares bookings.
@MainActor
enum SignedTimesheetChangeInputs {
    private static func ms(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return date.timeIntervalSince1970 * 1000
    }

    /// Stored document ids by in-app id, so every booking id the script sees is spelled as Firestore stores it (the
    /// record iOS writes reads the same on web).
    static func documentKeys(bookings: [Booking], managerBookings: [ManagerSiteBooking]) -> [UUID: String] {
        var keys: [UUID: String] = [:]
        for booking in bookings { keys[booking.id] = booking.documentKey }
        for booking in managerBookings { keys[booking.id] = booking.documentKey }
        return keys
    }

    /// A line's booking id as stored: `op-<uuid>` / `mgr-<uuid>` / a bare id → the stored document id (unchanged when
    /// it is not an in-app id).
    static func storedBookingId(_ raw: String?, keys: [UUID: String]) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("op-") { text = String(text.dropFirst(3)) } else if text.hasPrefix("mgr-") { text = String(text.dropFirst(4)) }
        if let uuid = UUID(uuidString: text) { return keys[uuid] ?? WorkDocumentKeys.storedId(for: uuid) }
        return text
    }

    private static func collection(forLineId id: String, fallback: String?) -> String {
        if let fallback, !fallback.isEmpty { return fallback }
        return id.hasPrefix("mgr-") ? "managerSiteBookings" : "bookings"
    }

    /// The stored sheet fields the rule reads (`SignedTimesheetSheet`), instants as epoch ms.
    static func sheet(_ draft: TimesheetDraft, keys: [UUID: String]) -> [String: Any] {
        var sheet: [String: Any] = [
            "operativeSignedAt": ms(draft.operativeSignedAt),
            "operativeSignedBookingsAt": ms(draft.operativeSignedBookingsAt),
            "operativeSignedBookingsSignedAt": ms(draft.operativeSignedBookingsSignedAt),
            "managerSignedAt": ms(draft.managerSignedAt),
            "approvedAt": ms(draft.approvedAt),
            "exportedAt": ms(draft.exportedAt),
            "invoiceGeneratedAt": ms(draft.invoiceGeneratedAt),
        ]
        sheet["operativeSignedBookings"] = draft.operativeSignedBookings.map { rows in rows.map(\.storedMap) as Any } ?? NSNull()
        // RULEBOOK 1.74.0 §8: the reviewer's own booking edits from this sheet's review (as stored, instants as ms).
        sheet["reviewerBookingEdits"] = TimesheetReviewerBookingEdits.stored(draft)
        if let override = draft.weeklyReportOverride {
            let lines: [[String: Any]] = override.lines.map { line in
                var row: [String: Any] = [
                    "id": line.id,
                    "bookingCollection": collection(forLineId: line.id, fallback: nil),
                ]
                row["bookingId"] = storedBookingId(line.bookingId, keys: keys) ?? NSNull()
                row["bookingFingerprint"] = line.bookingFingerprint ?? NSNull()
                row["isPayeDay"] = line.isPayeDay ?? false
                row["isLeave"] = line.isLeave ?? false
                row["reviewPartOf"] = line.reviewPartOf ?? NSNull()
                return row
            }
            sheet["weeklyReportOverride"] = ["approvedAt": ms(override.approvedAt), "lines": lines] as [String: Any]
        } else {
            sheet["weeklyReportOverride"] = NSNull()
        }
        return sheet
    }

    /// The collector's lines in the rule's line shape (`SignedTimesheetLine`).
    static func liveLines(_ lines: [TimesheetPayrollLineItem], keys: [UUID: String]) -> [[String: Any]] {
        lines.map { line in
            var row: [String: Any] = [
                "id": line.id,
                "bookingCollection": collection(forLineId: line.id, fallback: line.bookingCollection),
                "isPayeDay": line.isPayeDay,
                "bookingCreatedAt": ms(line.bookingCreatedAt),
                "bookingUpdatedAt": ms(line.bookingUpdatedAt),
            ]
            row["bookingId"] = storedBookingId(line.bookingId, keys: keys) ?? NSNull()
            row["bookingFingerprint"] = line.bookingFingerprint ?? NSNull()
            return row
        }
    }

    /// The stored booking documents (labour and manager site, anyone's) in the rule's document shape. `range` limits them
    /// to the bookings of the pay run (a day either side); `alsoIds` keeps any booking the sheet signed wherever it is now.
    static func bookingDocuments(
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        range: ClosedRange<Date>? = nil,
        alsoIds: Set<String> = []
    ) -> [[String: Any]] {
        let cal = OrganizationRulebookContext.calendar
        let lower = range.flatMap { cal.date(byAdding: .day, value: -1, to: $0.lowerBound) }
        let upper = range.flatMap { cal.date(byAdding: .day, value: 2, to: $0.upperBound) }
        func keep(_ date: Date, _ id: String) -> Bool {
            if alsoIds.contains(id.lowercased()) { return true }
            guard let lower, let upper else { return true }
            return date >= lower && date < upper
        }
        var rows: [[String: Any]] = []
        for booking in bookings where keep(booking.date, booking.documentKey) {
            var row: [String: Any] = [
                "bookingId": booking.documentKey,
                "collection": "bookings",
                "dayKey": OrganizationRulebookContext.dayKey(booking.date),
                "timeSlot": booking.timeSlot.rawValue,
                "isBreakRemoved": booking.isBreakRemoved,
                "status": booking.status.rawValue,
                "personId": booking.operativeKey ?? Booking.operativeMatchKey(for: booking.operativeId),
                "projectId": booking.projectKey ?? WorkDocumentKeys.storedId(for: booking.projectId),
            ]
            row["workStartTime"] = booking.workStartTime ?? NSNull()
            row["workEndTime"] = booking.workEndTime ?? NSNull()
            row["otMultiplierOverride"] = booking.otMultiplierOverride ?? NSNull()
            rows.append(row)
        }
        for booking in managerBookings where keep(booking.date, booking.documentKey) {
            var row: [String: Any] = [
                "bookingId": booking.documentKey,
                "collection": "managerSiteBookings",
                "dayKey": OrganizationRulebookContext.dayKey(booking.date),
                "timeSlot": booking.timeSlot.rawValue,
                "isBreakRemoved": booking.isBreakRemoved,
                "personId": booking.userId,
                "locationType": booking.locationType.rawValue,
                "locationId": booking.storedLocationId ?? "",
                "customLocationName": booking.customLocationName ?? "",
            ]
            row["workStartTime"] = booking.workStartTime ?? NSNull()
            row["workEndTime"] = booking.workEndTime ?? NSNull()
            row["otMultiplierOverride"] = booking.otMultiplierOverride ?? NSNull()
            rows.append(row)
        }
        return rows
    }

    /// Every id the person's bookings may be stored under (`bookingIdsForAccount`: users id, former ids, same-email ids,
    /// `operatives` rows on their email), plus the users documents on their email the manager site bookings name.
    /// Nil when the script did not answer (then a booking is never read as given to someone else).
    static func personIds(user: AppUser, operatives: [Operative], users: [AppUser]) -> [String]? {
        let account = CanonicalBusinessEngine.CanonicalBookingPersonAccount(
            id: user.id, email: user.email, formerIds: user.formerUserIds, aliasIds: user.sameEmailUserIds
        )
        guard let ids = CanonicalBusinessEngine.bookingIdsForAccount(
            account,
            operatives: operatives.map { CanonicalBusinessEngine.CanonicalBookingPersonOperative(id: $0.documentId, email: $0.email) }
        ) else { return nil }
        let managerIds = StaffEmailIdentity.userIds(sharing: user.email, in: users + [user])
        var out: [String] = []
        for id in ids + Array(managerIds) where !out.contains(id) { out.append(id) }
        return out
    }

    /// The booking ids a sheet signed (record and snapshot), lower case, so their documents are always passed.
    static func signedIds(_ draft: TimesheetDraft, keys: [UUID: String]) -> Set<String> {
        var ids = Set<String>()
        for row in draft.operativeSignedBookings ?? [] { ids.insert(row.bookingId.lowercased()) }
        for line in draft.weeklyReportOverride?.lines ?? [] {
            if let id = storedBookingId(line.bookingId, keys: keys) { ids.insert(id.lowercased()) }
        }
        return ids
    }
}

/// RULEBOOK 1.47.0 §8: one person's sheet for one pay run against the live bookings (web `draftBookingChanges` /
/// `periodBookingChanges`). Every answer comes from the script.
@MainActor
enum SignedTimesheetChanges {
    struct Inputs {
        var bookings: [Booking]
        var managerBookings: [ManagerSiteBooking]
        var operatives: [Operative]
        var projects: [Project]
        var smallWorks: [Project]
        var organization: Organization?
        var users: [AppUser]
        /// The period's bookings have arrived from the server and the loaded window holds the whole pay run
        /// (`PayInputsLoad.periodBookings(...).loaded`).
        var liveLoaded: Bool
    }

    /// The collector's lines for the person and period. Pay rates do not decide what changed, so the history is empty.
    static func liveLines(user: AppUser, period: WeekRange, inputs: Inputs) -> [TimesheetPayrollLineItem] {
        TimesheetPayrollCollector.collect(
            for: user,
            week: period,
            bookings: inputs.bookings,
            managerBookings: inputs.managerBookings,
            operatives: inputs.operatives,
            projects: inputs.projects,
            smallWorks: inputs.smallWorks,
            history: .empty,
            policy: inputs.organization?.settings.payrollTimePolicy ?? .default,
            organization: inputs.organization,
            scheduleOptions: inputs.organization?.settings.myScheduleOptions ?? MyScheduleOptions(),
            relatedUsers: inputs.users
        ).lineItems
    }

    /// Whether anything was signed (a sheet nobody signed is never changed).
    static func isSigned(_ draft: TimesheetDraft) -> Bool {
        draft.operativeSignedAt != nil || draft.weeklyReportOverride != nil
    }

    /// `signedTimesheetBookingChanges` for one draft. `lines` are the collector's lines when the screen has them.
    static func change(
        draft: TimesheetDraft,
        user: AppUser,
        period: WeekRange,
        inputs: Inputs,
        lines: [TimesheetPayrollLineItem]? = nil
    ) -> RulebookSignedTimesheetChange? {
        guard isSigned(draft) else { return nil }
        let keys = SignedTimesheetChangeInputs.documentKeys(bookings: inputs.bookings, managerBookings: inputs.managerBookings)
        let live = lines ?? liveLines(user: user, period: period, inputs: inputs)
        let documents = SignedTimesheetChangeInputs.bookingDocuments(
            bookings: inputs.bookings,
            managerBookings: inputs.managerBookings,
            range: period.start...period.end,
            alsoIds: SignedTimesheetChangeInputs.signedIds(draft, keys: keys)
        )
        return CanonicalBusinessEngine.signedTimesheetBookingChanges(
            sheet: SignedTimesheetChangeInputs.sheet(draft, keys: keys),
            liveLines: SignedTimesheetChangeInputs.liveLines(live, keys: keys),
            liveBookings: documents,
            personIds: SignedTimesheetChangeInputs.personIds(user: user, operatives: inputs.operatives, users: inputs.users),
            liveLoaded: inputs.liveLoaded,
            selfSigned: !TimesheetApprovalPolicy.requiresLineManagerCounterSign(for: user),
            // RULEBOOK 1.54.0 §8: late extras waiting for the line manager (`timesheetLateExtrasSummary`).
            lateExtras: TimesheetLateExtrasSupport.summary(draft)
        )
    }

    /// `signedTimesheetBookingRecord` from the lines the screen shows, with the booking documents' person ids.
    static func record(
        lines: [TimesheetPayrollLineItem],
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking]
    ) -> [TimesheetSignedBookingRow]? {
        let keys = SignedTimesheetChangeInputs.documentKeys(bookings: bookings, managerBookings: managerBookings)
        return CanonicalBusinessEngine.signedTimesheetBookingRecord(
            liveLines: SignedTimesheetChangeInputs.liveLines(lines, keys: keys),
            liveBookings: SignedTimesheetChangeInputs.bookingDocuments(bookings: bookings, managerBookings: managerBookings)
        )
    }

    /// Writes what the person signs onto the draft with the operative signature (step 4 of the 1.47.0 hand-off):
    /// the record, the signature instant it belongs to, and a pending server time (`FieldValue.serverTimestamp()` on the
    /// next save). False when the record could not be built — the caller then does not sign.
    static func stampSignedBookings(
        on draft: inout TimesheetDraft,
        lines: [TimesheetPayrollLineItem],
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking]
    ) -> Bool {
        guard let signedAt = draft.operativeSignedAt,
              let record = record(lines: lines, bookings: bookings, managerBookings: managerBookings) else { return false }
        draft.operativeSignedBookings = record
        draft.operativeSignedBookingsSignedAt = signedAt
        draft.operativeSignedBookingsAt = nil
        draft.operativeSignedBookingsAtPending = true
        return true
    }
}

/// RULEBOOK 1.47.0 §8 (lists, counts, the My Timesheets entry): the change of any person's sheet, computed once per
/// draft, period and loaded bookings (web `periodBookingChanges` memo). The screens attach their stores; with none
/// attached, nothing reads as changed.
@MainActor
final class SignedTimesheetChangeContext {
    static let shared = SignedTimesheetChangeContext()

    private weak var firebaseBackend: FirebaseBackend?
    private weak var bookingStore: BookingStore?
    private weak var managerScheduleStore: ManagerScheduleStore?
    private weak var operativeStore: OperativeStore?
    private weak var projectStore: ProjectStore?
    private weak var userStore: UserStore?
    private var memo: [String: RulebookSignedTimesheetChange?] = [:]

    /// Web `HUB_CHANGE_SCAN_RUNS`: the My Timesheets entry checks only the last six pay runs.
    static let hubScanRuns = 6

    func attach(
        firebaseBackend: FirebaseBackend,
        bookingStore: BookingStore,
        managerScheduleStore: ManagerScheduleStore,
        operativeStore: OperativeStore,
        projectStore: ProjectStore,
        userStore: UserStore
    ) {
        self.firebaseBackend = firebaseBackend
        self.bookingStore = bookingStore
        self.managerScheduleStore = managerScheduleStore
        self.operativeStore = operativeStore
        self.projectStore = projectStore
        self.userStore = userStore
    }

    private func signature(_ draft: TimesheetDraft) -> String {
        func ms(_ date: Date?) -> String { date.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "-" }
        let record = (draft.operativeSignedBookings ?? []).map { "\($0.bookingId):\($0.fingerprint):\($0.personId):\($0.place)" }
        let snapshot = (draft.weeklyReportOverride?.lines ?? []).map { "\($0.id):\($0.bookingFingerprint ?? "")" }
        // RULEBOOK 1.54.0: late extras, the stored reviews and the snapshot's money rows decide the answer too.
        let money = ((draft.weeklyReportOverride?.priceWork ?? []) + (draft.weeklyReportOverride?.expenses ?? []))
            .map { "\($0.id):\($0.amount):\($0.lateExtra == true)" }
        let late = (draft.lateExtras ?? []).map { "\($0.id):\($0.reviewFingerprint ?? ""):\($0.amount):\($0.lateState ?? "")" }
        return [
            ms(draft.operativeSignedAt), ms(draft.managerSignedAt), ms(draft.exportedAt), ms(draft.approvedAt),
            ms(draft.invoiceGeneratedAt),
            ms(draft.operativeSignedBookingsAt), ms(draft.operativeSignedBookingsSignedAt),
            ms(draft.weeklyReportOverride?.approvedAt), record.joined(separator: ","), snapshot.joined(separator: ","),
            money.joined(separator: ","), late.joined(separator: ","), draft.extraEntryReviewsJSON ?? "-",
            // RULEBOOK 1.74.0: the reviewer's booking edits decide the answer too.
            draft.reviewerBookingEditsJSON ?? "-",
            draft.exportedAtStored == true ? "x" : "-",
            // RULEBOOK 1.55.0: the version read (an original and its revision are different sheets).
            draft.versionDocumentId ?? "-",
        ].joined(separator: "|")
    }

    /// The people content the answer depends on (review of #234 item 2): the person, every users document (ids, emails,
    /// former and same-email ids, employment type — the whole document) and every operatives row's id and email, so an
    /// email or id change while a list is open is a new answer. Counts alone missed edits.
    static func peopleStamp(user: AppUser, operatives: [Operative], users: [AppUser]) -> Int {
        var hasher = Hasher()
        hasher.combine(user)
        hasher.combine(rosterStamp(operatives: operatives, users: users))
        return hasher.finalize()
    }

    /// The roster part of `peopleStamp` (every users document, every operatives row's id and email).
    static func rosterStamp(operatives: [Operative], users: [AppUser]) -> Int {
        var hasher = Hasher()
        hasher.combine(users.count)
        for person in users { hasher.combine(person) }
        hasher.combine(operatives.count)
        for row in operatives {
            hasher.combine(row.documentId)
            hasher.combine(row.email)
        }
        return hasher.finalize()
    }

    /// Review of #234 (A): the roster and organisation stamps are hashed once per store revision, not on every call
    /// (a cache hit no longer pays for hashing the whole roster). The revisions change whenever the content does.
    private var rosterStampCache: (users: Int, operatives: Int, stamp: Int)?
    private var organizationStampCache: (revision: Int, stamp: Int)?

    private func cachedRosterStamp(userStore: UserStore, operativeStore: OperativeStore) -> Int {
        if let held = rosterStampCache, held.users == userStore.revision, held.operatives == operativeStore.revision {
            return held.stamp
        }
        let stamp = Self.rosterStamp(operatives: operativeStore.allOperatives, users: userStore.organizationUsers)
        rosterStampCache = (userStore.revision, operativeStore.revision, stamp)
        return stamp
    }

    private func cachedOrganizationStamp(_ firebaseBackend: FirebaseBackend) -> Int {
        if let held = organizationStampCache, held.revision == firebaseBackend.organizationRevision { return held.stamp }
        let stamp = Self.organizationStamp(firebaseBackend.currentOrganization)
        organizationStampCache = (firebaseBackend.organizationRevision, stamp)
        return stamp
    }

    /// The organisation content the collector prices with (review of #234 item 2): the settings (working hours, schedule
    /// options, invoicing) and the whole working-hours state (prior, effective day, scheduled change, history JSON).
    static func organizationStamp(_ organization: Organization?) -> Int {
        var hasher = Hasher()
        guard let organization else { return 0 }
        hasher.combine(organization.settings)
        hasher.combine(organization.payrollTimePolicyPrior)
        hasher.combine(organization.payrollTimePolicyEffectiveFrom)
        hasher.combine(organization.payrollTimePolicyScheduled)
        hasher.combine(organization.payrollPolicyStateJSON)
        return hasher.finalize()
    }

    /// The change of `user`'s `draft` for `period`, or nil (not signed, stores not attached, script did not answer).
    func change(draft: TimesheetDraft, user: AppUser, period: WeekRange) -> RulebookSignedTimesheetChange? {
        guard SignedTimesheetChanges.isSigned(draft),
              let firebaseBackend, let bookingStore, let managerScheduleStore,
              let operativeStore, let projectStore, let userStore else { return nil }
        let loaded = PayInputsLoad.periodBookings(
            firebaseBackend: firebaseBackend,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            from: period.start
        ).loaded
        // The person's ids come from the operatives list too (web third review #325): nothing reads as changed before.
        let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId
        guard loaded, orgId != nil, operativeStore.finishedLoadOrganizationId == orgId, !operativeStore.isLoading else {
            // RULEBOOK 1.54.0 (web `periodBookingChanges`): late extras need no bookings — waiting ones still put the
            // sheet with the line manager.
            return CanonicalBusinessEngine.timesheetChangesWithLateExtras(bookingChange: nil, late: TimesheetLateExtrasSupport.summary(draft))
        }
        let key = [
            user.id,
            String(Int64(period.start.timeIntervalSince1970)),
            String(Int64(period.end.timeIntervalSince1970)),
            signature(draft),
            String(bookingStore.revision),
            String(managerScheduleStore.revision),
            String(operativeStore.revision),
            String(projectStore.revision),
            String(user.hashValue),
            String(cachedRosterStamp(userStore: userStore, operativeStore: operativeStore)),
            String(cachedOrganizationStamp(firebaseBackend)),
            firebaseBackend.currentOrganization?.firestoreDocumentId ?? "",
        ].joined(separator: "#")
        if let held = memo[key] { return held }
        if memo.count > 2000 { memo.removeAll() }
        let inputs = SignedTimesheetChanges.Inputs(
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings,
            operatives: operativeStore.allOperatives,
            projects: projectStore.projects,
            smallWorks: projectStore.smallWorks,
            organization: firebaseBackend.currentOrganization,
            users: userStore.organizationUsers,
            liveLoaded: true
        )
        let change = SignedTimesheetChanges.change(draft: draft, user: user, period: period, inputs: inputs)
        memo[key] = change
        return change
    }

    /// The change of the sheet stored for `user` and `periodStart` on this device.
    func change(userId: String, user: AppUser, periodStart: Date, settings: OrganizationInvoicingSettings) -> RulebookSignedTimesheetChange? {
        let draft = TimesheetDraftStore.load(userId: userId, weekStart: periodStart)
        guard SignedTimesheetChanges.isSigned(draft) else { return nil }
        let storedEnd = TimesheetDraftStore.storedPeriodEnd(userId: userId, weekStart: periodStart)
        let period = TimesheetPayrollPolicy.periodMatchingStoredStart(periodStart, storedEnd: storedEnd, settings: settings)
        return change(draft: draft, user: user, period: period)
    }

    /// The My Timesheets entry: whether any of the person's own signed, unexported sheets of the last six pay runs waits
    /// for them to sign again. Bookings are asked for only from the earliest of those runs.
    private func hubPeriods(settings: OrganizationInvoicingSettings) -> [WeekRange] {
        UserTimesheetQueueRulebook.recentPayRuns(settings: settings)
    }

    /// RULEBOOK 1.66.0 §8 (web `TimesheetsScreen` / hub `coversPeriod`): the change User Timesheets reads for a sheet.
    /// The booking-change window is the last six pay runs, the same on the landing cards and the lists as on web: a run
    /// in it gets `change(draft:user:period:)`; an older run gets its waiting late extras alone, its bookings read as not
    /// changed. Export does not use this: it checks every sheet it stamps in full.
    func queueChange(
        draft: TimesheetDraft,
        user: AppUser,
        period: WeekRange,
        settings: OrganizationInvoicingSettings
    ) -> RulebookSignedTimesheetChange? {
        guard let windowStart = hubPeriods(settings: settings).map(\.start).min(), period.start >= windowStart else {
            guard SignedTimesheetChanges.isSigned(draft) else { return nil }
            return CanonicalBusinessEngine.timesheetChangesWithLateExtras(bookingChange: nil, late: TimesheetLateExtrasSupport.summary(draft))
        }
        return change(draft: draft, user: user, period: period)
    }

    /// Asks for the bookings from the earliest of the last six pay runs (not the whole archive), when any of the
    /// person's sheets there is signed and not exported. Plumbing only.
    func ensureHubBookings(user: AppUser, settings: OrganizationInvoicingSettings) {
        guard let firebaseBackend, let bookingStore, let managerScheduleStore else { return }
        // RULEBOOK 1.55.0 §8: exported sheets too — a booking change after export makes a revision due.
        let signed = hubPeriods(settings: settings).filter { period in
            let draft = TimesheetDraftStore.load(userId: user.id, weekStart: period.start)
            return SignedTimesheetChanges.isSigned(draft)
        }
        guard let earliest = signed.map(\.start).min() else { return }
        PayInputsLoad.ensurePeriodBookings(
            firebaseBackend: firebaseBackend,
            bookingStore: bookingStore,
            managerScheduleStore: managerScheduleStore,
            from: earliest
        )
    }

    /// The My Timesheets entry's triangle: a signed, unexported sheet waits for the person to sign again (1.47.0), or
    /// — RULEBOOK 1.55.0 §8 — an exported sheet has a revision due (`timesheetRevisionDue`).
    func ownSheetNeedsSigningAgain(user: AppUser, settings: OrganizationInvoicingSettings) -> Bool {
        ownSheetTriangleMessage(user: user, settings: settings) != nil
    }

    /// The popup of the My Timesheets entry's triangle, or nil when there is none: `SIGNED_TIMESHEET_CHANGED_MESSAGE`
    /// for a signed sheet to sign again (1.47.0), `TIMESHEET_REVISION_DUE_MESSAGE` for a revision due (1.55.0). The
    /// newest pay run decides when both occur.
    func ownSheetTriangleMessage(user: AppUser, settings: OrganizationInvoicingSettings) -> String? {
        let periods = hubPeriods(settings: settings)
        for period in periods {
            let draft = TimesheetDraftStore.load(userId: user.id, weekStart: period.start)
            guard SignedTimesheetChanges.isSigned(draft) else { continue }
            if TimesheetApprovalPolicy.isExported(draft) {
                let due = revisionDue(draft: draft, user: user, period: period)
                if due.due { return due.message ?? CanonicalBusinessEngine.timesheetRevisionDueMessage }
            } else if let reopened = change(draft: draft, user: user, period: period), reopened.waitingForPerson {
                return reopened.message ?? CanonicalBusinessEngine.signedTimesheetChangedMessage
            }
        }
        return nil
    }

    /// RULEBOOK 1.55.0 §8 `timesheetRevisionDue`: the draft (its pay run's latest version) is exported and its
    /// bookings changed since — a revision is due. `.notDue` until the pay run's bookings have loaded.
    func revisionDue(draft: TimesheetDraft, user: AppUser, period: WeekRange) -> RulebookTimesheetRevisionDue {
        guard SignedTimesheetChanges.isSigned(draft), TimesheetApprovalPolicy.isExported(draft) else { return .notDue }
        return TimesheetDraftStore.revisionDue(
            for: draft,
            userId: user.id,
            weekStart: period.start,
            change: change(draft: draft, user: user, period: period)
        )
    }
}
