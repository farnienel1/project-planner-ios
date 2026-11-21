import XCTest
import UIKit
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK 1.68.0 §29 (owner decision 17 Nov): the iPhone site audit PDF is the web one. Both apps lay the shared
/// fixture (`siteAuditReportFixtureForApps`) out through the rulebook and must get the same text lines and page
/// breaks as `SITE_AUDIT_REPORT_FIXTURE_EXPECTED`; the renderer must draw every op; field limits come from the
/// rulebook and stored longer text is never refused.
@MainActor
final class SiteAuditReportLayoutTests: XCTestCase {
    func testSharedFixtureGivesTheSameLinesAndPagesAsWeb() throws {
        let fixture = try XCTUnwrap(CanonicalBusinessEngine.siteAuditReportFixture(), "the packed script has no site audit fixture")
        XCTAssertEqual(fixture.inputs.count, 7)
        XCTAssertEqual(fixture.expected.count, fixture.inputs.count)
        for (index, entry) in fixture.inputs.enumerated() {
            let name = entry["name"] as? String ?? "#\(index)"
            let input = try XCTUnwrap(entry["input"] as? [String: Any])
            let expected = try XCTUnwrap(fixture.expected.first { $0["name"] as? String == name }, name)
            let layout = try XCTUnwrap(CanonicalBusinessEngine.siteAuditReportLayout(input), name)
            let pages = try XCTUnwrap(layout["pages"] as? [[String: Any]], name)
            XCTAssertEqual(pages.count, expected["pageCount"] as? Int, "\(name): page count")
            XCTAssertEqual(layout["fileName"] as? String, expected["fileName"] as? String, "\(name): file name")
            let opCount = pages.reduce(0) { $0 + ((($1["ops"] as? [Any])?.count) ?? 0) }
            XCTAssertEqual(opCount, expected["opCount"] as? Int, "\(name): op count")
            let lines = try XCTUnwrap(CanonicalBusinessEngine.siteAuditReportTextLines(layout), name)
            XCTAssertEqual(lines, expected["pages"] as? [[String]], "\(name): text lines per page")
        }
    }

    func testOwnersReportHasRealPageNumbers() throws {
        let fixture = try XCTUnwrap(CanonicalBusinessEngine.siteAuditReportFixture())
        let owner = try XCTUnwrap(fixture.inputs.first { $0["name"] as? String == "owner-c646" }?["input"] as? [String: Any])
        let layout = try XCTUnwrap(CanonicalBusinessEngine.siteAuditReportLayout(owner))
        let lines = try XCTUnwrap(CanonicalBusinessEngine.siteAuditReportTextLines(layout))
        // Before 1.68.0 every footer read "Page n of n".
        for (index, page) in lines.enumerated() {
            XCTAssertTrue(page.contains("Page \(index + 1) of \(lines.count)"), "page \(index + 1)")
        }
        // The tagline the owner asked to remove (Q4) is gone.
        XCTAssertFalse(lines.joined().contains { $0.contains("Mechanical & Electrical Contractors") })
    }

