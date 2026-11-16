//
//  Rulebook+TimesheetRevisions.swift
//  Project Planner
//
//  RULEBOOK 1.55.0 §8, §13, §16 (owner decisions 16 Nov; web `lib/canonical/timesheetRevisions.ts`): timesheet
//  revisions — REV 1, REV 2, …. An exported timesheet never changes. After export a booking change makes a revision
//  due (`timesheetRevisionDue`, derived); "Review and sign again" (the person) or "Create revision" (an admin or the
//  line manager) creates `settings/{original id}_rev{N}`; it is signed like any sheet and exported as REV N.
//  Typed wrappers only: every id, label, number, difference, version pick and create shape is the packed script's
//  (`CanonicalBusinessEngine.callJSON`). Swift never builds a revision id or compares versions itself (AGENTS.md Rule 0).
//

import Foundation
@preconcurrency import FirebaseFirestore

/// RULEBOOK 1.55.0 §8: which version of each pay run `FirebaseBackend.listTimesheetStates` gives — `latest`
/// (`timesheetLatestVersion`: lists, My Timesheets, User Timesheets and, owner decision J4, the weekly report) or `all`
/// (every stored version, grouped by the caller).
nonisolated enum TimesheetListVersions: Sendable {
    case latest, all
}

/// One stored version of a pay run's timesheet (`timesheetVersionsForPeriod`), with its stored Firestore data as read
/// (native values, so a revision can copy fields exactly as stored).
nonisolated struct TimesheetVersionInfo: @unchecked Sendable {
    let documentId: String
    let baseDocumentId: String
    /// 0 for the original, N for REV N.
    let revision: Int
    /// `exportedAt` stored (the field the security rules test).
    let exported: Bool
    /// Signed off (the line manager counter-signed, or a self-signed person signed with the snapshot written).
    let signedOff: Bool
    /// The stored document as read (Firestore values).
    let data: [String: Any]

    /// The version as the script reads it (`TimesheetVersion`): its stored data turned into JSON.
    var scriptJSON: [String: Any] {
        [
            "documentId": documentId,
            "baseDocumentId": baseDocumentId,
            "revision": revision,
            "exported": exported,
            "signedOff": signedOff,
            "data": FirebaseBackend.firestoreJSON(data),
        ]
    }
}

/// `timesheetRevisionDue({ chain, change })`.
nonisolated struct RulebookTimesheetRevisionDue: Equatable, Sendable {
    let due: Bool
    let nextRevision: Int?
    let documentId: String
    let label: String
    let message: String?
    let reviewerMessage: String?

    static let notDue = RulebookTimesheetRevisionDue(due: false, nextRevision: nil, documentId: "", label: "", message: nil, reviewerMessage: nil)

    init(due: Bool, nextRevision: Int?, documentId: String, label: String, message: String?, reviewerMessage: String?) {
        self.due = due
        self.nextRevision = nextRevision
        self.documentId = documentId
        self.label = label
        self.message = message
        self.reviewerMessage = reviewerMessage
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any], let due = row["due"] as? Bool else { return nil }
        self.init(
            due: due,
            nextRevision: (row["nextRevision"] as? NSNumber)?.intValue,
            documentId: row["documentId"] as? String ?? "",
            label: row["label"] as? String ?? "",
            message: row["message"] as? String,
            reviewerMessage: row["reviewerMessage"] as? String
        )
    }
}

/// `canCreateTimesheetRevision({ reviewer, chain, writerIsSubject })`.
nonisolated struct RulebookTimesheetRevisionCheck: Equatable, Sendable {
    let allowed: Bool
    /// `ok` | `not-reviewer` | `no-sheet` | `not-exported` | `revision-open` | `limit`.
    let reason: String
    let nextRevision: Int?
    let documentId: String
    let message: String

    init?(json: Any?) {
        guard let row = json as? [String: Any], let allowed = row["allowed"] as? Bool else { return nil }
        self.allowed = allowed
        self.reason = row["reason"] as? String ?? (allowed ? "ok" : "not-reviewer")
        self.nextRevision = (row["nextRevision"] as? NSNumber)?.intValue
        self.documentId = row["documentId"] as? String ?? ""
        self.message = row["message"] as? String ?? ""
    }
}

