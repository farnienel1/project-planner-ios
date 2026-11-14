//
//  SiteAuditDraftSupport.swift
//  Project Planner
//
//  Owner decisions 12 Nov: site audit drafts saved on the phone as the person works (item 6), and an instant
//  "Submit & generate PDF" that uploads in the background (item 5a).
//

import SwiftUI
import UIKit

/// Saves the open site audit as a draft a moment after each change (and at once when the app goes to the background
/// or the editor closes). Writes run one after another off the main thread; a photo is shrunk, encoded and written
/// only when it is new or replaced (not when it is already written or being written).
@MainActor
final class SiteAuditDraftAutosaver {
    struct Snapshot {
        var draft: SiteAuditDraft
        /// The photo of each item that has one on screen.
        var images: [UUID: UIImage]
    }

    let draftId: UUID
    let userId: String
    let organizationId: String
    private let store: SiteAuditDraftStore
    /// The store's sign-out counter when this editor opened: a save after a sign-out is refused by the store.
    private let epoch: Int
    private var debounceTask: Task<Void, Never>?
    private var writeChain: Task<Void, Never>?
    /// The photo object last written, or being written, for each item (compared by identity, so a replaced photo is
    /// written again and one already on its way is not encoded twice).
    private var queuedPhotos: [UUID: UIImage] = [:]
    private(set) var isStopped = false
    /// A draft file exists for this audit (resumed, or written at least once).
    private(set) var hasDraftOnDisk: Bool

    init(
        draftId: UUID,
        userId: String,
        organizationId: String,
        existsOnDisk: Bool = false,
        store: SiteAuditDraftStore = .shared
    ) {
        self.draftId = draftId
        self.userId = userId
        self.organizationId = organizationId
        self.store = store
        self.epoch = store.currentEpoch
        self.hasDraftOnDisk = existsOnDisk
    }

    /// A photo read back from the draft on disk is already saved there.
    func markPhotoOnDisk(itemId: UUID, image: UIImage) {
        queuedPhotos[itemId] = image
    }

    func schedule(_ snapshot: Snapshot) {
        guard !isStopped else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.write(snapshot)
        }
    }

    func saveNow(_ snapshot: Snapshot) {
        guard !isStopped else { return }
        debounceTask?.cancel()
        debounceTask = nil
        write(snapshot)
    }

    /// Submit: the last state is written with `submittedAt` and kept as a backup until the upload queue saves the
    /// audit (`SiteAuditOfflineStore` then calls `deleteSubmittedDraft`). No more saves after this. Returns once the
    /// write is on disk; call it before starting the upload, so a quick upload's delete cannot run before it. If the
    /// queue has already saved the audit by then (`isStillQueued` false, e.g. the retry timer got there first), the
    /// draft is removed here instead.
    func finishSubmitted(_ snapshot: Snapshot, isStillQueued: () -> Bool) async {
        guard !isStopped else { return }
        debounceTask?.cancel()
        debounceTask = nil
        var submitted = snapshot
        submitted.draft.submittedAt = Date()
        write(submitted)
        isStopped = true
        await writeChain?.value
        if !isStillQueued() {
            let store = self.store
            let id = draftId
            await Task.detached(priority: .utility) { store.deleteSubmittedDraft(id: id) }.value
            SiteAuditDraftNotifications.postChanged()
        }
    }

    private func write(_ snapshot: Snapshot) {
        guard !isStopped else { return }
        let changed: [(UUID, UIImage)] = snapshot.images.compactMap { id, image in
            queuedPhotos[id] === image ? nil : (id, image)
        }
        for (id, image) in changed { queuedPhotos[id] = image }
        let current = Set(snapshot.draft.items.map(\.id))
        queuedPhotos = queuedPhotos.filter { current.contains($0.key) }
        hasDraftOnDisk = true

        let previous = writeChain
        let store = self.store
        let draft = snapshot.draft
        let epoch = self.epoch
        writeChain = Task { [weak self] in
            await previous?.value
            let failedPhotoIds = await Task.detached(priority: .utility) { () -> [UUID] in
                var photos: [UUID: Data] = [:]
                for (id, image) in changed {
                    // The same size and quality the upload uses (`preparedForUpload`), not the full camera image.
                    if let data = SiteAuditMediaProcessor.preparedForUpload(image).jpegData(compressionQuality: 0.82) {
                        photos[id] = data
                    }
                }
                do {
                    try store.save(draft, photos: photos, epoch: epoch)
                    return changed.map(\.0).filter { photos[$0] == nil }
                } catch {
                    print("🔥🔥🔥 DEBUG: [SiteAuditDraft] save failed: \(error.localizedDescription)")
                    return changed.map(\.0)
                }
            }.value
            SiteAuditDraftNotifications.postChanged()
            // Not written: forget them, so the next save tries again.
            guard let self else { return }
            for id in failedPhotoIds where self.queuedPhotos[id] === changed.first(where: { $0.0 == id })?.1 {
                self.queuedPhotos[id] = nil
            }
        }
    }
}

/// The Drafts list on the Site Audit hub reloads when a draft is written or removed (the editor's last save lands
/// after the editor has closed).
enum SiteAuditDraftNotifications {
    static let changed = Notification.Name("SiteAuditDraftsDidChange")

    static func postChanged() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// The organisation logo for a site audit PDF: kept in memory after the first load and read from the URL cache when
/// offline, and never waited on for more than a couple of seconds, so "Submit & generate PDF" stays quick.
enum SiteAuditLogoLoader {
    private static var cache: [String: UIImage] = [:]

    static func logo(urlString: String?) async -> UIImage? {
        guard let urlString, let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return nil }
        if let cached = cache[urlString] { return cached }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 2.5)
        request.httpMethod = "GET"
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let image = UIImage(data: data) else { return nil }
        cache[urlString] = image
        return image
    }
}

/// Starts uploading queued site audits now (the queue's own retry timer waits a minute first), and asks iOS for a
/// little time to finish if the person leaves the app straight away. Anything not finished stays queued
/// (`SiteAuditOfflineStore`) and goes on the next pass: foreground, reconnect or the retry timer.
enum SiteAuditBackgroundUpload {
    static func start(smartCache: SmartCacheService, userRetry: Bool = false) {
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "SiteAuditUpload") {
            // iOS calls the expiration handler on the main thread.
            MainActor.assumeIsolated { box.end() }
        }
        Task { @MainActor in
            await smartCache.refreshConnectionAndSync(userRetry: userRetry)
            box.end()
        }
    }

    @MainActor
    private final class BackgroundTaskBox {
        var id: UIBackgroundTaskIdentifier = .invalid
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
