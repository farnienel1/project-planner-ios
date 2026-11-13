import XCTest
@testable import Project_Planner

/// Owner decisions 12 Nov: site audit drafts kept on the phone (item 6) and the background save after
/// "Submit & generate PDF" (item 5a).
final class SiteAuditDraftStoreTests: XCTestCase {
    private var root: URL!
    private var store: SiteAuditDraftStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TEST-SiteAuditDrafts-\(UUID().uuidString)", isDirectory: true)
        store = SiteAuditDraftStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDraft(
        id: UUID = UUID(),
        userId: String = "TEST-user-a",
        organizationId: String = "TEST-org-1",
        items: [SiteAuditDraftItemRecord] = [],
        updatedAt: Date = Date()
    ) -> SiteAuditDraft {
        SiteAuditDraft(
            id: id,
            userId: userId,
            organizationId: organizationId,
            projectId: UUID(),
            projectJobNumber: "J-1042",
            projectName: "TEST-Kitchen refit",
            typeRawValue: "Snags",
            customTitle: "Plant room",
            authorName: "TEST Person",
            date: Date(timeIntervalSince1970: 1_800_000_000),
            visibleToOperatives: false,
            items: items,
            createdAt: Date(timeIntervalSince1970: 1_799_000_000),
            updatedAt: updatedAt
        )
    }

