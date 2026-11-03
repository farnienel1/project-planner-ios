import XCTest
@testable import Project_Planner

/// RULEBOOK 1.15.0, 1.16.0 and 1.16.1 behaviour on iOS through `CanonicalBusinessEngine`. Every expected value was
/// checked in node against the packed `canonical-business.js` (sha256 586f1b0b…5c8).
@MainActor
final class Rulebook1160Tests: XCTestCase {
    // MARK: Health & safety file links (1.16.1)

    /// `mergeHealthSafetyRowCopies`: one row per id (case ignored), the first copy's order, but the copy that still
    /// has a `fileURL` wins; the rows come back as the native maps passed in.
    func testMergeHealthSafetyRowCopiesKeepsTheCopyWithALink() throws {
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let primary: [[String: Any]] = [
            ["id": "RAMS-1", "fileURL": "", "title": "Lost link", "uploadedAt": stamp],
            ["id": "RAMS-2", "fileURL": "https://x/2", "title": "Two"],
        ]
        let secondary: [[String: Any]] = [
            ["id": "rams-1", "fileURL": "https://x/1", "title": "With link"],
            ["id": "RAMS-3", "title": "Three"],
        ]
        let merged = try XCTUnwrap(CanonicalBusinessEngine.mergeHealthSafetyRowCopies(primary: primary, secondary: secondary))
        XCTAssertEqual(merged.compactMap { $0["id"] as? String }, ["rams-1", "RAMS-2", "RAMS-3"])
        XCTAssertEqual(merged.first?["fileURL"] as? String, "https://x/1")
        XCTAssertEqual(merged.first?["title"] as? String, "With link")
        XCTAssertNil(merged.first?["__hsCopyIndex"], "the position marker never reaches the stored map")
    }

    /// The two settings copies of a job read as one: the RAMS row keeps the copy with the download link.
    func testMergedHealthSafetyDocumentsKeepTheDownloadLink() {
        let settingsCopy: [String: Any] = ["ramsDocuments": [["id": "R1", "title": "RAMS", "fileURL": ""]]]
        let olderCopy: [String: Any] = ["ramsDocuments": [["id": "r1", "title": "RAMS", "fileURL": "https://x/r1.pdf"]]]
        let merged = FirebaseBackend.mergedHealthSafetyDocuments([settingsCopy, olderCopy])
        let rows = merged["ramsDocuments"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["fileURL"] as? String, "https://x/r1.pdf")
    }

    /// `healthSafetyDocumentWriteFields`: a blank `fileURL` / `fileName` never overwrites a stored link.
    func testBlankFileLinkNeverOverwritesStoredLink() throws {
        let stored: [String: Any] = [
            "ramsDocuments": [["id": "d1", "fileURL": "https://x", "fileName": "a.pdf", "title": "A"]],
        ]
        let write = try XCTUnwrap(CanonicalBusinessEngine.healthSafetyDocumentWriteFields(
            stored: stored,
            next: ["ramsDocuments": [["id": "D1", "fileURL": "", "fileName": "", "title": "B"]]]
        ))
        let rows = write.set["ramsDocuments"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.first?["fileURL"] as? String, "https://x")
        XCTAssertEqual(rows.first?["fileName"] as? String, "a.pdf")
        XCTAssertEqual(rows.first?["title"] as? String, "B")
    }

    /// Stored file references: a download URL with a token opens as is; `gs://`, bare Storage paths and token-less
    /// Firebase URLs are resolved through Storage (`fileReportStoragePath`); `file://` and blanks cannot be opened.
    func testStoredFileTargets() {
        XCTAssertEqual(
            StoredFileTarget.target(for: "gs://b.appspot.com/organizations/o/healthSafety/x/rams/a.pdf"),
            .storage("organizations/o/healthSafety/x/rams/a.pdf")
        )
        XCTAssertEqual(StoredFileTarget.target(for: "organizations/o/x.pdf"), .storage("organizations/o/x.pdf"))
        XCTAssertEqual(
            StoredFileTarget.target(for: "https://firebasestorage.googleapis.com/v0/b/b.appspot.com/o/organizations%2Fo%2Fx.pdf?alt=media"),
            .storage("organizations/o/x.pdf")
        )
        let tokened = "https://firebasestorage.googleapis.com/v0/b/b.appspot.com/o/organizations%2Fo%2Fx.pdf?alt=media&token=t"
        XCTAssertEqual(StoredFileTarget.target(for: tokened), .url(URL(string: tokened)!))
        XCTAssertNil(StoredFileTarget.target(for: "file:///var/x.pdf"))
        XCTAssertNil(StoredFileTarget.target(for: "  "))
    }
}
