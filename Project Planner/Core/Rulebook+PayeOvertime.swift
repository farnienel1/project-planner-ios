//
//  Rulebook+PayeOvertime.swift
//  Project Planner
//
//  RULEBOOK 1.29.0 (§4.5 PAYE payday, §7 weekly report PAYE section, §13 overtime notices, §25 PAYE overtime): typed
//  wrappers for web `lib/canonical/payePayrun.ts` and `lib/canonical/payeOvertime.ts`, called through
//  `CanonicalBusinessEngine.callJSON`. Every date, figure, state, permission and write shape comes from the packed
//  script; Swift only builds the inputs and reads the answers. Nothing is decided here.
//
//  RULEBOOK 1.32.0 (§25): partial approval (`overtimeApprovalWrites` → `lineOutcomes`, `waitingBookingIds`,
//  `appliedBookingIds`, `complete`, `message`), one Approve (`OVERTIME_APPROVE_LABEL`, `overtimeRequestAnyDecided`),
//  per-line outcome labels (`overtimeLineOutcomeLabel`), all records for this person (`overtimePersonIds`), future days
//  of the current payrun (`overtimeEditableUntil`) and own edits as requests with a line manager
//  (`canEditOwnBookingOvertime({ person, roster })`).
//
//  RULEBOOK 1.33.0 (§25, §13, owner decisions 6 Nov): Send → Return. One ✓ ✕ ⚙ state machine (`overtimeChoiceAfter`,
//  drawn with `overtimeChoiceView`), one readiness rule per button (`overtimeSubmitReady` / `overtimeSubmitLines`,
//  `overtimeReturnReady`, `overtimeGenerateReady`), Return as one transaction (`overtimeReturnWrites`: booking writes,
//  booking deletes with their tombstone, reviews and the request fields), the new line states, reports marked out of
//  date (`overtimeReportOutOfDate`), the notices (`overtimeRequestSubmittedMessage`, `overtimeReturnedMessage`,
//  `overtimeReopenedMessage`) and where they open (`overtimeNotificationRange`). `overtimeApprovalWrites`,
//  `overtimeRequestAnyDecided` and "Needs an admin" are gone from the rulebook and from here.
//

import Foundation

// MARK: - JSON plumbing

/// Turns script answers into typed values and typed inputs into script arguments. No rule lives here.
nonisolated enum RulebookJSON {
    /// A script answer (dictionary or array) decoded as `T`. Nil for `null`, a fragment or a shape that does not decode.
    static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// An encodable value as a JSON object for the script (dictionary or array). Nil when it does not encode.
    static func object<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// `value` or JSON `null`.
    static func orNull(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    /// Firestore-safe copy of a script answer: JSON `null` stays `NSNull` (Firestore stores null), numbers stay numbers.
    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }
}

// MARK: - Types (the script's shapes)

/// `PayePayrun`: a PAYE payrun, organisation-zone day keys, inclusive; `payDate` is the payday.
nonisolated struct PayePayrun: Codable, Hashable, Sendable, Identifiable {
    var start: String
    var end: String
    var payDate: String
    var payday: Int
    var id: String { "\(start)|\(end)" }
}

/// `PayePaydayHistoryEntry`.
nonisolated struct PayePaydayHistoryEntry: Codable, Hashable, Sendable {
    var day: Int
    var effectiveFrom: String
}

/// `OvertimeFigures`: hours only, never money.
nonisolated struct OvertimeFigures: Codable, Hashable, Sendable {
    var clockHours: Double
    var multiplier: Double
    var breakHours: Double
    var overtimeHours: Double
    /// "1h × 1.5 = 1.5h".
    var text: String
    var dayWindow: String?
    var organizationMultiplier: Double
    var customMultiplier: Double?
}

/// `OvertimeRequestLine` as stored on a request.
nonisolated struct OvertimeRequestLine: Codable, Hashable, Sendable {
    var bookingId: String
    var collection: String
    var dayKey: String
    var jobId: String?
    var fingerprint: String
    /// `keep` | `edit` | `strike`.
    var action: String
    var proposedStart: String?
    var proposedEnd: String?
    var proposedMultiplier: Double?
    var cancel: Bool
    var overtimeHoursBefore: Double
    var overtimeHoursAfter: Double
}

/// `OvertimeLine`: one booking's overtime with its state (`payeOvertimeLines`).
nonisolated struct OvertimeLine: Codable, Hashable, Sendable, Identifiable {
    var bookingId: String
    var collection: String
    var dayKey: String
    var dayLabel: String
    var jobId: String?
    var jobNumber: String
    var jobName: String
    var title: String
    var start: String
    var end: String
    var timeSlot: String
    var fingerprint: String
    /// 1.33.0: `needsReview` | `waiting` | `changedSinceRequest` | `confirmed` | `returnedApproved` | `returnedChanged` |
    /// `returnedDeclined` | `reopened` | `deleted` | `cancelled` (`OVERTIME_LINE_STATES`).
    var state: String
    var stateLabel: String
    /// Nil for a cancelled or deleted line.
    var figures: OvertimeFigures?
    var requestId: String?
    var requestLine: OvertimeRequestLine?
    /// 1.33.0: who returned the line and their name (nil when not returned).
    var decidedBy: String?
    var deciderName: String?
    /// 1.33.0: the request line the person last sent for this booking (`overtimeLineBaselineChoice` starts from it).
    var sentLine: OvertimeRequestLine?

    var id: String { "\(collection)/\(bookingId)" }
}

/// The booking as the overtime rules read it (`OvertimeBookingInput`), built from the rulebook booking readers.
nonisolated struct OvertimeBookingInput: Hashable, Sendable, Identifiable {
    var id: String
    /// `bookings` or `managerSiteBookings`.
    var collection: String
    /// `operativeId` of a labour booking, `userId` of a manager site booking, as stored.
    var personId: String
    /// Organisation-zone `YYYY-MM-DD`.
    var dayKey: String
    var timeSlot: String?
    var workStartTime: String?
    var workEndTime: String?
    var isBreakRemoved: Bool
    var otMultiplierOverride: Double?
    /// Missing reads Confirmed (manager site bookings carry none).
    var status: String?
    var jobId: String?
    var jobNumber: String = ""
    var jobName: String = ""

    /// The script argument (every key present; missing values are JSON null).
    var json: [String: Any] {
        [
            "id": id,
            "collection": collection,
            "personId": personId,
            "dayKey": dayKey,
            "timeSlot": RulebookJSON.orNull(timeSlot),
            "workStartTime": RulebookJSON.orNull(workStartTime),
            "workEndTime": RulebookJSON.orNull(workEndTime),
            "isBreakRemoved": isBreakRemoved,
            "otMultiplierOverride": RulebookJSON.orNull(otMultiplierOverride),
            "status": RulebookJSON.orNull(status),
            "jobId": RulebookJSON.orNull(jobId),
            "jobNumber": jobNumber,
            "jobName": jobName,
        ]
    }

    var lookupKey: String { "\(collection)/\(id.lowercased())" }
}

/// A tick, cross or cog on a line (`OvertimeDecision` / the request proposal).
nonisolated enum OvertimeAction: Hashable, Sendable {
    case keep
    case approve
    case strike
    /// `multiplier` nil = the organisation's rate.
    case edit(start: String, end: String, multiplier: Double?)

    /// The proposal shape (`overtimeRequestLineFields`): `keep` | `strike` | `edit`.
    var proposalJSON: [String: Any] {
        switch self {
        case .keep, .approve: return ["action": "keep"]
        case .strike: return ["action": "strike"]
        case .edit(let start, let end, let multiplier):
            return ["action": "edit", "start": start, "end": end, "multiplier": RulebookJSON.orNull(multiplier)]
        }
    }

    /// The decision shape (`OvertimeDecision`): `approve` | `strike` | `edit`. A null rate is sent as null, never left
    /// out (left out means "leave the rate" in `overtimeBookingWriteFields`).
    var decisionJSON: [String: Any] {
        switch self {
        case .keep, .approve: return ["action": "approve"]
        case .strike: return ["action": "strike"]
        case .edit(let start, let end, let multiplier):
            return ["action": "edit", "start": start, "end": end, "multiplier": RulebookJSON.orNull(multiplier)]
        }
    }

    var shortLabel: String {
        switch self {
        case .keep, .approve: return "Ticked"
        case .strike: return "Crossed"
        case .edit(let start, let end, _): return "Changed to \(start)–\(end)"
        }
    }
}

/// `overtimeStrikeOutcome`.
nonisolated struct OvertimeStrikeOutcome: Codable, Hashable, Sendable {
    nonisolated struct Warning: Codable, Hashable, Sendable {
        var title: String
        var summary: String
        var body: String
        var back: String
        var confirm: String
        var footnote: String
    }
    /// `none` | `trim` | `delete` (1.33.0: was `cancel`) | `notAllowed`.
    var kind: String
    var start: String?
    var end: String?
    var warning: Warning?
    var message: String?
}

