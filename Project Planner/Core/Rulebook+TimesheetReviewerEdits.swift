//
//  Rulebook+TimesheetReviewerEdits.swift
//  Project Planner
//
//  RULEBOOK 1.74.0 §8 / §16 (owner decision 23 Nov; web `lib/canonical/timesheetBookingChanges.ts`,
//  `timesheetReviewBookingWrites.ts`, `timesheetLineDisplay.ts`).
//
//  1. The line manager makes as many ⚙ / ✕ changes as they like before counter-signing: every reviewer booking write
//     from the review also records `reviewerBookingEdits.{key}` on the sheet in the SAME batch
//     (`timesheetReviewerBookingEditRecord`, the booking as left by `timesheetReviewBookingAfterEdit` of
//     `timesheetReviewBookingDocument`). `signedTimesheetBookingChanges` then reads that booking as no change for the
//     person while their signature is current.
//  2. Lines are shown booking by booking (A, A overtime, B, B overtime) and a booking's empty 0h / £0 standard line is
//     not shown when it has an overtime line (`timesheetLineDisplayOrder`, `timesheetLineIsEmptyStandardPart`).
//
//  Swift only builds the script's inputs and reads its answers; nothing is decided here.
//

import Foundation
import FirebaseFirestore

/// `timesheetReviewerBookingEditRecord` → what to write at `reviewerBookingEdits.{key}` (the app adds `editedAt`).
nonisolated struct RulebookTimesheetReviewerBookingEdit {
    var key: String
    /// The record as the script gave it (`bookingId`, `collection`, `fingerprint`, `place`, `deleted`, `editedBy`,
    /// `forSignedAtMs`). Plain JSON values only.
    var value: [String: Any]
}

extension CanonicalBusinessEngine {
    private nonisolated static func reviewerEditText(_ name: String, fallback: String) -> String {
        constant(name, as: String.self) ?? fallback
    }

    /// `TIMESHEET_REVIEWER_BOOKING_EDITS_FIELD` (`reviewerBookingEdits`).
    nonisolated static var timesheetReviewerBookingEditsField: String {
        reviewerEditText("TIMESHEET_REVIEWER_BOOKING_EDITS_FIELD", fallback: "reviewerBookingEdits")
    }

    /// `TIMESHEET_REVIEW_BOOKING_UPDATED_MESSAGE` — after a reviewer's ⚙ / ✕ (the sheet stays with the reviewer).
    nonisolated static var timesheetReviewBookingUpdatedMessage: String {
        reviewerEditText(
            "TIMESHEET_REVIEW_BOOKING_UPDATED_MESSAGE",
            fallback: "Booking updated. Keep reviewing — the person sees the changes when you counter-sign."
        )
    }

    /// `TIMESHEET_REVIEW_BOOKING_NOT_RECORDED_MESSAGE` — the booking was saved but the signed, stored, unexported sheet
    /// could not record it, so it really has gone back to the person.
    nonisolated static var timesheetReviewBookingNotRecordedMessage: String {
        reviewerEditText(
            "TIMESHEET_REVIEW_BOOKING_NOT_RECORDED_MESSAGE",
            fallback: "Booking updated, but the timesheet could not record it, so it has gone back to the person to sign again."
        )
    }

    /// RULEBOOK 1.74.0 `timesheetReviewBookingDocument({ collection, id, data, timeZone })`: the stored booking (read
    /// fresh, `FirebaseBackend.firestoreJSON`) in the rulebook's document shape. Nil when it cannot be read.
    nonisolated static func timesheetReviewBookingDocument(collection: String, id: String, data: [String: Any]) -> [String: Any]? {
        var stored = data
        stored.removeValue(forKey: "id")
        stored.removeValue(forKey: "collection")
        let input: [String: Any] = [
            "collection": collection,
            "id": id,
            "data": stored,
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
        ]
        return callJSON("timesheetReviewBookingDocument", arguments: [input]) as? [String: Any]
    }

