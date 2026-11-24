//
//  Rulebook+TimesheetRevisionDraft.swift
//  Project Planner
//
//  RULEBOOK 1.90.0 §8 (owner request 24 Nov, point 4; web `lib/canonical/timesheetRevisionDraft.ts`). A revision a
//  reviewer creates starts as a DRAFT held with them: the person is never offered Sign (the security rules refuse
//  their write too); the reviewer changes its bookings with ⚙ / ✕, then presses "Save changes and send timesheet to …"
//  (grey until the draft holds a change, then blue) or the red "Cancel revision". Swift only builds the script's
//  inputs and reads its answers — every word and test is the rulebook's (AGENTS.md Rule 0).
//

import Foundation

/// `timesheetRevisionDraftState` → what a screen shows for a draft revision.
nonisolated struct RulebookTimesheetRevisionDraftState: Equatable, Sendable {
    let draft: Bool
    /// The viewer is the reviewer who may send or cancel it.
    let reviewerActs: Bool
    let changeCount: Int
    let bookingEdits: Int
    /// Send is enabled (blue).
    let canSend: Bool
    let canCancel: Bool
    /// False while a draft: never offer Sign to the person.
    let personMaySign: Bool
    let sendLabel: String
    let help: String?
    let cancelLabel: String
    let personMessage: String?

    /// Not a draft (and what a screen shows when the script did not answer for a sheet that is not stored as a draft).
    static let notDraft = RulebookTimesheetRevisionDraftState(
        draft: false, reviewerActs: false, changeCount: 0, bookingEdits: 0, canSend: false, canCancel: false,
        personMaySign: true, sendLabel: "", help: nil, cancelLabel: "", personMessage: nil
    )

    init(
        draft: Bool, reviewerActs: Bool, changeCount: Int, bookingEdits: Int, canSend: Bool, canCancel: Bool,
        personMaySign: Bool, sendLabel: String, help: String?, cancelLabel: String, personMessage: String?
    ) {
        self.draft = draft
        self.reviewerActs = reviewerActs
        self.changeCount = changeCount
        self.bookingEdits = bookingEdits
        self.canSend = canSend
        self.canCancel = canCancel
        self.personMaySign = personMaySign
        self.sendLabel = sendLabel
        self.help = help
        self.cancelLabel = cancelLabel
        self.personMessage = personMessage
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any], let draft = row["draft"] as? Bool else { return nil }
        let changes = row["changes"] as? [String: Any] ?? [:]
        self.init(
            draft: draft,
            reviewerActs: row["reviewerActs"] as? Bool ?? false,
            changeCount: (changes["count"] as? NSNumber)?.intValue ?? 0,
            bookingEdits: (changes["bookingEdits"] as? NSNumber)?.intValue ?? 0,
            canSend: row["canSend"] as? Bool ?? false,
            canCancel: row["canCancel"] as? Bool ?? false,
            personMaySign: row["personMaySign"] as? Bool ?? !draft,
            sendLabel: row["sendLabel"] as? String ?? "",
            help: row["help"] as? String,
            cancelLabel: row["cancelLabel"] as? String ?? "",
            personMessage: row["personMessage"] as? String
        )
    }
}

extension CanonicalBusinessEngine {
    private nonisolated static func draftText(_ name: String, fallback: String) -> String {
        constant(name, as: String.self) ?? fallback
    }

    /// `TIMESHEET_REVISION_DRAFT_FIELD` (`revisionDraft`).
    nonisolated static var timesheetRevisionDraftField: String {
        draftText("TIMESHEET_REVISION_DRAFT_FIELD", fallback: "revisionDraft")
    }

    /// `TIMESHEET_REVISION_DRAFT_REFUSED_MESSAGE` — the person's write refused while the revision is a draft.
    nonisolated static var timesheetRevisionDraftRefusedMessage: String {
        draftText(
            "TIMESHEET_REVISION_DRAFT_REFUSED_MESSAGE",
            fallback: "This revision is still being prepared by your line manager. You can sign it once they send it to you."
        )
    }

