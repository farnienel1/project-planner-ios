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

    /// `TIMESHEET_MAKE_CHANGES_OLD_SHEET_HELP` (review of #427, finding 1).
    nonisolated static var timesheetMakeChangesOldSheetHelp: String {
        makeChangesText(
            "TIMESHEET_MAKE_CHANGES_OLD_SHEET_HELP",
            fallback: "This timesheet was signed before 14 Nov. Export it, then use Make changes to correct it in a revision."
        )
    }

    private nonisolated static func makeChangesInput(
        viewerIsReviewer: Bool,
        viewerIsSubject: Bool,
        selfSigned: Bool,
        reopened: Bool,
        revisionAllowed: Bool
    ) -> [String: Any] {
        [
            "viewerIsReviewer": viewerIsReviewer,
            "viewerIsSubject": viewerIsSubject,
            "selfSigned": selfSigned,
            "change": ["reopened": reopened],
            "revisionAllowed": revisionAllowed,
        ]
    }

    /// RULEBOOK 1.76.0 `timesheetMakeChangesAction(sheet, input)`. `sheet` is `TimesheetDraftStore.statusPayload(for:)`
    /// (signatures, `exportedAt`, `invoiceGeneratedAt`) plus the signed copy (`weeklyReportOverride.lines` with
    /// `bookingFingerprint`, `isLeave`, `isPayeDay`, `reviewPartOf`; review of #427). Nil when the script did not answer
    /// (no button; fail closed).
    nonisolated static func timesheetMakeChangesAction(
        sheet: [String: Any],
        viewerIsReviewer: Bool,
        viewerIsSubject: Bool,
        selfSigned: Bool,
        reopened: Bool,
        revisionAllowed: Bool
    ) -> RulebookTimesheetMakeChangesAction? {
        let input = makeChangesInput(
            viewerIsReviewer: viewerIsReviewer, viewerIsSubject: viewerIsSubject, selfSigned: selfSigned,
            reopened: reopened, revisionAllowed: revisionAllowed
        )
        guard let raw = callJSON("timesheetMakeChangesAction", arguments: [sheet, input]) as? String else { return nil }
        return RulebookTimesheetMakeChangesAction(rawValue: raw)
    }

    /// RULEBOOK 1.76.0 `timesheetMakeChangesHelp(action)`: the text under the button ('' when none).
    nonisolated static func timesheetMakeChangesHelp(_ action: RulebookTimesheetMakeChangesAction?) -> String {
        guard let action else { return "" }
        return callJSON("timesheetMakeChangesHelp", arguments: [action.rawValue]) as? String ?? ""
    }

    /// RULEBOOK 1.76.0 `timesheetMakeChangesHelp(null, sheet, input)` (review of #427, finding 1): on a signed-off sheet
    /// whose signed copy cannot tell a changed booking, `TIMESHEET_MAKE_CHANGES_OLD_SHEET_HELP`; otherwise ''.
    nonisolated static func timesheetMakeChangesHelpWithoutAction(
        sheet: [String: Any],
        viewerIsReviewer: Bool,
        viewerIsSubject: Bool,
        selfSigned: Bool,
        reopened: Bool
    ) -> String {
        let input = makeChangesInput(
            viewerIsReviewer: viewerIsReviewer, viewerIsSubject: viewerIsSubject, selfSigned: selfSigned,
            reopened: reopened, revisionAllowed: false
        )
        return callJSON("timesheetMakeChangesHelp", arguments: [NSNull(), sheet, input]) as? String ?? ""
    }

    /// RULEBOOK 1.76.0 `timesheetRevisionReviewerMayEditBookings(sheet, input)`: `sheet` is the status payload plus
    /// `revision` and `revisionOf` (review of #427, finding 9). False when the script did not answer.
    nonisolated static func timesheetRevisionReviewerMayEditBookings(
        sheet: [String: Any],
        viewerIsReviewer: Bool,
        viewerIsSubject: Bool
    ) -> Bool {
        let input: [String: Any] = ["viewerIsReviewer": viewerIsReviewer, "viewerIsSubject": viewerIsSubject]
        return callJSON("timesheetRevisionReviewerMayEditBookings", arguments: [sheet, input]) as? Bool ?? false
    }
}
