import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Project_Planner

/// RULEBOOK 1.50.0 §24 (owner decisions 15 Nov): upload hardening and safe links on iOS, through
/// `CanonicalBusinessEngine` (`uploadAllowed`, `photoPrepareRefusal`, `imageDimensionsFromHeader`, `safeExternalUrl`).
/// Expected values were checked in node against the packed `canonical-business.js` (rulebook 1.50.0, sha256
/// 42329d4b…3cdb4b).
@MainActor
final class Rulebook1500UploadTests: XCTestCase {
    private let pdf = Data("%PDF-1.4\n%âãÏÓ\n1 0 obj\n".utf8)
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00])
    private let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#.utf8)
    private let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x06, 0x00])
    private let org = "TEST-org"

    func testThePackedScriptIsRulebook1500OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        XCTAssertNotEqual(stamp.version.compare("1.50.0", options: .numeric), .orderedAscending)
        for name in ["uploadAllowed", "uploadKindForStoragePath", "safeExternalUrl", "photoPrepareRefusal", "imageDimensionsFromHeader"] {
            XCTAssertEqual(CanonicalBusinessEngine.exportKind(name), "function", name)
        }
    }

    // MARK: - uploadAllowed

    func testAnSVGRenamedJpgIsRefused() {
        let decision = CanonicalBusinessEngine.uploadAllowed(kind: "task_attachment", fileName: "photo.jpg", contentType: "", sizeBytes: svg.count, headBytes: svg)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "content_mismatch")
        XCTAssertNil(decision.contentType)
        let claimed = CanonicalBusinessEngine.uploadAllowed(kind: "variation_evidence", fileName: "photo.jpg", contentType: "image/jpeg", sizeBytes: svg.count, headBytes: svg)
        XCTAssertFalse(claimed.allowed)
    }

    func testAnXlsmIsRefused() {
        let decision = CanonicalBusinessEngine.uploadAllowed(kind: "task_attachment", fileName: "talk.xlsm", contentType: "", sizeBytes: zip.count, headBytes: zip)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "type_not_allowed")
        XCTAssertEqual(
            decision.message,
            "This type of file cannot be uploaded. Use a photo (JPEG, PNG, HEIC or WebP) or a PDF, up to 10 MB."
        )
        XCTAssertFalse(CanonicalBusinessEngine.uploadAllowed(kind: "health_safety", fileName: "talk.xlsx", contentType: nil, sizeBytes: 128, headBytes: nil).allowed)
    }

    /// `application/octet-stream` is never written: unknown bytes are refused, and a real PDF is written as a PDF.
    func testOctetStreamIsNeverTheWrittenType() {
        let unknown = CanonicalBusinessEngine.uploadAllowed(
            kind: "task_attachment", fileName: "", contentType: "application/octet-stream",
            sizeBytes: 6, headBytes: Data([1, 2, 3, 4, 0, 9])
        )
        XCTAssertFalse(unknown.allowed)
        XCTAssertEqual(unknown.reason, "content_unknown")
        let realPDF = CanonicalBusinessEngine.uploadAllowed(
            kind: "task_attachment", fileName: "scan.pdf", contentType: "application/octet-stream",
            sizeBytes: pdf.count, headBytes: pdf
        )
        XCTAssertTrue(realPDF.allowed)
        XCTAssertEqual(realPDF.contentType, "application/pdf")
    }

    func testAnOversizeFileIsRefused() {
        let tenMB = 10 * 1024 * 1024
        let over = CanonicalBusinessEngine.uploadAllowed(kind: "variation_evidence", fileName: "a.pdf", contentType: "application/pdf", sizeBytes: tenMB + 1, headBytes: pdf)
        XCTAssertFalse(over.allowed)
        XCTAssertEqual(over.reason, "too_large")
        XCTAssertEqual(over.message, "This file is too large. Use a photo (JPEG, PNG, HEIC or WebP) or a PDF, up to 10 MB.")
        XCTAssertTrue(CanonicalBusinessEngine.uploadAllowed(kind: "variation_evidence", fileName: "a.pdf", contentType: "application/pdf", sizeBytes: tenMB, headBytes: pdf).allowed)
        XCTAssertFalse(CanonicalBusinessEngine.uploadAllowed(kind: "profile_photo", fileName: "profile.jpg", contentType: "image/jpeg", sizeBytes: 2 * 1024 * 1024 + 1, headBytes: jpeg).allowed)
    }

    func testAJPEGAndAPDFAreAccepted() {
        let photo = CanonicalBusinessEngine.uploadAllowed(kind: "site_audit_photo", fileName: "u_1.jpg", contentType: "image/jpeg", sizeBytes: jpeg.count, headBytes: jpeg)
        XCTAssertTrue(photo.allowed)
        XCTAssertEqual(photo.contentType, "image/jpeg")
        let file = CanonicalBusinessEngine.uploadAllowed(kind: "paye_claim_evidence", fileName: "u_1.pdf", contentType: "application/pdf", sizeBytes: pdf.count, headBytes: pdf)
        XCTAssertTrue(file.allowed)
        XCTAssertEqual(file.contentType, "application/pdf")
        XCTAssertEqual(CanonicalBusinessEngine.uploadAllowedTypes["variation_evidence"]?.maxBytes, 10 * 1024 * 1024)
        XCTAssertEqual(CanonicalBusinessEngine.uploadAllowedTypes["profile_photo"]?.maxBytes, 2 * 1024 * 1024)
    }

    func testGIFIsNeverAllowed() {
        let gif = Data("GIF89a\u{01}\u{00}".utf8)
        XCTAssertFalse(CanonicalBusinessEngine.uploadAllowed(kind: "task_attachment", fileName: "a.gif", contentType: "", sizeBytes: gif.count, headBytes: gif).allowed)
    }

    // MARK: - The one check before every upload

    func testEveryAppUploadPathHasAKind() {
        let paths = [
            "organizations/\(org)/tasks/T/files/u_1.pdf",
            "organizations/\(org)/tasks/T/images/u_1.jpg",
            "organizations/\(org)/healthSafety/P/talks/u_1.pdf",
            "organizations/\(org)/healthSafety/P/deadlines/u_1.pdf",
            "organizations/\(org)/healthSafety/P/variationEvidence/u_1.pdf",
            "organizations/\(org)/variations/V/u_1.pdf",
            "organizations/\(org)/userProfiles/U/profile.jpg",
            "organizations/\(org)/branding/company_logo/u_1.png",
            "organizations/\(org)/siteAudits/A/images/u_1.jpg",
            "organizations/\(org)/payeClaims/U/u_1.jpg",
            "organizations/\(org)/personalSiteAudits/U/A/u_1.jpg",
            "organizations/\(org)/operatives/X/qualifications/Q/certificates/u_1.jpg",
        ]
        for path in paths {
            XCTAssertNotNil(CanonicalBusinessEngine.uploadKindForStoragePath(path), path)
        }
        XCTAssertNil(CanonicalBusinessEngine.uploadKindForStoragePath("somewhere/else.pdf"))
    }

    func testCheckedUploadContentTypeWritesTheDetectedType() throws {
        let path = "organizations/\(org)/variations/V/u_1.pdf"
        XCTAssertEqual(try StorageUploadPolicy.checkedUploadContentType(storagePath: path, data: pdf, declaredContentType: "application/octet-stream"), "application/pdf")
        XCTAssertThrowsError(try StorageUploadPolicy.checkedUploadContentType(
            storagePath: "organizations/\(org)/tasks/T/files/u_1.jpg", data: svg, declaredContentType: "image/jpeg"
        ))
        XCTAssertThrowsError(try StorageUploadPolicy.checkedUploadContentType(storagePath: "elsewhere/u_1.pdf", data: pdf, declaredContentType: "application/pdf"))
    }

    /// The 1.50.0 Storage rules are live (web #333): certificates take every allowed photo type as well as JPEG and PDF,
    /// and a PNG certificate stays a PNG when it is redrawn (web `stripPhotoLocation` `auto`).
    func testCertificatesAcceptEveryAllowedPhotoType() throws {
        let base = "organizations/\(org)/operatives/X/qualifications/Q/certificates/"
        XCTAssertEqual(try StorageUploadPolicy.checkedUploadContentType(storagePath: base + "u_1.jpg", data: jpeg, declaredContentType: "image/jpeg"), "image/jpeg")
        XCTAssertEqual(try StorageUploadPolicy.checkedUploadContentType(storagePath: base + "u_1.pdf", data: pdf, declaredContentType: "application/pdf"), "application/pdf")
        let png = try XCTUnwrap(solidImage(size: 8).pngData())
        XCTAssertEqual(try StorageUploadPolicy.checkedUploadContentType(storagePath: base + "u_1.png", data: png, declaredContentType: "image/png"), "image/png")
        let prepared = try StorageUploadPolicy.prepareFileData(
            png, originalFileName: "certificate.png", declaredContentType: "", family: .qualificationCertificate,
            uid: "TEST-uid", unixMilliseconds: 1_793_750_000_000
        )
        XCTAssertEqual(prepared.contentType, "image/png")
        XCTAssertTrue(prepared.objectName.hasSuffix(".png"))
        XCTAssertEqual(prepared.data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(try StorageUploadPolicy.checkedUploadContentType(storagePath: base + prepared.objectName, data: prepared.data, declaredContentType: prepared.contentType), "image/png")
    }

    /// HEIC and WebP certificates pass the pick-time check (as `OperativeQualificationsEditorView` runs it) and are
    /// redrawn to JPEG by `prepareFileData` (only a PNG stays a PNG).
    func testHEICAndWebPCertificatesPassAndAreRedrawnToJPEG() throws {
        let kind = StorageUploadPolicy.uploadKind(for: .qualificationCertificate)
        // 8×8 lossless WebP (RIFF…WEBP), checked in node against the packed script: `image/webp`, allowed.
        let webp = try XCTUnwrap(Data(base64Encoded: "UklGRhwAAABXRUJQVlA4TA8AAAAvB8ABAAcQ/Y/+ByKi/wEA"))
        var samples: [(name: String, data: Data, types: Set<String>)] = [("certificate.webp", webp, ["image/webp"])]
        if let heic = encodedHEIC(solidImage(size: 16)) {
            samples.append(("certificate.heic", heic, ["image/heic", "image/heif"]))
        }
        for sample in samples {
            let picked = CanonicalBusinessEngine.uploadAllowed(
                kind: kind, fileName: sample.name, contentType: nil, sizeBytes: 1, headBytes: sample.data
            )
            XCTAssertTrue(picked.allowed, sample.name)
            XCTAssertTrue(sample.types.contains(picked.contentType ?? ""), sample.name)
            XCTAssertNil(StorageUploadPolicy.refusal(
                family: .qualificationCertificate,
                fileExtension: (sample.name as NSString).pathExtension,
                contentType: nil,
                byteCount: sample.data.count
            ), sample.name)
            let prepared = try StorageUploadPolicy.prepareFileData(
                sample.data, originalFileName: sample.name, declaredContentType: nil, family: .qualificationCertificate,
                uid: "TEST-uid", unixMilliseconds: 1_793_750_000_000
            )
            XCTAssertEqual(prepared.contentType, "image/jpeg", sample.name)
            XCTAssertTrue(prepared.objectName.hasSuffix(".jpg"), sample.name)
            XCTAssertEqual(prepared.data.prefix(3), Data([0xFF, 0xD8, 0xFF]), sample.name)
        }
        if samples.count < 2 {
            throw XCTSkip("ImageIO cannot encode HEIC on this runner; the WebP certificate was checked.")
        }
    }

    func testPrepareFileDataRefusesARenamedSVGAndKeepsAPDF() throws {
        XCTAssertThrowsError(try StorageUploadPolicy.prepareFileData(
            svg, originalFileName: "site.jpg", declaredContentType: nil, family: .workFile,
            uid: "TEST-uid", unixMilliseconds: 1_793_750_000_000
        ))
        let kept = try StorageUploadPolicy.prepareFileData(
            pdf, originalFileName: "RAMS final.pdf", declaredContentType: nil, family: .workFile,
            uid: "TEST-uid", unixMilliseconds: 1_793_750_000_000
        )
        XCTAssertEqual(kept.contentType, "application/pdf")
        XCTAssertEqual(kept.objectName, "TEST-uid_1793750000000.pdf")
        XCTAssertEqual(kept.data, pdf)
    }

    /// A company logo is never turned into a JPEG.
    func testALogoImageIsUploadedAsPNG() throws {
        let prepared = try StorageUploadPolicy.prepareImage(
            solidImage(size: 16), family: .companyLogo, uid: "TEST-uid", unixMilliseconds: 1_793_750_000_000,
            initialQuality: 0.75, encodeFailedMessage: "x", oversizedMessage: "y"
        )
        XCTAssertEqual(prepared.contentType, "image/png")
        XCTAssertTrue(prepared.objectName.hasSuffix(".png"))
        XCTAssertEqual(prepared.data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testRedrawnPhotosAreAtMost2560Pixels() throws {
        let jpegData = try XCTUnwrap(StorageUploadPolicy.jpegDataByRedrawing(solidImage(size: 3000)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpegData as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        XCTAssertLessThanOrEqual(width, 2560)
    }

    // MARK: - Photo limits before decoding

    func testPhotoPrepareRefusal() {
        XCTAssertNil(CanonicalBusinessEngine.photoPrepareRefusal(sizeBytes: 1024, width: 4000, height: 3000))
        XCTAssertEqual(
            CanonicalBusinessEngine.photoPrepareRefusal(sizeBytes: 40 * 1024 * 1024 + 1, width: nil, height: nil),
            "This photo is over 40 MB, too large to prepare. Use a smaller photo (JPEG, PNG, HEIC or WebP)."
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.photoPrepareRefusal(sizeBytes: 1024, width: 10_000, height: 6_000),
            "This photo is over 50 megapixels, too large to prepare. Use a smaller photo (JPEG, PNG, HEIC or WebP)."
        )
    }

    func testImageDimensionsFromAPNGHeader() throws {
        let png = try XCTUnwrap(solidImage(size: 12).pngData())
        let size = try XCTUnwrap(CanonicalBusinessEngine.imageDimensionsFromHeader(png))
        XCTAssertEqual(size.width, 12)
        XCTAssertEqual(size.height, 12)
        XCTAssertNil(StorageUploadPolicy.photoPrepareRefusal(data: png))
        // A PNG header that says 10 000 × 6 000 is refused without decoding it.
        var bomb = png
        bomb.replaceSubrange(16..<24, with: Data([0x00, 0x00, 0x27, 0x10, 0x00, 0x00, 0x17, 0x70]))
        XCTAssertNotNil(StorageUploadPolicy.photoPrepareRefusal(data: bomb))
        XCTAssertThrowsError(try StorageUploadPolicy.preparablePhoto(from: bomb))
    }

    // MARK: - safeExternalUrl

    func testSafeExternalUrlRefusesJavascriptAndPlainHttp() {
        XCTAssertNil(CanonicalBusinessEngine.safeExternalUrl("javascript:alert(1)"))
        XCTAssertNil(CanonicalBusinessEngine.safeExternalUrl("JaVaScRiPt:alert(1)"))
        XCTAssertNil(CanonicalBusinessEngine.safeExternalUrl("data:text/html;base64,PHNjcmlwdD4="))
        XCTAssertNil(CanonicalBusinessEngine.safeExternalUrl("file:///var/mobile/x.pdf"))
        XCTAssertNil(CanonicalBusinessEngine.safeExternalUrl("http://example.com/a.pdf"))
        XCTAssertNil(CanonicalBusinessEngine.safeExternalURL("http://example.com/a.pdf"))
        XCTAssertEqual(CanonicalBusinessEngine.safeExternalUrl("https://example.com/a.pdf"), "https://example.com/a.pdf")
        XCTAssertEqual(CanonicalBusinessEngine.safeExternalUrl("http://localhost:9199/v0/b/x"), "http://localhost:9199/v0/b/x")
        XCTAssertNil(CanonicalBusinessEngine.safeExternalUrl(nil))
    }

    /// Only a material supplier `websiteURL` passes `allowHttp`; even then `javascript:` is no link.
    func testWebsiteURLMayBePlainHttp() {
        XCTAssertEqual(CanonicalBusinessEngine.safeExternalUrl("http://supplier.example/item", allowHttp: true), "http://supplier.example/item")
        XCTAssertNil(CanonicalBusinessEngine.safeExternalUrl("javascript:alert(1)", allowHttp: true))
    }

    /// Stored file links (health & safety, deadlines, certificates) open only as `safeExternalUrl` allows.
    func testStoredFileTargetsFollowSafeExternalUrl() {
        XCTAssertNil(StoredFileTarget.target(for: "http://example.com/rams.pdf"))
        if case .url = StoredFileTarget.target(for: "javascript:alert(1)") {
            XCTFail("javascript: must never become a link")
        }
        let https = "https://example.com/rams.pdf"
        XCTAssertEqual(StoredFileTarget.target(for: https), .url(URL(string: https)!))
    }

    // MARK: - Helpers

    private func encodedHEIC(_ image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func solidImage(size: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }
}