extension CanonicalBusinessEngine {
    // MARK: Texts (read from the script; the fallback only for a script that did not run)

    private nonisolated static func revisionText(_ name: String, fallback: String) -> String {
        constant(name, as: String.self) ?? fallback
    }

    /// `TIMESHEET_REVISION_NOTICE_TYPE` — `timesheet_revision_to_sign`.
    nonisolated static var timesheetRevisionNoticeType: String {
        revisionText("TIMESHEET_REVISION_NOTICE_TYPE", fallback: "timesheet_revision_to_sign")
    }

    nonisolated static var timesheetRevisionNoticeTitle: String {
        revisionText("TIMESHEET_REVISION_NOTICE_TITLE", fallback: "Timesheet revision")
    }

    nonisolated static var timesheetRevisionNoticeMessage: String {
        revisionText("TIMESHEET_REVISION_NOTICE_MESSAGE", fallback: "Your timesheet has a revision to sign")
    }

    nonisolated static var timesheetRevisionDueNoticeTitle: String {
        revisionText("TIMESHEET_REVISION_DUE_NOTICE_TITLE", fallback: "Update to your exported timesheet")
    }

    nonisolated static var timesheetRevisionDueMessage: String {
        revisionText(
            "TIMESHEET_REVISION_DUE_MESSAGE",
            fallback: "A booking has changed since this timesheet was exported. The exported timesheet stays as it was; please review and sign the update (a revision), or speak to your line manager if something isn't correct."
        )
    }

    nonisolated static var timesheetRevisionDueStatus: String {
        revisionText("TIMESHEET_REVISION_DUE_STATUS", fallback: "Update to sign")
    }

    nonisolated static var timesheetRevisionDueReviewerMessage: String {
        revisionText(
            "TIMESHEET_REVISION_DUE_REVIEWER_MESSAGE",
            fallback: "Bookings have changed since this timesheet was exported. The exported timesheet stays as it was; the person signs an update (a revision), then you counter-sign it."
        )
    }

    nonisolated static var timesheetReviewAndSignRevisionLabel: String {
        revisionText("TIMESHEET_REVIEW_AND_SIGN_REVISION_LABEL", fallback: "Review and sign again")
    }

    nonisolated static var timesheetCreateRevisionLabel: String {
        revisionText("TIMESHEET_CREATE_REVISION_LABEL", fallback: "Create revision")
    }

    nonisolated static var timesheetCreateRevisionHelp: String {
        revisionText(
            "TIMESHEET_CREATE_REVISION_HELP",
            fallback: "This timesheet is exported and cannot be changed. A revision is a new version built from the live bookings, price work and expenses for this pay run. The person signs it, then their line manager counter-signs it."
        )
    }

    nonisolated static var timesheetRevisionOpenMessage: String {
        revisionText("TIMESHEET_REVISION_OPEN_MESSAGE", fallback: "A revision of this timesheet is already open. Finish and export it first.")
    }

    nonisolated static var timesheetRevisionNotExportedMessage: String {
        revisionText("TIMESHEET_REVISION_NOT_EXPORTED_MESSAGE", fallback: "Only an exported timesheet can have a revision.")
    }

    /// `TIMESHEET_REVISION_EXTRAS_MESSAGE` — a revision's entries are frozen for the person.
    nonisolated static var timesheetRevisionExtrasMessage: String {
        revisionText(
            "TIMESHEET_REVISION_EXTRAS_MESSAGE",
            fallback: "This is a revision of an exported timesheet — add price work or expenses to your next timesheet."
        )
    }

    /// `TIMESHEET_REVISION_DIFFERENCE_UNKNOWN` — the previous version has no signed snapshot.
    nonisolated static var timesheetRevisionDifferenceUnknown: String {
        revisionText("TIMESHEET_REVISION_DIFFERENCE_UNKNOWN", fallback: "Difference not available (older export)")
    }

    nonisolated static var timesheetEarlierVersionsLabel: String {
        revisionText("TIMESHEET_EARLIER_VERSIONS_LABEL", fallback: "Earlier versions")
    }

