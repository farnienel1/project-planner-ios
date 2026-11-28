import XCTest
@testable import Project_Planner

/// Owner report 26 Nov: site audit PDFs on web had every photo blank. A photo the PDF cannot draw keeps its grey box,
/// but the share button must say so (never silent); the words match web's `siteAuditPdfPhotosNotice`.
final class SiteAuditPhotoLoadTests: XCTestCase {
    func testNoNoticeWhenEveryPhotoIsDrawn() {
        XCTAssertNil(SiteAuditPDFBuilder.photosNotDrawnNotice(photos: 3, notDrawn: 0))
        XCTAssertNil(SiteAuditPDFBuilder.photosNotDrawnNotice(photos: 0, notDrawn: 0))
    }

    func testNoticeNamesHowManyPhotosAreMissing() {
        let all = SiteAuditPDFBuilder.photosNotDrawnNotice(photos: 6, notDrawn: 6) ?? ""
        XCTAssertTrue(all.contains("All 6 photos could not be loaded and are shown as grey boxes"), all)
        let one = SiteAuditPDFBuilder.photosNotDrawnNotice(photos: 3, notDrawn: 1) ?? ""
        XCTAssertTrue(one.contains("1 of 3 photos could not be loaded and is shown as grey boxes"), one)
        let single = SiteAuditPDFBuilder.photosNotDrawnNotice(photos: 1, notDrawn: 1) ?? ""
        XCTAssertTrue(single.contains("The photo could not be loaded and is shown"), single)
    }

    func testANonHttpsPhotoAddressIsNotLoaded() async {
        let image = await SiteAuditPDFBuilder.loadStoredPhoto(urlString: "gs://bucket/organizations/o1/a.jpg")
        XCTAssertNil(image)
        let none = await SiteAuditPDFBuilder.loadStoredPhoto(urlString: nil)
        XCTAssertNil(none)
    }
}
