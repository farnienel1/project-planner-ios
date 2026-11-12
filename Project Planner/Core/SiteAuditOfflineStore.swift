//
//  SiteAuditOfflineStore.swift
//  Project Planner
//
//  Queues new site audits created offline until network is available.
//

import Foundation
import UIKit
import Combine

struct PendingSiteAuditRecord: Codable, Identifiable {
    let id: UUID
    let organizationId: String
    /// `var`: each photo's remote URL is written back here as soon as its upload succeeds.
    var audit: SiteAudit
    /// Maps site-audit item id → JPEG filename in the pending folder.
    let localImageNames: [String: String]
    let createdAt: Date
    /// Failed sync passes that counted as tries (missing on records saved before this field: 0). Background timer
    /// passes never count. At `SiteAuditOfflineStore.maxAutoAttempts` the retry timer stops counting this audit;
    /// foreground, reconnect, Retry now and Sync now still try it, and Retry now / Sync now start the count again.
    var attemptCount: Int? = nil
}

@MainActor
final class SiteAuditOfflineStore: ObservableObject {
    static let shared = SiteAuditOfflineStore()

    @Published private(set) var pending: [PendingSiteAuditRecord] = []

    private let indexKey = "site_audit_offline_v1"
    private let folderName = "SiteAuditPending"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        loadIndex()
    }

    var pendingCount: Int { pending.count }

    /// After this many failed uploads a queued audit no longer keeps the background retry timer alive.
    static let maxAutoAttempts = 5

    /// Queued audits the retry timer still retries on its own.
    var retryableCount: Int {
        pending.filter { ($0.attemptCount ?? 0) < Self.maxAutoAttempts }.count
    }

    /// Audits a sync pass is uploading now. A second pass at the same time (sign-out "Sync now" beside a background
    /// pass) skips them. With each uploaded photo's URL saved back to the record as it succeeds, a later pass only
    /// uploads the photos that have not gone yet (a photo whose upload finished but whose URL was not saved, e.g. the
    /// app closed at that moment, can still go twice; the copy is unused).
    private(set) var claimedAuditIds: Set<UUID> = []

    func claimAuditForSync(id: UUID) -> Bool {
        claimedAuditIds.insert(id).inserted
    }

    func releaseAuditClaim(id: UUID) {
        claimedAuditIds.remove(id)
    }

    /// Retry now / Sync now: every queued audit starts its tries again.
    func resetAttempts() {
        guard pending.contains(where: { ($0.attemptCount ?? 0) > 0 }) else { return }
        for index in pending.indices { pending[index].attemptCount = 0 }
        persistIndex()
    }

    private func recordUploadedPhoto(auditId: UUID, itemId: UUID, url: String) {
        guard let index = pending.firstIndex(where: { $0.id == auditId }),
              let item = pending[index].audit.items.firstIndex(where: { $0.id == itemId }) else { return }
        pending[index].audit.items[item].imageURL = url
        persistIndex()
    }

    private func recordFailedAttempt(id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].attemptCount = (pending[index].attemptCount ?? 0) + 1
        persistIndex()
    }

    func enqueue(
        audit: SiteAudit,
        organizationId: String,
        draftItems: [SiteAuditDraftItem]
    ) throws {
        let folder = try pendingFolder(for: audit.id)
        var imageNames: [String: String] = [:]
        for draft in draftItems {
            guard let image = draft.image,
                  let data = SiteAuditMediaProcessor.preparedForUpload(image).jpegData(compressionQuality: 0.82) else { continue }
            let fileName = "\(draft.id.uuidString).jpg"
            try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
            imageNames[draft.id.uuidString] = fileName
        }
        pending.removeAll { $0.id == audit.id }
        pending.append(
            PendingSiteAuditRecord(
                id: audit.id,
                organizationId: organizationId,
                audit: audit,
                localImageNames: imageNames,
                createdAt: Date()
            )
        )
        persistIndex()
    }

    func remove(id: UUID) {
        pending.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: pendingFolderURL(for: id))
        persistIndex()
    }

    /// Sign-out: every queued audit and its photos are removed, so the next account on this phone never uploads
    /// (or sees) them (security audit M6).
    func clearAll() {
        for record in pending {
            try? FileManager.default.removeItem(at: pendingFolderURL(for: record.id))
        }
        try? FileManager.default.removeItem(
            at: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(folderName, isDirectory: true)
        )
        pending = []
        UserDefaults.standard.removeObject(forKey: indexKey)
        objectWillChange.send()
    }

    func image(for record: PendingSiteAuditRecord, itemId: UUID) -> UIImage? {
        guard let fileName = record.localImageNames[itemId.uuidString] else { return nil }
        let url = pendingFolderURL(for: record.id).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// `countsAsAttempt` false for a background timer pass: a failure is not counted as a try.
    func syncPending(firebaseBackend: FirebaseBackend, countsAsAttempt: Bool = true) async {
        guard !pending.isEmpty else { return }
        let queue = pending.map(\.id)
        for recordId in queue {
            // The record as it is now (photo URLs saved by an earlier pass included), not a stale copy.
            guard let record = pending.first(where: { $0.id == recordId }), claimAuditForSync(id: recordId) else { continue }
            defer { releaseAuditClaim(id: recordId) }
            do {
                var items: [SiteAuditItem] = []
                for item in record.audit.items {
                    var remoteURL = item.imageURL
                    if remoteURL == nil,
                       let fileName = record.localImageNames[item.id.uuidString],
                       let image = UIImage(contentsOfFile: pendingFolderURL(for: record.id).appendingPathComponent(fileName).path) {
                        remoteURL = try await firebaseBackend.uploadSiteAuditImage(
                            image,
                            auditId: record.audit.id,
                            organizationId: record.organizationId
                        )
                        if let remoteURL {
                            recordUploadedPhoto(auditId: record.id, itemId: item.id, url: remoteURL)
                        }
                    }
                    items.append(SiteAuditItem(
                        id: item.id,
                        title: item.title,
                        location: item.location,
                        assignee: item.assignee,
                        comments: item.comments,
                        annotations: item.annotations,
                        imageURL: remoteURL,
                        imageCapturedAt: item.imageCapturedAt,
                        createdAt: item.createdAt
                    ))
                }
                var audit = record.audit
                audit.items = items
                try await firebaseBackend.saveSiteAudit(audit, organizationId: record.organizationId)
                remove(id: record.id)
            } catch {
                if countsAsAttempt { recordFailedAttempt(id: record.id) }
                print("🔥🔥🔥 DEBUG: [SiteAuditOffline] Sync failed for \(record.id): \(error.localizedDescription)")
            }
        }
    }

    private func pendingFolderURL(for auditId: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(auditId.uuidString, isDirectory: true)
    }

    private func pendingFolder(for auditId: UUID) throws -> URL {
        let url = pendingFolderURL(for: auditId)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func loadIndex() {
        guard let data = UserDefaults.standard.data(forKey: indexKey),
              let decoded = try? decoder.decode([PendingSiteAuditRecord].self, from: data) else {
            pending = []
            return
        }
        pending = decoded.sorted { $0.createdAt < $1.createdAt }
    }

    private func persistIndex() {
        guard let data = try? encoder.encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: indexKey)
        objectWillChange.send()
    }
}
