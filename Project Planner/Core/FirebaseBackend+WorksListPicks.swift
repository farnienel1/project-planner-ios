//
//  FirebaseBackend+WorksListPicks.swift
//  Project Planner
//
//  RULEBOOK 1.33.0 §21: the person's "My Projects" / "My Small works" picks, live from
//  `organizations/{orgId}/worksListPicks/{uid}` (`myWorksPicksPath`), so a change on web or another device shows here at
//  once. Which jobs are on the list, the pre-fill and the order are the rulebook's (`myWorksList`, `myWorksPickerRows`);
//  this file only reads and writes the document (web `lib/works/useMyWorksPicks.ts`). The security rules let only the
//  person read and write their own document.
//

import Combine
import Foundation
@preconcurrency import FirebaseFirestore

extension FirebaseBackend {
    /// Listens to the signed-in person's picks in `organizationId`. `onChange` runs on the main actor with the parsed
    /// picks (`parseMyWorksPicks`; a missing document is never saved), the read error, and whether the snapshot came
    /// from this device's cache (`includeMetadataChanges`, so the switch from the cached copy to the server's answer is
    /// heard). A snapshot for an organisation that is no longer open is dropped. Nil when the path cannot be built.
    func listenMyWorksPicks(
        organizationId: String,
        uid: String,
        onChange: @escaping @MainActor (_ picks: MyWorksPicks, _ error: String?, _ fromCache: Bool) -> Void
    ) -> ListenerRegistration? {
        let orgId = normalizedOrganizationId(organizationId)
        guard let path = CanonicalBusinessEngine.myWorksPicksPath(organizationId: orgId, uid: uid) else { return nil }
        return db.document(path).addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, error in
            let picks = CanonicalBusinessEngine.parseMyWorksPicks(snapshot?.exists == true ? snapshot?.data() : nil)
            let message = error?.localizedDescription
            let fromCache = snapshot?.metadata.isFromCache ?? true
            Task { @MainActor in
                guard let self, self.acceptsLiveSnapshot(organizationId: orgId) else { return }
                onChange(picks, message, fromCache)
            }
        }
    }

    /// 1.33.1 (owner report: My Projects took about 20 s to show): the picks as this device last saw them, read from the
    /// Firestore cache only, so the list paints at once. `onResult` gets nil when the cache does not hold the document
    /// (never read on this device); the live listener then brings the server's answer.
    func readCachedMyWorksPicks(
        organizationId: String,
        uid: String,
        onResult: @escaping @MainActor (_ picks: MyWorksPicks?) -> Void
    ) {
        let orgId = normalizedOrganizationId(organizationId)
        guard let path = CanonicalBusinessEngine.myWorksPicksPath(organizationId: orgId, uid: uid) else {
            onResult(nil)
            return
        }
        db.document(path).getDocument(source: .cache) { [weak self] snapshot, error in
            let picks: MyWorksPicks? = (error == nil && snapshot != nil)
                ? CanonicalBusinessEngine.parseMyWorksPicks(snapshot?.exists == true ? snapshot?.data() : nil)
                : nil
            Task { @MainActor in
                guard let self, self.acceptsLiveSnapshot(organizationId: orgId) else { return }
                onResult(picks)
            }
        }
    }

    /// The document and fields of one kind's save: `myWorksPicksWriteFields(kind, ids, updatedAt)` with `updatedAt` the
    /// server timestamp — exactly what the security rules accept (`projects` / `smallWorks` / `updatedAt` only,
    /// `updatedAt == request.time`) and what web writes (`lib/works/useMyWorksPicks.ts`). No write metadata. Nil when
    /// the path cannot be built or the script did not answer.
    static func myWorksPicksWrite(
        organizationId: String,
        uid: String,
        kind: JobKind,
        ids: [String]
    ) -> (path: String, fields: [String: Any])? {
        let orgId = normalizedOrganizationId(organizationId)
        guard let path = CanonicalBusinessEngine.myWorksPicksPath(organizationId: orgId, uid: uid),
              var fields = CanonicalBusinessEngine.myWorksPicksWriteFields(kind: kind, ids: ids) else { return nil }
        fields["updatedAt"] = FieldValue.serverTimestamp()
        return (path, fields)
    }

    /// Writes one kind's list, merged (the other kind is left as stored). Firestore applies it to this device's cache
    /// at once; the await returns when the server confirms, so callers bound it (`FirestoreWriteAck.run`).
    func writeMyWorksPicks(path: String, fields: [String: Any]) async throws {
        try await db.document(path).setData(fields, merge: true)
    }
}

/// 1.33.1 (owner report: Save stayed on "Saving…" for ever): how a My list save ended.
enum MyWorksPicksSaveOutcome: Equatable {
    /// The server confirmed it.
    case saved
    /// Not confirmed within the wait: Firestore holds it on this phone and sends it (Pending sync).
    case pendingSync
    /// The server refused it (Firestore rolls the cached copy back); the message is shown.
    case refused(String)

    /// Waits for `write` for at most `timeoutSeconds` (`FirestoreWriteAck`). Never waits longer, never throws.
    @MainActor
    static func run(
        timeoutSeconds: Double = FirestoreWriteAck.defaultTimeoutSeconds,
        _ write: @escaping () async throws -> Void
    ) async -> MyWorksPicksSaveOutcome {
        do {
            try await FirestoreWriteAck.run(timeoutSeconds: timeoutSeconds, write)
            return .saved
        } catch is FirestoreWriteAck.TimedOut {
            return .pendingSync
        } catch {
            let text = error.localizedDescription
            return .refused(text.isEmpty ? MyWorksPicksModel.saveFailedMessage : "\(MyWorksPicksModel.saveFailedMessage) \(text)")
        }
    }
}