/// `overtimeCogPreview` (figures dropped; the texts are what the cog shows).
nonisolated struct OvertimeCogPreview: Codable, Hashable, Sendable {
    var beforeText: String
    var afterText: String
    var changed: Bool
    var error: String?
}

/// `overtimeRateControl`.
nonisolated struct OvertimeRateControl: Codable, Hashable, Sendable {
    var show: Bool
    var organizationMultiplier: Double
    var organizationLabel: String
    var customMultiplier: Double?
    var steps: [Double]
}

/// `overtimeHubAccess`.
nonisolated struct OvertimeHubAccess: Codable, Hashable, Sendable {
    var showButton: Bool
    var mine: Bool
    var users: Bool

    static let hidden = OvertimeHubAccess(showButton: false, mine: false, users: false)
}

/// A booking write of `overtimeReturnWrites` / `overtimeDirectWrites`: `set` keys and `remove` keys.
nonisolated struct OvertimeBookingWrite: @unchecked Sendable {
    var collection: String
    var bookingId: String
    var set: [String: Any]
    var remove: [String]

    init?(_ raw: Any?) {
        guard let row = raw as? [String: Any],
              let collection = row["collection"] as? String,
              let bookingId = row["bookingId"] as? String else { return nil }
        self.collection = collection
        self.bookingId = bookingId
        self.set = row["set"] as? [String: Any] ?? [:]
        self.remove = row["remove"] as? [String] ?? []
    }
}

/// 1.33.0 `OvertimeBookingDelete` (item f): a labour booking an approved red X removes, and its tombstone
/// (`bookingTombstoneWriteFields`, with `overtimeRequestId` on a Return). The app adds the tombstone's `deletedAt`.
nonisolated struct OvertimeBookingDelete: @unchecked Sendable {
    var collection: String
    var bookingId: String
    var tombstone: [String: Any]

    init?(_ raw: Any?) {
        guard let row = raw as? [String: Any],
              let collection = row["collection"] as? String,
              let bookingId = row["bookingId"] as? String,
              let tombstone = row["tombstone"] as? [String: Any] else { return nil }
        self.collection = collection
        self.bookingId = bookingId
        self.tombstone = tombstone
    }
}

/// A review write: `overtimeReviews/{docId}` fields.
nonisolated struct OvertimeReviewWrite: @unchecked Sendable {
    var docId: String
    var fields: [String: Any]

    init?(_ raw: Any?) {
        guard let row = raw as? [String: Any],
              let docId = row["docId"] as? String,
              let fields = row["fields"] as? [String: Any] else { return nil }
        self.docId = docId
        self.fields = fields
    }
}

/// `overtimeReturnWrites` answer (1.33.0 Return, one transaction). `ok` false (`notPending` | `undecided`) writes
/// nothing; `ok` true applies `bookingWrites`, `bookingDeletes` (each with its tombstone), `reviewWrites` and
/// `requestFields` (`approved`, with `staleBookingIds` / `deletedBookingIds`). `lineOutcomes` maps a request line's
/// booking id to `applied` | `declined` | `removed` | `alreadyApplied` | `stale` | `refused` | `deleted` | `unreadable` |
/// `foreign` (labels: `overtimeLineOutcomeLabel`). `message` is `overtimeReturnMessage` ("Returned 5 lines. …").
nonisolated struct OvertimeReturnPlan: @unchecked Sendable {
    var ok: Bool
    /// `notPending` | `undecided` when `ok` is false; nil when `ok`.
    var reason: String?
    /// When refused: the lines still undecided.
    var bookingIds: [String]
    var bookingWrites: [OvertimeBookingWrite]
    var bookingDeletes: [OvertimeBookingDelete]
    var reviewWrites: [OvertimeReviewWrite]
    var requestFields: [String: Any]
    var appliedBookingIds: [String]
    var staleBookingIds: [String]
    var deletedBookingIds: [String]
    var droppedBookingIds: [String]
    var lineOutcomes: [String: String]
    var message: String

    init?(_ raw: Any?) {
        guard let row = raw as? [String: Any], let ok = row["ok"] as? Bool else { return nil }
        self.ok = ok
        reason = ok ? nil : row["reason"] as? String
        bookingIds = row["bookingIds"] as? [String] ?? []
        bookingWrites = (row["bookingWrites"] as? [Any] ?? []).compactMap { OvertimeBookingWrite($0) }
        bookingDeletes = (row["bookingDeletes"] as? [Any] ?? []).compactMap { OvertimeBookingDelete($0) }
        reviewWrites = (row["reviewWrites"] as? [Any] ?? []).compactMap { OvertimeReviewWrite($0) }
        requestFields = row["requestFields"] as? [String: Any] ?? [:]
        appliedBookingIds = row["appliedBookingIds"] as? [String] ?? []
        staleBookingIds = row["staleBookingIds"] as? [String] ?? []
        deletedBookingIds = row["deletedBookingIds"] as? [String] ?? []
        droppedBookingIds = row["droppedBookingIds"] as? [String] ?? []
        lineOutcomes = row["lineOutcomes"] as? [String: String] ?? [:]
        message = row["message"] as? String ?? ""
    }
}

/// `overtimeDirectWrites` answer.
nonisolated struct OvertimeDirectPlan: @unchecked Sendable {
    var bookingWrite: OvertimeBookingWrite?
    /// 1.33.0: the delete (with its tombstone) of an all-overtime booking the red X removes.
    var bookingDelete: OvertimeBookingDelete?
    var reviewWrite: OvertimeReviewWrite
    var hoursChanged: Bool

    init?(_ raw: Any?) {
        guard let row = raw as? [String: Any], let review = OvertimeReviewWrite(row["reviewWrite"]) else { return nil }
        bookingWrite = OvertimeBookingWrite(row["bookingWrite"])
        bookingDelete = OvertimeBookingDelete(row["bookingDelete"])
        reviewWrite = review
        hoursChanged = row["hoursChanged"] as? Bool ?? false
    }
}

/// `parseOvertimeRequestDocument`: the parsed record (passed back to the script as it came) and its typed view.
nonisolated struct OvertimeRequestRecord: Identifiable, @unchecked Sendable {
    private nonisolated struct Fields: Decodable {
        var id: String
        var userId: String
        var rangeStart: String
        var rangeEnd: String
        var status: String
        var lines: [OvertimeRequestLine]
        var createdAtMs: Double?
        var appliedBookingIds: [String]?
        var droppedBookingIds: [String]?
    }

    let raw: [String: Any]
    let id: String
    let userId: String
    let rangeStart: String
    let rangeEnd: String
    /// `pending` | `approved` | `withdrawn`.
    let status: String
    let lines: [OvertimeRequestLine]
    let createdAtMs: Double?
    /// 1.32.0: lines applied by an earlier partial approval; 1.33.0: lines returned by a Return.
    let appliedBookingIds: [String]
    /// Lines left out (deleted, unreadable, refused, not theirs).
    let droppedBookingIds: [String]

    init?(raw: Any?) {
        guard let row = raw as? [String: Any], let view = RulebookJSON.decode(Fields.self, from: row) else { return nil }
        self.raw = row
        id = view.id
        userId = view.userId
        rangeStart = view.rangeStart
        rangeEnd = view.rangeEnd
        status = view.status
        lines = view.lines
        createdAtMs = view.createdAtMs
        appliedBookingIds = view.appliedBookingIds ?? []
        droppedBookingIds = view.droppedBookingIds ?? []
    }

    var isPending: Bool { status == "pending" }
}

/// `parseOvertimeReviewDocument`.
nonisolated struct OvertimeReviewRecord: Identifiable, @unchecked Sendable {
    let raw: [String: Any]
    let id: String
    let bookingId: String

    init?(raw: Any?) {
        guard let row = raw as? [String: Any], let id = row["id"] as? String else { return nil }
        self.raw = row
        self.id = id
        bookingId = row["bookingId"] as? String ?? ""
    }
}

