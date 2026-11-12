//
//  DataParityListenerLedger.swift
//  Project Planner
//
//  RULEBOOK 1.38.0 §27 "Data check" (review fix): what each live listener actually received from Firestore — the
//  document ids exactly as stored (case kept, never a `UUID` that folds case), whether its last snapshot carried this
//  device's unconfirmed writes, and whether a server (not cache) snapshot has arrived for its current query. The data
//  check (`DataParityMonitor`) counts these ids, so a placeholder row, a nameless client or a document a reader cannot
//  turn into a record still counts once, exactly as the server's `count()` does. Web counts the same thing (its
//  listener documents, `mergeOrgCollectionSnapshot`). App plumbing only: nothing here decides a rule, and nothing is
//  written anywhere.
//
//  A listener registers with `begin` when it attaches (a new generation replaces the old one, so a removed listener's
//  late callback is ignored), records every snapshot with `record`, and is forgotten with `end` / `removeAll`
//  (organisation switch, sign-out). Snapshots merge by `merge`, the `LiveSnapshotMerge` rule on ids: a server snapshot
//  replaces, a cache snapshot never empties the list and a shorter one only adds.
//

import Foundation

nonisolated final class DataParityListenerLedger: @unchecked Sendable {
    static let shared = DataParityListenerLedger()

    /// The listener's documents and state for one key.
    nonisolated struct Snapshot: Sendable {
        let organizationId: String
        /// Document ids the listener holds, as stored (case kept), once each.
        let ids: [String]
        /// The last snapshot of some part carried this device's writes the server has not confirmed yet.
        let pendingWrites: Bool
        /// Every part has had a server answer (or was refused: its last ids are what the app shows).
        let serverSnapshot: Bool
        /// The legacy `INITIAL-PLACEHOLDER` job document the readers drop (`workDocuments`), as received.
        var placeholderCount: Int { ids.filter { $0 == "INITIAL-PLACEHOLDER" }.count }
    }

    private struct Source {
        var ids: [String] = []
        var pending = false
        var server = false
        var failed = false
    }

    private struct Entry {
        let generation: Int
        let organizationId: String
        let sourceCount: Int
        var sources: [Int: Source] = [:]
    }

    private var entries: [String: Entry] = [:]
    private var nextGeneration = 0
    private let lock = NSLock()

    init() {}

    /// A listener for `key` attaches (with `sourceCount` parts). Returns its generation for `record`.
    func begin(key: String, organizationId: String, sourceCount: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextGeneration += 1
        entries[key] = Entry(generation: nextGeneration, organizationId: organizationId, sourceCount: max(0, sourceCount))
        return nextGeneration
    }

    /// One snapshot of part `source`. Ignored when a newer listener replaced this one.
    func record(key: String, generation: Int, source: Int, ids: [String], fromCache: Bool, hasPendingWrites: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key], entry.generation == generation else { return }
        var part = entry.sources[source] ?? Source()
        part.ids = Self.merge(existing: part.ids, incoming: ids, fromCache: fromCache)
        part.pending = hasPendingWrites
        part.server = part.server || !fromCache
        part.failed = false
        entry.sources[source] = part
        entries[key] = entry
    }

    /// Part `source` was refused by the server: its last ids stay (that is what the app shows).
    func markFailed(key: String, generation: Int, source: Int) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key], entry.generation == generation else { return }
        var part = entry.sources[source] ?? Source()
        part.failed = true
        entry.sources[source] = part
        entries[key] = entry
    }

    func end(key: String) {
        lock.lock(); entries[key] = nil; lock.unlock()
    }

    func removeAll() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }

    /// The listener's state for `key` in `organizationId`; nil when no listener of that organisation is recorded.
    func snapshot(key: String, organizationId: String) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key], Self.sameOrganization(entry.organizationId, organizationId) else { return nil }
        var seen = Set<String>()
        var ids: [String] = []
        for index in entry.sources.keys.sorted() {
            for id in entry.sources[index]?.ids ?? [] where seen.insert(id).inserted { ids.append(id) }
        }
        let answered = (0..<entry.sourceCount).allSatisfy { index in
            guard let part = entry.sources[index] else { return false }
            return part.server || part.failed
        }
        return Snapshot(
            organizationId: entry.organizationId,
            ids: ids,
            pendingWrites: entry.sources.values.contains { $0.pending },
            serverSnapshot: answered
        )
    }

    /// The `LiveSnapshotMerge.apply` rule on document ids: a server snapshot is the collection; a cache snapshot never
    /// empties a list and a shorter one only adds ids. Pure, so `DataParityFixtureTests` runs this exact code.
    static func merge(existing: [String], incoming: [String], fromCache: Bool) -> [String] {
        guard fromCache else { return incoming }
        if incoming.isEmpty && !existing.isEmpty { return existing }
        guard incoming.count < existing.count else { return incoming }
        var seen = Set<String>()
        var out: [String] = []
        for id in existing + incoming where seen.insert(id).inserted { out.append(id) }
        return out
    }

    private static func sameOrganization(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