    func testRendererDrawsEveryOpIntoAPdf() throws {
        let fixture = try XCTUnwrap(CanonicalBusinessEngine.siteAuditReportFixture())
        for entry in fixture.inputs {
            let name = entry["name"] as? String ?? "?"
            let input = try XCTUnwrap(entry["input"] as? [String: Any])
            let layout = try XCTUnwrap(CanonicalBusinessEngine.siteAuditReportLayout(input))
            let pages = try XCTUnwrap(layout["pages"] as? [[String: Any]])
            // One picture for every image op (a tiny solid image), and none for the rest: both paths are drawn.
            let picture = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).image { context in
                UIColor.gray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
            }
            var images: [String: UIImage] = [:]
            for page in pages {
                for op in (page["ops"] as? [[String: Any]]) ?? [] where op["kind"] as? String == "image" {
                    if let ref = op["ref"] as? String, images.count.isMultiple(of: 2) { images[ref] = picture }
                }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("SiteAuditReportLayoutTests-\(name).pdf")
            let drawn = try SiteAuditPDFBuilder.render(layout: layout, images: images, to: url)
            let opCount = pages.reduce(0) { $0 + ((($1["ops"] as? [Any])?.count) ?? 0) }
            XCTAssertEqual(drawn.count, opCount, "\(name): every op drawn")
            let drawnText = drawn.compactMap(\.text)
            let layoutText = try XCTUnwrap(CanonicalBusinessEngine.siteAuditReportTextLines(layout)).flatMap { $0 }
            XCTAssertEqual(drawnText, layoutText, "\(name): every line drawn in order")
            let document = try XCTUnwrap(CGPDFDocument(url as CFURL), name)
            XCTAssertEqual(document.numberOfPages, pages.count, "\(name): PDF pages")
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 1.68.0 (owner request 17 Nov): the company logo at the top right, fitted whole; the initials badge when
    /// there is no logo or it could not be loaded (the app passes no logo).
    func testCompanyLogoTopRightOrInitialsBadge() throws {
        let fixture = try XCTUnwrap(CanonicalBusinessEngine.siteAuditReportFixture())
        func firstPageOps(_ name: String) throws -> [[String: Any]] {
            let input = try XCTUnwrap(fixture.inputs.first { $0["name"] as? String == name }?["input"] as? [String: Any], name)
            let layout = try XCTUnwrap(CanonicalBusinessEngine.siteAuditReportLayout(input), name)
            return try XCTUnwrap((layout["pages"] as? [[String: Any]])?.first?["ops"] as? [[String: Any]], name)
        }
        let rightMargin = 595.28 - 32
        for (name, aspect) in [("logo-very-wide", 12.0), ("logo-very-tall", 1.0 / 12.0), ("owner-c646", 4.0 / 3.0)] {
            let ops = try firstPageOps(name)
            let logo = try XCTUnwrap(ops.first { $0["kind"] as? String == "image" && $0["ref"] as? String == "logo" }, name)
            let w = try XCTUnwrap(logo["w"] as? Double), h = try XCTUnwrap(logo["h"] as? Double)
            let x = try XCTUnwrap(logo["x"] as? Double), y = try XCTUnwrap(logo["y"] as? Double)
            XCTAssertEqual(w / h, aspect, accuracy: aspect * 0.03, "\(name): aspect kept")
            XCTAssertLessThanOrEqual(w, 98.01, "\(name): fits the box")
            XCTAssertLessThanOrEqual(h, 52.01, "\(name): fits the box")
            XCTAssertEqual(x + w + 6, rightMargin, accuracy: 0.05, "\(name): right edge on the margin")
            XCTAssertEqual(y, 30, accuracy: 0.05, "\(name): at the top")
            XCTAssertFalse(ops.contains { $0["kind"] as? String == "text" && $0["text"] as? String == "RM" }, "\(name): no badge")
        }
        let missing = try firstPageOps("logo-missing-or-failed")
        XCTAssertFalse(missing.contains { $0["kind"] as? String == "image" && $0["ref"] as? String == "logo" })
        XCTAssertTrue(missing.contains { $0["kind"] as? String == "text" && $0["text"] as? String == "RM" })
    }

    /// A logo that cannot be read (a PDF logo, a bad URL) gives nil and never blocks the report.
    func testCompanyLogoLoaderFallsBackToNil() async {
        let refused = await CompanyLogoLoader.logo(urlString: "http://example.com/logo.png")
        XCTAssertNil(refused)
        let missing = await CompanyLogoLoader.logo(urlString: nil)
        XCTAssertNil(missing)
        XCTAssertNil(UIImage(data: Data("%PDF-1.7 logo".utf8)), "a PDF logo is not a picture: the badge shows")
    }

    /// Review of #262: the input is composed by the rulebook (`siteAuditReportInput`) — the job's address lines, never
    /// map coordinates; a stored photo that did not load keeps a 4 : 3 box; the same audit gives the same pages.
    func testInputIsComposedByTheRulebook() throws {
        let input = try XCTUnwrap(CanonicalBusinessEngine.siteAuditReportInput([
            "audit": ["id": "A", "projectJobNumber": "C1", "projectName": "Job", "type": "General", "authorName": "Ann",
                      "dateMs": 0, "createdAtMs": 0,
                      "items": [["id": "loaded", "imageURL": "https://x/a.jpg"], ["id": "failed", "imageURL": "https://x/b.jpg"], ["id": "none"]]],
            "job": ["clientName": "RED", "addressLine1": "71 Broadwick St", "addressLine2": "", "townCity": "London", "postcode": "W1F 9QY"],
            "photos": ["loaded": ["width": 300, "height": 400]],
            "timeZone": "Europe/London",
        ]))
        XCTAssertEqual(input["siteAddress"] as? String, "71 Broadwick St, London, W1F 9QY")
        XCTAssertEqual(input["clientName"] as? String, "RED")
        let items = try XCTUnwrap((input["audit"] as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual((items[0]["photo"] as? [String: Double])?["height"], 400)
        XCTAssertEqual((items[1]["photo"] as? [String: Double])?["width"], 4)
        XCTAssertTrue(items[2]["photo"] is NSNull || items[2]["photo"] == nil)
    }

    func testFieldLimitsComeFromTheRulebook() throws {
        let limits = CanonicalBusinessEngine.siteAuditFieldLimits
        XCTAssertEqual(limits["title"], 120)
        XCTAssertEqual(limits["location"], 120)
        XCTAssertEqual(limits["assignee"], 80)
        XCTAssertEqual(limits["comments"], 2000)
        XCTAssertEqual(limits["annotations"], 2000)
        XCTAssertEqual(limits["customTitle"], 120)
        // Final review of #389 / #262: personal audit job number and name are limited, never cut.
        XCTAssertEqual(limits["jobNumber"], 60)
        XCTAssertEqual(limits["jobName"], 200)
        XCTAssertEqual(CanonicalBusinessEngine.siteAuditFieldLabel("jobName"), "Job name")
        let longJob: [String: Any] = [
            "jobNumber": String(repeating: "9", count: 61), "jobName": "Job", "date": "2026-11-18",
            "items": [["id": "i", "title": "T"]],
        ]
        XCTAssertNotNil(CanonicalBusinessEngine.personalSiteAuditValidationError(draft: longJob, organizationId: nil, ownerUserId: nil))
        XCTAssertEqual(CanonicalBusinessEngine.siteAuditFieldLabel("location"), "Location")
        let counter = try XCTUnwrap(CanonicalBusinessEngine.siteAuditFieldCounter(field: "title", value: String(repeating: "a", count: 34)))
        XCTAssertEqual(counter.label, "34 / 120")
        XCTAssertFalse(counter.blocksSave)
    }

    /// Final review of #389 / #262: each photo's object name is unique per item and the same on every retry.
    func testPhotoObjectPathIsUniquePerItemAndStable() {
        let paths = (0..<3).map {
            CanonicalBusinessEngine.siteAuditPhotoObjectPath(
                kind: "project", organizationId: "org", userId: "U1abc", auditId: "A1",
                createdAtMs: 1_763_400_000_000, index: $0, fileExtension: "jpg"
            )
        }
        XCTAssertEqual(paths, (0..<3).map { "organizations/org/siteAudits/A1/images/U1abc_\(1_763_400_000_000 + $0).jpg" })
        XCTAssertEqual(
            CanonicalBusinessEngine.siteAuditPhotoObjectPath(
                kind: "personal", organizationId: "org", userId: "U1abc", auditId: "A1",
                createdAtMs: 1_763_400_000_000, index: 1, fileExtension: "jpg"
            ),
            "organizations/org/personalSiteAudits/U1abc/A1/U1abc_1763400000001.jpg"
        )
    }

    func testOnlyNewEditsAreLimitedStoredTextPasses() {
        let long = String(repeating: "x", count: 121)
        XCTAssertNotNil(CanonicalBusinessEngine.siteAuditFieldLimitError(["title": long]))
        // Guardrail 3: a title stored before the limit, left as it is, is never refused or cut.
        XCTAssertNil(CanonicalBusinessEngine.siteAuditFieldLimitError(["title": long], stored: ["title": long]))
        XCTAssertNotNil(CanonicalBusinessEngine.siteAuditFieldLimitError(["title": long + "y"], stored: ["title": long]))
    }

    /// The audit made on web (the contract sample) opens on the iPhone with every field, the photo time included,
    /// and the iPhone's save writes `imageCapturedAt` back (owner Q1).
    func testWebAuditOpensAndSavesOnIPhoneWithNothingLost() throws {
        let bundle = Bundle(for: SiteAuditReportLayoutTests.self)
        let url = bundle.url(forResource: "CrossPlatformContract", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("CrossPlatformContract.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let collections = try XCTUnwrap(root["collections"] as? [[String: Any]])
        let siteAudits = try XCTUnwrap(collections.first { $0["id"] as? String == "siteAudits" })
        let samples = try XCTUnwrap(siteAudits["samples"] as? [[String: Any]])
        let web = try XCTUnwrap(samples.first { $0["platform"] as? String == "web" })
        let docId = try XCTUnwrap(web["docId"] as? String)
        let data = try XCTUnwrap(web["data"] as? [String: Any])
        let audit = try XCTUnwrap(FirebaseBackend.siteAudit(documentId: docId, data: firestoreData(data) as? [String: Any] ?? data))
        let webItems = try XCTUnwrap(data["items"] as? [[String: Any]])
        XCTAssertEqual(audit.items.count, webItems.count)
        for (stored, item) in zip(webItems, audit.items) {
            XCTAssertEqual(item.title, stored["title"] as? String ?? "")
            XCTAssertEqual(item.location, stored["location"] as? String ?? "")
            XCTAssertEqual(item.assignee, stored["assignee"] as? String ?? "")
            XCTAssertEqual(item.comments, stored["comments"] as? String ?? "")
            XCTAssertEqual(item.annotations, stored["annotations"] as? String ?? "")
            if stored["imageCapturedAt"] != nil, !(stored["imageCapturedAt"] is NSNull) {
                XCTAssertNotNil(item.imageCapturedAt, "the photo time web stored is read")
            }
        }
        let payload = try FirebaseBackend.siteAuditPayload(audit, organizationId: "ORG-1", storedItems: data["items"])
        let written = try XCTUnwrap(payload["items"] as? [[String: Any]])
        for (stored, item) in zip(webItems, written) where stored["imageCapturedAt"] != nil && !(stored["imageCapturedAt"] is NSNull) {
            XCTAssertNotNil(item["imageCapturedAt"], "the iPhone's save keeps the photo time")
        }
    }

    private func firestoreData(_ value: Any) -> Any {
        if let map = value as? [String: Any] {
            if map.count == 2, let seconds = map["seconds"] as? NSNumber, let nanos = map["nanoseconds"] as? NSNumber {
                return Timestamp(seconds: seconds.int64Value, nanoseconds: nanos.int32Value)
            }
            return map.mapValues { firestoreData($0) }
        }
        if let list = value as? [Any] { return list.map { firestoreData($0) } }
        return value
    }
}