/// `parseOvertimeReportDocument`: the saved copy (passed to `overtimeReportRows` as it came) and its typed view.
nonisolated struct OvertimeReportRecord: Identifiable, @unchecked Sendable {
    private nonisolated struct Fields: Decodable {
        nonisolated struct Totals: Decodable { var overtimeHours: Double; var lineCount: Double }
        var id: String
        var userName: String
        var companyName: String
        var rangeStart: String
        var rangeEnd: String
        var totals: Totals
        var generatedAtMs: Double?
        var outOfDate: Bool?
    }

    let raw: [String: Any]
    let id: String
    let userName: String
    let companyName: String
    let rangeStart: String
    let rangeEnd: String
    let overtimeHours: Double
    let generatedAtMs: Double?
    /// 1.33.0: a stored out-of-date mark (the screens work it out with `overtimeReportOutOfDate`).
    let storedOutOfDate: Bool

    init?(raw: Any?) {
        guard let row = raw as? [String: Any], let view = RulebookJSON.decode(Fields.self, from: row) else { return nil }
        self.raw = row
        id = view.id
        userName = view.userName
        companyName = view.companyName
        rangeStart = view.rangeStart
        rangeEnd = view.rangeEnd
        overtimeHours = view.totals.overtimeHours
        generatedAtMs = view.generatedAtMs
        storedOutOfDate = view.outOfDate ?? false
    }
}

/// `overtimeReportRows`: the PDF's content. 1.33.0 (owner 6 Nov, laid out like the invoice report): the header
/// (`documentTitle`, `companyName`, `personName`, `period`, `generated` from `reportGeneratedText`), the table
/// (`columns`, `table`), the total (`totalLabel` / `totalValue`), `emptyMessage`, `footer` and the out-of-date mark.
nonisolated struct OvertimeReportRows: Codable, Hashable, Sendable {
    /// One table row: day, job, start–finish, overtime; a declined line reads "0h" with "Declined by {name}".
    nonisolated struct TableRow: Codable, Hashable, Sendable {
        var bookingId: String
        var day: String
        var job: String
        var time: String
        var overtime: String
        var note: String
        var declined: Bool
    }

    var title: String
    var subtitle: String
    var rows: [String]
    var total: String
    var documentTitle: String
    var companyName: String
    var personName: String
    var period: String
    var generatedAt: String
    var generatedBy: String
    var generated: String
    var columns: [String]
    var table: [TableRow]
    var totalLabel: String
    var totalValue: String
    var emptyMessage: String
    var footer: String
    var outOfDate: Bool
    var outOfDateNote: String
}

/// 1.33.0 `OvertimeChoice`: the person's or the decider's ✓ ✕ ⚙ on one line (`overtimeChoiceAfter`). `mark` is
/// `none` | `tick` | `cross`; `edit` holds the cog's start, finish and rate (nil rate = the organisation's).
nonisolated struct OvertimeChoice: Codable, Hashable, Sendable {
    nonisolated struct Edit: Codable, Hashable, Sendable {
        var start: String
        var end: String
        var multiplier: Double?
    }

    var mark: String
    var edit: Edit?

    /// `OVERTIME_EMPTY_CHOICE`.
    static let empty = OvertimeChoice(mark: "none", edit: nil)

    /// The script argument (`edit` and its rate as JSON null when absent).
    var json: [String: Any] {
        [
            "mark": mark,
            "edit": edit.map { ["start": $0.start, "end": $0.end, "multiplier": RulebookJSON.orNull($0.multiplier)] as [String: Any] as Any }
                ?? NSNull(),
        ]
    }

    init(mark: String, edit: Edit?) {
        self.mark = mark
        self.edit = edit
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any], let mark = row["mark"] as? String else { return nil }
        self.mark = mark
        if let edit = row["edit"] as? [String: Any], let start = edit["start"] as? String, let end = edit["end"] as? String {
            self.edit = Edit(start: start, end: end, multiplier: (edit["multiplier"] as? NSNumber)?.doubleValue)
        } else {
            self.edit = nil
        }
    }
}

/// 1.33.0 `OvertimeChoiceEvent`: a tap on ✓, ✕, a saved cog, or a reset.
nonisolated enum OvertimeChoiceEvent: Hashable, Sendable {
    case tick
    case cross
    case cog(start: String, end: String, multiplier: Double?)
    case reset

    var json: [String: Any] {
        switch self {
        case .tick: return ["kind": "tick"]
        case .cross: return ["kind": "cross"]
        case .reset: return ["kind": "reset"]
        case .cog(let start, let end, let multiplier):
            return ["kind": "cog", "start": start, "end": end, "multiplier": RulebookJSON.orNull(multiplier)]
        }
    }
}

/// 1.33.0 `overtimeChoiceView`: what both apps draw for one line's choice. `tick` / `cross` / `cog` are `filled` |
/// `grey` | `idle`; `figureStruck` strikes the booking's figure; `newFigure` goes under it; `label` is the person's or
/// the decider's word; `complete` once ✓ or ✕ is set.
nonisolated struct OvertimeChoiceLook: Codable, Hashable, Sendable {
    var tick: String
    var cross: String
    var cog: String
    var figureStruck: Bool
    var oldFigure: String
    var newFigure: String?
    var label: String
    var complete: Bool

    /// Nothing chosen, nothing drawn (the script did not answer).
    static let idle = OvertimeChoiceLook(
        tick: "idle", cross: "idle", cog: "idle", figureStruck: false, oldFigure: "", newFigure: nil, label: "", complete: false
    )
}

/// A button-readiness answer (`overtimeSubmitReady`, `overtimeReturnReady`, `overtimeGenerateReady`).
nonisolated struct OvertimeButtonReadiness: Codable, Hashable, Sendable {
    var ready: Bool
    var undecidedCount: Int?
    /// `overtimeSubmitReady`: the lines Send for approval would send.
    var bookingIds: [String]?
    var message: String?

    static let notReady = OvertimeButtonReadiness(ready: false, undecidedCount: nil, bookingIds: nil, message: nil)
}

/// 1.33.0 `overtimeNotificationRange`: the payrun an overtime notice opens.
nonisolated struct OvertimeNotificationRange: Codable, Hashable, Sendable {
    /// `current` | `past` | `custom`.
    var range: String
    var start: String
    var end: String
}

/// A notice's title and text (`overtimeRequestSubmittedMessage`, `overtimeReturnedMessage`, `overtimeReopenedMessage`).
nonisolated struct OvertimeNotice: Codable, Hashable, Sendable {
    var title: String
    var message: String
}

/// One `weeklyReportPayeOvertime` row. RULEBOOK 1.32.0 §7: one row per PAYE person, job and multiplier, with the
/// clock hours priced at `multiplier`, the organisation's rate on those days, whether the bookings carry their own rate
/// different from it (`changedFromOrganization`), `multiplierText` ("2h at ×1.5 = 3h", `overtimeMultiplierText`) and
/// `label` ("Sam · J-1042 · 2h at ×1.5 = 3h", plus " · changed from organisation rate (×1.5)" on an edited row).
nonisolated struct WeeklyReportPayeOvertimeRow: Codable, Hashable, Sendable {
    var personId: String
    var name: String
    var jobId: String?
    var jobNumber: String
    var jobName: String
    var clockHours: Double
    var breakHours: Double
    var multiplier: Double
    var organizationMultiplier: Double
    var changedFromOrganization: Bool
    var overtimeHours: Double
    var multiplierText: String
    var label: String
}

/// The edit mode `canEditOwnBookingOvertime` answers.
nonisolated enum OvertimeEditMode: String, Sendable {
    case direct
    case request
    case readOnly = "none"
}

// MARK: - The organisation document the rules read

/// The organisation as the PAYE rules read it: the stored working-hours state (`payrollTimePolicy` and its history,
/// for `effectivePayrollTimePolicy` on each day) and `invoicing.payePayday` / `invoicing.payePaydayHistory` as stored.
nonisolated enum OvertimeOrganizationDocument {
    /// `{ payePayday, payePaydayHistory }` of `organizations/{orgId}.invoicing` as JSON text (Firestore values made JSON),
    /// or nil when neither is stored. Kept on `Organization.payePaydayJSON`.
    static func payePaydayJSON(fromOrganizationData data: [String: Any]) -> String? {
        guard let invoicing = data["invoicing"] as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        for key in ["payePayday", "payePaydayHistory"] {
            if let value = invoicing[key] { out[key] = FirebaseBackend.firestoreJSON(value) }
        }
        guard !out.isEmpty, JSONSerialization.isValidJSONObject(out),
              let bytes = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    /// The `invoicing` PAYE fields read back from `payePaydayJSON`; empty when none.
    static func invoicing(json: String?) -> [String: Any] {
        guard let json, let bytes = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return [:] }
        return object
    }

    /// The open organisation as one document for the overtime and payrun rules.
    @MainActor static func document(_ org: Organization?) -> [String: Any] {
        guard let org else { return ["invoicing": [String: Any]()] }
        var doc = PayrollTimePolicyCatalog.payrollPolicyDocument(for: org)
        doc["invoicing"] = invoicing(json: org.payePaydayJSON)
        doc["name"] = org.name
        doc["countryCode"] = org.countryCode
        return doc
    }
}

// MARK: - Script calls

extension CanonicalBusinessEngine {
    nonisolated static var overtimeTimeZone: String { OrganizationRulebookContext.timeZoneIdentifier }

