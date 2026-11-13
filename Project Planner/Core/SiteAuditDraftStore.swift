//
//  SiteAuditDraftStore.swift
//  Project Planner
//
//  Unfinished site audits saved on this phone while the person works (owner decision 12 Nov, item 6).
//
//  A draft is device-only: nothing is written to Firestore until the person submits it (RULEBOOK §1 — device storage
//  is a cache or a per-device preference only; an unsubmitted draft is not shared data). Each draft lives in its own
//  folder, per signed-in account and per organisation:
//
//      Application Support/SiteAuditDrafts/<user>/<organisation>/<draft id>/draft.json
//                                                                          /<item id>.jpg
//
//  Photos are JPEG files on disk, never UserDefaults. Submitting or deleting a draft removes its folder; sign-out
//  removes every draft on the phone (`deleteAll`, from `FirebaseBackend.clearDeviceQueuesOnSignOut`), so the next
//  account never sees another person's unfinished audit.
//

import Foundation

/// One item of a draft, as written to `draft.json`. The photo (when there is one) is `<item id>.jpg` beside it.
nonisolated struct SiteAuditDraftItemRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var location: String
    var assignee: String
    var comments: String
    var annotations: String
    var capturedAt: Date?
    var createdAt: Date
    /// True when the item has a photo on disk (`SiteAuditDraftStore.photoFileName(for:)`).
    var hasPhoto: Bool
}

/// An unfinished site audit kept on this phone. Its `id` becomes the audit's id when it is submitted, so submitting
/// the same draft twice (the app closed between queueing the audit and removing the draft) replaces the queued copy
/// instead of making a second audit.
nonisolated struct SiteAuditDraft: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var userId: String
    var organizationId: String
    /// The job picked, if any. A job that is no longer visible when the draft is resumed is picked again.
    var projectId: UUID?
    var projectJobNumber: String
    var projectName: String
    /// `SiteAuditType` raw value.
    var typeRawValue: String
    var customTitle: String
    var authorName: String
    var date: Date
    var visibleToOperatives: Bool
    var items: [SiteAuditDraftItemRecord]
    var createdAt: Date
    var updatedAt: Date

    /// The Drafts list row title, e.g. "Snagging · J-1042 Riverside".
    var listTitle: String {
        let title = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = [projectJobNumber, projectName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let head = title.isEmpty ? typeRawValue : "\(typeRawValue) · \(title)"
        return job.isEmpty ? "\(head) · No job picked" : "\(head) · \(job)"
    }

    var itemCountText: String {
        "\(items.count) item\(items.count == 1 ? "" : "s")"
    }
}

