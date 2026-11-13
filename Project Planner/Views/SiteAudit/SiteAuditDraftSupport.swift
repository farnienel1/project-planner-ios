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
/// or the editor closes). Writes run one after another off the main thread; a photo is encoded and written only when
/// it is new or replaced since the last save.
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
    private var debounceTask: Task<Void, Never>?
    private var writeChain: Task<Void, Never>?
    /// The photo object last written for each item (compared by identity, so a replaced photo is written again).
    private var writtenPhotos: [UUID: UIImage] = [:]
    private(set) var isStopped = false

    init(draftId: UUID, userId: String, organizationId: String, store: SiteAuditDraftStore = .shared) {
        self.draftId = draftId
        self.userId = userId
        self.organizationId = organizationId
        self.store = store
    }

    /// A photo read back from the draft on disk is already saved there.
    func markPhotoOnDisk(itemId: UUID, image: UIImage) {
        writtenPhotos[itemId] = image
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

    /// Submit or delete: no more saves; with `deleteDraft` the draft and its photos are removed (after any write
    /// still running, so it cannot come back).
    func stop(deleteDraft: Bool) {
        isStopped = true
        debounceTask?.cancel()
        debounceTask = nil
        guard deleteDraft else { return }
        let store = self.store
        let (draftId, userId, organizationId) = (self.draftId, self.userId, self.organizationId)
        store.delete(draftId: draftId, userId: userId, organizationId: organizationId)
        let chain = writeChain
        Task {
            await chain?.value
            store.delete(draftId: draftId, userId: userId, organizationId: organizationId)
        }
    }

    private func write(_ snapshot: Snapshot) {
        guard !isStopped else { return }
        let changed: [(UUID, UIImage)] = snapshot.images.compactMap { id, image in
            writtenPhotos[id] === image ? nil : (id, image)
        }
        let previous = writeChain
        let store = self.store
        let draft = snapshot.draft
        writeChain = Task { [weak self] in
            await previous?.value
            guard let self, !self.isStopped else { return }
            let saved = await Task.detached(priority: .utility) { () -> Bool in
                var photos: [UUID: Data] = [:]
                for (id, image) in changed {
                    if let data = image.jpegData(compressionQuality: 0.85) { photos[id] = data }
                }
                do {
                    try store.save(draft, photos: photos)
                    return true
                } catch {
                    print("🔥🔥🔥 DEBUG: [SiteAuditDraft] save failed: \(error.localizedDescription)")
                    return false
                }
            }.value
            if self.isStopped {
                // Submitted or deleted while this write ran.
                store.delete(draftId: draft.id, userId: draft.userId, organizationId: draft.organizationId)
                return
            }
            guard saved else { return }
            for (id, image) in changed { self.writtenPhotos[id] = image }
            let current = Set(draft.items.map(\.id))
            self.writtenPhotos = self.writtenPhotos.filter { current.contains($0.key) }
        }
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
