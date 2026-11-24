import XCTest
@testable import Project_Planner

/// RULEBOOK 1.80.0 §30: subcontractor insurance and RAMS documents through `CanonicalBusinessEngine` (no Swift rule).
/// Expected values are the web `lib/canonical/subcontractorDocuments.test.ts` cases.
@MainActor
final class SubcontractorDocumentsTests: XCTestCase {
    private let org = "org-1"
    private let sub = "SUB-1"
    private func path(_ name: String) -> String { "organizations/\(org)/subcontractors/\(sub)/documents/\(name)" }

    func testStoragePathAndKind() {
        let p = CanonicalBusinessEngine.subcontractorDocumentStoragePath(
            organizationId: org, subcontractorId: sub, uid: "u1", unixMs: 1700, fileExtension: "pdf"
        )
        XCTAssertEqual(p, path("u1_1700.pdf"))
        XCTAssertEqual(CanonicalBusinessEngine.storedFileKind(path("u1_1700.pdf")), "subcontractor_document")
        XCTAssertEqual(StorageUploadPolicy.uploadKind(for: .subcontractorDocument), "subcontractor_document")
    }

    func testReaderKeepsOnlyThisFirmsFiles() {
        let data: [String: Any] = [
            "organizationId": org,
            "documents": [
                "insurance": [
                    ["path": path("u_1.pdf"), "name": "PL.pdf", "expiresOn": "2027-03-01", "uploadedBy": "u"],
                    ["path": "https://evil.test/x.pdf"],
                ],
                "rams": [["id": "R-1", "path": path("u_2.jpg"), "expiresOn": "tomorrow"]],
            ],
        ]
        let docs = CanonicalBusinessEngine.parseSubcontractorDocuments(subcontractorId: sub, data: data)
        XCTAssertEqual(docs?.insurance.count, 1)
        XCTAssertEqual(docs?.insurance.first?.expiresOn, "2027-03-01")
        XCTAssertEqual(docs?.rams.first?.id, "R-1")
        XCTAssertNil(docs?.rams.first?.expiresOn)
        let old = CanonicalBusinessEngine.parseSubcontractorDocuments(subcontractorId: sub, data: ["name": "Pipes"])
        XCTAssertEqual(old?.insurance.count, 0)
        XCTAssertEqual(old?.rams.count, 0)
    }

    func testAddWriteKeepsStoredEntries() {
        let stored: [String: Any] = ["documents": ["insurance": [["id": "keep", "path": path("other_1.pdf")]]]]
        let answer = CanonicalBusinessEngine.subcontractorDocumentAddWriteFields(
            stored: stored, kind: "insurance", subcontractorId: sub, organizationId: org,
            path: path("u_9.pdf"), name: "New.pdf", contentType: "application/pdf", sizeBytes: 9,
            uploadedAtMs: 9, uploadedBy: "u", expiresOn: nil
        )
        XCTAssertEqual(answer.outcome, "added")
        XCTAssertEqual(answer.write?.fieldPath, "documents.insurance")
        XCTAssertEqual(answer.write?.value.count, 2)
        let removed = CanonicalBusinessEngine.subcontractorDocumentRemoveWriteFields(
            stored: stored, kind: "insurance", subcontractorId: sub, entryId: "KEEP"
        )
        XCTAssertEqual(removed.removedPath, path("other_1.pdf"))
        XCTAssertEqual(removed.write?.value.count, 0)
    }

    func testExpiryLabels() {
        let now = Date(timeIntervalSince1970: Double(Date.UTC(2026, 11, 24, 12)) / 1000)
        XCTAssertEqual(CanonicalBusinessEngine.subcontractorDocumentExpiryState(expiresOn: nil, now: now, timeZone: "Europe/London").label, "No expiry")
        XCTAssertEqual(CanonicalBusinessEngine.subcontractorDocumentExpiryState(expiresOn: "2026-11-23", now: now, timeZone: "Europe/London").label, "Expired")
        XCTAssertEqual(CanonicalBusinessEngine.subcontractorDocumentExpiryState(expiresOn: "2026-11-25", now: now, timeZone: "Europe/London").label, "Expires in 1 day")
    }

    func testCanManageSubcontractors() {
        XCTAssertTrue(CanonicalBusinessEngine.canManageSubcontractors(["isSuperAdmin": true]))
        XCTAssertTrue(CanonicalBusinessEngine.canManageSubcontractors(["manager": true, "subContractors": true]))
        XCTAssertFalse(CanonicalBusinessEngine.canManageSubcontractors(["manager": true, "subContractors": false]))
        XCTAssertFalse(CanonicalBusinessEngine.canManageSubcontractors(["operativeMode": true, "subContractors": true]))
    }
}

private extension Date {
    /// Epoch milliseconds of a UTC calendar time (month 1-based).
    static func UTC(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
