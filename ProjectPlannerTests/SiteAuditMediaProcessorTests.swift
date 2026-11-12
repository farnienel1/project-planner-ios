import XCTest
import UIKit
@testable import Project_Planner

/// Multi-add decodes photos straight to display size (ImageIO), never a full-size decode first.
@MainActor
final class SiteAuditMediaProcessorTests: XCTestCase {
    private func jpeg(width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    func testLargePhotoIsDownsampledToDisplaySize() throws {
        let image = try XCTUnwrap(SiteAuditMediaProcessor.displayImage(from: jpeg(width: 3000, height: 2000)))
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        XCTAssertLessThanOrEqual(longest, SiteAuditMediaProcessor.displayMaxPixelDimension + 1)
        XCTAssertGreaterThan(longest, 1000)
    }

    func testDraftImageKeepsAspectRatio() throws {
        let image = try XCTUnwrap(SiteAuditMediaProcessor.draftImage(from: jpeg(width: 2400, height: 1200)))
        XCTAssertEqual(image.size.width / image.size.height, 2, accuracy: 0.02)
    }

    func testUnreadableDataGivesNil() {
        XCTAssertNil(SiteAuditMediaProcessor.displayImage(from: Data([0x00, 0x01, 0x02])))
    }
}
