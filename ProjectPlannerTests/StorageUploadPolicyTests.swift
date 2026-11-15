import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Project_Planner

@MainActor
final class StorageUploadPolicyTests: XCTestCase {
    func testProfileObjectNameIsProfileJpg() {
        XCTAssertEqual(StorageUploadPolicy.profileObjectName, "profile.jpg")
    }

    func testGeneratedObjectNameDropsTheOriginalBasename() {
        let name = StorageUploadPolicy.generatedObjectName(
            uid: "abc",
            unixMilliseconds: 1_710_000_000_000,
            originalFileName: "Site plan final.xlsx"
        )
        XCTAssertEqual(name, "abc_1710000000000.xlsx")
        XCTAssertFalse(name?.contains("Site plan final") ?? true)
        XCTAssertFalse(name?.contains(" ") ?? true)
        XCTAssertTrue(name?.range(of: #"^[A-Za-z0-9_-]+_[0-9]+\.[a-z0-9]+$"#, options: .regularExpression) != nil)
    }

    /// RULEBOOK 1.50.0 §24: work files are photos and PDFs only — no text, Excel, Word, CSV or ZIP.
    func testPlainTextAndExcelAreRefusedForWorkFiles() {
        XCTAssertNotNil(StorageUploadPolicy.refusal(family: .workFile, fileExtension: "txt", contentType: "text/plain", byteCount: 128))
        XCTAssertNotNil(StorageUploadPolicy.refusal(family: .workFile, fileExtension: "txt", contentType: "application/octet-stream", byteCount: 128))
        XCTAssertNotNil(StorageUploadPolicy.refusal(family: .workFile, fileExtension: "xlsx", contentType: "application/octet-stream", byteCount: 128))
        XCTAssertNotNil(StorageUploadPolicy.refusal(family: .workFile, fileExtension: "xlsm", contentType: nil, byteCount: 128))
        XCTAssertNotNil(StorageUploadPolicy.refusal(family: .workFile, fileExtension: "docx", contentType: nil, byteCount: 128))
        XCTAssertNotNil(StorageUploadPolicy.refusal(family: .workFile, fileExtension: "zip", contentType: nil, byteCount: 128))
        XCTAssertNotNil(StorageUploadPolicy.refusal(family: .workFile, fileExtension: "svg", contentType: "image/svg+xml", byteCount: 128))
        XCTAssertNotNil(StorageUploadPolicy.refusal(family: .workFile, fileExtension: "gif", contentType: "image/gif", byteCount: 128))
        XCTAssertNil(StorageUploadPolicy.refusal(family: .workFile, fileExtension: "pdf", contentType: "application/pdf", byteCount: 128))
        XCTAssertNil(StorageUploadPolicy.refusal(family: .workFile, fileExtension: "heic", contentType: nil, byteCount: 128))
        XCTAssertEqual(StorageUploadPolicy.workFileContentTypes, [.jpeg, .png, .heic, .heif, .webP, .pdf])
    }

    /// RULEBOOK 1.50.0: certificates take every photo type and PDF, up to 10 MB. A photo is judged on 40 MB when picked
    /// (it is redrawn first); a PDF on the 10 MB cap.
    func testQualificationTypesAndTenMegabyteCap() {
        let ten = 10 * 1024 * 1024
        let eleven = 11 * 1024 * 1024
        XCTAssertNil(StorageUploadPolicy.refusal(family: .qualificationCertificate, fileExtension: "png", contentType: "image/png", byteCount: 1024))
        XCTAssertNil(StorageUploadPolicy.refusal(family: .qualificationCertificate, fileExtension: "heic", contentType: "image/heic", byteCount: 1024))
        XCTAssertNil(StorageUploadPolicy.refusal(family: .qualificationCertificate, fileExtension: "pdf", contentType: "application/pdf", byteCount: ten))
        XCTAssertNil(StorageUploadPolicy.refusal(family: .qualificationCertificate, fileExtension: "jpg", contentType: "image/jpeg", byteCount: ten))
        XCTAssertNil(StorageUploadPolicy.refusal(family: .qualificationCertificate, fileExtension: "jpeg", contentType: "image/pjpeg", byteCount: ten))
        XCTAssertNotNil(StorageUploadPolicy.refusal(family: .qualificationCertificate, fileExtension: "pdf", contentType: "application/pdf", byteCount: eleven))
        XCTAssertNotNil(StorageUploadPolicy.refusal(family: .qualificationCertificate, fileExtension: "jpg", contentType: "image/jpeg", byteCount: 40 * 1024 * 1024 + 1))
    }

    /// RULEBOOK 1.50.0: variation evidence is capped at 10 MB (was 20 MB).
    func testVariationTenMegabytesIsTheCap() {
        let ten = 10 * 1024 * 1024
        XCTAssertEqual(StorageUploadPolicy.variationMaxBytes, ten)
        XCTAssertNil(StorageUploadPolicy.refusal(family: .variationEvidence, fileExtension: "pdf", contentType: "application/pdf", byteCount: ten))
        XCTAssertNotNil(StorageUploadPolicy.refusal(family: .variationEvidence, fileExtension: "pdf", contentType: "application/pdf", byteCount: ten + 1))
        XCTAssertNotNil(StorageUploadPolicy.refusal(family: .variationEvidence, fileExtension: "xlsx", contentType: "application/octet-stream", byteCount: 128))
    }

    func testLogoPdfIsAllowedUntilFiveMegabytes() {
        XCTAssertNil(
            StorageUploadPolicy.refusal(
                family: .companyLogo,
                fileExtension: "pdf",
                contentType: "application/pdf",
                byteCount: 5 * 1024 * 1024
            )
        )
        XCTAssertNotNil(
            StorageUploadPolicy.refusal(
                family: .companyLogo,
                fileExtension: "pdf",
                contentType: "application/pdf",
                byteCount: 5 * 1024 * 1024 + 1
            )
        )
    }

    /// The profile photo is redrawn and its 2 MB cap is checked on the redrawn bytes (`checkedUploadContentType`); a
    /// profile PDF is never allowed.
    func testProfilePhotoCapAndTypes() throws {
        XCTAssertNotNil(StorageUploadPolicy.refusal(family: .profilePhoto, fileExtension: "pdf", contentType: "application/pdf", byteCount: 1024))
        let path = "organizations/TEST-org/userProfiles/u1/profile.jpg"
        var big = Data([0xFF, 0xD8, 0xFF, 0xE0])
        big.append(Data(count: 2 * 1024 * 1024))
        XCTAssertThrowsError(try StorageUploadPolicy.checkedUploadContentType(storagePath: path, data: big, declaredContentType: "image/jpeg"))
        let small = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        XCTAssertEqual(try StorageUploadPolicy.checkedUploadContentType(storagePath: path, data: small, declaredContentType: "image/jpeg"), "image/jpeg")
    }

    func testRedrawnJPEGDropsGPS() throws {
        let source = try jpegWithGPS()
        let input = properties(of: source)
        XCTAssertNotNil(input?[kCGImagePropertyGPSDictionary])

        let image = try XCTUnwrap(UIImage(data: source))
        let output = try XCTUnwrap(StorageUploadPolicy.jpegDataByRedrawing(image))
        let outputProperties = properties(of: output)
        XCTAssertNil(outputProperties?[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(output.prefix(3), Data([0xFF, 0xD8, 0xFF]))
    }

    private func jpegWithGPS() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            XCTFail("Could not create a JPEG destination")
            return Data()
        }
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 51.5074,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.1278,
            kCGImagePropertyGPSLongitudeRef: "W"
        ]
        CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            XCTFail("Could not write the GPS JPEG")
            return Data()
        }
        return data as Data
    }

    private func properties(of data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }
}