    nonisolated static var timesheetOriginalVersionLabel: String {
        revisionText("TIMESHEET_ORIGINAL_VERSION_LABEL", fallback: "Original")
    }

    /// `TIMESHEET_REVISION_COPIED_FIELDS` — the fields a revision copies exactly as stored.
    nonisolated static var timesheetRevisionCopiedFields: [String] {
        constant("TIMESHEET_REVISION_COPIED_FIELDS", as: [String].self) ?? []
    }

    // MARK: Ids and labels

    /// `parseTimesheetRevisionDocId(id)` → the original's id and the revision (0 = the original); nil when not a
    /// timesheet id, or when it ends in a revision suffix that is not 1–99 written without a leading zero (`_rev0`,
    /// `_rev01`, `_rev100`) — such an id is neither an original nor a revision.
    nonisolated static func parseTimesheetRevisionDocId(_ documentId: String?) -> (documentId: String, baseDocumentId: String, revision: Int)? {
        guard let documentId,
              let row = callJSON("parseTimesheetRevisionDocId", arguments: [documentId]) as? [String: Any],
              let id = row["documentId"] as? String,
              let base = row["baseDocumentId"] as? String,
              let revision = (row["revision"] as? NSNumber)?.intValue else { return nil }
        return (id, base, revision)
    }

    /// `timesheetRevisionDocId(baseDocumentId, revision)`; nil when not usable.
    nonisolated static func timesheetRevisionDocId(baseDocumentId: String, revision: Int) -> String? {
        guard let id = callJSON("timesheetRevisionDocId", arguments: [baseDocumentId, revision]) as? String, !id.isEmpty else {
            return nil
        }
        return id
    }

    /// `timesheetRevisionLabel(revision)` — "REV 1"; "" for the original.
    nonisolated static func timesheetRevisionLabel(_ revision: Int?) -> String {
        callJSON("timesheetRevisionLabel", arguments: [revision ?? 0]) as? String ?? ""
    }

    /// `timesheetInvoiceNumber({ documentId, userId })` — "TS-{stamp}-6A9632", built only from the ORIGINAL's stored id
    /// and stored `userId` (never the viewer's or a current users id); nil when not usable.
    nonisolated static func timesheetInvoiceNumber(originalDocumentId: String, storedUserId: String?) -> String? {
        let input: [String: Any] = ["documentId": originalDocumentId, "userId": storedUserId ?? ""]
        guard let number = callJSON("timesheetInvoiceNumber", arguments: [input]) as? String, !number.isEmpty else { return nil }
        return number
    }

    /// `timesheetInvoiceNumberForRevision(base, revision)` — the number plus "-REV1"; unchanged for 0.
    nonisolated static func timesheetInvoiceNumberForRevision(_ base: String, revision: Int?) -> String? {
        guard let number = callJSON("timesheetInvoiceNumberForRevision", arguments: [base, revision ?? 0]) as? String,
              !number.isEmpty else { return nil }
        return number
    }

    /// `timesheetRevisionDifference({ total, previousTotal, currency })` — "+£44.12"; nil when either total is unknown.
    nonisolated static func timesheetRevisionDifference(total: Double?, previousTotal: Double?, currency: String) -> (amount: Double, text: String)? {
        let input: [String: Any] = [
            "total": total.map { $0 as Any } ?? NSNull(),
            "previousTotal": previousTotal.map { $0 as Any } ?? NSNull(),
            "currency": currency,
        ]
        guard let row = callJSON("timesheetRevisionDifference", arguments: [input]) as? [String: Any],
              let amount = (row["amount"] as? NSNumber)?.doubleValue,
              let text = row["text"] as? String else { return nil }
        return (amount, text)
    }

    /// RULEBOOK 1.54.1 / 1.55.0: a stored version is exported as the security rules read it (`tsExportedIn`) —
    /// `resolveTimesheetExportedAtMs(data) != null`, so an `exportedAt` a leftover web build copied from
    /// `invoiceGeneratedAt` is not an export. `data` is the stored document (Firestore values). False when the script
    /// did not answer.
    nonisolated static func timesheetStoredExported(_ data: [String: Any]?) -> Bool {
        guard let data else { return false }
        let answer = callJSON("resolveTimesheetExportedAtMs", arguments: [FirebaseBackend.firestoreJSON(data)])
        return answer is NSNumber
    }

