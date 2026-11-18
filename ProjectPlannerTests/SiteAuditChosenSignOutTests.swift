import XCTest
@testable import Project_Planner

/// Final review of #389 / #262 (owner rule: fix on both apps): a chosen sign-out stops site audits still uploading,
/// then deletes the photos they already uploaded — never those of an audit already saved or whose state could not be
/// read — as web's `removeUnsentSiteAuditsFor` does.
final class SiteAuditChosenSignOutTests: XCTestCase {
    private func audit(_ urls: [String?]) -> SiteAudit {
        SiteAudit(
            id: UUID(),
            projectId: UUID(),
            projectJobNumber: "C646",
            projectName: "Site",
            type: .general,
            customTitle: "",
            authorName: "Test Admin",
            date: Date(timeIntervalSince1970: 1_763_400_000),
            items: urls.map {
                SiteAuditItem(
                    id: UUID(), title: "Item", location: "", assignee: "", comments: "", annotations: "",
                    imageURL: $0, imageCapturedAt: nil, createdAt: Date(timeIntervalSince1970: 1_763_400_000)
                )
            },
            createdAt: Date(timeIntervalSince1970: 1_763_400_000),
            createdByUserId: "U1",
            visibleToOperatives: true
        )
    }

    private func record(_ audit: SiteAudit) -> PendingSiteAuditRecord {
        PendingSiteAuditRecord(
            id: audit.id,
            organizationId: "org",
            audit: audit,
            localImageNames: [:],
            createdAt: Date(timeIntervalSince1970: 1_763_400_000)
        )
    }

    func testUploadedPhotosOfUnsavedAuditsAreDeletedSavedAndUnknownAreKept() {
        let unsent = audit(["https://x/a.jpg", nil, "https://x/b.jpg", ""])
        let saved = audit(["https://x/saved.jpg"])
        let unknown = audit(["https://x/unknown.jpg"])
        let urls = SiteAuditOfflineStore.photoURLsToDeleteOnChosenSignOut(
            [record(unsent), record(saved), record(unknown)],
            savedOrUnknownAuditIds: [saved.id, unknown.id]
        )
        XCTAssertEqual(urls, ["https://x/a.jpg", "https://x/b.jpg"], "only uploaded photos of audits never saved")
        XCTAssertTrue(SiteAuditOfflineStore.photoURLsToDeleteOnChosenSignOut([record(audit([nil, nil]))], savedOrUnknownAuditIds: []).isEmpty)
    }

    func testStopMovesTheGenerationSoRunningPassesStop() {
        let stop = SiteAuditUploadStop.shared
        let start = stop.current
        XCTAssertFalse(stop.stopped(since: start))
        stop.stop()
        XCTAssertTrue(stop.stopped(since: start), "a pass or upload started before the sign-out stops")
        XCTAssertFalse(stop.stopped(since: stop.current), "uploads after signing back in are not stopped")
    }
}
