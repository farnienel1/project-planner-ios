//
//  Rulebook+DataParity.swift
//  Project Planner
//
//  Rulebook 1.38.0 (docs/RULEBOOK.md §27 "Data check", owner decision 11 Nov). Web `lib/canonical/dataParity.ts`,
//  called through `CanonicalBusinessEngine`:
//    - `DATA_PARITY_CHECKS` — the lists checked;
//    - `dataParityCheck` — server count vs device count per list → mismatches and the lists to reload;
//    - `dataParityCheckDue` — the throttle (never offline; Check now always);
//    - `dataParityConfirm`, `DATA_PARITY_CONFIRM_DELAY_MS` — the two-look rule before anything is re-read;
//    - `dataParityLogEntry`, `dataParityLogAppend` — the device-local record of a check and its re-check;
//    - `dataParitySummary` — the Settings → Data health text (organisation zone).
//  Nothing is decided here. When the script does not answer, no list is compared and nothing is reloaded.
//

import Foundation

/// One `DATA_PARITY_CHECKS` row.
nonisolated struct RulebookDataParityCheckDefinition: Equatable, Sendable {
    var key: String
    var collection: String
    /// `organization` (`organizations/{orgId}/{collection}`) or `users` (top-level `users` where `organizationId`).
    var scope: String
    var windowed: Bool
    var label: String
}

/// `DATA_PARITY_CHECKS` as decoded from the script.
nonisolated struct RulebookDataParityCheckRow: Decodable, Sendable {
    let key: String
    let collection: String
    let scope: String
    let windowed: Bool
    let label: String
}

/// One list given to `dataParityCheck`.
nonisolated struct RulebookDataParityListInput: Sendable {
    var key: String
    /// The server's `count()` of the listener's query; nil when it could not be read.
    var serverCount: Int?
    /// The ids the app holds for that query (counted once each).
    var localIds: [String]?
    /// Documents the reader leaves out but the server counts (the legacy placeholder job document).
    var readerDroppedCount: Int = 0
    /// `notListening`, `documentReads`, `pendingWrites` or `awaitingServerSnapshot`, when the app did not compare.
    var skipped: String?

    var json: [String: Any] {
        var row: [String: Any] = ["key": key, "readerDroppedCount": readerDroppedCount]
        row["serverCount"] = serverCount.map { $0 as Any } ?? NSNull()
        if let localIds { row["localIds"] = localIds }
        if let skipped { row["skipped"] = skipped }
        return row
    }
}

/// `dataParityCheck(...)`. `raw` is the script's result, kept to build the log entry.
nonisolated struct RulebookDataParityResult: @unchecked Sendable {
    var ok: Bool
    var reloadKeys: [String]
    var checkedKeys: [String]
    var raw: [String: Any]
}

/// `dataParitySummary(...)`.
nonisolated struct RulebookDataParitySummary: Equatable, Sendable {
    /// `none`, `ok` or `warning`.
    var tone: String
    var title: String
    var lines: [String]
}

extension CanonicalBusinessEngine {
    /// `DATA_PARITY_CHECKS`. Empty when the script did not load.
    nonisolated static var dataParityChecks: [RulebookDataParityCheckDefinition] {
        guard let rows = dataParityChecksConstant() else { return [] }
        return rows.compactMap { row in
            guard let key = row["key"] as? String, let collection = row["collection"] as? String else { return nil }
            return RulebookDataParityCheckDefinition(
                key: key,
                collection: collection,
                scope: row["scope"] as? String ?? "organization",
                windowed: row["windowed"] as? Bool ?? false,
                label: row["label"] as? String ?? key
            )
        }
    }

    private nonisolated static func dataParityChecksConstant() -> [[String: Any]]? {
        guard let rows = constant("DATA_PARITY_CHECKS", as: [RulebookDataParityCheckRow].self) else { return nil }
        return rows.map { ["key": $0.key, "collection": $0.collection, "scope": $0.scope, "windowed": $0.windowed, "label": $0.label] }
    }

    /// `DATA_PARITY_CONFIRM_DELAY_MS` (5 seconds when the script did not load): the wait before the second look.
    nonisolated static var dataParityConfirmDelayMs: Double {
        constant("DATA_PARITY_CONFIRM_DELAY_MS", as: Double.self) ?? 5_000
    }

    /// `dataParityConfirm({ first, confirm })`: the two-look rule — only the lists the second look found different
    /// again are re-read. Nil when the script does not answer (nothing is re-read then).
    nonisolated static func dataParityConfirm(
        first: RulebookDataParityResult,
        confirm: RulebookDataParityResult?
    ) -> RulebookDataParityResult? {
        let input: [String: Any] = ["first": first.raw, "confirm": confirm.map { $0.raw as Any } ?? NSNull()]
        guard let raw = callJSON("dataParityConfirm", arguments: [input]) as? [String: Any] else { return nil }
        return RulebookDataParityResult(
            ok: raw["ok"] as? Bool ?? false,
            reloadKeys: raw["reloadKeys"] as? [String] ?? [],
            checkedKeys: raw["checked"] as? [String] ?? [],
            raw: raw
        )
    }