    /// `timesheetExportedTotal(data)` — a stored version's signed-snapshot invoice total; nil when it has no signed
    /// snapshot (the difference is then unknown, `TIMESHEET_REVISION_DIFFERENCE_UNKNOWN`). `data` is the stored document.
    nonisolated static func timesheetExportedTotal(_ data: [String: Any]) -> Double? {
        (callJSON("timesheetExportedTotal", arguments: [FirebaseBackend.firestoreJSON(data)]) as? NSNumber)?.doubleValue
    }

    // MARK: Versions

    /// `timesheetVersionsForPeriod(documents)`: one chain per original, oldest first. Each version keeps its stored
    /// Firestore data (matched back by document id). Nil when the script did not answer.
    nonisolated static func timesheetVersionsForPeriod(_ documents: [(documentId: String, data: [String: Any])]) -> [[TimesheetVersionInfo]]? {
        var stored: [String: [String: Any]] = [:]
        for row in documents where stored[row.documentId] == nil { stored[row.documentId] = row.data }
        let input: [[String: Any]] = documents.map { ["documentId": $0.documentId, "data": FirebaseBackend.firestoreJSON($0.data)] }
        guard let chains = callJSON("timesheetVersionsForPeriod", arguments: [input]) as? [[[String: Any]]] else { return nil }
        return chains.map { chain in
            chain.compactMap { version -> TimesheetVersionInfo? in
                guard let id = version["documentId"] as? String,
                      let base = version["baseDocumentId"] as? String,
                      let revision = (version["revision"] as? NSNumber)?.intValue else { return nil }
                return TimesheetVersionInfo(
                    documentId: id,
                    baseDocumentId: base,
                    revision: revision,
                    exported: version["exported"] as? Bool ?? false,
                    signedOff: version["signedOff"] as? Bool ?? false,
                    data: stored[id] ?? [:]
                )
            }
        }
    }

    /// Picks a version of `chain` with the script's chooser (`timesheetLatestVersion` /
    /// `timesheetEarlierVersions`) and maps its answer back to the chain's entries by document id.
    private nonisolated static func pickVersions(_ function: String, _ chain: [TimesheetVersionInfo]) -> [TimesheetVersionInfo]? {
        guard !chain.isEmpty else { return [] }
        let answer = callJSON(function, arguments: [chain.map(\.scriptJSON)])
        let ids: [String]
        if let list = answer as? [[String: Any]] {
            ids = list.compactMap { $0["documentId"] as? String }
        } else if let one = answer as? [String: Any], let id = one["documentId"] as? String {
            ids = [id]
        } else if answer is NSNull {
            ids = []
        } else {
            return nil
        }
        return ids.compactMap { id in chain.first { $0.documentId == id } }
    }

    /// `timesheetLatestVersion(chain)` — what lists and the period page show.
    nonisolated static func timesheetLatestVersion(_ chain: [TimesheetVersionInfo]) -> TimesheetVersionInfo? {
        pickVersions("timesheetLatestVersion", chain)?.first
    }

    /// `timesheetRevisionReportState({ revision, exported, signedOff, change })` (owner decision J4): `due` / `open` /
    /// `none`, whether the pay run counts as approved, and the report label ("Revision due", "REV 1 waiting for
    /// signature"). Nil when the script did not answer.
    nonisolated static func timesheetRevisionReportState(
        revision: Int?,
        exported: Bool,
        signedOff: Bool,
        change: RulebookSignedTimesheetChange?
    ) -> (state: String, label: String)? {
        let changeJSON: Any = change.map { ["changed": $0.changed, "exported": $0.exported] as [String: Any] } ?? NSNull()
        let input: [String: Any] = ["revision": revision ?? 0, "exported": exported, "signedOff": signedOff, "change": changeJSON]
        guard let row = callJSON("timesheetRevisionReportState", arguments: [input]) as? [String: Any],
              let state = row["state"] as? String else { return nil }
        return (state, row["label"] as? String ?? "")
    }

