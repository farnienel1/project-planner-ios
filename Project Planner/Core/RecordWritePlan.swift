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
    static func action(mode: RecordSaveMode?, documentExists: Bool) -> RecordWriteAction {
        if documentExists { return .update }
        switch mode {
        case .update: return .refuseDeletedElsewhere
        case .create, .none: return .create
        }
    }
}

/// An edit whose document no longer exists on the server. Final: never retried, never turned into a create.
nonisolated struct RecordDeletedElsewhereError: LocalizedError, Sendable {
    static let message = "This was deleted on another device."
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
    func worksToSave(from projects: [Project]) -> [(work: Project, mode: RecordSaveMode, previous: Project?)] {
        works.compactMap { change in
            projects.first(where: { $0.id == change.id }).map { (work: $0, mode: change.mode, previous: change.previous) }
        }
    }

    func clientsToSave(from all: [Client]) -> [(client: Client, mode: RecordSaveMode, previous: Client?)] {
        clients.compactMap { change in
            all.first(where: { $0.id == change.id }).map { (client: $0, mode: change.mode, previous: change.previous) }
        }
    }
}
