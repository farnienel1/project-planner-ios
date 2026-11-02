//
//  OrgLiveListeners.swift
//  Project Planner
//
//  RULEBOOK §1 "Live screens use real-time listeners": a screen showing shared data listens for changes so a
//  save on web appears here without a refresh. App plumbing only: every snapshot is read through the same
//  rulebook reader as the one-off load (`parseHolidayDocuments`, `parseWorkDocument` via `jobs(fromDocuments:)`,
//  `parseClientDocument`, `parseOperativeDocument`, `parseManagerDocument`, `parseSubcontractorDocument`,
//  `parseSubcontractorBookingDocument`, `parseTaskDocument`, `parseJobTypesDocument`,
//  `parseMaterialSendRecordDocument`, all through `CanonicalBusinessEngine`), and no business rule is computed here.
//
//  One listener per collection per organisation (never per row). All of them live in `OrgListenerRegistry`,
//  which `FirebaseBackend.stopScheduleLiveListeners()` empties on an organisation switch and on sign-out
//  (AGENTS rule 2: never keep another company's listener). Firestore serves the cached copy first and
//  offline, and the same listener resumes with server data when the connection returns.
//

import Foundation
@preconcurrency import FirebaseFirestore

extension Notification.Name {
    /// A live listener changed an input of the warnings scan (annual leave, operatives, managers, dismissed
    /// warnings). RULEBOOK §5: "Warnings refresh whenever bookings, leave, settings or users change".
    static let liveWarningInputsDidChange = Notification.Name("liveWarningInputsDidChange")
    /// The organisation's `annualLeaveDefaults` arrived or changed: users parsed with
    /// `annualLeaveDefaultsPending` are read again (`parseUserDocument`).
    static let organizationAnnualLeaveDefaultsDidChange = Notification.Name("organizationAnnualLeaveDefaultsDidChange")
}

