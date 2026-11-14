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
/// Every field but the id is read with a default, so a draft written by an older or newer build still opens.
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

    init(
        id: UUID,
        title: String,
        location: String,
        assignee: String,
        comments: String,
        annotations: String,
        capturedAt: Date?,
        createdAt: Date,
        hasPhoto: Bool
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.assignee = assignee
        self.comments = comments
        self.annotations = annotations
        self.capturedAt = capturedAt
        self.createdAt = createdAt
        self.hasPhoto = hasPhoto
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        assignee = try c.decodeIfPresent(String.self, forKey: .assignee) ?? ""
        comments = try c.decodeIfPresent(String.self, forKey: .comments) ?? ""
        annotations = try c.decodeIfPresent(String.self, forKey: .annotations) ?? ""
        capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        hasPhoto = try c.decodeIfPresent(Bool.self, forKey: .hasPhoto) ?? false
    }
}

/// An unfinished site audit kept on this phone. Its `id` becomes the audit's id when it is submitted, so submitting
/// the same draft twice replaces the queued copy (or updates the saved audit) instead of making a second audit.
nonisolated struct SiteAuditDraft: Codable, Equatable, Identifiable, Sendable {
    /// The `draft.json` format. Bump it when a field changes meaning; new fields are read with a default.
    static let currentVersion = 1

    let id: UUID
    var version: Int = SiteAuditDraft.currentVersion
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
    /// Set when the person submitted it: the draft is kept as a backup until the upload queue has saved the audit
    /// (`SiteAuditOfflineStore` then removes it, `deleteSubmittedDraft`). A submitted draft whose audit is no longer
    /// queued (e.g. a forced sign-out cleared the queue) is shown to submit again.
    var submittedAt: Date? = nil

    init(
        id: UUID,
        userId: String,
        organizationId: String,
        projectId: UUID?,
        projectJobNumber: String,
        projectName: String,
        typeRawValue: String,
        customTitle: String,
        authorName: String,
        date: Date,
        visibleToOperatives: Bool,
        items: [SiteAuditDraftItemRecord],
        createdAt: Date,
        updatedAt: Date,
        submittedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.organizationId = organizationId
        self.projectId = projectId
        self.projectJobNumber = projectJobNumber
        self.projectName = projectName
        self.typeRawValue = typeRawValue
        self.customTitle = customTitle
        self.authorName = authorName
        self.date = date
        self.visibleToOperatives = visibleToOperatives
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.submittedAt = submittedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        userId = try c.decode(String.self, forKey: .userId)
        organizationId = try c.decode(String.self, forKey: .organizationId)
        projectId = try c.decodeIfPresent(UUID.self, forKey: .projectId)
        projectJobNumber = try c.decodeIfPresent(String.self, forKey: .projectJobNumber) ?? ""
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        typeRawValue = try c.decodeIfPresent(String.self, forKey: .typeRawValue) ?? "General"
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle) ?? ""
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        visibleToOperatives = try c.decodeIfPresent(Bool.self, forKey: .visibleToOperatives) ?? true
        items = try c.decodeIfPresent([SiteAuditDraftItemRecord].self, forKey: .items) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        submittedAt = try c.decodeIfPresent(Date.self, forKey: .submittedAt)
    }

    /// The Drafts list row title, e.g. "Snags · Plant room · J-1042 Riverside".
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

nonisolated enum SiteAuditDraftStoreError: Error, LocalizedError {
    /// A save started before a sign-out: it is dropped, so the draft never comes back.
    case signedOut

    var errorDescription: String? { "The draft was not saved because you signed out." }
}