    /// RULEBOOK 1.74.0 `timesheetReviewBookingAfterEdit(before, { set, remove })`: the booking as the write leaves it.
    /// `set` values the script gave (NSNull for a removed override). Nil when the script did not answer.
    nonisolated static func timesheetReviewBookingAfterEdit(before: [String: Any], set: [String: Any], remove: [String]) -> [String: Any]? {
        callJSON("timesheetReviewBookingAfterEdit", arguments: [before, ["set": set, "remove": remove]]) as? [String: Any]
    }

    /// RULEBOOK 1.74.0 `timesheetReviewerBookingEditRecord({ sheet, booking, after, deleted, editedBy })`. `sheet` is
    /// the draft's status payload (`SignedTimesheetChangeInputs.sheet`: `operativeSignedAt` as epoch ms, `exportedAt`).
    /// Nil when there is nothing to record (not signed by the person, exported, unusable id) or the script did not answer.
    nonisolated static func timesheetReviewerBookingEditRecord(
        sheet: [String: Any],
        collection: String,
        bookingId: String,
        after: [String: Any]?,
        deleted: Bool,
        editedBy: String
    ) -> RulebookTimesheetReviewerBookingEdit? {
        let input: [String: Any] = [
            "sheet": sheet,
            "booking": ["collection": collection, "bookingId": bookingId],
            "after": after.map { $0 as Any } ?? NSNull(),
            "deleted": deleted,
            "editedBy": editedBy,
        ]
        guard let row = callJSON("timesheetReviewerBookingEditRecord", arguments: [input]) as? [String: Any],
              let key = row["key"] as? String, !key.isEmpty,
              let value = row["value"] as? [String: Any] else { return nil }
        return RulebookTimesheetReviewerBookingEdit(key: key, value: value)
    }

    /// RULEBOOK 1.74.0 `timesheetLineDisplayOrder(lines)`: the indexes of `rows` in the order a timesheet shows them,
    /// the empty standard part of an all-overtime booking left out. Each row must carry `__index`. The bridge cannot pass
    /// the `effectiveAmount` / `day` functions, so callers put the effective amount in `amount` (what the function reads
    /// without one) and a named slot's resolved clock window in `details` (what `day` would give). Nil when the script
    /// did not answer.
    nonisolated static func timesheetLineDisplayOrder(_ rows: [[String: Any]]) -> [Int]? {
        guard let ordered = callJSON("timesheetLineDisplayOrder", arguments: [rows]) as? [[String: Any]] else { return nil }
        let indexes = ordered.compactMap { ($0["__index"] as? NSNumber)?.intValue }
        return indexes.count == ordered.count ? indexes : nil
    }
}

/// RULEBOOK 1.74.0 §8: one line as `timesheetLineDisplayOrder` reads it (`TimesheetLineOrderInput`).
nonisolated struct TimesheetLineOrderInput {
    var id: String
    /// The line's booking id as the line holds it (`op-…` / `mgr-…` / bare); nil when it names no booking.
    var bookingId: String?
    var bookingCollection: String?
    var date: Date
    var isOvertimeLine: Bool
    var paidHours: Double
    /// The effective amount (a larger edited review counts; a signed row is never hidden).
    var amount: Double
    var bookingStartTime: String?
    var bookingEndTime: String?
    var details: String
}

