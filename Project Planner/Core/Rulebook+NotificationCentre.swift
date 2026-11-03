//
//  Rulebook+NotificationCentre.swift
//  Project Planner
//
//  Rulebook 1.16.0 (docs/RULEBOOK.md §13, notification centre reliability): typed wrappers for the recipient
//  account (`notificationRecipientAccountId`), the push payload (`pushPayloadFields`), the company switch on a tapped
//  row from another organisation (`notificationOrganizationSwitch`) and server-time inbox rows
//  (`notificationCreatedAtIsServerTime`), plus the operatives catalogue payload the recipient rules read. Every answer
//  comes from the packed script through `CanonicalBusinessEngine.callJSON`; nothing is decided here.
//

import Foundation

extension CanonicalBusinessEngine {
    /// `notificationRecipientAccountId(id, roster, catalogue)`: the signed-in account a notice for `id` is written to
    /// (account id, invite placeholder, former or same-email id, operatives catalogue id, any letter case). Nil when the
    /// roster cannot resolve it (unknown id, nobody active) or the script did not answer.
    nonisolated static func notificationRecipientAccountId(
        _ id: String,
        roster: [[String: Any]],
        catalogue: [[String: Any]]? = nil
    ) -> String? {
        var arguments: [Any] = [id, roster]
        if let catalogue { arguments.append(catalogue) }
        guard let answer = callJSON("notificationRecipientAccountId", arguments: arguments) as? String,
              !answer.isEmpty else { return nil }
        return answer
    }

    /// `pushPayloadFields(row)`: the one push data payload (`notificationId`, `type`, `relatedId`, `dayKey`,
    /// `catalogue`, `userId`, `organizationId`), string values only, a missing value left out. Nil when the script
    /// did not answer.
    nonisolated static func pushPayloadFields(_ row: [String: Any]) -> [String: String]? {
        guard let answer = callJSON("pushPayloadFields", arguments: [row]) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (key, value) in answer {
            if let text = value as? String { out[key] = text }
        }
        return out
    }

    /// `PUSH_PAYLOAD_KEYS`: the keys `pushPayloadFields` reads, in order.
    nonisolated static var pushPayloadKeys: [String] {
        constant("PUSH_PAYLOAD_KEYS", as: [String].self) ?? []
    }

    /// `notificationOrganizationSwitch({ rowOrganizationId, openOrganizationId, membershipIds })`: the organisation to
    /// switch to before routing a tapped row or push from another company, or nil (same company, unknown company, not
    /// a member, or the script did not answer).
    nonisolated static func notificationOrganizationSwitch(
        rowOrganizationId: String?,
        openOrganizationId: String?,
        membershipIds: [String]
    ) -> String? {
        let input: [String: Any] = [
            "rowOrganizationId": rowOrganizationId ?? "",
            "openOrganizationId": openOrganizationId ?? "",
            "membershipIds": membershipIds,
        ]
        guard let answer = callJSON("notificationOrganizationSwitch", arguments: [input]) as? String,
              !answer.isEmpty else { return nil }
        return answer
    }

    /// `notificationCreatedAtIsServerTime(type, scheduledAt)`: false only for a scheduled type
    /// (`SCHEDULED_NOTIFICATION_TYPES`) written ahead of time with its own due instant.
    nonisolated static func notificationCreatedAtIsServerTime(type: String, hasScheduledAt: Bool) -> Bool? {
        let scheduledAt: Any = hasScheduledAt ? (1 as Any) : (NSNull() as Any)
        return callJSON("notificationCreatedAtIsServerTime", arguments: [type, scheduledAt]) as? Bool
    }
}

/// The operatives catalogue rows the recipient rules read (`NotificationCatalogueRow`: `id`, `email`, `userId`): a
/// booked id that is not an account resolves to the account by its link or email. No rule is decided here.
enum NotificationCataloguePayload {
    static func rows(_ operatives: [Operative]) -> [[String: Any]] {
        operatives.map { operative in
            var row: [String: Any] = ["id": operative.documentId, "email": operative.email]
            if let linked = operative.linkedUserId?.trimmingCharacters(in: .whitespacesAndNewlines), !linked.isEmpty {
                row["userId"] = linked
            }
            return row
        }
    }
}
