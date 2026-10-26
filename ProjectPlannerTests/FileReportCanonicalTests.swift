import XCTest
@testable import Project_Planner

@MainActor
final class FileReportCanonicalTests: XCTestCase {
    private typealias Engine = CanonicalBusinessEngine

    private func input(
        storagePath: String = "organizations/org-1/siteAudits/a1/photo.jpg",
        surface: String = "site_audit",
        parentId: String = "a1",
        fileName: String = "",
        reason: String = "copyright",
        details: String = ""
    ) -> Engine.CanonicalFileReportInput {
        Engine.CanonicalFileReportInput(
            organizationId: "org-1",
            storagePath: storagePath,
            surface: surface,
            parentId: parentId,
            fileName: fileName,
            reason: reason,
            details: details,
            reportedByUserId: "uid-1"
        )
    }

    private func refusal(_ input: Engine.CanonicalFileReportInput) throws -> String? {
        switch try XCTUnwrap(Engine.fileReportWriteFields(input)) {
        case .fields: return nil
        case .refused(let error): return error
        }
    }

    func testDownloadURLBecomesStoragePath() throws {
        let url = "https://firebasestorage.googleapis.com/v0/b/demo.appspot.com/o/organizations%2Forg-1%2Ftasks%2Ft1%2Fplan.pdf?alt=media&token=abc"
        XCTAssertEqual(Engine.fileReportStoragePath(url), "organizations/org-1/tasks/t1/plan.pdf")
        XCTAssertEqual(
            Engine.fileReportStoragePath("gs://demo.appspot.com/organizations/org-1/x.jpg"),
            "organizations/org-1/x.jpg"
        )
        XCTAssertNil(Engine.fileReportStoragePath("https://example.com/x.jpg"))
        XCTAssertNil(Engine.fileReportStoragePath(""))
    }

    func testWriteFieldsAreOpenAndFillFileName() throws {
        guard case .fields(let fields) = try XCTUnwrap(Engine.fileReportWriteFields(input(details: "  why  "))) else {
            return XCTFail("expected fields")
        }
        XCTAssertEqual(fields["status"] as? String, "open")
        XCTAssertEqual(fields["organizationId"] as? String, "org-1")
        XCTAssertEqual(fields["fileName"] as? String, "photo.jpg")
        XCTAssertEqual(fields["details"] as? String, "why")
        XCTAssertEqual(fields["reportedByUserId"] as? String, "uid-1")
        XCTAssertNil(fields["createdAt"])
        XCTAssertEqual(
            Set(fields.keys),
            ["organizationId", "storagePath", "surface", "parentId", "fileName", "reason", "details", "reportedByUserId", "status"]
        )
    }

    func testRefusesOtherOrgPathUnknownReasonAndBlankParent() throws {
        XCTAssertEqual(try refusal(input(storagePath: "organizations/org-2/x.jpg")), "bad_path")
        XCTAssertEqual(try refusal(input(reason: "spam")), "bad_reason")
        XCTAssertEqual(try refusal(input(parentId: "  ")), "missing_parent")
        XCTAssertEqual(try refusal(input(surface: "profile_photo")), "bad_surface")
    }

    func testDetailsCappedAtMax() throws {
        let max = try XCTUnwrap(Engine.fileReportDetailsMax)
        XCTAssertEqual(max, 1000)
        guard case .fields(let fields) = try XCTUnwrap(
            Engine.fileReportWriteFields(input(details: String(repeating: "a", count: 1500)))
        ) else {
            return XCTFail("expected fields")
        }
        XCTAssertEqual((fields["details"] as? String)?.count, max)
    }

    func testCopyAndConstants() throws {
        XCTAssertEqual(Engine.fileReportReasons, ["copyright", "personal_data", "offensive", "wrong_file", "other"])
        XCTAssertEqual(Engine.fileReportLinkLabel, "Report a problem with this file")
        XCTAssertEqual(Engine.fileReportSentCopy, "Thanks — an admin will review this.")
        XCTAssertEqual(Engine.fileReportStatusCopy("open"), "Open")
        for reason in try XCTUnwrap(Engine.fileReportReasons) {
            XCTAssertFalse(try XCTUnwrap(Engine.fileReportReasonCopy(reason)).isEmpty)
        }
    }

    func testOnlyAdminsReview() {
        let admin = Engine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: false)
        let manager = Engine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false)
        let adminAsOperative = Engine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: true)
        XCTAssertEqual(Engine.canReviewFileReports(admin), true)
        XCTAssertEqual(Engine.canReviewFileReports(manager), false)
        XCTAssertEqual(Engine.canReviewFileReports(adminAsOperative), false)
        XCTAssertNil(Engine.fileReportReviewWriteFields(status: "open", reviewedByUserId: "uid-1"))
        XCTAssertEqual(
            Engine.fileReportReviewWriteFields(status: "removed", reviewedByUserId: "uid-1")?["status"] as? String,
            "removed"
        )
    }
}