    /// `timesheetEarlierVersions(chain)` — the versions before the latest, newest first (read only).
    nonisolated static func timesheetEarlierVersions(_ chain: [TimesheetVersionInfo]) -> [TimesheetVersionInfo] {
        pickVersions("timesheetEarlierVersions", chain) ?? []
    }

    /// `timesheetRevisionDue({ chain, change })` — `change` is `signedTimesheetBookingChanges` of the latest version.
    /// Nil when the script did not answer.
    nonisolated static func timesheetRevisionDue(chain: [TimesheetVersionInfo], change: RulebookSignedTimesheetChange?) -> RulebookTimesheetRevisionDue? {
        let changeJSON: Any = change.map { ["changed": $0.changed, "exported": $0.exported] as [String: Any] } ?? NSNull()
        let input: [String: Any] = ["chain": chain.map(\.scriptJSON), "change": changeJSON]
        return RulebookTimesheetRevisionDue(json: callJSON("timesheetRevisionDue", arguments: [input]))
    }

    /// `canCreateTimesheetRevision({ reviewer, chain, writerIsSubject })`. `reviewer` is the `timesheetWriterIsReviewer`
    /// input (`writerUserId`, `subjectUserId`, `writerIsAdmin`, `writerFormerIds`, `writerAliasIds`,
    /// `subjectLineManagerIds`, `roster`). Nil when the script did not answer (nothing is offered then).
    nonisolated static func canCreateTimesheetRevision(
        reviewer: [String: Any],
        chain: [TimesheetVersionInfo],
        writerIsSubject: Bool
    ) -> RulebookTimesheetRevisionCheck? {
        let input: [String: Any] = ["reviewer": reviewer, "chain": chain.map(\.scriptJSON), "writerIsSubject": writerIsSubject]
        return RulebookTimesheetRevisionCheck(json: callJSON("canCreateTimesheetRevision", arguments: [input]))
    }

    /// `timesheetRevisionCreateFields({ previous, writerUserId })` → the target id, the revision and the KEYS to write,
    /// with the script's values for the revision fields. The copied fields (`TIMESHEET_REVISION_COPIED_FIELDS`) are
    /// written from `previous` exactly as stored (native Firestore values: the security rules compare them with the
    /// previous version), never from the script's JSON copy (a Timestamp would come back as a map). A copied key
    /// stored as `null` on the previous version is copied as `null` too, so the create never "removes" a copied key the
    /// rules see on the previous version. Nil when `previous` is not an exported timesheet version.
    nonisolated static func timesheetRevisionCreateFields(
        previousDocumentId: String,
        previousData: [String: Any],
        writerUserId: String,
        liveLines: [[String: Any]]? = nil
    ) -> (documentId: String, revision: Int, fields: [String: Any])? {
        // Owner decision 16 Nov (finding 6 = a): `liveLines` (id, `bookingFingerprint`, amount, paid hours) — the labour
        // decisions are kept only for bookings unchanged since (`timesheetRevisionLabourReviews`); none → all dropped.
        var input: [String: Any] = [
            "previous": ["documentId": previousDocumentId, "data": FirebaseBackend.firestoreJSON(previousData)],
            "writerUserId": writerUserId,
        ]
        if let liveLines { input["liveLines"] = liveLines }
        guard let row = callJSON("timesheetRevisionCreateFields", arguments: [input]) as? [String: Any],
              let documentId = row["documentId"] as? String, !documentId.isEmpty,
              let revision = (row["revision"] as? NSNumber)?.intValue,
              let scriptFields = row["fields"] as? [String: Any] else { return nil }
        let copied = Set(timesheetRevisionCopiedFields)
        var fields: [String: Any] = [:]
        for (key, value) in scriptFields {
            if key == "payrollLineReviews", let kept = value as? [String: Any], let stored = previousData[key] as? [String: Any] {
                // The labour decisions the script kept: each written exactly as stored (a part of the stored map).
                fields[key] = stored.filter { kept[$0.key] != nil }
            } else if copied.contains(key) {
                guard let stored = previousData[key] else { continue }
                fields[key] = stored
            } else {
                fields[key] = value
            }
        }
        for key in copied where fields[key] == nil && previousData[key] is NSNull {
            fields[key] = NSNull()
        }
        // `revision` is written as an integer (the rules test `revision is int`).
        if fields["revision"] != nil { fields["revision"] = revision }
        return (documentId, revision, fields)
    }