    /// A string constant of the script (`OVERTIME_HUB_LABEL`, `PAYE_PAYDAY_NOT_SET_MESSAGE`, …), or `fallback`.
    nonisolated static func overtimeText(_ name: String, fallback: String) -> String {
        constant(name, as: String.self) ?? fallback
    }

    /// `BOOKING_TOMBSTONE_COLLECTION`: where a deleted booking's tombstone is written.
    nonisolated static var bookingTombstoneCollection: String {
        constant("BOOKING_TOMBSTONE_COLLECTION", as: String.self) ?? "deletedBookings"
    }

    /// `OVERTIME_DELETE_WARNING` (1.33.0): the red X delete warning on an all-overtime day, the same on every platform.
    nonisolated static var overtimeDeleteWarning: OvertimeStrikeOutcome.Warning? {
        guard let row = constant("OVERTIME_DELETE_WARNING", as: [String: String].self) else { return nil }
        return OvertimeStrikeOutcome.Warning(
            title: row["title"] ?? "",
            summary: "",
            body: row["body"] ?? "",
            back: row["back"] ?? "",
            confirm: row["confirm"] ?? "",
            footnote: row["footnote"] ?? ""
        )
    }

    // MARK: PAYE payday and payruns (§4.5)

    /// `payePaydayHistory(org)`.
    nonisolated static func payePaydayHistory(_ org: [String: Any]) -> [PayePaydayHistoryEntry] {
        RulebookJSON.decode([PayePaydayHistoryEntry].self, from: callJSON("payePaydayHistory", arguments: [org])) ?? []
    }

    /// `payePayday(org)`: the current payday, or nil when none is set.
    nonisolated static func payePayday(_ org: [String: Any]) -> Int? {
        (callJSON("payePayday", arguments: [org]) as? NSNumber)?.intValue
    }

    /// `payePayrunPeriod(org, dayKey)`.
    nonisolated static func payePayrunPeriod(_ org: [String: Any], dayKey: String) -> PayePayrun? {
        RulebookJSON.decode(PayePayrun.self, from: callJSON("payePayrunPeriod", arguments: [org, dayKey]))
    }

    /// `payePastPayruns(org, todayKey)`, newest first.
    nonisolated static func payePastPayruns(_ org: [String: Any], todayKey: String) -> [PayePayrun] {
        RulebookJSON.decode([PayePayrun].self, from: callJSON("payePastPayruns", arguments: [org, todayKey])) ?? []
    }

    /// `payePayrunLabel(run)`: "PAYE payrun: 26 Oct – 25 Nov · paid 25 Nov".
    nonisolated static func payePayrunLabel(_ run: PayePayrun) -> String {
        let input: [String: Any] = ["start": run.start, "end": run.end, "payDate": run.payDate]
        return callJSON("payePayrunLabel", arguments: [input]) as? String ?? "\(run.start) – \(run.end)"
    }

    /// `formatPayePayrunDay(dayKey)`: `2026-11-25` → `25 Nov`.
    nonisolated static func formatPayePayrunDay(_ dayKey: String) -> String {
        callJSON("formatPayePayrunDay", arguments: [dayKey]) as? String ?? dayKey
    }

    /// `payePaydayValidationError(day)`.
    nonisolated static func payePaydayValidationError(_ day: Int) -> String? {
        callJSON("payePaydayValidationError", arguments: [day]) as? String
    }

    /// `payePaydayWriteFields(org, day, todayKey)`: the partial update (dotted keys), or nil when invalid or unchanged.
    nonisolated static func payePaydayWriteFields(_ org: [String: Any], day: Int, todayKey: String) -> [String: Any]? {
        callJSON("payePaydayWriteFields", arguments: [org, day, todayKey]) as? [String: Any]
    }

    /// `payeCustomRange(start, end)`: the two day keys in order, or nil.
    nonisolated static func payeCustomRange(start: String, end: String) -> (start: String, end: String)? {
        guard let row = callJSON("payeCustomRange", arguments: [start, end]) as? [String: Any],
              let a = row["start"] as? String, let b = row["end"] as? String else { return nil }
        return (a, b)
    }

    // MARK: Lines (§25)

    /// `payeOvertimeLines`: the person's lines in the range with their states.
    nonisolated static func payeOvertimeLines(
        personIds: [String],
        bookings: [OvertimeBookingInput],
        organization: [String: Any],
        range: (start: String, end: String),
        reviews: [OvertimeReviewRecord],
        requests: [OvertimeRequestRecord],
        names: [String: String] = [:],
        jobs: [[String: Any]] = []
    ) -> [OvertimeLine] {
        let input: [String: Any] = [
            "personIds": personIds,
            "bookings": bookings.map(\.json),
            "organization": organization,
            "timeZone": overtimeTimeZone,
            "range": ["start": range.start, "end": range.end],
            "reviews": reviews.map(\.raw),
            "requests": requests.map(\.raw),
            // 1.33.0: the decider's name on returned lines ("Changed by {name}") and the job of a deleted line.
            "names": names,
            "jobs": jobs,
        ]
        return RulebookJSON.decode([OvertimeLine].self, from: callJSON("payeOvertimeLines", arguments: [input])) ?? []
    }

    /// `overtimeLinesTotal(lines)`.
    nonisolated static func overtimeLinesTotal(_ lines: [OvertimeLine]) -> Double {
        guard let payload = RulebookJSON.object(lines) else { return 0 }
        return (callJSON("overtimeLinesTotal", arguments: [payload]) as? NSNumber)?.doubleValue ?? 0
    }

    /// `canGenerateOvertimeReport(lines)` (1.29–1.32 callers: every line finished in any way).
    nonisolated static func canGenerateOvertimeReport(_ lines: [OvertimeLine]) -> Bool {
        guard let payload = RulebookJSON.object(lines) else { return false }
        return callJSON("canGenerateOvertimeReport", arguments: [payload]) as? Bool ?? false
    }

    // MARK: ✓ ✕ ⚙ and the three buttons (1.33.0, `overtimeChoices.ts`)

    nonisolated static func choicesJSON(_ choices: [String: OvertimeChoice]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in choices { out[key] = value.json }
        return out
    }

    /// `overtimeChoiceAfter(choice, event)`: the one ✓ ✕ ⚙ state machine (person and decider). Nil when the script did
    /// not answer.
    nonisolated static func overtimeChoiceAfter(_ choice: OvertimeChoice?, event: OvertimeChoiceEvent) -> OvertimeChoice? {
        OvertimeChoice(json: callJSON("overtimeChoiceAfter", arguments: [RulebookJSON.orNull(choice?.json), event.json]))
    }

    /// `overtimeLineChoice(line, choices)`: the person's current choice for a line (what they marked here, else the
    /// line's baseline). Nil for a line that cannot be marked (deleted, cancelled).
    nonisolated static func overtimeLineChoice(_ line: OvertimeLine, choices: [String: OvertimeChoice]) -> OvertimeChoice? {
        guard let payload = RulebookJSON.object(line) else { return nil }
        return OvertimeChoice(json: callJSON("overtimeLineChoice", arguments: [payload, choicesJSON(choices)]))
    }

    /// `overtimeChoiceDecision(choice)`: ✓ → approve, ⚙ + ✓ → edit, ✕ → strike; nil while unmarked.
    nonisolated static func overtimeChoiceDecision(_ choice: OvertimeChoice?) -> OvertimeAction? {
        guard let row = callJSON("overtimeChoiceDecision", arguments: [RulebookJSON.orNull(choice?.json)]) as? [String: Any],
              let action = row["action"] as? String else { return nil }
        switch action {
        case "approve": return .approve
        case "strike": return .strike
        case "edit":
            guard let start = row["start"] as? String, let end = row["end"] as? String else { return nil }
            return .edit(start: start, end: end, multiplier: (row["multiplier"] as? NSNumber)?.doubleValue)
        default: return nil
        }
    }

    /// `overtimeChoiceView({ choice, booking, organization, timeZone, role })`: what one line's ✓ ✕ ⚙ and figure look
    /// like. `role` is `person` | `decider`.
    nonisolated static func overtimeChoiceView(
        _ choice: OvertimeChoice?,
        booking: OvertimeBookingInput?,
        organization: [String: Any],
        role: String
    ) -> OvertimeChoiceLook {
        let input: [String: Any] = [
            "choice": RulebookJSON.orNull(choice?.json),
            "booking": RulebookJSON.orNull(booking?.json),
            "organization": organization,
            "timeZone": overtimeTimeZone,
            "role": role,
        ]
        return RulebookJSON.decode(OvertimeChoiceLook.self, from: callJSON("overtimeChoiceView", arguments: [input])) ?? .idle
    }