/// Files for site audit drafts. Thread-safe (one lock), so drafts are read and written off the main thread.
nonisolated final class SiteAuditDraftStore: @unchecked Sendable {
    static let shared = SiteAuditDraftStore(rootURL: SiteAuditDraftStore.defaultRootURL)

    static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiteAuditDrafts", isDirectory: true)
    }

    private static let draftFileName = "draft.json"

    let rootURL: URL
    private let lock = NSLock()
    /// Moves on at every sign-out. A save that names an older value is refused, so an autosave still running when
    /// the person signed out cannot write their draft back.
    private var epoch = 0
    // The default date encoding keeps every date exactly (milliseconds would round sub-millisecond times).
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    var currentEpoch: Int {
        lock.lock(); defer { lock.unlock() }
        return epoch
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
        return draftFolders(in: folder).compactMap { entry -> SiteAuditDraft? in
            guard let draft = readDraft(at: entry),
                  draft.userId == userId,
                  draft.organizationId == organizationId else { return nil }
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
    /// that is not there yet. `epoch` (from `currentEpoch` when the editor opened): refused after a sign-out.
    func save(_ draft: SiteAuditDraft, photos: [UUID: Data] = [:], epoch: Int? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        if let epoch, epoch != self.epoch { throw SiteAuditDraftStoreError.signedOut }
        let folder = draftFolder(draftId: draft.id, userId: draft.userId, organizationId: draft.organizationId)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        excludeRootFromBackup()

        var stored = draft
        stored.version = SiteAuditDraft.currentVersion
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

    /// Delete: the draft and its photos are removed from the phone.
    func delete(draftId: UUID, userId: String, organizationId: String) {
        lock.lock(); defer { lock.unlock() }
        removeDraftFolder(draftFolder(draftId: draftId, userId: userId, organizationId: organizationId))
    }

    /// The upload queue saved this audit: its submitted draft (any account, any organisation) is no longer needed.
    /// A draft the person reopened and changed since (no `submittedAt`) is kept.
    func deleteSubmittedDraft(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        for folder in allDraftFolders() where folder.lastPathComponent == id.uuidString {
            guard let draft = readDraft(at: folder), draft.submittedAt != nil else { continue }
            removeDraftFolder(folder)
        }
    }

    /// Sign-out. In-flight saves are refused from here on (the counter moves), so an autosave still running cannot
    /// write a draft back.
    /// - A sign-out the person chose (`keepDrafts` false) removes that account's drafts, in every organisation. Other
    ///   accounts' drafts on the phone (kept by their own forced sign-out) are theirs and are left alone; only they
    ///   ever list them. With no account id known, every draft on the phone is removed.
    /// - A forced sign-out (`keepDrafts` true) removes nothing, so work submitted but not uploaded is offered again
    ///   when the person signs back in.
    /// Removed folders are moved aside at once and deleted in the background, never holding up the main thread.
    func signedOut(userId: String?, keepDrafts: Bool) {
        lock.lock(); defer { lock.unlock() }
        epoch += 1
        guard !keepDrafts else { return }
        let target: URL
        if let userId, !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            target = userFolder(userId: userId)
        } else {
            target = rootURL
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return }
        let trash = rootURL.deletingLastPathComponent()
            .appendingPathComponent("SiteAuditDrafts-removed-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.moveItem(at: target, to: trash)
        } catch {
            try? fm.removeItem(at: target)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: trash)
        }
    }

    /// Drafts of one account (every organisation): what its sign-out would delete.
    func draftCount(userId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let user = userFolder(userId: userId)
        return draftFolders(in: user).flatMap { draftFolders(in: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.draftFileName).path) }
            .count
    }

    // MARK: Private (call with the lock held)

    private func readDraft(at folder: URL) -> SiteAuditDraft? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.draftFileName)),
              let draft = try? decoder.decode(SiteAuditDraft.self, from: data),
              folder.lastPathComponent == draft.id.uuidString else { return nil }
        return draft
    }

    private func draftFolders(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// root/<user>/<organisation>/<draft>
    private func allDraftFolders() -> [URL] {
        draftFolders(in: rootURL).flatMap { user in
            draftFolders(in: user).flatMap { org in draftFolders(in: org) }
        }
        .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.draftFileName).path) }
    }

    private func removeDraftFolder(_ folder: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        // Leave no empty organisation or account folders behind.
        let orgFolder = folder.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: orgFolder.path))?.isEmpty == true {
            try? fm.removeItem(at: orgFolder)
        }
        let userFolder = orgFolder.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: userFolder.path))?.isEmpty == true {
            try? fm.removeItem(at: userFolder)
        }
    }

    /// Drafts can hold many photos; they stay on this phone and are not copied into device backups.
    private func excludeRootFromBackup() {
        var url = rootURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
