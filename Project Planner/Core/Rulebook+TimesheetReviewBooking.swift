//
//  Rulebook+TimesheetReviewBooking.swift
//  Project Planner
//
//  RULEBOOK 1.71.0 / 1.72.0 §8 (owner decisions 23 Nov, issue 22A, A and B; web
//  `lib/canonical/timesheetReviewBookingWrites.ts`, `timesheetPeriod.ts`). A line manager's ✓ ✕ ⚙ on a timesheet line
//  under review: none once the sheet is exported (`timesheetLineReviewActionsAllowed`); ⚙ changes the BOOKING
//  (`timesheetReviewBookingEditWrites`, `timesheetReviewOvertimeRate`); ✕ on the standard line deletes the booking with
//  its tombstone (`timesheetReviewBookingDelete` after `timesheetReviewDeleteBookingWarning`); ✕ on the overtime line
//  trims it to its standard part (`timesheetReviewOvertimeStrike`). Swift only builds the script's inputs and reads its
//  answers; nothing is decided here.
//

import Foundation

// MARK: - Script shapes

/// `timesheetLabourLineReviewActions` → which of ✓ ✕ ⚙ one labour line offers.
nonisolated struct RulebookTimesheetLabourLineReviewActions: Hashable, Sendable {
    var approve: Bool
    var removeBooking: Bool
    var editBooking: Bool

    static let none = RulebookTimesheetLabourLineReviewActions(approve: false, removeBooking: false, editBooking: false)
}

/// `timesheetReviewBookingEditWrites` → a partial update of the booking, or why it cannot be written (the wrapper
/// returns nil when the script did not answer).
nonisolated enum RulebookTimesheetReviewBookingEdit {
    /// `set` / `remove` as the script gave them (the app adds write metadata). `changed` false: nothing to write.
    case write(collection: String, bookingId: String, set: [String: Any], remove: [String], changed: Bool)
    case refused(String)
}

/// `timesheetReviewBookingDelete` → the booking delete and its tombstone (the app adds the server `deletedAt`).
nonisolated struct RulebookTimesheetReviewBookingDelete {
    var collection: String
    var bookingId: String
    var tombstone: [String: Any]
}

/// `timesheetReviewDeleteBookingWarning` → the confirm shown before ✕ deletes a booking.
nonisolated struct RulebookTimesheetReviewDeleteWarning: Hashable, Sendable {
    var title: String
    var summary: String
    var message: String
    var overtimeNote: String?
    var undoNote: String
    var confirmLabel: String
    var cancelLabel: String
}

/// `timesheetReviewOvertimeStrike` → ✕ on an overtime line.
nonisolated enum RulebookTimesheetReviewOvertimeStrike {
    /// Trim to the standard part: confirm with this copy, then write `set` / `remove` (times and slot only).
    case trim(collection: String, bookingId: String, set: [String: Any], remove: [String], warning: RulebookTimesheetReviewDeleteWarning)
    /// No standard part: only the delete (with `overtimeLine: true`).
    case delete
    case refused(String)
}

// MARK: - Script calls

extension CanonicalBusinessEngine {
    private nonisolated static func reviewBookingText(_ name: String, fallback: String) -> String {
        constant(name, as: String.self) ?? fallback
    }

    /// `TIMESHEET_REVIEW_EDIT_BOOKING_NOTE`.
    nonisolated static var timesheetReviewEditBookingNote: String {
        reviewBookingText(
            "TIMESHEET_REVIEW_EDIT_BOOKING_NOTE",
            fallback: "Saving changes the booking itself, so scheduling, daily Overview and the weekly report show the new hours. You can keep reviewing; the person sees the change when you counter-sign."
        )
    }

    /// `TIMESHEET_REVIEW_BOOKING_SENT_BACK_MESSAGE` — 1.72.0 copy, kept for older builds only (1.74.0 screens show
    /// `timesheetReviewBookingUpdatedMessage` / `timesheetReviewBookingNotRecordedMessage`).
    nonisolated static var timesheetReviewBookingSentBackMessage: String {
        reviewBookingText(
            "TIMESHEET_REVIEW_BOOKING_SENT_BACK_MESSAGE",
            fallback: "Booking updated. The timesheet has gone back to the person to review and sign again."
        )
    }