    private func item(_ title: String, photo: Bool) -> SiteAuditDraftItemRecord {
        SiteAuditDraftItemRecord(
            id: UUID(),
            title: title,
            location: "Level 2",
            assignee: "TEST Person",
            comments: "Comment for \(title)",
            annotations: "Arrow top left",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_100),
            createdAt: Date(timeIntervalSince1970: 1_800_000_050),
            hasPhoto: photo
        )
    }

    // MARK: Save and restore

    func testSaveThenRestoreKeepsEveryFieldAndPhoto() throws {
        let withPhoto = item("Cracked tile", photo: true)
        let noPhoto = item("Missing label", photo: false)
        let draft = makeDraft(items: [withPhoto, noPhoto])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        try store.save(draft, photos: [withPhoto.id: jpeg])

        let restored = store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-1")
        XCTAssertEqual(restored, [draft])
        XCTAssertEqual(
            store.photoData(draftId: draft.id, itemId: withPhoto.id, userId: "TEST-user-a", organizationId: "TEST-org-1"),
            jpeg
        )
        XCTAssertNil(store.photoData(draftId: draft.id, itemId: noPhoto.id, userId: "TEST-user-a", organizationId: "TEST-org-1"))
        XCTAssertEqual(draft.listTitle, "Snags · Plant room · J-1042 TEST-Kitchen refit")
        XCTAssertEqual(draft.itemCountText, "2 items")
    }

    func testPhotoIsAJPEGFileOnDiskNotInUserDefaults() throws {
        let photoItem = item("Photo", photo: true)
        let draft = makeDraft(items: [photoItem])
        try store.save(draft, photos: [photoItem.id: Data([1, 2, 3])])
        let file = store.draftFolder(draftId: draft.id, userId: draft.userId, organizationId: draft.organizationId)
            .appendingPathComponent(SiteAuditDraftStore.photoFileName(for: photoItem.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(file.lastPathComponent.hasSuffix(".jpg"))
    }

    func testLaterSaveKeepsPhotoAlreadyOnDiskWithoutRewritingIt() throws {
        let photoItem = item("Photo", photo: true)
        var draft = makeDraft(items: [photoItem])
        try store.save(draft, photos: [photoItem.id: Data([9, 9, 9])])
        draft.customTitle = "Changed title"
        try store.save(draft) // no photo data: the file on disk stays
        XCTAssertEqual(store.drafts(userId: draft.userId, organizationId: draft.organizationId).first?.customTitle, "Changed title")
        XCTAssertEqual(
            store.photoData(draftId: draft.id, itemId: photoItem.id, userId: draft.userId, organizationId: draft.organizationId),
            Data([9, 9, 9])
        )
    }

    func testRemovedItemLosesItsPhotoFile() throws {
        let keep = item("Keep", photo: true)
        let drop = item("Drop", photo: true)
        var draft = makeDraft(items: [keep, drop])
        try store.save(draft, photos: [keep.id: Data([1]), drop.id: Data([2])])
        draft.items = [keep]
        try store.save(draft)
        XCTAssertNil(store.photoData(draftId: draft.id, itemId: drop.id, userId: draft.userId, organizationId: draft.organizationId))
        XCTAssertNotNil(store.photoData(draftId: draft.id, itemId: keep.id, userId: draft.userId, organizationId: draft.organizationId))
    }

    func testItemMarkedWithPhotoButNoFileIsKeptWithoutPhoto() throws {
        let ghostPhoto = item("No file", photo: true)
        let draft = makeDraft(items: [ghostPhoto])
        try store.save(draft) // never written
        let restored = try XCTUnwrap(store.drafts(userId: draft.userId, organizationId: draft.organizationId).first)
        XCTAssertEqual(restored.items.count, 1)
        XCTAssertFalse(restored.items[0].hasPhoto)
    }

    func testDraftsAreNewestFirst() throws {
        let older = makeDraft(updatedAt: Date(timeIntervalSince1970: 100))
        let newer = makeDraft(updatedAt: Date(timeIntervalSince1970: 200))
        try store.save(older)
        try store.save(newer)
        XCTAssertEqual(store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-1").map(\.id), [newer.id, older.id])
    }

    // MARK: Delete

    func testDeleteRemovesDraftAndPhotos() throws {
        let photoItem = item("Photo", photo: true)
        let draft = makeDraft(items: [photoItem])
        try store.save(draft, photos: [photoItem.id: Data([1])])
        store.delete(draftId: draft.id, userId: draft.userId, organizationId: draft.organizationId)
        XCTAssertTrue(store.drafts(userId: draft.userId, organizationId: draft.organizationId).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.draftFolder(draftId: draft.id, userId: draft.userId, organizationId: draft.organizationId).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.userFolder(userId: draft.userId).path))
    }

    func testDeleteOneDraftKeepsTheOthers() throws {
        let first = makeDraft()
        let second = makeDraft()
        try store.save(first)
        try store.save(second)
        store.delete(draftId: first.id, userId: first.userId, organizationId: first.organizationId)
        XCTAssertEqual(store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-1").map(\.id), [second.id])
    }

    func testSignOutDeleteAllRemovesEveryDraftOnThePhone() throws {
        try store.save(makeDraft(userId: "TEST-user-a"))
        try store.save(makeDraft(userId: "TEST-user-b"))
        store.deleteAll()
        XCTAssertTrue(store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-1").isEmpty)
        XCTAssertTrue(store.drafts(userId: "TEST-user-b", organizationId: "TEST-org-1").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDeleteAllForOneUserKeepsAnotherUsersDrafts() throws {
        try store.save(makeDraft(userId: "TEST-user-a", organizationId: "TEST-org-1"))
        try store.save(makeDraft(userId: "TEST-user-a", organizationId: "TEST-org-2"))
        let other = makeDraft(userId: "TEST-user-b")
        try store.save(other)
        store.deleteAll(userId: "TEST-user-a")
        XCTAssertTrue(store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-1").isEmpty)
        XCTAssertTrue(store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-2").isEmpty)
        XCTAssertEqual(store.drafts(userId: "TEST-user-b", organizationId: "TEST-org-1").map(\.id), [other.id])
    }

    // MARK: Per user and per organisation

    func testDraftsAreSeparatePerUserAndPerOrganisation() throws {
        let aOrg1 = makeDraft(userId: "TEST-user-a", organizationId: "TEST-org-1")
        let aOrg2 = makeDraft(userId: "TEST-user-a", organizationId: "TEST-org-2")
        let bOrg1 = makeDraft(userId: "TEST-user-b", organizationId: "TEST-org-1")
        try store.save(aOrg1)
        try store.save(aOrg2)
        try store.save(bOrg1)
        XCTAssertEqual(store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-1").map(\.id), [aOrg1.id])
        XCTAssertEqual(store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-2").map(\.id), [aOrg2.id])
        XCTAssertEqual(store.drafts(userId: "TEST-user-b", organizationId: "TEST-org-1").map(\.id), [bOrg1.id])
        XCTAssertTrue(store.drafts(userId: "TEST-user-b", organizationId: "TEST-org-2").isEmpty)
    }

    func testDraftFileNamingAnotherAccountIsNeverListed() throws {
        // A draft.json copied into another account's folder (or written there by a bug) is skipped.
        let draft = makeDraft(userId: "TEST-user-a")
        try store.save(draft)
        let source = store.draftFolder(draftId: draft.id, userId: "TEST-user-a", organizationId: "TEST-org-1")
        let target = store.draftFolder(draftId: draft.id, userId: "TEST-user-b", organizationId: "TEST-org-1")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        XCTAssertTrue(store.drafts(userId: "TEST-user-b", organizationId: "TEST-org-1").isEmpty)
    }

    func testFolderKeysCannotEscapeTheDraftsFolder() {
        XCTAssertEqual(SiteAuditDraftStore.folderKey("abc-DEF_123"), "abc-DEF_123")
        XCTAssertFalse(SiteAuditDraftStore.folderKey("../other").contains("/"))
        XCTAssertFalse(SiteAuditDraftStore.folderKey("../other").contains(".."))
        XCTAssertFalse(SiteAuditDraftStore.folderKey("organizations/x").contains("/"))
        XCTAssertEqual(SiteAuditDraftStore.folderKey(""), "_")
        XCTAssertNotEqual(SiteAuditDraftStore.folderKey("a/b"), SiteAuditDraftStore.folderKey("a_b"))
    }

    func testSaveStartedBeforeSignOutIsRefused() throws {
        let epochBefore = store.currentEpoch
        store.deleteAll()
        XCTAssertThrowsError(try store.save(makeDraft(), epoch: epochBefore)) { error in
            XCTAssertTrue(error is SiteAuditDraftStoreError)
        }
        XCTAssertTrue(store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-1").isEmpty)
        // A new editor (opened after the sign-out) saves as normal.
        let draft = makeDraft()
        try store.save(draft, epoch: store.currentEpoch)
        XCTAssertEqual(store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-1").map(\.id), [draft.id])
    }

    func testForcedSignOutKeepsOnlyThatPersonsDrafts() throws {
        let mine = makeDraft(userId: "TEST-user-a")
        try store.save(mine)
        try store.save(makeDraft(userId: "TEST-user-b"))
        store.deleteAll(keepingUserId: "TEST-user-a")
        XCTAssertEqual(store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-1").map(\.id), [mine.id])
        XCTAssertTrue(store.drafts(userId: "TEST-user-b", organizationId: "TEST-org-1").isEmpty)
        XCTAssertEqual(store.totalDraftCount(), 1)
    }

    func testSavedAuditRemovesOnlyItsSubmittedDraft() throws {
        var submitted = makeDraft()
        submitted.submittedAt = Date()
        try store.save(submitted)
        let reopened = makeDraft(userId: "TEST-user-b") // same audit id would be unusual; a plain draft here
        try store.save(reopened)
        store.deleteSubmittedDraft(id: submitted.id)
        XCTAssertTrue(store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-1").isEmpty)
        // A draft without submittedAt (never submitted, or reopened and changed) is never removed by the queue.
        store.deleteSubmittedDraft(id: reopened.id)
        XCTAssertEqual(store.drafts(userId: "TEST-user-b", organizationId: "TEST-org-1").map(\.id), [reopened.id])
    }

    func testDraftWrittenWithoutNewerFieldsStillOpens() throws {
        // A draft.json from before `version` / `submittedAt`, with an item missing optional text.
        let id = UUID()
        let itemId = UUID()
        let json = """
        {"id":"\(id.uuidString)","userId":"TEST-user-a","organizationId":"TEST-org-1",
         "projectJobNumber":"J-1","projectName":"TEST-Site","typeRawValue":"General","customTitle":"",
         "authorName":"TEST Person","date":800000000,"visibleToOperatives":true,
         "items":[{"id":"\(itemId.uuidString)","title":"Item","createdAt":800000000,"hasPhoto":false}],
         "createdAt":800000000,"updatedAt":800000001}
        """
        let folder = store.draftFolder(draftId: id, userId: "TEST-user-a", organizationId: "TEST-org-1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent("draft.json"))
        let restored = try XCTUnwrap(store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-1").first)
        XCTAssertEqual(restored.version, 1)
        XCTAssertNil(restored.submittedAt)
        XCTAssertEqual(restored.items.first?.comments, "")
        // The next save writes the current version.
        try store.save(restored)
        XCTAssertEqual(store.drafts(userId: "TEST-user-a", organizationId: "TEST-org-1").first?.version, SiteAuditDraft.currentVersion)
    }

    // MARK: Background save after Submit (item 5a)

    func testUploadStateFollowsTheQueue() {
        func state(queued: Bool, uploading: Bool = false, online: Bool = true, attempts: Int = 0, error: String? = nil) -> SiteAuditUploadState {
            SiteAuditUploadState.resolve(isQueued: queued, isUploading: uploading, isOnline: online,
                                         attemptCount: attempts, maxAutoAttempts: 5, lastError: error)
        }
        XCTAssertEqual(state(queued: false), .saved)
        XCTAssertEqual(state(queued: false, online: false, error: "old"), .saved)
        XCTAssertEqual(state(queued: true, uploading: true), .uploading)
        XCTAssertEqual(state(queued: true, online: false), .waitingForConnection)
        XCTAssertEqual(state(queued: true), .waitingToUpload)
        // A failure (counted or from a background pass) is never shown as just "waiting".
        XCTAssertEqual(state(queued: true, error: "denied"), .failedWillRetry(lastError: "denied"))
        XCTAssertEqual(state(queued: true, attempts: 4, error: "denied"), .failedWillRetry(lastError: "denied"))
        XCTAssertEqual(state(queued: true, attempts: 5, error: "denied"), .needsRetry(lastError: "denied"))
        // An upload already running wins over the try count.
        XCTAssertEqual(state(queued: true, uploading: true, attempts: 9), .uploading)
        // Offline wins over the try count: it will go when the phone is back online.
        XCTAssertEqual(state(queued: true, online: false, attempts: 9), .waitingForConnection)
    }

    func testUploadStateWording() {
        XCTAssertEqual(SiteAuditUploadState.saved.statusText, "Saved")
        XCTAssertEqual(SiteAuditUploadState.waitingForConnection.statusText, "Waiting to upload — will upload when online")
        XCTAssertNil(SiteAuditUploadState.saved.detailText)
        XCTAssertNotNil(SiteAuditUploadState.waitingForConnection.detailText)
        // An edit refused by the server shows why, as "Update failed: …" used to.
        XCTAssertEqual(SiteAuditUploadState.needsRetry(lastError: "Missing or insufficient permissions.").errorText,
                       "Last error: Missing or insufficient permissions.")
        XCTAssertNil(SiteAuditUploadState.failedWillRetry(lastError: "  ").errorText)
        XCTAssertTrue(SiteAuditUploadState.needsRetry(lastError: nil).showsRetryButton)
        XCTAssertTrue(SiteAuditUploadState.failedWillRetry(lastError: "x").showsRetryButton)
        XCTAssertFalse(SiteAuditUploadState.waitingToUpload.showsRetryButton)
        XCTAssertFalse(SiteAuditUploadState.failedWillRetry(lastError: nil).statusText.contains("shortly"))
    }

    func testSyncPassRemovesOnlyTheCopyItSaved() {
        let saved = UUID()
        // Still the copy the pass read: remove it.
        XCTAssertTrue(SiteAuditOfflineStore.shouldRemoveAfterSync(currentRevision: .some(saved), syncedRevision: saved))
        // A newer copy was queued meanwhile (an edit, or a draft submitted again): keep it for the next pass.
        XCTAssertFalse(SiteAuditOfflineStore.shouldRemoveAfterSync(currentRevision: .some(UUID()), syncedRevision: saved))
        // Records saved before revisions existed (nil on both sides) are removed as before.
        XCTAssertTrue(SiteAuditOfflineStore.shouldRemoveAfterSync(currentRevision: .some(nil), syncedRevision: nil))
        // Already gone: nothing to remove.
        XCTAssertFalse(SiteAuditOfflineStore.shouldRemoveAfterSync(currentRevision: nil, syncedRevision: saved))
    }
}

/// Queuing an audit again keeps the photo URLs an older queued copy already uploaded.
@MainActor
final class SiteAuditQueueCarryOverTests: XCTestCase {
    private func item(_ id: UUID, url: String?, capturedAt: Date?) -> SiteAuditItem {
        SiteAuditItem(id: id, title: "TEST item", location: "", assignee: "", comments: "", annotations: "",
                      imageURL: url, imageCapturedAt: capturedAt, createdAt: Date(timeIntervalSince1970: 1))
    }

    private func audit(_ items: [SiteAuditItem]) -> SiteAudit {
        SiteAudit(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, projectId: UUID(),
                  projectJobNumber: "J-1", projectName: "TEST-Site", type: .general, customTitle: "",
                  authorName: "TEST Person", date: Date(timeIntervalSince1970: 1), items: items,
                  createdAt: Date(timeIntervalSince1970: 1), createdByUserId: "TEST-user", visibleToOperatives: true)
    }

    func testSamePhotoKeepsItsUploadedURLAndAChangedPhotoDoesNot() {
        let same = UUID(), replaced = UUID(), added = UUID()
        let t1 = Date(timeIntervalSince1970: 100), t2 = Date(timeIntervalSince1970: 200)
        let older = audit([
            item(same, url: "https://example.test/same.jpg", capturedAt: t1),
            item(replaced, url: "https://example.test/old.jpg", capturedAt: t1),
        ])
        let next = audit([
            item(same, url: nil, capturedAt: t1),
            item(replaced, url: nil, capturedAt: t2),
            item(added, url: nil, capturedAt: t2),
        ])
        let merged = SiteAuditOfflineStore.carryingUploadedPhotoURLs(into: next, from: older)
        XCTAssertEqual(merged.items.map(\.imageURL), ["https://example.test/same.jpg", nil, nil])
        XCTAssertEqual(SiteAuditOfflineStore.carryingUploadedPhotoURLs(into: next, from: nil), next)
    }
}