/// The picks of the signed-in person in the open organisation, for one list screen. Re-subscribes when the
/// organisation or person changes and never shows another company's picks (`FirebaseBackend.currentOrganization`).
@MainActor
final class MyWorksPicksModel: ObservableObject {
    static let saveFailedMessage = "Your list was not saved."
    static let pendingSyncMessage = "Saved on this phone. Pending sync."

    @Published private(set) var picks: MyWorksPicks = .neverSaved
    /// True once the picks are known for this person and organisation: from this device's cache, the server, or (no
    /// cached copy) the rulebook's pre-fill straight away — the list never waits for the server to paint.
    @Published private(set) var loaded = false
    /// True once the server has answered (the shown picks may be the cached copy until then).
    @Published private(set) var confirmedByServer = false
    @Published private(set) var error: String?
    /// The last save is held by Firestore on this phone and not confirmed yet.
    @Published private(set) var pendingSync = false
    /// The last save was refused by the server (shown on the list; the listener brings back the stored list).
    @Published private(set) var saveError: String?

    private var key = ""
    private var registration: ListenerRegistration?
    private var saveGeneration = 0

    /// Starts (or keeps) the listener for `organizationId` / `uid`. Blank ids stop it (the list is then the pre-fill).
    func listen(backend: FirebaseBackend, organizationId: String?, uid: String?) {
        let org = organizationId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let user = uid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let next = org.isEmpty || user.isEmpty ? "" : "\(org)/\(user)"
        guard next != key else { return }
        stop()
        key = next
        guard !next.isEmpty else {
            // No organisation or account to read: the list is the pre-fill (never saved), as after a read error.
            loaded = true
            return
        }
        // Cache first: paint at once with what this device last saw, or the pre-fill when it has nothing.
        backend.readCachedMyWorksPicks(organizationId: org, uid: user) { [weak self] cached in
            guard let self, self.key == next, !self.loaded else { return }
            if let cached { self.apply(cached) }
            self.loaded = true
        }
        registration = backend.listenMyWorksPicks(organizationId: org, uid: user) { [weak self] picks, error, fromCache in
            guard let self, self.key == next else { return }
            self.receive(picks: picks, error: error, fromCache: fromCache)
        }
    }

    /// One listener answer. Publishes only what changed, so a metadata-only snapshot (our own write confirmed) does
    /// not redraw the screen. A read error keeps the picks already shown.
    func receive(picks next: MyWorksPicks, error message: String?, fromCache: Bool) {
        if message == nil { apply(next) }
        if error != message { error = message }
        if !loaded { loaded = true }
        if !fromCache, !confirmedByServer { confirmedByServer = true }
    }

    private func apply(_ next: MyWorksPicks) {
        if picks != next { picks = next }
    }

    /// Saves one kind's list. Throws only when nothing could be written (no path, no answer from the script); then the
    /// sheet shows the error and stays open. Otherwise the write is handed to Firestore — which applies it on this
    /// phone at once — the shown list follows straight away, and the server's answer is awaited in the background for
    /// at most `timeoutSeconds`: confirmed, Pending sync, or refused (shown on the list).
    func save(
        backend: FirebaseBackend,
        organizationId: String?,
        uid: String?,
        kind: JobKind,
        ids: [String],
        timeoutSeconds: Double = FirestoreWriteAck.defaultTimeoutSeconds
    ) throws {
        guard let org = organizationId, let user = uid,
              let write = FirebaseBackend.myWorksPicksWrite(organizationId: org, uid: user, kind: kind, ids: ids) else {
            throw NSError(domain: "MyWorks", code: 400, userInfo: [NSLocalizedDescriptionKey: "Could not save your list. Try again."])
        }
        let written = MyWorksPicks.after(picks, kind: kind, ids: write.fields[kind.rawValue] as? [String] ?? ids)
        start(timeoutSeconds: timeoutSeconds, optimistic: written) {
            try await backend.writeMyWorksPicks(path: write.path, fields: write.fields)
        }
    }

    /// The save's bookkeeping, separate from Firestore so it can be tested. Returns the outcome when it settles.
    @discardableResult
    func start(
        timeoutSeconds: Double = FirestoreWriteAck.defaultTimeoutSeconds,
        optimistic: MyWorksPicks? = nil,
        _ write: @escaping () async throws -> Void
    ) -> Task<MyWorksPicksSaveOutcome, Never> {
        saveGeneration += 1
        let generation = saveGeneration
        saveError = nil
        pendingSync = false
        if let optimistic { apply(optimistic) }
        return Task { @MainActor [weak self] in
            let outcome = await MyWorksPicksSaveOutcome.run(timeoutSeconds: timeoutSeconds, write)
            guard let self, self.saveGeneration == generation else { return outcome }
            switch outcome {
            case .saved:
                self.pendingSync = false
            case .pendingSync:
                self.pendingSync = true
            case .refused(let message):
                self.pendingSync = false
                self.saveError = message
            }
            return outcome
        }
    }

    func stop() {
        registration?.remove()
        registration = nil
        key = ""
        picks = .neverSaved
        loaded = false
        confirmedByServer = false
        error = nil
        pendingSync = false
        saveError = nil
        saveGeneration += 1
    }
}

extension MyWorksPicks {
    /// `picks` with one kind's list replaced (what this device shows while the write is on its way).
    static func after(_ picks: MyWorksPicks, kind: JobKind, ids: [String]) -> MyWorksPicks {
        var next = picks
        if kind == .smallWorks { next.smallWorks = ids } else { next.projects = ids }
        return next
    }
}