    /// `DATA_PARITY_MIN_INTERVAL_MS` (10 minutes when the script did not load).
    nonisolated static var dataParityMinIntervalMs: Double {
        constant("DATA_PARITY_MIN_INTERVAL_MS", as: Double.self) ?? 600_000
    }

    /// `dataParityCheckDue({ trigger, lastCheckedMs, nowMs, online })`. False when the script does not answer.
    nonisolated static func dataParityCheckDue(trigger: String, lastCheckedMs: Double?, nowMs: Double, online: Bool) -> Bool {
        let input: [String: Any] = [
            "trigger": trigger,
            "lastCheckedMs": lastCheckedMs.map { $0 as Any } ?? NSNull(),
            "nowMs": nowMs,
            "online": online,
        ]
        return callJSON("dataParityCheckDue", arguments: [input]) as? Bool ?? false
    }

    /// `dataParityCheck({ lists })`. Nil when the script does not answer (nothing is reloaded then).
    nonisolated static func dataParityCheck(lists: [RulebookDataParityListInput]) -> RulebookDataParityResult? {
        guard let raw = callJSON("dataParityCheck", arguments: [["lists": lists.map(\.json)]]) as? [String: Any] else {
            return nil
        }
        return RulebookDataParityResult(
            ok: raw["ok"] as? Bool ?? false,
            reloadKeys: raw["reloadKeys"] as? [String] ?? [],
            checkedKeys: raw["checked"] as? [String] ?? [],
            raw: raw
        )
    }

    /// `dataParityLogEntry({ atMs, trigger, first, recheck })` as stored JSON.
    nonisolated static func dataParityLogEntry(
        atMs: Double,
        trigger: String,
        first: RulebookDataParityResult,
        recheck: RulebookDataParityResult?
    ) -> [String: Any]? {
        let input: [String: Any] = [
            "atMs": atMs,
            "trigger": trigger,
            "first": first.raw,
            "recheck": recheck.map { $0.raw as Any } ?? NSNull(),
        ]
        return callJSON("dataParityLogEntry", arguments: [input]) as? [String: Any]
    }

    /// `dataParityLogAppend(log, entry)`: newest last, at most `DATA_PARITY_LOG_LIMIT`.
    nonisolated static func dataParityLogAppend(_ log: [[String: Any]], entry: [String: Any]) -> [[String: Any]] {
        callJSON("dataParityLogAppend", arguments: [log, entry]) as? [[String: Any]] ?? (log + [entry])
    }

    /// `dataParitySummary({ entry, timeZone })`.
    nonisolated static func dataParitySummary(entry: [String: Any]?, timeZone: String) -> RulebookDataParitySummary {
        let input: [String: Any] = ["entry": entry.map { $0 as Any } ?? NSNull(), "timeZone": timeZone]
        guard let raw = callJSON("dataParitySummary", arguments: [input]) as? [String: Any] else {
            return RulebookDataParitySummary(tone: "none", title: "Data check is not available on this device.", lines: [])
        }
        return RulebookDataParitySummary(
            tone: raw["tone"] as? String ?? "none",
            title: raw["title"] as? String ?? "",
            lines: raw["lines"] as? [String] ?? []
        )
    }

    /// `dataParitySumCounts(counts)`: the sum of a plan's disjoint query counts; nil when any is unknown.
    nonisolated static func dataParitySumCounts(_ counts: [Int?]) -> Int? {
        let input: [Any] = counts.map { $0.map { $0 as Any } ?? NSNull() }
        return (callJSON("dataParitySumCounts", arguments: [input]) as? NSNumber)?.intValue
    }

    /// `dataCheckPanelEnabled(config, organizationId)` (owner change 11 Nov): `platformConfig/app.dataCheckPanel` exactly
    /// true, or the organisation listed in `dataCheckPanelOrganizationIds`. Nil when the script did not answer.
    nonisolated static func dataCheckPanelEnabled(config: [String: Any]?, organizationId: String) -> Bool? {
        callJSON("dataCheckPanelEnabled", arguments: [config.map { $0 as Any } ?? NSNull(), organizationId]) as? Bool
    }

    /// `dataCheckPanelVisible({ viewerIsAdmin, dataCheckPanelEnabled })`. False when the script did not answer.
    nonisolated static func dataCheckPanelVisible(viewerIsAdmin: Bool, dataCheckPanelEnabled: Bool) -> Bool {
        let input: [String: Any] = ["viewerIsAdmin": viewerIsAdmin, "dataCheckPanelEnabled": dataCheckPanelEnabled]
        return callJSON("dataCheckPanelVisible", arguments: [input]) as? Bool ?? false
    }
}
