import Foundation

/// RULEBOOK 1.60.1 §13: the timesheet notice ids of one signature. Each signature of a pay run — the person's
/// (`timesheet_pending_manager_signoff`) or the line manager's counter-signature (`timesheet_signed_by_manager`, and its
/// `line_manager_peer_update` rows) — gets its own row and push, keyed by the signature instant
/// (`timesheetNotificationDedupeKey` / `lineManagerPeerNoticeKey` `signedAtMs`). A retry of the same signature builds the
/// same ids. The instant is read from the signed draft here, so a call site cannot drop it.
enum TimesheetSignatureNotices {
    struct Signature: Equatable {
        /// REV N of the signed version (nil / 0 the original), RULEBOOK 1.55.0.
        let revision: Int?
        /// The signature instant: `operativeSignedAt` for the person, `managerSignedAt` for the counter-signature.
        let signedAt: Date?
    }

    /// The person's signature on `draft` (after `TimesheetDraftStore.applySignOff(role: "operative")`).
    static func ownerSigned(_ draft: TimesheetDraft) -> Signature {
        Signature(revision: draft.revision, signedAt: draft.operativeSignedAt)
    }

    /// The line manager's counter-signature on `draft` (after `applySignOff(role: "manager")`).
    static func counterSigned(_ draft: TimesheetDraft) -> Signature {
        Signature(revision: draft.revision, signedAt: draft.managerSignedAt)
    }

    /// The `timesheet_pending_manager_signoff` row id for one line manager. Nil when the script did not answer.
    static func pendingNoticeId(subjectId: String, managerId: String, weekStart: Date, signature: Signature) -> UUID? {
        CanonicalBusinessEngine.timesheetNotificationDedupeKey(
            type: AppNotification.NotificationType.timesheetPendingManagerSignoff.rawValue,
            subjectId: subjectId,
            periodStartDayKey: OrganizationRulebookContext.dayKey(weekStart),
            timeZone: OrganizationRulebookContext.timeZoneIdentifier,
            recipientId: managerId,
            revision: signature.revision,
            signedAt: signature.signedAt
        ).map(NotificationService.syntheticNotificationId(fromKey:))
    }

    /// The `timesheet_signed_by_manager` row id. Nil when the script did not answer.
    static func signedNoticeId(subjectId: String, weekStart: Date, signature: Signature) -> UUID? {
        CanonicalBusinessEngine.timesheetNotificationDedupeKey(
            type: AppNotification.NotificationType.timesheetSignedByManager.rawValue,
            subjectId: subjectId,
            periodStartDayKey: OrganizationRulebookContext.dayKey(weekStart),
            timeZone: OrganizationRulebookContext.timeZoneIdentifier,
            revision: signature.revision,
            signedAt: signature.signedAt
        ).map(NotificationService.syntheticNotificationId(fromKey:))
    }

    /// The counter-signature's peer summary, as both apps have always written it ("Sam's timesheet (1–15 Nov)").
    static func peerSummary(operativeName: String, weekTitle: String) -> String {
        "\(operativeName)'s timesheet (\(weekTitle))"
    }

    /// The `line_manager_peer_update` row id a counter-signature writes for one peer (`lineManagerPeerNoticeKey`, the id
    /// `NotificationService.notifyLineManagerPeerAction` writes). Nil when the script did not answer.
    static func counterSignPeerNoticeId(signedByName: String, summary: String, peerId: String, signature: Signature) -> UUID? {
        CanonicalBusinessEngine.lineManagerPeerNoticeKey(
            actorName: signedByName, actionSummary: summary, peerId: peerId, actionVerb: "signed", signedAt: signature.signedAt
        ).map(NotificationService.syntheticNotificationId(fromKey:))
    }
}