    /// `timesheetRevisionToSignRecipients(subject, actor, roster)` — the sheet's person, never the actor.
    nonisolated static func timesheetRevisionToSignRecipients(subject: Any, actor: Any, roster: [[String: Any]]) -> [String]? {
        callJSON("timesheetRevisionToSignRecipients", arguments: [subject, actor, roster]) as? [String]
    }

    /// `timesheetRevisionNoticeKey(revisionDocumentId)` — `timesheetRevision|{id}`; nil for an original.
    nonisolated static func timesheetRevisionNoticeKey(_ revisionDocumentId: String) -> String? {
        guard let key = callJSON("timesheetRevisionNoticeKey", arguments: [revisionDocumentId]) as? String, !key.isEmpty else { return nil }
        return key
    }
}

/// RULEBOOK 1.55.0 §8: the REV label, invoice number and difference a version shows — web
/// `lib/timesheets/timesheetRevisionCopy.ts`. Every figure and word is the rulebook's (`timesheetRevisionLabel`,
/// `timesheetInvoiceNumber`, `timesheetInvoiceNumberForRevision`, `timesheetRevisionDifference`); this only joins them.
nonisolated struct TimesheetRevisionCopy: Equatable, Sendable {
    /// "REV 1", or "" for the original.
    let label: String
    let invoiceNumber: String
    /// "+£44.12", `TIMESHEET_REVISION_DIFFERENCE_UNKNOWN` (the previous version has no signed snapshot), or nil.
    let differenceText: String?
    /// "REV 1 · +£44.12 from the previous version" for documents, or "".
    let note: String

    /// `originalDocumentId` and `storedUserId` are the ORIGINAL's stored id and stored `userId` (never the viewer's).
    /// `previousKnown`: the previous version was read (its total may still be unknown — no signed snapshot).
    static func make(
        originalDocumentId: String,
        storedUserId: String?,
        revision: Int?,
        total: Double?,
        previousExportedTotal: Double?,
        previousKnown: Bool,
        currency: String
    ) -> TimesheetRevisionCopy {
        let rev = max(0, revision ?? 0)
        let base = CanonicalBusinessEngine.timesheetInvoiceNumber(originalDocumentId: originalDocumentId, storedUserId: storedUserId) ?? ""
        let number = base.isEmpty ? "" : (CanonicalBusinessEngine.timesheetInvoiceNumberForRevision(base, revision: rev) ?? base)
        let label = CanonicalBusinessEngine.timesheetRevisionLabel(rev)
        guard rev > 0 else { return TimesheetRevisionCopy(label: label, invoiceNumber: number, differenceText: nil, note: "") }
        let difference = previousExportedTotal == nil
            ? nil
            : CanonicalBusinessEngine.timesheetRevisionDifference(total: total, previousTotal: previousExportedTotal, currency: currency)
        let differenceText = difference?.text ?? (previousKnown ? CanonicalBusinessEngine.timesheetRevisionDifferenceUnknown : nil)
        let note: String
        if let difference {
            note = "\(label) · \(difference.text) from the previous version"
        } else if let differenceText {
            note = "\(label) · \(differenceText)"
        } else {
            note = label
        }
        return TimesheetRevisionCopy(label: label, invoiceNumber: number, differenceText: differenceText, note: note)
    }
}

/// RULEBOOK 1.55.0 §8: the version chains this device last read, by every version's document id (web
/// `versionChainsById`) — for the earlier versions shown read only and the previous version's total. In memory only;
/// never a source of a write.
@MainActor
enum TimesheetVersionChainCache {
    private static var byId: [String: [TimesheetVersionInfo]] = [:]

    static func remember(_ chain: [TimesheetVersionInfo]) {
        guard !chain.isEmpty else { return }
        if byId.count > 2000 { byId.removeAll() }
        for version in chain { byId[version.documentId] = chain }
    }

    static func chain(for documentId: String?) -> [TimesheetVersionInfo] {
        guard let documentId, !documentId.isEmpty else { return [] }
        return byId[documentId] ?? []
    }
}