    /// `OVERTIME_PERSON_CHOICE_LABELS` / `OVERTIME_DECIDER_LABELS` (`tick`, `cross`, `changed`, `needsMark`).
    nonisolated static func overtimeChoiceLabels(role: String) -> [String: String] {
        constant(role == "decider" ? "OVERTIME_DECIDER_LABELS" : "OVERTIME_PERSON_CHOICE_LABELS", as: [String: String].self) ?? [:]
    }

    /// `overtimeSubmitReady({ lines, choices })`: Send for approval is green (every line marked, something to send).
    nonisolated static func overtimeSubmitReady(lines: [OvertimeLine], choices: [String: OvertimeChoice]) -> OvertimeButtonReadiness {
        guard let payload = RulebookJSON.object(lines) else { return .notReady }
        let input: [String: Any] = ["lines": payload, "choices": choicesJSON(choices)]
        return RulebookJSON.decode(OvertimeButtonReadiness.self, from: callJSON("overtimeSubmitReady", arguments: [input])) ?? .notReady
    }

    /// `overtimeSubmitLines({ lines, choices, bookings, organization, timeZone, personIds })`: the request lines Send for
    /// approval writes (raw, as stored) and the lines refused. Empty when not ready.
    nonisolated static func overtimeSubmitLines(
        lines: [OvertimeLine],
        choices: [String: OvertimeChoice],
        bookings: [OvertimeBookingInput],
        organization: [String: Any],
        personIds: [String]
    ) -> (lines: [[String: Any]], refused: [String]) {
        guard let payload = RulebookJSON.object(lines) else { return ([], []) }
        let input: [String: Any] = [
            "lines": payload,
            "choices": choicesJSON(choices),
            "bookings": bookings.map(\.json),
            "organization": organization,
            "timeZone": overtimeTimeZone,
            "personIds": personIds,
        ]
        guard let row = callJSON("overtimeSubmitLines", arguments: [input]) as? [String: Any] else { return ([], []) }
        return (row["lines"] as? [[String: Any]] ?? [], row["refused"] as? [String] ?? [])
    }

    /// `overtimeGenerateReady({ lines, hasLineManager, choices, reports })`: Generate overtime report is green.
    /// `reports` are the saved reports of exactly this range.
    nonisolated static func overtimeGenerateReady(
        lines: [OvertimeLine],
        hasLineManager: Bool,
        choices: [String: OvertimeChoice],
        reports: [OvertimeReportRecord]
    ) -> OvertimeButtonReadiness {
        guard let payload = RulebookJSON.object(lines) else { return .notReady }
        let input: [String: Any] = [
            "lines": payload,
            "hasLineManager": hasLineManager,
            "choices": choicesJSON(choices),
            "reports": reports.map(\.raw),
        ]
        return RulebookJSON.decode(OvertimeButtonReadiness.self, from: callJSON("overtimeGenerateReady", arguments: [input])) ?? .notReady
    }

    /// `overtimeReportOutOfDate({ report, lines })`: the saved report no longer matches the live lines of its range.
    nonisolated static func overtimeReportOutOfDate(_ report: OvertimeReportRecord, lines: [OvertimeLine]) -> Bool {
        guard let payload = RulebookJSON.object(lines) else { return report.storedOutOfDate }
        let input: [String: Any] = ["report": report.raw, "lines": payload]
        return callJSON("overtimeReportOutOfDate", arguments: [input]) as? Bool ?? report.storedOutOfDate
    }

    /// `hasActiveLineManager(person, roster)`.
    nonisolated static func overtimeHasActiveLineManager(person: [String: Any], roster: [[String: Any]]) -> Bool {
        callJSON("hasActiveLineManager", arguments: [person, roster]) as? Bool ?? false
    }

    /// `overtimeBookingFingerprint(booking)`.
    nonisolated static func overtimeBookingFingerprint(_ booking: OvertimeBookingInput) -> String {
        callJSON("overtimeBookingFingerprint", arguments: [booking.json]) as? String ?? ""
    }

    /// `overtimeLineIsStale(storedFingerprint, booking)`.
    nonisolated static func overtimeLineIsStale(storedFingerprint: String, booking: OvertimeBookingInput?) -> Bool {
        callJSON("overtimeLineIsStale", arguments: [storedFingerprint, RulebookJSON.orNull(booking?.json)]) as? Bool ?? true
    }

    /// `overtimeBookingIsTheirs(booking, personIds)`.
    nonisolated static func overtimeBookingIsTheirs(_ booking: OvertimeBookingInput, personIds: [String]) -> Bool {
        callJSON("overtimeBookingIsTheirs", arguments: [booking.json, personIds]) as? Bool ?? false
    }

    // MARK: The red X, the cog and the rate

    /// `overtimeStrikeOutcome`.
    nonisolated static func overtimeStrikeOutcome(_ booking: OvertimeBookingInput, organization: [String: Any]) -> OvertimeStrikeOutcome? {
        let input: [String: Any] = ["booking": booking.json, "organization": organization, "timeZone": overtimeTimeZone]
        return RulebookJSON.decode(OvertimeStrikeOutcome.self, from: callJSON("overtimeStrikeOutcome", arguments: [input]))
    }

    /// `overtimeCogPreview`.
    nonisolated static func overtimeCogPreview(
        _ booking: OvertimeBookingInput,
        organization: [String: Any],
        start: String,
        end: String,
        multiplier: Double?
    ) -> OvertimeCogPreview? {
        let input: [String: Any] = [
            "booking": booking.json,
            "organization": organization,
            "timeZone": overtimeTimeZone,
            "start": start,
            "end": end,
            "multiplier": RulebookJSON.orNull(multiplier),
        ]
        return RulebookJSON.decode(OvertimeCogPreview.self, from: callJSON("overtimeCogPreview", arguments: [input]))
    }

    /// `overtimeRateControl`: Edit Booking's "Overtime rate".
    nonisolated static func overtimeRateControl(_ booking: OvertimeBookingInput, organization: [String: Any]) -> OvertimeRateControl? {
        let input: [String: Any] = ["booking": booking.json, "organization": organization, "timeZone": overtimeTimeZone]
        return RulebookJSON.decode(OvertimeRateControl.self, from: callJSON("overtimeRateControl", arguments: [input]))
    }

    /// `overtimeMultiplierValidationError(value)`: nil for the organisation rate (nil) or a valid custom rate.
    nonisolated static func overtimeMultiplierValidationError(_ value: Double?) -> String? {
        callJSON("overtimeMultiplierValidationError", arguments: [RulebookJSON.orNull(value)]) as? String
    }

    /// `overtimeMultiplierWriteFields(stored, next)`: `set` / `remove` for Edit Booking's rate.
    nonisolated static func overtimeMultiplierWriteFields(stored: Double?, next: Double?) -> (set: [String: Any], remove: [String])? {
        guard let row = callJSON(
            "overtimeMultiplierWriteFields",
            arguments: [RulebookJSON.orNull(stored), RulebookJSON.orNull(next)]
        ) as? [String: Any] else { return nil }
        return (row["set"] as? [String: Any] ?? [:], row["remove"] as? [String] ?? [])
    }

    /// `organizationOvertimeMultiplier(org, dayKey, timeZone)`.
    nonisolated static func organizationOvertimeMultiplier(_ organization: [String: Any], dayKey: String) -> Double? {
        (callJSON("organizationOvertimeMultiplier", arguments: [organization, dayKey, overtimeTimeZone]) as? NSNumber)?.doubleValue
    }

    /// `OVERTIME_MULTIPLIER_STEPS`: 1, 1.25 … 3.
    nonisolated static var overtimeMultiplierSteps: [Double] {
        constant("OVERTIME_MULTIPLIER_STEPS", as: [Double].self) ?? []
    }

    // MARK: Who

    /// `canEditOwnBookingOvertime`: `direct` | `request` | `none`. 1.32.0: `editableUntilKey` (`overtimeEditableUntil`,
    /// the last day of the current PAYE payrun) wins over `todayKey`; `person` (the PAYE person, `RulebookPeople.person`)
    /// and `roster` make own edits requests when the person has an active line manager.
    nonisolated static func canEditOwnBookingOvertime(
        viewer: JobAccessViewer?,
        isPaye: Bool,
        booking: [String: Any],
        job: [String: Any]?,
        managers: [[String: Any]],
        todayKey: String,
        editableUntilKey: String?,
        person: [String: Any],
        roster: [[String: Any]]
    ) -> OvertimeEditMode {
        let input: [String: Any] = [
            "viewer": RulebookJSON.orNull(viewer?.json),
            "isPaye": isPaye,
            "booking": booking,
            "job": RulebookJSON.orNull(job),
            "managers": managers,
            "todayKey": todayKey,
            "editableUntilKey": RulebookJSON.orNull(editableUntilKey),
            "person": person,
            "roster": roster,
        ]
        let raw = callJSON("canEditOwnBookingOvertime", arguments: [input]) as? String ?? "none"
        return OvertimeEditMode(rawValue: raw) ?? .readOnly
    }

