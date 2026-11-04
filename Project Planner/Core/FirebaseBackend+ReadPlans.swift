//
//  FirebaseBackend+ReadPlans.swift
//  Project Planner
//
//  RULEBOOK 1.10.0 §17 "Reads are enforced": Firestore rules are not filters, so a manager without the Projects /
//  Small works toggle and an operative may not list a whole job or booking collection. Every job and booking read
//  and listener here is built from `jobQueryPlan` / `bookingQueryPlan` (through `CanonicalBusinessEngine`, see
//  `Rulebook+JobAccess.swift`): one Firestore query per plan entry (plus `date >= bookingLoadStart` where the
//  collection has it), merged by document id. Admins and managers with a toggle keep whole collections. The same
//  queries are valid under the rules before 1.10.0. App plumbing only; no rule is decided here.
//

import Foundation
@preconcurrency import FirebaseFirestore

/// One Firestore read a plan entry turns into: a query (with the same query without the date bound, used while
/// the composite index is still building — Firestore answers "failed precondition" then), or one document.
nonisolated struct PlannedReadSource {
    enum Kind {
        case query(Query, withoutDateBound: Query?)
        case document(DocumentReference)
    }
    let kind: Kind
}

/// Several listeners that together are one list: each source's latest documents, merged by document id. Until every
/// source has answered from the server the merged list counts as a cache snapshot (it may only add, never remove).
nonisolated final class PlannedSnapshotMerge<Doc>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [Int: (docs: [Doc], fromCache: Bool)] = [:]
    private let sourceCount: Int
    private let documentId: (Doc) -> String

    init(sourceCount: Int, documentId: @escaping (Doc) -> String) {
        self.sourceCount = sourceCount
        self.documentId = documentId
    }

    func update(source: Int, docs: [Doc], fromCache: Bool) -> (docs: [Doc], fromCache: Bool) {
        lock.lock(); defer { lock.unlock() }
        latest[source] = (docs, fromCache)
        var seen = Set<String>()
        var merged: [Doc] = []
        for index in 0..<sourceCount {
            for doc in latest[index]?.docs ?? [] where seen.insert(documentId(doc)).inserted {
                merged.append(doc)
            }
        }
        let complete = latest.count == sourceCount && !latest.values.contains { $0.fromCache }
        return (merged, !complete)
    }
}

/// One registration standing for several Firestore listeners (one per plan entry).
nonisolated final class CompositeListenerRegistration: NSObject, ListenerRegistration, @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [Int: ListenerRegistration] = [:]
    private var removed = false

    func set(_ index: Int, _ registration: ListenerRegistration) {
        lock.lock()
        if removed {
            lock.unlock()
            registration.remove()
            return
        }
        let previous = parts[index]
        parts[index] = registration
        lock.unlock()
        previous?.remove()
    }

    /// True once `remove()` ran: a scheduled re-attach does nothing then.
    var isRemoved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return removed
    }

    func remove() {
        lock.lock()
        removed = true
        let all = Array(parts.values)
        parts.removeAll()
        lock.unlock()
        all.forEach { $0.remove() }
    }
}

extension FirebaseBackend {
    // MARK: Plans → Firestore

