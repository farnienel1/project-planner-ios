import XCTest
@testable import Project_Planner

/// RULEBOOK 1.83.0 §31: insurance & accreditations through `CanonicalBusinessEngine` (no Swift rule). Expected values
/// are the web `lib/canonical/orgCompliance.test.ts` cases.
@MainActor
final class OrgComplianceTests: XCTestCase {
    private let org = "org1"
    private let today = "2026-11-24"
    private func path(_ name: String) -> String { "organizations/\(org)/compliance/\(name)" }
    private let details = OrgComplianceDetailsInput(
        docType: "public_liability", title: "Public liability 2026–27", issuer: "Aviva", reference: "P-1",
        coverAmount: "10,000,000", expiresOn: "2027-03-31"
    )

    func testPathKindAndSections() {
        XCTAssertEqual(CanonicalBusinessEngine.orgComplianceStoragePath(organizationId: org, uid: "u1", unixMs: 5, fileExtension: "pdf"), path("u1_5.pdf"))
        XCTAssertEqual(CanonicalBusinessEngine.storedFileKind(path("u1_5.pdf")), "org_compliance_document")
        XCTAssertEqual(StorageUploadPolicy.uploadKind(for: .orgComplianceDocument), "org_compliance_document")
        XCTAssertEqual(CanonicalBusinessEngine.orgComplianceSections.map(\.key), ["insurance", "trade", "quality"])
        XCTAssertEqual(CanonicalBusinessEngine.orgComplianceSections.first?.coverLabel, "Limit of indemnity")
    }

    func testOnlyAdmins() {
        XCTAssertTrue(CanonicalBusinessEngine.canManageOrganizationCompliance(["adminAccess": true]))
        XCTAssertFalse(CanonicalBusinessEngine.canManageOrganizationCompliance(["manager": true, "role": "manager"]))
        XCTAssertFalse(CanonicalBusinessEngine.canManageOrganizationCompliance(["operativeMode": true, "role": "operative"]))
    }

    func testStatusOrderCountsAndSubtitle() {
        XCTAssertEqual(CanonicalBusinessEngine.orgComplianceExpiryStatus(expiresOn: "2026-12-14", todayKey: today).label, "20 days left · 14 Dec 2026")
        XCTAssertEqual(CanonicalBusinessEngine.orgComplianceExpiryStatus(expiresOn: "2026-10-03", todayKey: today).tone, "red")
        XCTAssertEqual(CanonicalBusinessEngine.orgComplianceExpiryStatus(expiresOn: nil, todayKey: today).label, "No expiry date")
        let data: [String: Any] = [
            "documents": [
                "insurance": [
                    ["id": "a", "path": path("u1_1.pdf"), "title": "Zeta", "docType": "public_liability"],
                    ["id": "b", "path": path("u1_2.pdf"), "title": "Beta", "docType": "public_liability", "expiresOn": "2027-06-01"],
                    ["id": "c", "path": path("u1_3.pdf"), "title": "Gamma", "docType": "public_liability", "expiresOn": "2026-01-01"],
                    ["id": "d", "path": "https://evil.example/x.pdf"],
                ],
                "trade": [["path": path("u1_5.pdf"), "docType": "gas_safe", "expiresOn": "2026-12-01"]],
            ],
        ]
        guard let docs = CanonicalBusinessEngine.parseOrgComplianceDocuments(data: data, organizationId: org) else {
            return XCTFail("the script did not answer")
        }
        XCTAssertEqual(docs.insurance.count, 3)
        XCTAssertEqual(docs.trade.first?.title, "Gas Safe registration")
        XCTAssertEqual(CanonicalBusinessEngine.orgComplianceSortedEntries(docs.insurance, todayKey: today).map(\.id), ["c", "b", "a"])
        let counts = CanonicalBusinessEngine.orgComplianceCounts(docs, todayKey: today)
        XCTAssertEqual(counts, RulebookOrgComplianceCounts(total: 4, expiringSoon: 1, expired: 1, attention: 2))
        XCTAssertEqual(CanonicalBusinessEngine.orgComplianceHubSubtitle(counts), "4 documents · 2 need attention")
        XCTAssertEqual(CanonicalBusinessEngine.orgComplianceHubSubtitle(nil), "PI, PL, trade and ISO certificates")
        XCTAssertEqual(CanonicalBusinessEngine.parseOrgComplianceDocuments(data: nil, organizationId: org)?.quality.count, 0)
    }

    func testDetailsCheckAndWrites() {
        XCTAssertNil(CanonicalBusinessEngine.orgComplianceDetailsError(section: "insurance", details: details, todayKey: today))
        var bad = details
        bad.title = " "
        XCTAssertEqual(CanonicalBusinessEngine.orgComplianceDetailsError(section: "insurance", details: bad, todayKey: today), "Enter a name.")
        let file = OrgComplianceFileInput(path: path("u1_10.pdf"), fileName: "pl.pdf", contentType: "application/pdf", sizeBytes: 100, uploadedAtMs: 10, uploadedBy: "u1")
        let added = CanonicalBusinessEngine.orgComplianceAddWriteFields(stored: [:], section: "insurance", organizationId: org, todayKey: today, details: details, file: file)
        XCTAssertEqual(added.outcome, "added")
        let documents = added.payload?["documents"] as? [String: Any]
        let list = documents?["insurance"] as? [[String: Any]]
        XCTAssertEqual(list?.count, 1)
        XCTAssertEqual((list?.first?["coverAmount"] as? NSNumber)?.intValue, 10_000_000)
        guard let stored = added.payload, let id = list?.first?["id"] as? String else { return XCTFail("no write") }
        let again = CanonicalBusinessEngine.orgComplianceAddWriteFields(stored: stored, section: "insurance", organizationId: org, todayKey: today, details: details, file: file)
        XCTAssertEqual(again.outcome, "alreadyLinked")
        XCTAssertNil(again.payload)
        let newFile = OrgComplianceFileInput(path: path("u1_30.pdf"), fileName: "pl2.pdf", contentType: "application/pdf", sizeBytes: 100, uploadedAtMs: 30, uploadedBy: "u1")
        let replaced = CanonicalBusinessEngine.orgComplianceReplaceWriteFields(stored: stored, section: "insurance", organizationId: org, entryId: id, todayKey: today, details: details, file: newFile)
        XCTAssertEqual(replaced.outcome, "replaced")
        XCTAssertEqual(replaced.oldPath, path("u1_10.pdf"))
        let removed = CanonicalBusinessEngine.orgComplianceRemoveWriteFields(stored: stored, section: "insurance", organizationId: org, entryId: id)
        XCTAssertEqual(removed.oldPath, path("u1_10.pdf"))
        XCTAssertEqual(((removed.payload?["documents"] as? [String: Any])?["insurance"] as? [Any])?.count, 0)
        let unchanged = CanonicalBusinessEngine.orgComplianceUpdateWriteFields(stored: stored, section: "insurance", organizationId: org, entryId: id, todayKey: today, details: details, updatedAtMs: 20, updatedBy: "u2")
        XCTAssertEqual(unchanged.outcome, "unchanged")
    }
}
