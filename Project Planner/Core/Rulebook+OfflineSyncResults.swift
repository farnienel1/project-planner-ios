//
//  Rulebook+OfflineSyncResults.swift
//  Project Planner
//
//  RULEBOOK 1.86.0 §2 (owner decision 24 Nov, web `lib/canonical/offlineSyncResults.ts`): the "Not synced" page — one
//  row per queued action the server refused when the phone came back online (`offlineSyncResultRows`), the local
//  notification's text (`offlineSyncResultNotificationText`), its copy (`OFFLINE_SYNC_RESULT_*`), and whether a queued
//  Replace waits for another company's settings (`offlineReplaceOrganizationReadDecision`). Swift only maps inputs.
//

import Foundation

/// A booking as the summary shows it: organisation-zone day, the app's label for the job or place, times or slot.
nonisolated struct OfflineSyncSummaryBooking: Codable, Equatable, Sendable {
    var dayKey: String?
    var place: String?
    var startTime: String?
    var endTime: String?
    var timeSlot: String?

    var json: [String: Any] {
        var out: [String: Any] = [:]
        if let dayKey { out["dayKey"] = dayKey }
        if let place { out["place"] = place }
        if let startTime { out["startTime"] = startTime }
        if let endTime { out["endTime"] = endTime }
        if let timeSlot { out["timeSlot"] = timeSlot }
        return out
    }
}

/// One row of the page, exactly as `offlineSyncResultRows` returns it.
nonisolated struct RulebookOfflineSyncResultRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let whenText: String
    let dayKey: String?
    let openDayLabel: String
    let dismissLabel: String
}

extension CanonicalBusinessEngine {
    nonisolated static var offlineSyncResultTitle: String {
        constant("OFFLINE_SYNC_RESULT_TITLE", as: String.self) ?? "Not synced"
    }

    nonisolated static var offlineSyncResultBanner: String {
        constant("OFFLINE_SYNC_RESULT_BANNER", as: String.self)
            ?? "Some changes from this phone were not synced. Tap to see what happened."
    }

    nonisolated static var offlineSyncResultEmpty: String {
        constant("OFFLINE_SYNC_RESULT_EMPTY", as: String.self) ?? "Everything on this phone has synced."
    }

    /// RULEBOOK 1.86.0 `offlineSyncResultRows(results, timeZone)`. Empty when the script did not answer.
    nonisolated static func offlineSyncResultRows(_ results: [[String: Any]], timeZone: String) -> [RulebookOfflineSyncResultRow] {
        guard JSONSerialization.isValidJSONObject(results),
              let rows = callJSON("offlineSyncResultRows", arguments: [results, timeZone]) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
            return RulebookOfflineSyncResultRow(
                id: id,
                title: title,
                detail: row["detail"] as? String ?? "",
                whenText: row["whenText"] as? String ?? "",
                dayKey: row["dayKey"] as? String,
                openDayLabel: row["openDayLabel"] as? String ?? "Open day",
                dismissLabel: row["dismissLabel"] as? String ?? "Got it"
            )
        }
    }

    /// RULEBOOK 1.86.0 `offlineSyncResultNotificationText(count)`.
    nonisolated static func offlineSyncResultNotificationText(count: Int) -> (title: String, body: String) {
        let row = callJSON("offlineSyncResultNotificationText", arguments: [count]) as? [String: Any]
        return (
            row?["title"] as? String ?? "Some changes were not synced",
            row?["body"] as? String ?? "Changes from this phone were not saved. Tap to see what happened."
        )
    }

    /// RULEBOOK 1.86.0 `offlineReplaceOrganizationReadDecision({ code, exists })`: `wait` or `refusePermission`.
    /// `wait` when the script did not answer (never refused on a guess).
    nonisolated static func offlineReplaceOrganizationReadDecision(code: Int?, exists: Bool?) -> String {
        var input: [String: Any] = [:]
        if let code { input["code"] = code }
        if let exists { input["exists"] = exists }
        return callJSON("offlineReplaceOrganizationReadDecision", arguments: [input]) as? String ?? "wait"
    }
}
