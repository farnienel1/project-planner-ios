//
//  RecordWritePlan.swift
//  Project Planner
//
//  RULEBOOK §1 "Partial writes only" and §2 (organisation records are online only): a save names whether it
//  creates a new record or edits one the user opened. An edit never re-creates a document deleted on another
//  device. App plumbing only — the fields written still come from the rulebook's partial-write helpers
//  (`jobWriteFields`, `clientWriteFields`, `operativeRowWriteFields`, `managerRowWriteFields`) through
//  `CanonicalBusinessEngine.peopleDocumentWrite`.
//

import Foundation

/// What the user did to the record being saved.
nonisolated enum RecordSaveMode: Sendable, Equatable {
    /// A record the user just made on this device: the document is created whole.
    case create
    /// An edit of a record that already exists on the server: a partial update only.
    case update
}

/// What a save does once the server copy has been read.
nonisolated enum RecordWriteAction: Sendable, Equatable {
    case create
    case update
    /// The edited document is gone from the server (deleted on another device). Nothing is written.
    case refuseDeletedElsewhere
}

nonisolated enum RecordWritePlan {
    /// `mode` nil is the legacy upsert; every save now names its mode (subcontractors and the material catalogue
    /// included), so nil is kept only for the plan's own tests.
    /// RULEBOOK 1.9.0 §1: an edit of a missing document is refused (`editOfMissingDocumentIsRefused`), never
    /// re-created.
    static func action(mode: RecordSaveMode?, documentExists: Bool) -> RecordWriteAction {
        if documentExists { return .update }
        let isCreate: Bool? = mode.map { $0 == .create }
        // Script silent: an edit is still never turned into a create (nothing is created without the rule).
        if CanonicalBusinessEngine.editOfMissingDocumentIsRefused(isCreate: isCreate, exists: false) ?? (isCreate == false) {
            return .refuseDeletedElsewhere
        }
        return .create
    }
}

/// An edit whose document no longer exists on the server. Final: never retried, never turned into a create.
nonisolated struct RecordDeletedElsewhereError: LocalizedError, Sendable {
    /// `EDIT_OF_MISSING_DOCUMENT_MESSAGE`.
    static var message: String { CanonicalBusinessEngine.editOfMissingDocumentMessage }
    let collection: String
    let documentId: String

    var errorDescription: String? { Self.message }
}

/// The records one ProjectStore action changed. Only these are written; the rest of the in-memory list is
/// never re-saved (a stale copy would overwrite web edits).
struct ProjectStoreChangeSet {
    struct Work {
        let id: UUID
        let mode: RecordSaveMode
        let previous: Project?
    }

    struct ClientChange {
        let id: UUID
        let mode: RecordSaveMode
        let previous: Client?
    }

    var works: [Work] = []
    var clients: [ClientChange] = []
    /// What started this save (`SYNC_WRITE_TRIGGERS`). Every ProjectStore change set is a user action; a launch,
    /// foreground or listener path that built one would be refused by `syncWriteAllowed`.
    var trigger: SyncWriteTrigger = .userAction

    /// Local cache only (a delete already written, or clearing data): nothing goes to Firestore.
    static let localOnly = ProjectStoreChangeSet()

    static func createWork(_ work: Project) -> ProjectStoreChangeSet {
        ProjectStoreChangeSet(works: [Work(id: work.id, mode: .create, previous: nil)])
    }

    static func updateWork(_ work: Project, previous: Project?) -> ProjectStoreChangeSet {
        ProjectStoreChangeSet(works: [Work(id: work.id, mode: .update, previous: previous)])
    }

    static func createClient(_ client: Client) -> ProjectStoreChangeSet {
        ProjectStoreChangeSet(clients: [ClientChange(id: client.id, mode: .create, previous: nil)])
    }

    static func updateClient(_ client: Client, previous: Client?) -> ProjectStoreChangeSet {
        ProjectStoreChangeSet(clients: [ClientChange(id: client.id, mode: .update, previous: previous)])
    }

    var isEmpty: Bool { works.isEmpty && clients.isEmpty }

    /// The in-memory records this change set names, with how each is saved. A record no longer in memory
    /// (deleted while the save waited) is skipped.
    /// `recordsToSave(records, changedIds)`: only the in-memory records this change set names.
    private static func kept(recordIds: [UUID], changedIds: [UUID]) -> Set<String> {
        let all = recordIds.map(\.uuidString)
        let changed = changedIds.map(\.uuidString)
        let ids = CanonicalBusinessEngine.recordsToSave(recordIds: all, changedIds: changed)
            ?? all.filter { Set(changed).contains($0) } // script silent: the exact ids named, nothing more
        return Set(ids.map { $0.lowercased() })
    }

    func worksToSave(from projects: [Project]) -> [(work: Project, mode: RecordSaveMode, previous: Project?)] {
        guard !works.isEmpty, SyncWriteGate.allows(trigger, "ProjectStore works") else { return [] }
        let keep = Self.kept(recordIds: projects.map(\.id), changedIds: works.map(\.id))
        return works.compactMap { change in
            guard keep.contains(change.id.uuidString.lowercased()) else { return nil }
            return projects.first(where: { $0.id == change.id }).map { (work: $0, mode: change.mode, previous: change.previous) }
        }
    }

    func clientsToSave(from all: [Client]) -> [(client: Client, mode: RecordSaveMode, previous: Client?)] {
        guard !clients.isEmpty, SyncWriteGate.allows(trigger, "ProjectStore clients") else { return [] }
        let keep = Self.kept(recordIds: all.map(\.id), changedIds: clients.map(\.id))
        return clients.compactMap { change in
            guard keep.contains(change.id.uuidString.lowercased()) else { return nil }
            return all.first(where: { $0.id == change.id }).map { (client: $0, mode: change.mode, previous: change.previous) }
        }
    }
}