    /// `overtimeEditableUntil(organization, todayKey)`: the last day a PAYE person may tick, cross or change (the end of
    /// the current PAYE payrun; today when no payday is set).
    nonisolated static func overtimeEditableUntil(_ organization: [String: Any], todayKey: String) -> String {
        callJSON("overtimeEditableUntil", arguments: [organization, todayKey]) as? String ?? todayKey
    }

    /// `overtimePersonIds({ person, roster, operatives })`: every id the person goes by plus every `operatives` row on
    /// their email (all records for this person: overtime loading, sending and approving, price work and expenses).
    /// `operatives` rows are `{ id, email }`. Empty when the script did not answer.
    nonisolated static func overtimePersonIds(person: [String: Any], roster: [[String: Any]], operatives: [[String: Any]]) -> [String] {
        let input: [String: Any] = ["person": person, "roster": roster, "operatives": operatives]
        return callJSON("overtimePersonIds", arguments: [input]) as? [String] ?? []
    }

    /// `canDecideOvertimeRequest(viewer, requester, roster)`.
    nonisolated static func canDecideOvertimeRequest(viewer: [String: Any], requester: [String: Any], roster: [[String: Any]]) -> Bool {
        callJSON("canDecideOvertimeRequest", arguments: [viewer, requester, roster]) as? Bool ?? false
    }

    /// `overtimeUserSubjects(viewer, roster)`.
    nonisolated static func overtimeUserSubjects(viewer: [String: Any], roster: [[String: Any]]) -> [String] {
        callJSON("overtimeUserSubjects", arguments: [viewer, roster]) as? [String] ?? []
    }

    /// `overtimeHubAccess({ viewer, roster })`.
    nonisolated static func overtimeHubAccess(viewer: [String: Any]?, roster: [[String: Any]]) -> OvertimeHubAccess {
        let input: [String: Any] = ["viewer": RulebookJSON.orNull(viewer), "roster": roster]
        return RulebookJSON.decode(OvertimeHubAccess.self, from: callJSON("overtimeHubAccess", arguments: [input])) ?? .hidden
    }

    /// `isAdminOutsideOperativeMode(person)`.
    nonisolated static func overtimeDeciderIsAdmin(_ person: [String: Any]) -> Bool {
        callJSON("isAdminOutsideOperativeMode", arguments: [person]) as? Bool ?? false
    }

    // MARK: Requests

    /// `overtimeRequestLineFields`: one request line (the raw shape to store, and its typed view), or nil.
    nonisolated static func overtimeRequestLineFields(
        _ booking: OvertimeBookingInput,
        organization: [String: Any],
        proposal: OvertimeAction,
        personIds: [String]?
    ) -> (raw: [String: Any], line: OvertimeRequestLine)? {
        var input: [String: Any] = [
            "booking": booking.json,
            "organization": organization,
            "timeZone": overtimeTimeZone,
            "proposal": proposal.proposalJSON,
        ]
        if let personIds { input["personIds"] = personIds }
        guard let raw = callJSON("overtimeRequestLineFields", arguments: [input]) as? [String: Any],
              let line = RulebookJSON.decode(OvertimeRequestLine.self, from: raw) else { return nil }
        return (raw, line)
    }

    /// `overtimeRequestWriteFields`: the new `overtimeRequests/{id}` fields (the app adds `createdAt` and metadata).
    nonisolated static func overtimeRequestWriteFields(
        userId: String,
        rangeStart: String,
        rangeEnd: String,
        lines: [[String: Any]],
        personIds: [String],
        bookings: [OvertimeBookingInput]
    ) -> [String: Any]? {
        let input: [String: Any] = [
            "userId": userId,
            "rangeStart": rangeStart,
            "rangeEnd": rangeEnd,
            "lines": lines,
            "personIds": personIds,
            "bookings": bookings.map(\.json),
        ]
        return callJSON("overtimeRequestWriteFields", arguments: [input]) as? [String: Any]
    }

    /// `overtimeRequestsToReplace(requests, userId, rangeStart, rangeEnd)`.
    nonisolated static func overtimeRequestsToReplace(
        _ requests: [OvertimeRequestRecord],
        userId: String,
        rangeStart: String,
        rangeEnd: String
    ) -> [String] {
        callJSON("overtimeRequestsToReplace", arguments: [requests.map(\.raw), userId, rangeStart, rangeEnd]) as? [String] ?? []
    }

    /// `overtimeRequestWithdrawWriteFields(request)`.
    nonisolated static func overtimeRequestWithdrawWriteFields(_ request: OvertimeRequestRecord) -> [String: Any]? {
        callJSON("overtimeRequestWithdrawWriteFields", arguments: [request.raw]) as? [String: Any]
    }

    /// `overtimeRequestsSuperseded(requests, userId, bookingIds)` (1.33.0): the person's pending requests a new Send for
    /// approval withdraws (every line still waiting is sent again).
    nonisolated static func overtimeRequestsSuperseded(_ requests: [OvertimeRequestRecord], userId: String, bookingIds: [String]) -> [String] {
        callJSON("overtimeRequestsSuperseded", arguments: [requests.map(\.raw), userId, bookingIds]) as? [String] ?? []
    }

    /// `overtimeLineOutcomeLabel(outcome)`: "Changed since they sent it — …", "Can't read this booking — …", …; nil for a
    /// returned line or no outcome. 1.33.0: no "Needs an admin".
    nonisolated static func overtimeLineOutcomeLabel(_ outcome: String?) -> String? {
        callJSON("overtimeLineOutcomeLabel", arguments: [RulebookJSON.orNull(outcome)]) as? String
    }

    nonisolated static func decisionsJSON(_ decisions: [String: OvertimeAction]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in decisions { out[key] = value.decisionJSON }
        return out
    }

    /// `overtimeReturnReady({ request, decisions, skipBookingIds })` (1.33.0): Return overtime is green once every waiting
    /// line is decided. `skipBookingIds`: lines the decider cannot read or that are not the requester's.
    nonisolated static func overtimeReturnReady(
        _ request: OvertimeRequestRecord,
        decisions: [String: OvertimeAction],
        skipBookingIds: [String]
    ) -> OvertimeButtonReadiness {
        let input: [String: Any] = ["request": request.raw, "decisions": decisionsJSON(decisions), "skipBookingIds": skipBookingIds]
        return RulebookJSON.decode(OvertimeButtonReadiness.self, from: callJSON("overtimeReturnReady", arguments: [input])) ?? .notReady
    }

    /// `overtimeReturnWrites` (1.33.0 Return): everything one transaction writes. `bookings` maps a request line's booking
    /// id to the live booking; a missing entry is a deleted booking. Tombstones say `deletedFrom: "ios"`.
    nonisolated static func overtimeReturnWrites(
        request: OvertimeRequestRecord,
        decisions: [String: OvertimeAction],
        bookings: [String: OvertimeBookingInput],
        organization: [String: Any],
        deciderId: String,
        requesterIds: [String],
        unreadableBookingIds: [String]
    ) -> OvertimeReturnPlan? {
        var live: [String: Any] = [:]
        for (key, value) in bookings { live[key] = value.json }
        let input: [String: Any] = [
            "request": request.raw,
            "decisions": decisionsJSON(decisions),
            "bookings": live,
            "organization": organization,
            "timeZone": overtimeTimeZone,
            "deciderId": deciderId,
            "requesterIds": requesterIds,
            "unreadableBookingIds": unreadableBookingIds,
            "platform": "ios",
        ]
        return OvertimeReturnPlan(callJSON("overtimeReturnWrites", arguments: [input]))
    }

    /// `overtimeDirectWrites`: a direct tick, cross or cog by a PAYE admin or a manager who may edit the booking.
    nonisolated static func overtimeDirectWrites(
        _ booking: OvertimeBookingInput,
        action: OvertimeAction,
        userId: String,
        reviewerId: String,
        organization: [String: Any]
    ) -> OvertimeDirectPlan? {
        let input: [String: Any] = [
            "booking": booking.json,
            "action": action.decisionJSON,
            "userId": userId,
            "reviewerId": reviewerId,
            "organization": organization,
            "timeZone": overtimeTimeZone,
            // 1.33.0: the tombstone of a red X delete says where it was made.
            "platform": "ios",
        ]
        return OvertimeDirectPlan(callJSON("overtimeDirectWrites", arguments: [input]))
    }