    /// The job reads for `collection` (`projects` / `smallWorks`): `jobQueryPlan(viewer, { documentIds })`, with the
    /// job ids of an operative's own bookings. Before the profile is known (or when the script did not answer) the
    /// whole collection, as before 1.10.0. `signature` names the plan (listener targets re-attach when it changes).
    func jobReadSources(organizationId orgId: String, collection: String) -> (sources: [PlannedReadSource], signature: String) {
        let base = db.collection("organizations").document(orgId).collection(collection)
        guard let viewer = JobAccessContext.readViewer,
              // RULEBOOK 1.26.0 §17: `enforced` is the organisation's `enforcedReads` switch (`securitySwitches`).
              let plan = CanonicalBusinessEngine.jobQueryPlan(
                viewer,
                documentIds: JobAccessContext.operativeJobIds,
                enforced: SecuritySwitchContext.switches(organizationId: orgId).enforcedReads
              ),
              let queries = plan["queries"] as? [[String: Any]] else {
            return ([PlannedReadSource(kind: .query(base, withoutDateBound: nil))], "all")
        }
        var sources: [PlannedReadSource] = []
        var parts: [String] = []
        for query in queries where query["collection"] as? String == collection {
            switch query["kind"] as? String {
            case "all":
                sources.append(PlannedReadSource(kind: .query(base, withoutDateBound: nil)))
                parts.append("all")
            case "managed":
                let field = query["field"] as? String ?? "managerUserIds"
                guard let value = query["value"] as? String, !value.isEmpty else { continue }
                sources.append(PlannedReadSource(kind: .query(base.whereField(field, arrayContains: value), withoutDateBound: nil)))
                parts.append("managed:\(field)=\(value)")
            case "documents":
                for id in query["ids"] as? [String] ?? [] where !id.isEmpty {
                    sources.append(PlannedReadSource(kind: .document(base.document(id))))
                    parts.append("doc:\(id)")
                }
            default:
                continue
            }
        }
        return (sources, parts.joined(separator: ","))
    }

    /// The booking reads for `collection` (`bookings`, `managerSiteBookings`, `subcontractorBookings`):
    /// `bookingQueryPlan(viewer, visibleJobIds, { ownBookingIds })`, adding `date >= start` to `bookings` and
    /// `managerSiteBookings` when the download is bounded. Before the profile is known, the whole collection.
    func bookingReadSources(
        organizationId orgId: String,
        collection: String,
        startingOn start: Date?
    ) -> (sources: [PlannedReadSource], signature: String) {
        let base = db.collection("organizations").document(orgId).collection(collection)
        let datedCollection = collection == "bookings" || collection == "managerSiteBookings"
        func bounded(_ query: Query) -> PlannedReadSource {
            guard datedCollection, let start else { return PlannedReadSource(kind: .query(query, withoutDateBound: nil)) }
            return PlannedReadSource(kind: .query(
                query.whereField("date", isGreaterThanOrEqualTo: Timestamp(date: start)),
                withoutDateBound: query
            ))
        }
        let startPart = start.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        guard let viewer = JobAccessContext.readViewer,
              let plan = CanonicalBusinessEngine.bookingQueryPlan(
                viewer,
                visibleJobIds: JobAccessContext.visibleJobIds,
                ownBookingIds: JobAccessContext.ownBookingIds.isEmpty ? nil : JobAccessContext.ownBookingIds,
                enforced: SecuritySwitchContext.switches(organizationId: orgId).enforcedReads
              ),
              let queries = plan["queries"] as? [[String: Any]] else {
            return ([bounded(base)], "all|\(startPart)")
        }
        var sources: [PlannedReadSource] = []
        var parts: [String] = []
        for query in queries where query["collection"] as? String == collection {
            switch query["kind"] as? String {
            case "all":
                sources.append(bounded(base))
                parts.append("all")
            case "job", "own":
                guard let field = query["field"] as? String,
                      let values = query["values"] as? [String], !values.isEmpty else { continue }
                let filtered: Query = (query["op"] as? String) == "=="
                    ? base.whereField(field, isEqualTo: values[0])
                    : base.whereField(field, in: values)
                sources.append(bounded(filtered))
                parts.append("\(field):\(values.joined(separator: "+"))")
            default:
                continue
            }
        }
        return (sources, parts.joined(separator: ",") + "|\(startPart)")
    }

    // MARK: One-off reads

    /// Every document the plan's queries return, merged by id. A query whose composite index is still building
    /// is read without the date bound. Throws only when every source failed.
    func readPlannedQueryDocuments(_ sources: [PlannedReadSource]) async throws -> [QueryDocumentSnapshot] {
        var seen = Set<String>()
        var out: [QueryDocumentSnapshot] = []
        var firstError: Error?
        var answered = 0
        for source in sources {
            guard case let .query(query, withoutDateBound) = source.kind else { continue }
            do {
                let snapshot: QuerySnapshot
                do {
                    snapshot = try await getQueryPreferringServer(query)
                } catch {
                    guard let withoutDateBound, Self.isFailedPrecondition(error) else { throw error }
                    snapshot = try await getQueryPreferringServer(withoutDateBound)
                }
                answered += 1
                for doc in snapshot.documents where seen.insert(doc.documentID).inserted { out.append(doc) }
            } catch {
                NSLog("PLANNED_READ_FAILED error=%@", error.localizedDescription)
                if firstError == nil { firstError = error }
            }
        }
        if answered == 0, let firstError { throw firstError }
        return out
    }

