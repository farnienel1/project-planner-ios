import XCTest
@testable import Project_Planner

/// RULEBOOK 1.79.0 (owner decisions 24 Nov) on iOS through `CanonicalBusinessEngine`: the app-icon number is the unread
/// count (never cleared on foreground); toolbox, material and variation notices open the job section they are about;
/// the Payrun Snapshot names whose signature an open revision waits for. Expected values checked in node against the
/// packed script (rulebook 1.79.0).
@MainActor
final class Rulebook1790Tests: XCTestCase {
    func testIconBadgeIsNeverClearedOnForeground() throws {
        XCTAssertEqual(try XCTUnwrap(CanonicalBusinessEngine.notificationIconBadgeClearsOnForeground), false)
    }

    func testToolboxNoticeNamesTheJobAndOpensHealthAndSafety() throws {
        XCTAssertEqual(
            CanonicalBusinessEngine.callJSON("notificationRelatedIdFor", arguments: ["toolbox_talk_issued", " JOB-1 "]) as? String,
            "JOB-1"
        )
        let destination = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "toolbox_talk_issued", relatedId: "JOB-1", dayKey: nil, catalogue: "smallWorks", role: "operative", deepLinkUserId: nil
        ))
        XCTAssertEqual(destination.kind, "healthSafety")
        XCTAssertEqual(destination.relatedId, "JOB-1")
    }

    func testMaterialNoticeOpensTheJobsMaterials() throws {
        let destination = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "material_order_placed", relatedId: "JOB-2", dayKey: nil, catalogue: "projects", role: "manager", deepLinkUserId: nil
        ))
        XCTAssertEqual(destination.kind, "jobMaterials")
        XCTAssertEqual(destination.relatedId, "JOB-2")
        let noJob = try XCTUnwrap(CanonicalBusinessEngine.notificationDestination(
            type: "material_order_placed", relatedId: nil, dayKey: nil, catalogue: nil, role: "manager", deepLinkUserId: nil
        ))
        XCTAssertEqual(noJob.kind, "materialOrders")
    }

    func testOpenRevisionNamesWhoseTurnItIs() throws {
        XCTAssertEqual(
            CanonicalBusinessEngine.callJSON("timesheetRevisionWaitingForLabel", arguments: [1, "person", "Samantha Jones"]) as? String,
            "REV 1 · waiting for Samantha"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.callJSON("timesheetRevisionWaitingForLabel", arguments: [1, "lineManager", "Sam"]) as? String,
            "REV 1 · waiting for line manager"
        )
    }

    func testPayrunSnapshotLinkDecodesTheDocumentId() throws {
        let json = #"{"kind":"timesheet","personId":"pat","start":"2026-11-09","end":"2026-11-15","documentId":"timesheet_pat_2026-11-09"}"#
        let link = try JSONDecoder().decode(PayrunSnapshotLink.self, from: Data(json.utf8))
        XCTAssertEqual(link.documentId, "timesheet_pat_2026-11-09")
        let older = try JSONDecoder().decode(PayrunSnapshotLink.self, from: Data(#"{"kind":"overtime","personId":"p","start":"a","end":"b"}"#.utf8))
        XCTAssertNil(older.documentId)
    }
}