    /// `overtimeDeciderMayWriteBooking({ booking, requesterUserId, requesterIds })` (1.33.0: every id of the requester).
    nonisolated static func overtimeDeciderMayWriteBooking(
        _ booking: OvertimeBookingInput,
        requesterUserId: String,
        requesterIds: [String]
    ) -> Bool {
        let input: [String: Any] = [
            "booking": ["id": booking.id, "personId": booking.personId],
            "requesterUserId": requesterUserId,
            "requesterIds": requesterIds,
        ]
        return callJSON("overtimeDeciderMayWriteBooking", arguments: [input]) as? Bool ?? false
    }

    // MARK: Readers

    /// `parseOvertimeRequestDocument(docId, data)` (Firestore values already made JSON).
    nonisolated static func parseOvertimeRequestDocument(docId: String, data: [String: Any]) -> OvertimeRequestRecord? {
        OvertimeRequestRecord(raw: callJSON("parseOvertimeRequestDocument", arguments: [docId, data]))
    }

    /// `parseOvertimeReviewDocument(docId, data)`.
    nonisolated static func parseOvertimeReviewDocument(docId: String, data: [String: Any]) -> OvertimeReviewRecord? {
        OvertimeReviewRecord(raw: callJSON("parseOvertimeReviewDocument", arguments: [docId, data]))
    }

    /// `parseOvertimeReportDocument(docId, data)`.
    nonisolated static func parseOvertimeReportDocument(docId: String, data: [String: Any]) -> OvertimeReportRecord? {
        OvertimeReportRecord(raw: callJSON("parseOvertimeReportDocument", arguments: [docId, data]))
    }

    // MARK: Notifications (§13)

    /// `overtimeRequestRecipients(requester, roster)`.
    nonisolated static func overtimeRequestRecipients(requester: Any, roster: [[String: Any]]) -> [String]? {
        callJSON("overtimeRequestRecipients", arguments: [requester, roster]) as? [String]
    }

    /// `overtimeReturnedRecipients(requester, decider, roster)` (1.33.0): the requester, unless they decided.
    nonisolated static func overtimeReturnedRecipients(requester: Any, decider: Any, roster: [[String: Any]]) -> [String]? {
        callJSON("overtimeReturnedRecipients", arguments: [requester, decider, roster]) as? [String]
    }

    /// `overtimeDeciderIsLineManager(decider, requester, roster)`: the decider is one of the requester's line managers.
    nonisolated static func overtimeDeciderIsLineManager(decider: Any, requester: [String: Any], roster: [[String: Any]]) -> Bool {
        callJSON("overtimeDeciderIsLineManager", arguments: [decider, requester, roster]) as? Bool ?? false
    }

    /// `overtimeReturnedMessage({ deciderName, deciderIsLineManager })`: "Your line manager {name} has returned your
    /// overtime request" (an admin: "{name} has returned your overtime request").
    nonisolated static func overtimeReturnedMessage(deciderName: String?, deciderIsLineManager: Bool) -> OvertimeNotice? {
        let input: [String: Any] = ["deciderName": RulebookJSON.orNull(deciderName), "deciderIsLineManager": deciderIsLineManager]
        return RulebookJSON.decode(OvertimeNotice.self, from: callJSON("overtimeReturnedMessage", arguments: [input]))
    }

    /// `overtimeRequestSubmittedMessage({ requesterName, rangeStart, rangeEnd })`.
    nonisolated static func overtimeRequestSubmittedMessage(requesterName: String?, rangeStart: String, rangeEnd: String) -> OvertimeNotice? {
        let input: [String: Any] = ["requesterName": RulebookJSON.orNull(requesterName), "rangeStart": rangeStart, "rangeEnd": rangeEnd]
        return RulebookJSON.decode(OvertimeNotice.self, from: callJSON("overtimeRequestSubmittedMessage", arguments: [input]))
    }

    /// `overtimeLineReopened({ before, after, organization, timeZone, reviews, requests })`: a booking change reopens an
    /// overtime line; `returned` when a Return had decided it. `reviews` / `requests` nil when the editor cannot read them.
    nonisolated static func overtimeLineReopened(
        before: OvertimeBookingInput,
        after: OvertimeBookingInput?,
        organization: [String: Any],
        reviews: [OvertimeReviewRecord]?,
        requests: [OvertimeRequestRecord]?
    ) -> (reopened: Bool, returned: Bool) {
        let input: [String: Any] = [
            "before": before.json,
            "after": RulebookJSON.orNull(after?.json),
            "organization": organization,
            "timeZone": overtimeTimeZone,
            "reviews": RulebookJSON.orNull(reviews?.map(\.raw)),
            "requests": RulebookJSON.orNull(requests?.map(\.raw)),
        ]
        guard let row = callJSON("overtimeLineReopened", arguments: [input]) as? [String: Any] else { return (false, false) }
        return (row["reopened"] as? Bool ?? false, row["returned"] as? Bool ?? false)
    }

    /// `overtimeReopenedRecipients({ bookedId, actor, roster, operatives, returned })`: the booked PAYE person (and their
    /// line managers when the line had been returned), never the editor.
    nonisolated static func overtimeReopenedRecipients(
        bookedId: String,
        actor: Any,
        roster: [[String: Any]],
        operatives: [[String: Any]],
        returned: Bool
    ) -> [String] {
        let input: [String: Any] = ["bookedId": bookedId, "actor": actor, "roster": roster, "operatives": operatives, "returned": returned]
        return callJSON("overtimeReopenedRecipients", arguments: [input]) as? [String] ?? []
    }

    /// `overtimeReopenedMessage({ dayKey, jobNumber, forLineManager, personName })`.
    nonisolated static func overtimeReopenedMessage(dayKey: String, jobNumber: String?, forLineManager: Bool, personName: String?) -> OvertimeNotice? {
        let input: [String: Any] = [
            "dayKey": dayKey,
            "jobNumber": RulebookJSON.orNull(jobNumber),
            "forLineManager": forLineManager,
            "personName": RulebookJSON.orNull(personName),
        ]
        return RulebookJSON.decode(OvertimeNotice.self, from: callJSON("overtimeReopenedMessage", arguments: [input]))
    }

    /// `overtimeNotificationRange({ organization, todayKey, rangeStart, rangeEnd, dayKey })`: the payrun an overtime
    /// notice opens. Nil when nothing usable is given.
    nonisolated static func overtimeNotificationRange(
        organization: [String: Any],
        todayKey: String,
        rangeStart: String?,
        rangeEnd: String?,
        dayKey: String?
    ) -> OvertimeNotificationRange? {
        let input: [String: Any] = [
            "organization": organization,
            "todayKey": todayKey,
            "rangeStart": RulebookJSON.orNull(rangeStart),
            "rangeEnd": RulebookJSON.orNull(rangeEnd),
            "dayKey": RulebookJSON.orNull(dayKey),
        ]
        return RulebookJSON.decode(OvertimeNotificationRange.self, from: callJSON("overtimeNotificationRange", arguments: [input]))
    }

    /// `bookingHoursChangedRecipients(owner, jobManagerIds, roster)`.
    nonisolated static func bookingHoursChangedRecipients(owner: Any, jobManagerIds: [String], roster: [[String: Any]]) -> [String]? {
        callJSON("bookingHoursChangedRecipients", arguments: [owner, jobManagerIds, roster]) as? [String]
    }

    /// `jobManagerIds(job)`.
    nonisolated static func overtimeJobManagerIds(_ job: [String: Any]?) -> [String] {
        callJSON("jobManagerIds", arguments: [RulebookJSON.orNull(job)]) as? [String] ?? []
    }

    // MARK: Reports

    /// `overtimeReportSnapshot`: the saved copy's fields (the app adds `generatedAt` and metadata).
    nonisolated static func overtimeReportSnapshot(
        userId: String,
        userName: String,
        companyName: String,
        rangeStart: String,
        rangeEnd: String,
        lines: [OvertimeLine],
        generatedBy: String
    ) -> [String: Any]? {
        guard let encoded = RulebookJSON.object(lines) else { return nil }
        let input: [String: Any] = [
            "userId": userId,
            "userName": userName,
            "companyName": companyName,
            "rangeStart": rangeStart,
            "rangeEnd": rangeEnd,
            "lines": encoded,
            "generatedBy": generatedBy,
        ]
        return callJSON("overtimeReportSnapshot", arguments: [input]) as? [String: Any]
    }

    /// `overtimeReportRows(snapshot, { timeZone, generatedByName, nowMs })` (1.33.0: header, table, total, footer and
    /// the out-of-date mark). `generatedByName` names the generator when the roster knows them.
    nonisolated static func overtimeReportRows(_ snapshot: [String: Any], generatedByName: String? = nil, now: Date = Date()) -> OvertimeReportRows? {
        let options: [String: Any] = [
            "timeZone": overtimeTimeZone,
            "generatedByName": RulebookJSON.orNull(generatedByName),
            "nowMs": now.timeIntervalSince1970 * 1000,
        ]
        return RulebookJSON.decode(OvertimeReportRows.self, from: callJSON("overtimeReportRows", arguments: [snapshot, options]))
    }

