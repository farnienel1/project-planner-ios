import XCTest
import UIKit
import FirebaseFirestore
@testable import Project_Planner

/// RULEBOOK 1.61.0 §29 (owner decision 17 Nov): the iPhone site audit PDF is the web one. Both apps lay the shared
/// fixture (`siteAuditReportFixtureForApps`) out through the rulebook and must get the same text lines and page
/// breaks as `SITE_AUDIT_REPORT_FIXTURE_EXPECTED`; the renderer must draw every op; field limits come from the
/// rulebook and stored longer text is never refused.
@MainActor
final class SiteAuditReportLayoutTests: XCTestCase {
    func testSharedFixtureGivesTheSameLinesAndPagesAsWeb() throws {
        let fixture = try XCTUnwrap(CanonicalBusinessEngine.siteAuditReportFixture(), "the packed script has no site audit fixture")
        XCTAssertEqual(fixture.inputs.count, 3)
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
        // Before 1.61.0 every footer read "Page n of n".
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

    func testFieldLimitsComeFromTheRulebook() throws {
        let limits = CanonicalBusinessEngine.siteAuditFieldLimits
        XCTAssertEqual(limits["title"], 120)
        XCTAssertEqual(limits["location"], 120)
        XCTAssertEqual(limits["assignee"], 80)
        XCTAssertEqual(limits["comments"], 2000)
        XCTAssertEqual(limits["annotations"], 2000)
        XCTAssertEqual(limits["customTitle"], 120)
        XCTAssertEqual(CanonicalBusinessEngine.siteAuditFieldLabel("location"), "Location")
        let counter = try XCTUnwrap(CanonicalBusinessEngine.siteAuditFieldCounter(field: "title", value: String(repeating: "a", count: 34)))
        XCTAssertEqual(counter.label, "34 / 120")
        XCTAssertFalse(counter.blocksSave)
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
