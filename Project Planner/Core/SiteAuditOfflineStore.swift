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
    let audit: SiteAudit
    /// Maps site-audit item id → JPEG filename in the pending folder.
    let localImageNames: [String: String]
    let createdAt: Date
    /// Failed uploads so far (missing on records saved before this field: 0). At `SiteAuditOfflineStore.maxAutoAttempts`
    /// the retry timer stops counting this audit; foreground, Retry now and Sync now still try it.
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
    /// pass) skips them, so an audit's photos are never uploaded twice.
    private(set) var claimedAuditIds: Set<UUID> = []

    func claimAuditForSync(id: UUID) -> Bool {
        claimedAuditIds.insert(id).inserted
    }

    func releaseAuditClaim(id: UUID) {
        claimedAuditIds.remove(id)
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

    func syncPending(firebaseBackend: FirebaseBackend) async {
        guard !pending.isEmpty else { return }
        let queue = pending
        for record in queue {
            guard pending.contains(where: { $0.id == record.id }), claimAuditForSync(id: record.id) else { continue }
            defer { releaseAuditClaim(id: record.id) }
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
                recordFailedAttempt(id: record.id)
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