/// Files for site audit drafts. Thread-safe (one lock), so the editor can write from a background task.
nonisolated final class SiteAuditDraftStore: @unchecked Sendable {
    static let shared = SiteAuditDraftStore(rootURL: SiteAuditDraftStore.defaultRootURL)

    static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiteAuditDrafts", isDirectory: true)
    }

    private static let draftFileName = "draft.json"

    let rootURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// A folder name for an account or organisation id: letters, digits, `-` and `_` kept, everything else
    /// percent-encoded (so `/` or `..` in an id can never reach another folder).
    static func folderKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return encoded.isEmpty ? "_" : encoded
    }

    static func photoFileName(for itemId: UUID) -> String {
        "\(itemId.uuidString).jpg"
    }

    func userFolder(userId: String) -> URL {
        rootURL.appendingPathComponent(Self.folderKey(userId), isDirectory: true)
    }

    func organizationFolder(userId: String, organizationId: String) -> URL {
        userFolder(userId: userId).appendingPathComponent(Self.folderKey(organizationId), isDirectory: true)
    }

    func draftFolder(draftId: UUID, userId: String, organizationId: String) -> URL {
        organizationFolder(userId: userId, organizationId: organizationId)
            .appendingPathComponent(draftId.uuidString, isDirectory: true)
    }

    /// The signed-in person's drafts in this organisation, most recently changed first. A file that cannot be read,
    /// or that names another account or organisation, is skipped (never shown to the wrong person).
    func drafts(userId: String, organizationId: String) -> [SiteAuditDraft] {
        lock.lock(); defer { lock.unlock() }
        let folder = organizationFolder(userId: userId, organizationId: organizationId)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { entry -> SiteAuditDraft? in
            guard let data = try? Data(contentsOf: entry.appendingPathComponent(Self.draftFileName)),
                  let draft = try? decoder.decode(SiteAuditDraft.self, from: data),
                  draft.userId == userId,
                  draft.organizationId == organizationId,
                  entry.lastPathComponent == draft.id.uuidString else { return nil }
            return draft
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func draft(id: UUID, userId: String, organizationId: String) -> SiteAuditDraft? {
        drafts(userId: userId, organizationId: organizationId).first { $0.id == id }
    }

    /// Writes the draft. `photos` holds JPEG data for the items whose photo is new or changed since the last save;
    /// an item marked `hasPhoto` without data here keeps the file already on disk. Photos of items that were removed,
    /// or no longer have a photo, are deleted. Photos are written before `draft.json`, so a draft never names a photo
    /// that is not there yet.
    func save(_ draft: SiteAuditDraft, photos: [UUID: Data] = [:]) throws {
        lock.lock(); defer { lock.unlock() }
        let folder = draftFolder(draftId: draft.id, userId: draft.userId, organizationId: draft.organizationId)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        excludeRootFromBackup()

        var stored = draft
        for index in stored.items.indices {
            let item = stored.items[index]
            let photoURL = folder.appendingPathComponent(Self.photoFileName(for: item.id))
            if item.hasPhoto, let data = photos[item.id] {
                try data.write(to: photoURL, options: .atomic)
            } else if item.hasPhoto, !fm.fileExists(atPath: photoURL.path) {
                // Marked as having a photo but none was ever written: keep the item, drop the claim.
                stored.items[index].hasPhoto = false
            }
        }
        let data = try encoder.encode(stored)
        try data.write(to: folder.appendingPathComponent(Self.draftFileName), options: .atomic)

        let keep = Set(stored.items.filter(\.hasPhoto).map { Self.photoFileName(for: $0.id) } + [Self.draftFileName])
        if let files = try? fm.contentsOfDirectory(atPath: folder.path) {
            for file in files where !keep.contains(file) {
                try? fm.removeItem(at: folder.appendingPathComponent(file))
            }
        }
    }

    func photoData(draftId: UUID, itemId: UUID, userId: String, organizationId: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let url = draftFolder(draftId: draftId, userId: userId, organizationId: organizationId)
            .appendingPathComponent(Self.photoFileName(for: itemId))
        return try? Data(contentsOf: url)
    }

    /// Delete or submit: the draft and its photos are removed from the phone.
    func delete(draftId: UUID, userId: String, organizationId: String) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.removeItem(at: draftFolder(draftId: draftId, userId: userId, organizationId: organizationId))
        // Leave no empty organisation or account folders behind.
        let orgFolder = organizationFolder(userId: userId, organizationId: organizationId)
        if (try? fm.contentsOfDirectory(atPath: orgFolder.path))?.isEmpty == true {
            try? fm.removeItem(at: orgFolder)
        }
        let userFolder = userFolder(userId: userId)
        if (try? fm.contentsOfDirectory(atPath: userFolder.path))?.isEmpty == true {
            try? fm.removeItem(at: userFolder)
        }
    }

    /// Every draft of one account, in every organisation.
    func deleteAll(userId: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: userFolder(userId: userId))
    }

    /// Sign-out: every draft on this phone is removed, so the next account never sees them.
    func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: rootURL)
    }

    /// Drafts can hold many photos; they stay on this phone and are not copied into device backups.
    private func excludeRootFromBackup() {
        var url = rootURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
