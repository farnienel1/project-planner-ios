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
    /// picks (`parseMyWorksPicks`; a missing document is never saved) or the read error. A snapshot for an organisation
    /// that is no longer open is dropped. Nil when the path cannot be built.
    func listenMyWorksPicks(
        organizationId: String,
        uid: String,
        onChange: @escaping @MainActor (_ picks: MyWorksPicks, _ error: String?) -> Void
    ) -> ListenerRegistration? {
        let orgId = normalizedOrganizationId(organizationId)
        guard let path = CanonicalBusinessEngine.myWorksPicksPath(organizationId: orgId, uid: uid) else { return nil }
        return db.document(path).addSnapshotListener { [weak self] snapshot, error in
            let picks = CanonicalBusinessEngine.parseMyWorksPicks(snapshot?.exists == true ? snapshot?.data() : nil)
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.acceptsLiveSnapshot(organizationId: orgId) else { return }
                onChange(message == nil ? picks : .neverSaved, message)
            }
        }
    }

    /// Saves one kind's list (`myWorksPicksWriteFields`, merged; the other kind is left as stored) with the server time.
    func saveMyWorksPicks(organizationId: String, uid: String, kind: JobKind, ids: [String]) async throws {
        let orgId = normalizedOrganizationId(organizationId)
        guard let path = CanonicalBusinessEngine.myWorksPicksPath(organizationId: orgId, uid: uid),
              var fields = CanonicalBusinessEngine.myWorksPicksWriteFields(kind: kind, ids: ids) else {
            throw NSError(
                domain: "FirebaseBackend",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Could not save your list. Try again."]
            )
        }
        fields["updatedAt"] = FieldValue.serverTimestamp()
        try await db.document(path).setData(fields, merge: true)
    }
}

/// The picks of the signed-in person in the open organisation, for one list screen. Re-subscribes when the
/// organisation or person changes and never shows another company's picks (`FirebaseBackend.currentOrganization`).
@MainActor
final class MyWorksPicksModel: ObservableObject {
    @Published private(set) var picks: MyWorksPicks = .neverSaved
    /// True once the document has been read for this person and organisation.
    @Published private(set) var loaded = false
    @Published private(set) var error: String?

    private var key = ""
    private var registration: ListenerRegistration?

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
        registration = backend.listenMyWorksPicks(organizationId: org, uid: user) { [weak self] picks, error in
            guard let self, self.key == next else { return }
            self.picks = picks
            self.error = error
            self.loaded = true
        }
    }

    func stop() {
        registration?.remove()
        registration = nil
        key = ""
        picks = .neverSaved
        loaded = false
        error = nil
    }
}
