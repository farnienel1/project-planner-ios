import XCTest
@testable import Project_Planner

/// RULEBOOK 1.25.0 §24 "Uploaded files" on iOS through `CanonicalBusinessEngine`. Expected values were checked in node
/// against the packed `canonical-business.js` (rulebook 1.25.0, sha256 c1491ca3…30bfc55).
@MainActor
final class Rulebook1250Tests: XCTestCase {
    private let uploaded = Date(timeIntervalSince1970: 1_793_750_000)
    private let member = CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: false, isManager: false, isOperativeMode: false)
    private let manager = CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: false, isManager: true, isOperativeMode: false)
    private let admin = CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: false)
    private let evidencePath = "organizations/ORG1/healthSafety/JOB/variationEvidence/uidA_1793750000000.jpg"

    func testThePackedScriptIsRulebook1250OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 25, 0]), "rulebook \(stamp.version) predates 1.25.0")
        let names = Set(CanonicalBusinessEngine.exportNames())
        for name in ["fileDeletePermission", "storedFileKind", "storedFileUploader", "storedFileObjectName"] {
            XCTAssertTrue(names.contains(name), "\(name) missing from the packed script")
        }
        XCTAssertEqual(CanonicalBusinessEngine.fileKeptOnRemoveCopy, "Removed from this list. The file itself is kept so an admin can restore it.")
    }

    func testEveryIOSUploadPathIsAKnownKind() {
        let kinds: [(String, String?)] = [
            ("organizations/ORG1/variations/V1/uidA_1793750000000.jpg", "variation_evidence"),
            (evidencePath, "variation_evidence"),
            ("organizations/ORG1/tasks/T1/files/uidA_1793750000000.pdf", "task_attachment"),
            ("organizations/ORG1/tasks/T1/images/uidA_1793750000000.jpg", "task_attachment"),
            ("organizations/ORG1/siteAudits/A1/images/uidA_1793750000000.jpg", "site_audit_photo"),
            ("organizations/ORG1/healthSafety/JOB/rams/uidA_1793750000000.pdf", "health_safety"),
            ("organizations/ORG1/operatives/OP1/qualifications/Q1/certificates/uidA_1793750000000.pdf", "qualification_certificate"),
            ("organizations/ORG1/branding/company_logo/uidA_1793750000000.png", "company_logo"),
            ("organizations/ORG1/timesheetExports/1793750000_Timesheet.pdf", "timesheet_export"),
            ("organizations/ORG1/userProfiles/uidA/profile.jpg", "profile_photo"),
            ("organizations/ORG1/other/x.pdf", nil),
        ]
        for (path, kind) in kinds {
            XCTAssertEqual(CanonicalBusinessEngine.storedFileKind(path), kind, path)
        }
        let uploader = CanonicalBusinessEngine.storedFileUploader(evidencePath)
        XCTAssertEqual(uploader?.uploaderUserId, "uidA")
        XCTAssertEqual(uploader?.uploadedAtMs, 1_793_750_000_000)
        XCTAssertNil(CanonicalBusinessEngine.storedFileUploader("organizations/ORG1/timesheetExports/1793750000_Timesheet.pdf"))
    }

    func testObjectNamesComeFromTheScript() {
        XCTAssertEqual(StorageUploadPolicy.generatedObjectName(uid: "abc123", unixMilliseconds: 1_793_750_000_000, fileExtension: "pdf"), "abc123_1793750000000.pdf")
        XCTAssertEqual(CanonicalBusinessEngine.storedFileObjectName(uid: "abc123", unixMs: 1_793_750_000_000, fileExtension: "pdf"), "abc123_1793750000000.pdf")
        XCTAssertNil(CanonicalBusinessEngine.storedFileObjectName(uid: "ab_c", unixMs: 1, fileExtension: "pdf"), "a uid with _ cannot be part of a name")
    }

    func testWhoMayDelete() {
        func permission(_ viewer: String, _ role: CanonicalBusinessEngine.CanonicalStaffAccountRole, path: String? = nil, org: String = "ORG1", after seconds: TimeInterval, uploadedAt: Date? = nil) -> RulebookFileDeletePermission {
            CanonicalBusinessEngine.fileDeletePermission(
                storagePath: path ?? evidencePath, organizationId: org, viewerUserId: viewer, viewerRole: role,
                now: uploaded.addingTimeInterval(seconds), uploadedAt: uploadedAt
            )
        }
        let undo = permission("uidA", member, org: "org1", after: 60)
        XCTAssertTrue(undo.allowed)
        XCTAssertEqual(undo.reason, "uploader_undo")
        XCTAssertEqual(undo.undoEndsAtMs, 1_793_750_900_000)
        XCTAssertEqual(permission("uidA", member, after: 16 * 60).reason, "undo_expired")
        XCTAssertEqual(permission("uidB", manager, after: 0).reason, "not_uploader", "a manager is not an admin")
        XCTAssertEqual(permission("uidB", admin, after: 0).reason, "admin")
        let adminInOperativeMode = CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: true, isManager: false, isOperativeMode: true)
        XCTAssertFalse(permission("uidB", adminInOperativeMode, after: 5).allowed)
        XCTAssertEqual(permission("uidA", admin, path: "organizations/ORG2/variations/V1/uidA_1.jpg", after: 0).reason, "other_organization")
        XCTAssertEqual(permission("uidA", manager, path: "organizations/ORG1/timesheetExports/1793750000_Timesheet.pdf", after: 5).reason, "admin_only")
        // The H&S clean-up: the uploader, seconds after the upload.
        XCTAssertTrue(permission("uidA", member, path: "organizations/ORG1/healthSafety/JOB/rams/uidA_1793750000000.pdf", after: 5).allowed)
        // A stored upload time wins over the time in the name.
        let late = uploaded.addingTimeInterval(9_990)
        XCTAssertTrue(permission("uidA", member, path: "organizations/ORG1/variations/V1/uidA_1793750000000.jpg", after: 10_000, uploadedAt: late).allowed)
    }
}