    /// `TIMESHEET_REVIEW_BOOKING_REFUSED_MESSAGE` (a permission-denied booking write).
    nonisolated static var timesheetReviewBookingRefusedMessage: String {
        reviewBookingText(
            "TIMESHEET_REVIEW_BOOKING_REFUSED_MESSAGE",
            fallback: "You can't change this booking from the timesheet. Ask an admin or the job's manager to change it in projects or small works."
        )
    }

    /// `TIMESHEET_REVIEW_BOOKING_MISSING_MESSAGE` (the booking was deleted elsewhere).
    nonisolated static var timesheetReviewBookingMissingMessage: String {
        reviewBookingText("TIMESHEET_REVIEW_BOOKING_MISSING_MESSAGE", fallback: "This booking was deleted on another device.")
    }

    /// RULEBOOK 1.71.0 `timesheetLineReviewActionsAllowed(sheet)`: false once the sheet is exported
    /// (`resolveTimesheetExportedAtMs`, so pass `exportedAt` and `invoiceGeneratedAt`). False when the script did not
    /// answer (an exported sheet is read-only; fail closed).
    nonisolated static func timesheetLineReviewActionsAllowed(_ sheet: [String: Any]) -> Bool {
        callJSON("timesheetLineReviewActionsAllowed", arguments: [sheet]) as? Bool ?? false
    }

    /// RULEBOOK 1.72.0 `timesheetLabourLineReviewActions({ sheet, line })`. `.none` when the script did not answer.
    nonisolated static func timesheetLabourLineReviewActions(
        sheet: [String: Any],
        bookingId: String?,
        bookingCollection: String?,
        isPayeDay: Bool,
        isLeave: Bool
    ) -> RulebookTimesheetLabourLineReviewActions {
        let line: [String: Any] = [
            "bookingId": RulebookJSON.orNull(bookingId),
            "bookingCollection": RulebookJSON.orNull(bookingCollection),
            "isPayeDay": isPayeDay,
            "isLeave": isLeave,
        ]
        guard let row = callJSON("timesheetLabourLineReviewActions", arguments: [["sheet": sheet, "line": line]]) as? [String: Any] else {
            return RulebookTimesheetLabourLineReviewActions.none
        }
        return RulebookTimesheetLabourLineReviewActions(
            approve: row["approve"] as? Bool ?? false,
            removeBooking: row["removeBooking"] as? Bool ?? false,
            editBooking: row["editBooking"] as? Bool ?? false
        )
    }

    // `timesheetReviewOvertimeRate` (a rate nobody changed is never written; back to the organisation's rate removes a
    // stored override) runs inside `timesheetReviewBookingEditWrites` through its `overtimeRate` input. It is not
    // wrapped on its own: the JSON bridge reads both its "leave" (undefined) and "remove" (null) answers as nil.

    /// RULEBOOK 1.72.0 `timesheetReviewBookingEditWrites({ booking, startTime, endTime, isBreakRemoved, overtimeRate,
    /// slotWindow, timeZone })`. `booking` is the live stored document (`FirebaseBackend.firestoreJSON`) with `id` and
    /// `collection`. `overtimeRate` only on an overtime line (`typed` the rate box on save, `opened` what it showed,
    /// `organizationMultiplier` the organisation's rate that day). `slotWindow` is the times the editor opened with.
    nonisolated static func timesheetReviewBookingEditWrites(
        booking: [String: Any],
        startTime: String,
        endTime: String,
        isBreakRemoved: Bool,
        overtimeRate: (typed: Double?, opened: Double?, organizationMultiplier: Double?)?,
        slotWindow: (start: String, end: String)?
    ) -> RulebookTimesheetReviewBookingEdit? {
        var input: [String: Any] = [
            "booking": booking,
            "startTime": startTime,
            "endTime": endTime,
            "isBreakRemoved": isBreakRemoved,
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
        ]
        if let overtimeRate {
            input["overtimeRate"] = [
                "typed": RulebookJSON.orNull(overtimeRate.typed),
                "opened": RulebookJSON.orNull(overtimeRate.opened),
                "organizationMultiplier": RulebookJSON.orNull(overtimeRate.organizationMultiplier),
            ]
        }
        if let slotWindow { input["slotWindow"] = ["start": slotWindow.start, "end": slotWindow.end] }
        guard let row = callJSON("timesheetReviewBookingEditWrites", arguments: [input]) as? [String: Any] else { return nil }
        guard row["ok"] as? Bool == true,
              let collection = row["collection"] as? String,
              let bookingId = row["bookingId"] as? String else {
            return .refused(row["error"] as? String ?? timesheetReviewBookingMissingMessage)
        }
        return .write(
            collection: collection,
            bookingId: bookingId,
            set: row["set"] as? [String: Any] ?? [:],
            remove: row["remove"] as? [String] ?? [],
            changed: row["changed"] as? Bool ?? false
        )
    }