    /// Every document the plan names (queries and single documents), as `(id, data)` rows for a rulebook reader.
    func readPlannedRows(_ sources: [PlannedReadSource]) async throws -> LiveDocumentRows {
        var rows: LiveDocumentRows = []
        var seen = Set<String>()
        let queryDocs = try await readPlannedQueryDocuments(sources.filter {
            if case .query = $0.kind { return true } else { return false }
        })
        for doc in queryDocs where seen.insert(doc.documentID).inserted { rows.append((id: doc.documentID, data: doc.data())) }
        for source in sources {
            guard case let .document(ref) = source.kind, !seen.contains(ref.documentID) else { continue }
            do {
                let snapshot = try await ref.getDocument()
                guard snapshot.exists, let data = snapshot.data() else { continue }
                seen.insert(ref.documentID)
                rows.append((id: ref.documentID, data: data))
            } catch {
                // A job the operative may not read (or that is gone) is simply not listed.
                NSLog("PLANNED_DOCUMENT_READ_FAILED path=%@ error=%@", ref.path, error.localizedDescription)
            }
        }
        return rows
    }

    /// Firestore "permission denied" (code 7): the security rules refused the read.
    nonisolated static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7
    }

    nonisolated static func isFailedPrecondition(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 9
    }

    // MARK: Listeners

    /// One listener per plan source, merged into one list (`PlannedSnapshotMerge`). With no source (an operative
    /// with no bookings yet), one empty server answer. `onChange` runs on the main actor.
    nonisolated static func listenPlannedSources<Doc>(
        _ sources: [PlannedReadSource],
        label: String,
        fromQueryDocument: @escaping (QueryDocumentSnapshot) -> Doc,
        fromDocument: @escaping (DocumentSnapshot) -> Doc?,
        documentId: @escaping (Doc) -> String,
        onRefused: (@MainActor () -> Void)? = nil,
        onChange: @escaping @MainActor (_ docs: [Doc], _ fromCache: Bool) -> Void
    ) -> ListenerRegistration {
        let registration = CompositeListenerRegistration()
        guard !sources.isEmpty else {
            Task { @MainActor in onChange([], false) }
            return registration
        }
        let merge = PlannedSnapshotMerge<Doc>(sourceCount: sources.count, documentId: documentId)
        func deliver(_ index: Int, _ docs: [Doc], _ fromCache: Bool) {
            let merged = merge.update(source: index, docs: docs, fromCache: fromCache)
            Task { @MainActor in onChange(merged.docs, merged.fromCache) }
        }
        func attach(_ index: Int, _ query: Query, fallback: Query?, attempt: Int = 0) {
            let listener = query.addSnapshotListener { snapshot, error in
                if let error {
                    if let fallback, Self.isFailedPrecondition(error) {
                        // The composite index is still building: listen without the date bound.
                        attach(index, fallback, fallback: nil)
                        return
                    }
                    NSLog("PLANNED_LISTENER_FAILED label=%@ source=%d attempt=%d error=%@", label, index, attempt, error.localizedDescription)
                    // Counted as answered (from cache), so the other sources can still add their rows.
                    deliver(index, [], true)
                    // RULEBOOK 1.26.0: refused by the rules (a security switch the plan did not know about yet, or a
                    // passing refusal: billing reopened, a membership or token race). The owner also marks this plan for
                    // re-attach, so the next re-plan (switch change, foreground, plan input) replaces it — which removes
                    // this registration and so cancels its pending retry: never two listeners for one target.
                    if Self.isPermissionDenied(error), let onRefused {
                        Task { @MainActor in onRefused() }
                    }
                    // A failed listener is dead: say so (the "Last updated" offline state) and attach it again
                    // with backoff (2 s, 4 s, … up to 60 s) until it answers or the plan is replaced. The other sources
                    // of the plan keep delivering; this one counts as answered from cache meanwhile.
                    Self.postPlannedListenerFailed(label: label, error: error)
                    let delay = Self.plannedListenerRetryDelay(attempt: attempt)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard !registration.isRemoved else { return }
                        attach(index, query, fallback: nil, attempt: attempt + 1)
                    }
                    return
                }
                guard let snapshot else { return }
                deliver(index, snapshot.documents.map(fromQueryDocument), snapshot.metadata.isFromCache)
            }
            registration.set(index, listener)
        }
        for (index, source) in sources.enumerated() {
            switch source.kind {
            case let .query(query, withoutDateBound):
                attach(index, query, fallback: withoutDateBound)
            case let .document(ref):
                let listener = ref.addSnapshotListener { snapshot, error in
                    if let error {
                        NSLog("PLANNED_DOCUMENT_LISTENER_FAILED path=%@ error=%@", ref.path, error.localizedDescription)
                        deliver(index, [], false)
                        // A job the operative may not read (or that is gone) is simply not listed; not a refusal of
                        // the plan, so it is not re-attached.
                        return
                    }
                    guard let snapshot else { return }
                    let doc = snapshot.exists ? fromDocument(snapshot) : nil
                    deliver(index, doc.map { [$0] } ?? [], snapshot.metadata.isFromCache)
                }
                registration.set(index, listener)
            }
        }
        return registration
    }

    /// Seconds before a failed planned listener is attached again: 2, 4, 8, 16, 32, then 60.
    nonisolated static func plannedListenerRetryDelay(attempt: Int) -> Double {
        min(60, pow(2, Double(min(max(attempt, 0), 6) + 1)))
    }

    /// Tells the screens a planned listener failed (`.plannedListenerFailed`; bookings and manager bookings also
    /// `.bookingsListenerFailed`, which shows the offline "Last updated" state).
    nonisolated static func postPlannedListenerFailed(label: String, error: Error) {
        let info: [String: Any] = ["label": label, "error": error.localizedDescription]
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .plannedListenerFailed, object: nil, userInfo: info)
            if label == "bookings" || label == "managerSiteBookings" {
                NotificationCenter.default.post(name: .bookingsListenerFailed, object: nil, userInfo: info)
            }
        }
    }

    /// `listenOrganizationQuery` for a planned read: one registry entry (`key`) whose target is the plan, so a
    /// new plan replaces the old listeners and the same plan is a no-op. Rows go to a rulebook reader.
    func listenOrganizationPlan(
        key: String,
        organizationId: String,
        plan: (sources: [PlannedReadSource], signature: String),
        onChange: @escaping @MainActor (_ rows: LiveDocumentRows, _ fromCache: Bool) -> Void
    ) {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty, isAuthenticated else { return }
        let target = "\(key):\(orgId)|plan:\(plan.signature)"
        let registry = liveListeners
        guard registry.needsAttach(key: key, target: target) else { return }
        let tokenBox = PlannedListenerToken()
        let registration = Self.listenPlannedSources(
            plan.sources,
            label: key,
            fromQueryDocument: { (id: $0.documentID, data: $0.data()) },
            fromDocument: { snapshot in snapshot.data().map { (id: snapshot.documentID, data: $0) } },
            documentId: { $0.id },
            onRefused: {
                // Keep this listener (it retries on backoff) but let the next re-plan replace it — only this one,
                // never a newer replacement.
                if let token = tokenBox.value { registry.markForReattach(key: key, token: token) }
            }
        ) { [weak self] rows, fromCache in
            guard let self, self.acceptsLiveSnapshot(organizationId: orgId) else { return }
            onChange(rows, fromCache)
        }
        tokenBox.value = registry.set(key: key, target: target, remove: { registration.remove() })
    }
}

/// The registry token of a planned listener, set right after it is stored (`listenOrganizationPlan`).
nonisolated final class PlannedListenerToken: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UUID?
    var value: UUID? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