/// RULEBOOK 1.74.0 §8: orders any list of timesheet lines with the rulebook's `timesheetLineDisplayOrder`. Display only:
/// figures keep reading every line. When the script does not answer, the list is shown as given (never hidden).
enum TimesheetLineDisplayOrder {
    static func ordered<T>(_ items: [T], input: (T) -> TimesheetLineOrderInput) -> [T] {
        guard items.count > 0 else { return items }
        let rows: [[String: Any]] = items.enumerated().map { index, item in
            row(input(item), index: index)
        }
        guard let indexes = CanonicalBusinessEngine.timesheetLineDisplayOrder(rows) else { return items }
        return indexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    /// The collector's lines in display order. `effectiveAmount` (optional) is the amount a review would pay.
    static func payrollLines(
        _ lines: [TimesheetPayrollLineItem],
        effectiveAmount: ((TimesheetPayrollLineItem) -> Double)? = nil
    ) -> [TimesheetPayrollLineItem] {
        ordered(lines) { line in
            TimesheetLineOrderInput(
                id: line.id,
                bookingId: line.bookingId,
                bookingCollection: line.bookingCollection,
                date: line.date,
                isOvertimeLine: line.isOvertimeLine,
                paidHours: line.paidHours,
                amount: effectiveAmount?(line) ?? line.amount,
                bookingStartTime: line.bookingStartTime,
                bookingEndTime: line.bookingEndTime,
                details: line.details
            )
        }
    }

    /// The collector's lines in display order for a sheet: a line an edited review would pay (`payrollLineReview`
    /// `edited`, revised amount larger than the line's) is never hidden (web `TimesheetPeriodPage` `effectiveAmount`).
    static func payrollLines(_ lines: [TimesheetPayrollLineItem], draft: TimesheetDraft) -> [TimesheetPayrollLineItem] {
        payrollLines(lines) { line in
            // Only a 0h / £0 standard line can be hidden; every other line keeps its own amount (no script call).
            guard !line.isOvertimeLine, abs(line.amount) <= 0.0001 else { return line.amount }
            let review = TimesheetDraftAdjustments.payrollReview(in: draft, lineId: line.id, live: line)
            guard review?.decision == .edited, let revised = review?.revisedAmount else { return line.amount }
            return max(line.amount, revised)
        }
    }

    private static func row(_ line: TimesheetLineOrderInput, index: Int) -> [String: Any] {
        var row: [String: Any] = [
            "__index": index,
            "id": line.id,
            "dayKey": OrganizationRulebookContext.dayKey(line.date),
            "isOvertimeLine": line.isOvertimeLine,
            "paidHours": line.paidHours.isFinite ? line.paidHours : 0,
            "amount": line.amount.isFinite ? line.amount : 0,
            "details": resolvedDetails(line),
        ]
        let collection = (line.bookingCollection?.isEmpty == false)
            ? line.bookingCollection!
            : (line.id.hasPrefix("mgr-") || (line.bookingId?.hasPrefix("mgr-") ?? false) ? "managerSiteBookings" : "bookings")
        if let id = SignedTimesheetChangeInputs.storedBookingId(line.bookingId, keys: [:]) {
            row["bookingId"] = id
            row["bookingCollection"] = collection
        }
        if let start = line.bookingStartTime, !start.isEmpty { row["bookingStartTime"] = start }
        if let end = line.bookingEndTime, !end.isEmpty { row["bookingEndTime"] = end }
        return row
    }

    /// A Full day / AM / PM line with no clock times reads its window on that day (`timesheetLineDisplay` with the
    /// working hours in effect), so it sorts by its clock start as web's `day` option gives it.
    private static func resolvedDetails(_ line: TimesheetLineOrderInput) -> String {
        if line.bookingStartTime?.isEmpty == false { return line.details }
        if line.details.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return line.details }
        guard let display = CanonicalBusinessEngine.timesheetLineDisplay(
            jobNumber: "",
            projectName: "",
            details: line.details,
            date: line.date
        ), display.times.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil else { return line.details }
        return display.times
    }
}