    /// RULEBOOK 1.72.0 `timesheetReviewBookingDelete({ booking, deletedBy, platform: 'ios' })`. Nil for unusable ids.
    nonisolated static func timesheetReviewBookingDelete(
        bookingId: String,
        collection: String,
        deletedBy: String
    ) -> RulebookTimesheetReviewBookingDelete? {
        let input: [String: Any] = [
            "booking": ["id": bookingId, "collection": collection],
            "deletedBy": deletedBy,
            "platform": "ios",
        ]
        guard let row = callJSON("timesheetReviewBookingDelete", arguments: [input]) as? [String: Any],
              let collection = row["collection"] as? String,
              let bookingId = row["bookingId"] as? String,
              let tombstone = row["tombstone"] as? [String: Any] else { return nil }
        return RulebookTimesheetReviewBookingDelete(collection: collection, bookingId: bookingId, tombstone: tombstone)
    }

    /// RULEBOOK 1.72.0 `timesheetReviewDeleteBookingWarning({ summary, overtimeLine })`. Nil when the script did not
    /// answer (the delete is then not offered).
    nonisolated static func timesheetReviewDeleteBookingWarning(summary: String, overtimeLine: Bool) -> RulebookTimesheetReviewDeleteWarning? {
        let input: [String: Any] = ["summary": summary, "overtimeLine": overtimeLine]
        guard let row = callJSON("timesheetReviewDeleteBookingWarning", arguments: [input]) as? [String: Any] else { return nil }
        return reviewWarning(row)
    }

    /// RULEBOOK 1.72.0 `timesheetReviewOvertimeStrike({ booking, organization, timeZone, summary })`. `booking` is the
    /// live stored document with `id`, `collection` and `dayKey`; `organization` the working-hours state
    /// (`OvertimeOrganizationDocument.document`).
    nonisolated static func timesheetReviewOvertimeStrike(
        booking: [String: Any],
        organization: [String: Any],
        summary: String
    ) -> RulebookTimesheetReviewOvertimeStrike? {
        let input: [String: Any] = [
            "booking": booking,
            "organization": organization,
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
            "summary": summary,
        ]
        guard let row = callJSON("timesheetReviewOvertimeStrike", arguments: [input]) as? [String: Any] else { return nil }
        switch row["kind"] as? String {
        case "trim":
            guard let collection = row["collection"] as? String, let bookingId = row["bookingId"] as? String,
                  let warning = reviewWarning(row) else { return nil }
            return .trim(
                collection: collection,
                bookingId: bookingId,
                set: row["set"] as? [String: Any] ?? [:],
                remove: row["remove"] as? [String] ?? [],
                warning: warning
            )
        case "delete":
            return .delete
        default:
            return .refused(row["error"] as? String ?? timesheetReviewBookingMissingMessage)
        }
    }

    private nonisolated static func reviewWarning(_ row: [String: Any]) -> RulebookTimesheetReviewDeleteWarning? {
        guard let title = row["title"] as? String, let message = row["message"] as? String,
              let confirm = row["confirmLabel"] as? String, let cancel = row["cancelLabel"] as? String else { return nil }
        return RulebookTimesheetReviewDeleteWarning(
            title: title,
            summary: row["summary"] as? String ?? "",
            message: message,
            overtimeNote: row["overtimeNote"] as? String,
            undoNote: row["undoNote"] as? String ?? "",
            confirmLabel: confirm,
            cancelLabel: cancel
        )
    }
}