    /// `TIMESHEET_REVISION_DRAFT_SENT_MESSAGE`.
    nonisolated static var timesheetRevisionDraftSentMessage: String {
        draftText("TIMESHEET_REVISION_DRAFT_SENT_MESSAGE", fallback: "Sent. They have been told the revision is ready to sign.")
    }

    /// `TIMESHEET_REVISION_DRAFT_CANCELLED_MESSAGE`.
    nonisolated static var timesheetRevisionDraftCancelledMessage: String {
        draftText("TIMESHEET_REVISION_DRAFT_CANCELLED_MESSAGE", fallback: "Revision cancelled.")
    }

    /// RULEBOOK 1.90.0 `timesheetRevisionIsDraft(sheet)`. Fail closed for the person: a sheet stored with
    /// `revisionDraft: true` reads as a draft when the script does not answer.
    nonisolated static func timesheetRevisionIsDraft(_ sheet: [String: Any]) -> Bool {
        if let answer = callJSON("timesheetRevisionIsDraft", arguments: [sheet]) as? Bool { return answer }
        return sheet["revisionDraft"] as? Bool == true
    }

    /// RULEBOOK 1.90.0 `timesheetRevisionDraftState(input)`. `sheet` carries `revision`, `revisionDraft`, the export
    /// stamps and `reviewerBookingEdits`; `previous` the version it corrects (nil: only booking edits count). When the
    /// script does not answer on a sheet stored as a draft, nobody may send and the person may not sign (fail closed).
    nonisolated static func timesheetRevisionDraftState(
        sheet: [String: Any],
        previous: [String: Any]? = nil,
        viewerIsReviewer: Bool,
        viewerIsSubject: Bool,
        personName: String?,
        revisionLabel: String?
    ) -> RulebookTimesheetRevisionDraftState {
        let input: [String: Any] = [
            "sheet": sheet,
            "previous": previous.map { $0 as Any } ?? NSNull(),
            "viewerIsReviewer": viewerIsReviewer,
            "viewerIsSubject": viewerIsSubject,
            "personName": RulebookJSON.orNull(personName),
            "revisionLabel": RulebookJSON.orNull(revisionLabel),
        ]
        if let state = RulebookTimesheetRevisionDraftState(json: callJSON("timesheetRevisionDraftState", arguments: [input])) {
            return state
        }
        guard sheet["revisionDraft"] as? Bool == true else { return .notDraft }
        return RulebookTimesheetRevisionDraftState(
            draft: true, reviewerActs: false, changeCount: 0, bookingEdits: 0, canSend: false, canCancel: false,
            personMaySign: false, sendLabel: "", help: nil, cancelLabel: "", personMessage: timesheetRevisionDraftRefusedMessage
        )
    }

    /// RULEBOOK 1.90.0 `timesheetRevisionDraftSendWriteFields(sheet)` → the fields to delete (`revisionDraft`); nil when
    /// the sheet is no longer a draft (nothing to write).
    nonisolated static func timesheetRevisionDraftSendRemovedFields(_ sheet: [String: Any]) -> [String]? {
        guard let row = callJSON("timesheetRevisionDraftSendWriteFields", arguments: [sheet]) as? [String: Any] else { return nil }
        return row["remove"] as? [String]
    }

    /// RULEBOOK 1.90.0 `timesheetRevisionCancelConfirmMessage(revisionLabel, changeCount)`.
    nonisolated static func timesheetRevisionCancelConfirmMessage(revisionLabel: String?, changeCount: Int) -> String {
        callJSON("timesheetRevisionCancelConfirmMessage", arguments: [RulebookJSON.orNull(revisionLabel), changeCount]) as? String
            ?? "Cancel this revision? The revision is deleted and nothing is sent."
    }
}