/// Every organisation-scoped live listener this session holds, keyed by name ("holidayBookings",
/// "timesheet", "materialSendRecords", …). Attaching the same target again is a no-op; a different target
/// for the same key replaces the old listener.
nonisolated final class OrgListenerRegistry: @unchecked Sendable {
    private struct Entry {
        let target: String
        let token: UUID
        let remove: () -> Void
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    init() {}

    /// True when `key` has no listener for `target` (a new one should attach).
    func needsAttach(key: String, target: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Same rule as `LaunchStartupPolicy.shouldAttachListener` (kept here: this type is nonisolated).
        let requested = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return false }
        return entries[key]?.target != requested
    }

    /// Stores the listener for `key`, removing any other one it replaces. Returns its token.
    @discardableResult
    func set(key: String, target: String, remove: @escaping () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        let previous = entries[key]
        entries[key] = Entry(target: target, token: token, remove: remove)
        lock.unlock()
        previous?.remove()
        return token
    }

    /// Removes `key`'s listener, or only the one with `token` when given (a failed listener drops itself so the
    /// next foreground can attach it again, without removing a newer replacement).
    func remove(key: String, token: UUID? = nil) {
        lock.lock()
        let entry = entries[key]
        if let entry, token == nil || entry.token == token {
            entries[key] = nil
        } else {
            lock.unlock()
            return
        }
        lock.unlock()
        entry?.remove()
    }

    /// Organisation switch and sign-out.
    func removeAll() {
        lock.lock()
        let all = Array(entries.values)
        entries.removeAll()
        lock.unlock()
        all.forEach { $0.remove() }
    }

    func isAttached(key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[key] != nil
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}

/// How a listener snapshot replaces an in-memory list (the bookings rule, `BookingStore.applyRemoteBookings`):
/// a server snapshot is the whole collection and replaces the list, so a record deleted on web leaves this
/// device too. A cache snapshot never empties a list already on screen, and a shorter one only adds and updates.
enum LiveSnapshotMerge {
    /// The list to publish, or nil when the snapshot must not change what is on screen.
    static func apply<T: Identifiable>(existing: [T], incoming: [T], fromCache: Bool) -> [T]? {
        guard fromCache else { return incoming }
        if incoming.isEmpty && !existing.isEmpty { return nil }
        guard incoming.count < existing.count else { return incoming }
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [T.ID] = []
        var seen = Set<T.ID>()
        for item in existing where seen.insert(item.id).inserted { order.append(item.id) }
        for item in incoming {
            if seen.insert(item.id).inserted { order.append(item.id) }
            byId[item.id] = item
        }
        return order.compactMap { byId[$0] }
    }
}

/// The registry token of one listener, set after the listener is created (its error handler reads it).
nonisolated final class LiveListenerToken: @unchecked Sendable {
    var value: UUID?
    init() {}
}

typealias LiveDocumentRows = [(id: String, data: [String: Any])]

extension FirebaseBackend {
    /// Whether a listener snapshot for `organizationId` still belongs to the open organisation.
    func acceptsLiveSnapshot(organizationId: String) -> Bool {
        WarningsBookingScanScheduler.acceptsListener(
            listenerOrganizationId: organizationId,
            currentOrganizationId: currentOrganization?.firestoreDocumentId,
            sessionOrganizationId: sessionOrganizationId
        )
    }

    /// One snapshot listener on a query under `organizations/{orgId}`, registered as `key`. Calling it again for
    /// the same key and target does nothing (foreground re-attach is free); a failed listener removes itself.
    /// `onChange` runs on the main actor with the documents as `(id, data)` rows for the rulebook reader.
    func listenOrganizationQuery(
        key: String,
        organizationId: String,
        targetSuffix: String = "",
        query makeQuery: (DocumentReference) -> Query,
        onChange: @escaping @MainActor (_ rows: LiveDocumentRows, _ fromCache: Bool) -> Void
    ) {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty, isAuthenticated else { return }
        let target = "\(key):\(orgId)|\(targetSuffix)"
        let registry = liveListeners
        guard registry.needsAttach(key: key, target: target) else { return }
        let token = LiveListenerToken()
        let registration = makeQuery(db.collection("organizations").document(orgId))
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    NSLog("LIVE_LISTENER_FAILED key=%@ org=%@ error=%@", key, orgId, error.localizedDescription)
                    Task { @MainActor in
                        if let value = token.value { registry.remove(key: key, token: value) }
                    }
                    return
                }
                guard let snapshot else { return }
                let fromCache = snapshot.metadata.isFromCache
                let rows: LiveDocumentRows = snapshot.documents.map { (id: $0.documentID, data: $0.data()) }
                Task { @MainActor in
                    guard let self, self.acceptsLiveSnapshot(organizationId: orgId) else { return }
                    onChange(rows, fromCache)
                }
            }
        token.value = registry.set(key: key, target: target, remove: { registration.remove() })
    }

    /// One snapshot listener on a single document under `organizations/{orgId}`. `data` is nil when the
    /// document does not exist. `hasPendingWrites` is true for this device's own unsent write.
    func listenOrganizationDocument(
        key: String,
        organizationId: String,
        document makeRef: (DocumentReference) -> DocumentReference,
        onChange: @escaping @MainActor (_ data: [String: Any]?, _ fromCache: Bool, _ hasPendingWrites: Bool) -> Void
    ) {
        let orgId = normalizedOrganizationId(organizationId)
        guard !orgId.isEmpty, isAuthenticated else { return }
        let ref = makeRef(db.collection("organizations").document(orgId))
        let target = "\(key):\(ref.path)"
        let registry = liveListeners
        guard registry.needsAttach(key: key, target: target) else { return }
        let token = LiveListenerToken()
        let registration = ref.addSnapshotListener { [weak self] snapshot, error in
            if let error {
                NSLog("LIVE_LISTENER_FAILED key=%@ path=%@ error=%@", key, ref.path, error.localizedDescription)
                Task { @MainActor in
                    if let value = token.value { registry.remove(key: key, token: value) }
                }
                return
            }
            guard let snapshot else { return }
            let fromCache = snapshot.metadata.isFromCache
            let pending = snapshot.metadata.hasPendingWrites
            let data = snapshot.exists ? snapshot.data() : nil
            Task { @MainActor in
                guard let self, self.acceptsLiveSnapshot(organizationId: orgId) else { return }
                onChange(data, fromCache, pending)
            }
        }
        token.value = registry.set(key: key, target: target, remove: { registration.remove() })
    }

    /// Stops one keyed listener (a screen that listened while open has closed).
    func stopLiveListener(key: String) {
        liveListeners.remove(key: key)
    }

    /// Live `materialSendRecords` for one job while its order history is open (`parseMaterialSendRecordDocument`
    /// via `materialSendRecord(documentId:data:)`), newest first. The screen stops it when it closes.
    func listenMaterialSendRecords(
        organizationId: String,
        projectId: UUID,
        onChange: @escaping @MainActor ([MaterialSendRecord]) -> Void
    ) {
        let values = JobKeys.queryValues(for: projectId)
        listenOrganizationQuery(
            key: "materialSendRecords",
            organizationId: organizationId,
            targetSuffix: projectId.uuidString,
            query: { $0.collection("materialSendRecords").whereField("projectId", in: values) }
        ) { rows, fromCache in
            guard !fromCache else { return }
            let records = rows.compactMap { FirebaseBackend.materialSendRecord(documentId: $0.id, data: $0.data) }
                .sorted { $0.sentAt > $1.sentAt }
            onChange(records)
        }
    }

    /// `dismissedWarnings` (RULEBOOK §5): the warnings scan reads the keys fresh each time; this listener only
    /// asks for a rescan when another device dismisses or restores a warning.
    func startDismissedWarningsListener(organizationId: String) {
        listenOrganizationQuery(
            key: "dismissedWarnings",
            organizationId: organizationId,
            query: { $0.collection("dismissedWarnings") }
        ) { _, fromCache in
            guard !fromCache else { return }
            NotificationCenter.default.post(name: .liveWarningInputsDidChange, object: nil)
        }
    }
}
