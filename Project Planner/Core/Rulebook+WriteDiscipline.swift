//
//  Rulebook+WriteDiscipline.swift
//  Project Planner
//
//  Rulebook 1.9.0 (docs/RULEBOOK.md §1 "Live screens use real-time listeners" and "Never re-save what you didn't
//  change"): which shared data a screen must listen to (`LIVE_COLLECTIONS`, `liveCollection`, `screenMustListen`),
//  what may start a write (`SYNC_WRITE_TRIGGERS`, `syncWriteAllowed`), which records a save writes (`recordsToSave`),
//  and that an edit of a missing document is refused (`editOfMissingDocumentIsRefused`, `replayRefusedIsFinal`,
//  `EDIT_OF_MISSING_DOCUMENT_MESSAGE`). Web `lib/canonical/liveSources.ts`, called through `CanonicalBusinessEngine`;
//  nothing is decided here.
//

import Foundation

/// `SYNC_WRITE_TRIGGERS`: what started a write. Only `userAction` and `offlineReplay` may write (`syncWriteAllowed`).
nonisolated enum SyncWriteTrigger: String, Sendable, CaseIterable {
    case userAction
    case offlineReplay
    case launch
    case foreground
    case reconnect
    case backgroundSync
    case pullToRefresh
    case listenerSnapshot
    /// RULEBOOK 1.10.0 §7: producing a Weekly Report never writes (`syncWriteAllowed('weeklyReport')` is false).
    case weeklyReport
}

/// One `LIVE_COLLECTIONS` row.
nonisolated struct CanonicalLiveCollection: Decodable, Equatable, Sendable {
    let id: String
    let path: String
    let scope: String
    let listen: Bool
    let note: String
}

extension CanonicalBusinessEngine {
    // MARK: Live screens

    /// `LIVE_COLLECTIONS`. Empty when the script did not answer.
    nonisolated static var liveCollections: [CanonicalLiveCollection] {
        constant("LIVE_COLLECTIONS", as: [CanonicalLiveCollection].self) ?? []
    }

    /// `liveCollection(id)`: the row for an id (exact, then without case). Nil when unknown.
    nonisolated static func liveCollection(_ id: String) -> CanonicalLiveCollection? {
        guard let row = callJSON("liveCollection", arguments: [id]) as? [String: Any],
              let rowId = row["id"] as? String else { return nil }
        return CanonicalLiveCollection(
            id: rowId,
            path: row["path"] as? String ?? "",
            scope: row["scope"] as? String ?? "organization",
            listen: row["listen"] as? Bool ?? true,
            note: row["note"] as? String ?? ""
        )
    }

    /// `screenMustListen(id)`: an unknown id is live (true).
    nonisolated static func screenMustListen(_ id: String) -> Bool {
        callJSON("screenMustListen", arguments: [id]) as? Bool ?? true
    }

    // MARK: Never re-save what you didn't change

    /// `SYNC_WRITE_TRIGGERS`, as the script lists them. Empty when the script did not answer.
    nonisolated static var syncWriteTriggers: [String] {
        constant("SYNC_WRITE_TRIGGERS", as: [String].self) ?? []
    }

    /// `syncWriteAllowed(trigger)`: true only for `userAction` and `offlineReplay`. False when the script did not
    /// answer (nothing is written without the rule).
    nonisolated static func syncWriteAllowed(_ trigger: SyncWriteTrigger) -> Bool {
        callJSON("syncWriteAllowed", arguments: [trigger.rawValue]) as? Bool ?? false
    }

    /// RULEBOOK 1.10.0 §1: `syncWriteAllowed(trigger, migration)` — a migration named in `IDEMPOTENT_MIGRATION_WRITES`
    /// (the warning-key migration, `warningResolutionMigrationWrites`) may run from a scan.
    nonisolated static func syncWriteAllowed(_ trigger: SyncWriteTrigger, migration: String) -> Bool {
        callJSON("syncWriteAllowed", arguments: [trigger.rawValue, migration]) as? Bool ?? false
    }

    /// `recordsToSave(records, changedIds)`: the ids (as given in `recordIds`) the user changed in this action,
    /// matched without case. Nil when the script did not answer.
    nonisolated static func recordsToSave(recordIds: [String], changedIds: [String]) -> [String]? {
        let rows = recordIds.map { ["id": $0] }
        guard let kept = callJSON("recordsToSave", arguments: [rows, changedIds]) as? [[String: Any]] else { return nil }
        return kept.compactMap { $0["id"] as? String }
    }

    /// `editOfMissingDocumentIsRefused({ isCreate, exists, code })`: an edit (`isCreate` false) whose document the
    /// read found missing (`exists` false) or the server answered not-found (`5`). Nil `isCreate` is unknown
    /// (never refused). Nil when the script did not answer.
    nonisolated static func editOfMissingDocumentIsRefused(isCreate: Bool?, exists: Bool? = nil, errorCode: Int? = nil) -> Bool? {
        var input: [String: Any] = ["isCreate": isCreate.map { $0 as Any } ?? NSNull()]
        if let exists { input["exists"] = exists }
        if let errorCode { input["code"] = errorCode }
        return callJSON("editOfMissingDocumentIsRefused", arguments: [input]) as? Bool
    }

    /// `replayRefusedIsFinal({ code, isCreate })`: permission-denied (`7`) always; not-found (`5`) on an edit replay.
    nonisolated static func replayRefusedIsFinal(errorCode: Int, isCreate: Bool?) -> Bool {
        let input: [String: Any] = ["code": errorCode, "isCreate": isCreate.map { $0 as Any } ?? NSNull()]
        return callJSON("replayRefusedIsFinal", arguments: [input]) as? Bool ?? false
    }

    /// `EDIT_OF_MISSING_DOCUMENT_MESSAGE` ("This was deleted on another device.").
    nonisolated static var editOfMissingDocumentMessage: String {
        constant("EDIT_OF_MISSING_DOCUMENT_MESSAGE", as: String.self) ?? "This was deleted on another device."
    }
}

/// The gate every write that is not obviously a button press passes (§1): a launch, foreground, reconnect,
/// background sync, pull-to-refresh or listener snapshot never writes a record. App plumbing over `syncWriteAllowed`.
nonisolated enum SyncWriteGate {
    static func allows(_ trigger: SyncWriteTrigger, _ what: @autoclosure () -> String, migration: String? = nil) -> Bool {
        let allowed = migration.map { CanonicalBusinessEngine.syncWriteAllowed(trigger, migration: $0) }
            ?? CanonicalBusinessEngine.syncWriteAllowed(trigger)
        if !allowed {
            NSLog("SYNC_WRITE_REFUSED trigger=%@ what=%@", trigger.rawValue, what())
        }
        return allowed
    }
}