/// RULEBOOK 1.74.0 §8: the sheet's `reviewerBookingEdits` map, read only (never written from a draft save:
/// `TIMESHEET_REVIEWER_ONLY_FIELDS`; the owner path drops it and the rules refuse the person's write).
enum TimesheetReviewerBookingEdits {
    /// The stored map as JSON text, every Firestore instant as epoch ms (the rulebook compares numbers). Nil when the
    /// sheet has none.
    static func jsonText(fromStoredSheet sheet: [String: Any]) -> String? {
        guard let map = sheet[CanonicalBusinessEngine.timesheetReviewerBookingEditsField] as? [String: Any], !map.isEmpty else {
            return nil
        }
        let json = plain(map)
        guard JSONSerialization.isValidJSONObject(json), let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The draft's map as plain JSON for the rulebook's `sheet` input; NSNull when there is none.
    static func stored(_ draft: TimesheetDraft) -> Any {
        guard let text = draft.reviewerBookingEditsJSON, let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return value
    }

    /// `draft` with one record added at once (the local copy, before the listener echoes the server's).
    static func adding(_ edit: RulebookTimesheetReviewerBookingEdit, to draft: inout TimesheetDraft) {
        var map = (stored(draft) as? [String: Any]) ?? [:]
        map[edit.key] = edit.value
        guard JSONSerialization.isValidJSONObject(map), let data = try? JSONSerialization.data(withJSONObject: map) else { return }
        draft.reviewerBookingEditsJSON = String(data: data, encoding: .utf8)
    }

    private static func plain(_ value: Any) -> Any {
        switch value {
        case let timestamp as Timestamp:
            return timestamp.dateValue().timeIntervalSince1970 * 1000
        case let date as Date:
            return date.timeIntervalSince1970 * 1000
        case let map as [String: Any]:
            return map.mapValues { plain($0) }
        case let list as [Any]:
            return list.map { plain($0) }
        default:
            return FirebaseBackend.firestoreJSON(value)
        }
    }
}

/// RULEBOOK 1.74.0 §8: builds what a reviewer's ⚙ / ✕ / overtime trim records on the sheet under review, and the notice
/// shown after the write (web `TimesheetPeriodPage` `afterReviewBookingWrite`).
enum TimesheetReviewerEditRecorder {
    /// The record for one booking write. `booking` is the live stored booking read fresh
    /// (`FirebaseBackend.readTimesheetReviewBooking`: its fields plus `id` / `collection`); `write` its partial update
    /// (`set` / `remove`), or nil for a delete. Nil when the sheet is not stored, not signed by the person, exported, or the
    /// script did not answer — the booking is then written alone.
    static func record(
        draft: TimesheetDraft,
        collection: String,
        bookingId: String,
        booking: [String: Any]?,
        write: (set: [String: Any], remove: [String])?,
        editedBy: String
    ) -> TimesheetReviewerEditSheetRecord? {
        guard let documentId = draft.versionDocumentId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !documentId.isEmpty, !documentId.contains("/") else { return nil }
        var after: [String: Any]? = nil
        if let write {
            guard let booking,
                  let before = CanonicalBusinessEngine.timesheetReviewBookingDocument(collection: collection, id: bookingId, data: booking),
                  let edited = CanonicalBusinessEngine.timesheetReviewBookingAfterEdit(before: before, set: write.set, remove: write.remove)
            else { return nil }
            after = edited
        }
        guard let edit = CanonicalBusinessEngine.timesheetReviewerBookingEditRecord(
            sheet: SignedTimesheetChangeInputs.sheet(draft, keys: [:]),
            collection: collection,
            bookingId: bookingId,
            after: after,
            deleted: write == nil,
            editedBy: editedBy
        ) else { return nil }
        return TimesheetReviewerEditSheetRecord(sheetDocumentId: documentId, edit: edit)
    }

    /// Review of #276: a copy read before 1.55.0 (`ensureVersionRead`) gives the version it came from; only that and the
    /// stored reviewer edits are taken over, never the rest of the read (the reviewer's unsaved decisions stay).
    static func takeVersion(from read: TimesheetDraft, into draft: inout TimesheetDraft) {
        guard draft.versionDocumentId == nil, let id = read.versionDocumentId, !id.isEmpty else { return }
        draft.versionDocumentId = id
        draft.revision = read.revision
        draft.originalStoredUserId = draft.originalStoredUserId ?? read.originalStoredUserId
        draft.reviewerBookingEditsJSON = read.reviewerBookingEditsJSON
    }

    /// After the write: `TIMESHEET_REVIEW_BOOKING_UPDATED_MESSAGE`, or — when nothing was recorded and the person has
    /// signed a sheet that is not exported (review of #276: whether or not this copy knows its stored document, since a
    /// copy read before 1.55.0 has no id) — `TIMESHEET_REVIEW_BOOKING_NOT_RECORDED_MESSAGE`.
    static func notice(recorded: Bool, draft: TimesheetDraft) -> String {
        if recorded { return CanonicalBusinessEngine.timesheetReviewBookingUpdatedMessage }
        let reopens = draft.operativeSignedAt != nil && !TimesheetLateExtrasSupport.exportedStored(draft)
        return reopens ? CanonicalBusinessEngine.timesheetReviewBookingNotRecordedMessage : CanonicalBusinessEngine.timesheetReviewBookingUpdatedMessage
    }
}
