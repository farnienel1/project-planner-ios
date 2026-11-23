//
//  Rulebook+TimesheetMakeChanges.swift
//  Project Planner
//
//  RULEBOOK 1.76.0 §8 (owner decisions 23 Nov, A1 and B1; web `lib/canonical/timesheetMakeChanges.ts`). The reviewer's
//  "Make changes" button: on a signed-off, unexported sheet it opens ⚙ / ✕ on the labour lines (nothing written until a
//  booking is changed); on an exported sheet it creates the next revision; on an open revision the person has not
//  signed yet, the reviewer may change its bookings. Swift only builds the script's inputs and reads its answers.
//

import Foundation

/// `timesheetMakeChangesAction` → what the button does, or nil when it is not shown.
nonisolated enum RulebookTimesheetMakeChangesAction: String, Hashable, Sendable {
    case reopenReview
    case createRevision
}

extension CanonicalBusinessEngine {
    private nonisolated static func makeChangesText(_ name: String, fallback: String) -> String {
        constant(name, as: String.self) ?? fallback
    }

    /// `TIMESHEET_MAKE_CHANGES_LABEL`.
    nonisolated static var timesheetMakeChangesLabel: String {
        makeChangesText("TIMESHEET_MAKE_CHANGES_LABEL", fallback: "Make changes")
    }

    /// `TIMESHEET_MAKE_CHANGES_ACTIVE_NOTE`.
    nonisolated static var timesheetMakeChangesActiveNote: String {
        makeChangesText(
            "TIMESHEET_MAKE_CHANGES_ACTIVE_NOTE",
            fallback: "Making changes: use ⚙ to change a booking or ✕ to remove it. The timesheet stays signed off until you change something; then sign it off again."
        )
    }

    /// `TIMESHEET_MAKE_CHANGES_CANCEL_LABEL`.
    nonisolated static var timesheetMakeChangesCancelLabel: String {
        makeChangesText("TIMESHEET_MAKE_CHANGES_CANCEL_LABEL", fallback: "Stop making changes")
    }

    /// `TIMESHEET_REVISION_REVIEWER_EDIT_NOTE`.
    nonisolated static var timesheetRevisionReviewerEditNote: String {
        makeChangesText(
            "TIMESHEET_REVISION_REVIEWER_EDIT_NOTE",
            fallback: "You can change or remove this revision\u{2019}s bookings with ⚙ and ✕ before the person signs it."
        )
    }

    /// RULEBOOK 1.76.0 `timesheetMakeChangesAction(sheet, input)`. `sheet` is `TimesheetDraftStore.statusPayload(for:)`
    /// (signatures, `exportedAt`, `invoiceGeneratedAt`). Nil when the script did not answer (no button; fail closed).
    nonisolated static func timesheetMakeChangesAction(
        sheet: [String: Any],
        viewerIsReviewer: Bool,
        viewerIsSubject: Bool,
        selfSigned: Bool,
        reopened: Bool,
        revisionAllowed: Bool
    ) -> RulebookTimesheetMakeChangesAction? {
        let input: [String: Any] = [
            "viewerIsReviewer": viewerIsReviewer,
            "viewerIsSubject": viewerIsSubject,
            "selfSigned": selfSigned,
            "change": ["reopened": reopened],
            "revisionAllowed": revisionAllowed,
        ]
        guard let raw = callJSON("timesheetMakeChangesAction", arguments: [sheet, input]) as? String else { return nil }
        return RulebookTimesheetMakeChangesAction(rawValue: raw)
    }

    /// RULEBOOK 1.76.0 `timesheetMakeChangesHelp(action)`: the text under the button ('' when none).
    nonisolated static func timesheetMakeChangesHelp(_ action: RulebookTimesheetMakeChangesAction?) -> String {
        guard let action else { return "" }
        return callJSON("timesheetMakeChangesHelp", arguments: [action.rawValue]) as? String ?? ""
    }

    /// RULEBOOK 1.76.0 `timesheetRevisionReviewerMayEditBookings(sheet, input)`: `sheet` is the status payload plus
    /// `revision` / `revisionOf`. False when the script did not answer.
    nonisolated static func timesheetRevisionReviewerMayEditBookings(
        sheet: [String: Any],
        viewerIsReviewer: Bool,
        viewerIsSubject: Bool
    ) -> Bool {
        let input: [String: Any] = ["viewerIsReviewer": viewerIsReviewer, "viewerIsSubject": viewerIsSubject]
        return callJSON("timesheetRevisionReviewerMayEditBookings", arguments: [sheet, input]) as? Bool ?? false
    }
}