    /// `reportGeneratedText({ generatedAtMs, nowMs, timeZone, generatedBy, userId, userName, generatedByName })`:
    /// "6 Nov 2026, 14:05 by Sam Smith" in the organisation zone (`generated`), and its parts.
    nonisolated static func reportGeneratedText(
        generatedAtMs: Double?,
        generatedBy: String?,
        userId: String?,
        userName: String?,
        generatedByName: String? = nil,
        now: Date? = Date()
    ) -> (generatedAt: String, generatedBy: String, generated: String) {
        let input: [String: Any] = [
            "generatedAtMs": RulebookJSON.orNull(generatedAtMs),
            "nowMs": RulebookJSON.orNull(now.map { $0.timeIntervalSince1970 * 1000 }),
            "timeZone": overtimeTimeZone,
            "generatedBy": RulebookJSON.orNull(generatedBy),
            "userId": RulebookJSON.orNull(userId),
            "userName": RulebookJSON.orNull(userName),
            "generatedByName": RulebookJSON.orNull(generatedByName),
        ]
        let row = callJSON("reportGeneratedText", arguments: [input]) as? [String: Any] ?? [:]
        return (row["generatedAt"] as? String ?? "", row["generatedBy"] as? String ?? "", row["generated"] as? String ?? "")
    }

    // MARK: Weekly report (§7)

    /// `weeklyReportPayeDay(person, dayKey, timeZone)`: the person is PAYE on that day, so it leaves the hours and pay rows.
    nonisolated static func weeklyReportPayeDay(employment: [String: Any], dayKey: String) -> Bool {
        callJSON("weeklyReportPayeDay", arguments: [employment, dayKey, overtimeTimeZone]) as? Bool ?? false
    }

    /// `OVERTIME_RATE_CHANGED_MARK` (1.32.0 §7): the weekly report's mark on a row whose multiplier was changed from the
    /// organisation rate. Nil when the script did not answer.
    nonisolated static var overtimeRateChangedMark: String? {
        constant("OVERTIME_RATE_CHANGED_MARK", as: String.self)
    }

    /// `weeklyReportPayeOvertime`: one row per PAYE person, job and multiplier, live from the bookings (1.32.0: each
    /// row carries its multiplier, `multiplierText`, and `changedFromOrganization`; `label` includes both).
    nonisolated static func weeklyReportPayeOvertime(
        people: [[String: Any]],
        bookings: [OvertimeBookingInput],
        organization: [String: Any],
        range: (start: String, end: String)
    ) -> [WeeklyReportPayeOvertimeRow] {
        let input: [String: Any] = [
            "people": people,
            "bookings": bookings.map(\.json),
            "organization": organization,
            "timeZone": overtimeTimeZone,
            "range": ["start": range.start, "end": range.end],
        ]
        return RulebookJSON.decode([WeeklyReportPayeOvertimeRow].self, from: callJSON("weeklyReportPayeOvertime", arguments: [input])) ?? []
    }
}

// MARK: - App rows → rulebook inputs

extension AppUser {
    /// The employment fields `employmentTypeOnDay` / `weeklyReportPayeDay` read (`EmploymentTypeUser`).
    var overtimeEmploymentPayload: [String: Any] {
        [
            "employmentType": employmentType.rawValue,
            "employmentTypeTransitionFrom": RulebookJSON.orNull(employmentTypeTransitionFrom?.rawValue),
            "employmentTypeEffectiveAt": RulebookJSON.orNull(employmentTypeEffectiveAt.map { CanonicalBusinessEngine.isoString(from: $0) }),
        ]
    }

    /// PAYE today (the stored employment type, as web `isPaye`).
    var isPayeEmployment: Bool { employmentType == .paye }
}

/// Booking rows → `OvertimeBookingInput`, through the rulebook booking readers (`parseBookingDocument`,
/// `parseManagerSiteBookingDocument`). Job number and name come from the loaded jobs.
nonisolated enum OvertimeBookingInputs {
    /// A labour booking document read by `parseBookingDocument`.
    static func labour(_ row: CanonicalBusinessEngine.CanonicalParsedBooking) -> OvertimeBookingInput {
        OvertimeBookingInput(
            id: row.id,
            collection: "bookings",
            personId: row.operativeId,
            dayKey: OrganizationRulebookContext.dayKey(Date(timeIntervalSince1970: row.dateMs / 1000)),
            timeSlot: row.timeSlot,
            workStartTime: row.workStartTime,
            workEndTime: row.workEndTime,
            isBreakRemoved: row.isBreakRemoved,
            otMultiplierOverride: row.otMultiplierOverride,
            status: row.status,
            jobId: row.projectId
        )
    }

    /// Manager site booking documents read by `parseManagerSiteBookingDocument` (with its 1.29.0
    /// `otMultiplierOverride`), keyed by nothing: one input per accepted document.
    static func managerSite(documents: [[String: Any]]) -> [OvertimeBookingInput] {
        var out: [OvertimeBookingInput] = []
        for document in documents {
            guard let id = document["id"] as? String, let data = document["data"] else { continue }
            guard let answer = CanonicalBusinessEngine.callJSON("parseManagerSiteBookingDocument", arguments: [id, data]) as? [String: Any],
                  answer["ok"] as? Bool == true,
                  let booking = answer["booking"] as? [String: Any],
                  let userId = booking["userId"] as? String,
                  let dateMs = (booking["dateMs"] as? NSNumber)?.doubleValue else { continue }
            out.append(
                OvertimeBookingInput(
                    id: id,
                    collection: "managerSiteBookings",
                    personId: userId,
                    dayKey: OrganizationRulebookContext.dayKey(Date(timeIntervalSince1970: dateMs / 1000)),
                    timeSlot: booking["timeSlot"] as? String,
                    workStartTime: booking["workStartTime"] as? String,
                    workEndTime: booking["workEndTime"] as? String,
                    isBreakRemoved: booking["isBreakRemoved"] as? Bool ?? false,
                    otMultiplierOverride: (booking["otMultiplierOverride"] as? NSNumber)?.doubleValue,
                    status: nil,
                    jobId: booking["locationId"] as? String
                )
            )
        }
        return out
    }

    /// `parseManagerSiteBookingDocument`'s `otMultiplierOverride` per document id (1.29.0), for the in-app manager site
    /// booking rows. Documents without one are absent.
    static func managerSiteRates(documents: [[String: Any]]) -> [String: Double] {
        var out: [String: Double] = [:]
        for booking in managerSite(documents: documents) {
            if let rate = booking.otMultiplierOverride { out[booking.id] = rate }
        }
        return out
    }

    /// An in-app labour booking (from `BookingStore`).
    @MainActor static func labour(_ booking: Booking) -> OvertimeBookingInput {
        OvertimeBookingInput(
            id: booking.documentKey,
            collection: "bookings",
            personId: booking.storedOperativeId,
            dayKey: OrganizationRulebookContext.dayKey(booking.date),
            timeSlot: booking.timeSlot.rawValue,
            workStartTime: booking.workStartTime,
            workEndTime: booking.workEndTime,
            isBreakRemoved: booking.isBreakRemoved,
            otMultiplierOverride: booking.otMultiplierOverride,
            status: booking.status.rawValue,
            jobId: booking.storedProjectId
        )
    }

    /// An in-app manager site booking (from `ManagerScheduleStore`).
    @MainActor static func managerSite(_ booking: ManagerSiteBooking) -> OvertimeBookingInput {
        OvertimeBookingInput(
            id: booking.documentKey,
            collection: "managerSiteBookings",
            personId: booking.userId,
            dayKey: OrganizationRulebookContext.dayKey(booking.date),
            timeSlot: booking.timeSlot.rawValue,
            workStartTime: booking.workStartTime,
            workEndTime: booking.workEndTime,
            isBreakRemoved: booking.isBreakRemoved,
            otMultiplierOverride: booking.otMultiplierOverride,
            status: nil,
            jobId: booking.storedLocationId
        )
    }

    /// Fills job number and name from the loaded jobs (by stored id, any case).
    @MainActor static func withJobs(_ rows: [OvertimeBookingInput], jobs: [Project]) -> [OvertimeBookingInput] {
        var byId: [String: Project] = [:]
        for job in jobs {
            byId[job.documentId.lowercased()] = job
            byId[job.id.uuidString.lowercased()] = job
        }
        return rows.map { row in
            var next = row
            if let key = row.jobId?.lowercased(), let job = byId[key] {
                next.jobNumber = job.jobNumber
                next.jobName = job.siteName
            }
            return next
        }
    }
}
