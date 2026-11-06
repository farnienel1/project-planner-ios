//
//  Rulebook+Release1320.swift
//  Project Planner
//
//  RULEBOOK 1.32.0 (web hand-off v1.32.0): typed wrappers for the settings, export-notice and small shared helpers —
//  `payePaydaySetupError` / `payePaydayMissing` / `payePaydayBanner` (§4.5), `rulebookVersionLabel` (§15),
//  `timesheetExportOwnSheetNotice` (§8), `legalPackAcceptanceWriteFields`, `invitationListConstraints` and
//  `invitationReadErrorIsSkippable`. Every answer comes from the packed script through `CanonicalBusinessEngine.callJSON`;
//  Swift only builds the inputs and reads the answers.
//

import Foundation

/// One equality constraint of an `invitations` query (`invitationListConstraints`): `field` == `value`.
nonisolated struct InvitationQueryConstraint: Equatable, Hashable, Sendable {
    let field: String
    let value: String
}

/// The Firestore error code name (`permission-denied`, `unavailable`, …) of an `NSError` in the Firestore domain, the
/// form the script's error helpers read (web passes `error.code`). Nil for any other error. Plumbing, not a rule.
nonisolated enum FirestoreErrorCodeName {
    private static let names: [Int: String] = [
        1: "cancelled", 2: "unknown", 3: "invalid-argument", 4: "deadline-exceeded", 5: "not-found",
        6: "already-exists", 7: "permission-denied", 8: "resource-exhausted", 9: "failed-precondition",
        10: "aborted", 11: "out-of-range", 12: "unimplemented", 13: "internal", 14: "unavailable",
        15: "data-loss", 16: "unauthenticated",
    ]

    static func of(_ error: Error) -> String? {
        let nsError = error as NSError
        guard nsError.domain == "FIRFirestoreErrorDomain" else { return nil }
        return names[nsError.code]
    }
}

extension CanonicalBusinessEngine {
    // MARK: PAYE payday required (§4.5)

    /// `payePaydaySetupError(day)`: nil when `day` is 1–31; `PAYE_PAYDAY_REQUIRED_MESSAGE` when none is picked;
    /// the invalid-day message otherwise.
    nonisolated static func payePaydaySetupError(_ day: Int?) -> String? {
        callJSON("payePaydaySetupError", arguments: [RulebookJSON.orNull(day)]) as? String
    }

    /// `payePaydayMissing(organization)`: true while the organisation has no PAYE payday. Nil when the script did not answer.
    nonisolated static func payePaydayMissing(_ organization: [String: Any]) -> Bool? {
        callJSON("payePaydayMissing", arguments: [organization]) as? Bool
    }

    /// `payePaydayBanner({ organization, loaded, viewerIsAdmin })`: `PAYE_PAYDAY_MISSING_BANNER` to admins,
    /// `PAYE_PAYDAY_NOT_SET_MESSAGE` to everyone else, nil once a payday is set or before the organisation has loaded.
    nonisolated static func payePaydayBanner(organization: [String: Any], loaded: Bool, viewerIsAdmin: Bool) -> String? {
        callJSON("payePaydayBanner", arguments: [[
            "organization": organization,
            "loaded": loaded,
            "viewerIsAdmin": viewerIsAdmin,
        ] as [String: Any]]) as? String
    }

    // MARK: Rules version (§15)

    /// `rulebookVersionLabel(version)`: "Rules 1.32.1" for the given version, or the packed stamp when nil. Empty when
    /// unknown (the line is then hidden).
    nonisolated static func rulebookVersionLabel(_ version: String? = nil) -> String {
        callJSON("rulebookVersionLabel", arguments: [RulebookJSON.orNull(version)]) as? String ?? ""
    }

    // MARK: Export notice (§8)

    /// `timesheetExportOwnSheetNotice({ ownSheetSigned, ownSheetExported })`: `TIMESHEET_EXPORT_OWN_SHEET_NOTICE` while the
    /// viewer's own sheet for the period is signed and not exported; nil otherwise.
    nonisolated static func timesheetExportOwnSheetNotice(ownSheetSigned: Bool, ownSheetExported: Bool) -> String? {
        callJSON("timesheetExportOwnSheetNotice", arguments: [[
            "ownSheetSigned": ownSheetSigned,
            "ownSheetExported": ownSheetExported,
        ] as [String: Any]]) as? String
    }

    // MARK: Legal pack acceptance write

    /// Stands in for the app's timestamp while the script builds the write; every field the script fills with
    /// `acceptedAt` gets `acceptedAt` back (a Firestore `Timestamp` cannot cross into the script).
    private static let legalPackAcceptedAtToken = "__legalPackAcceptedAt__"

    /// `legalPackAcceptanceWriteFields({ userId, version, acceptedAt, platform: 'ios' })`: `policyAccepted`,
    /// `policyAcceptedAt`, `legalPackVersion`, `legalPackAcceptedAt` and the write metadata (`updatedBy`,
    /// `updatedFrom`), with `acceptedAt` (the app's timestamp value) in each "at" field the script names. Nil when the
    /// version or user id is blank, or the script did not answer.
    nonisolated static func legalPackAcceptanceWriteFields(userId: String, version: String, acceptedAt: Any) -> [String: Any]? {
        guard let fields = callJSON("legalPackAcceptanceWriteFields", arguments: [[
            "userId": userId,
            "version": version,
            "acceptedAt": legalPackAcceptedAtToken,
            "platform": "ios",
        ] as [String: Any]]) as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        for (key, value) in fields {
            out[key] = (value as? String) == legalPackAcceptedAtToken ? acceptedAt : value
        }
        return out
    }

    // MARK: Invitation lookups

    /// `invitationListConstraints({ organizationId, email, actorManagesOperatives, senderIds })`: one list of equality
    /// constraints per `invitations` query — this organisation and the email in both stored forms (as typed and lower
    /// case), plus `invitedBy` per sender value for an operatives manager. Empty when the organisation or email is blank.
    nonisolated static func invitationListConstraints(
        organizationId: String,
        email: String,
        actorManagesOperatives: Bool,
        senderIds: [String]
    ) -> [[InvitationQueryConstraint]] {
        let input: [String: Any] = [
            "organizationId": organizationId,
            "email": email,
            "actorManagesOperatives": actorManagesOperatives,
            "senderIds": senderIds,
        ]
        guard let queries = callJSON("invitationListConstraints", arguments: [input]) as? [[[String]]] else { return [] }
        return queries.map { query in
            query.compactMap { pair in
                pair.count == 2 ? InvitationQueryConstraint(field: pair[0], value: pair[1]) : nil
            }
        }
    }

    /// `invitationReadErrorIsSkippable(code)`: a clean-up skips an invitation read only when the rules refused it
    /// (`permission-denied`); any other failure stops it.
    nonisolated static func invitationReadErrorIsSkippable(code: String?) -> Bool {
        callJSON("invitationReadErrorIsSkippable", arguments: [RulebookJSON.orNull(code)]) as? Bool ?? false
    }
}
