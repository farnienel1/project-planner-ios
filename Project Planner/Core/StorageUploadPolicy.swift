//
//  StorageUploadPolicy.swift
//  Project Planner
//
//  Preparing a file for Firebase Storage and the one check before every upload (RULEBOOK 1.50.0 §24, owner decisions
//  15 Nov). What may be uploaded — types per kind, size caps, the type read from the first bytes, the photo limits — is
//  the packed script's (`CanonicalBusinessEngine.uploadAllowed`, `UPLOAD_ALLOWED_TYPES`, `photoPrepareRefusal`,
//  `imageDimensionsFromHeader`); this file keeps no type list or cap of its own. It only redraws photos (EXIF / GPS
//  dropped, scaled to 2560 px and about 2.5 MB like web `lib/security/stripPhotoLocation.ts`) and names the object
//  (`storedFileObjectName`). Download URLs already stored on Firestore documents are not rewritten here.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

enum StorageUploadFamily {
    case profilePhoto
    case companyLogo
    case qualificationCertificate
    case siteAuditPhoto
    case taskImage
    case workFile
    case variationEvidence
    case timesheetPDF
}

struct PreparedStorageUpload {
    var data: Data
    var objectName: String
    var contentType: String
}

enum StorageUploadPolicy {
    static let profileObjectName = "profile.jpg"
    /// New health-and-safety uploads. `storage.rules` allows every object under `organizations/{orgId}/`.
    static let healthSafetyTalksFolder = "talks"
    static let healthSafetyOtherFolder = "other"

    /// Web `PHOTO_MAX_EDGE` / `PHOTO_TARGET_BYTES`: a redrawn photo is at most 2560 px on its long edge and about 2.5 MB.
    static let photoMaxPixelDimension: CGFloat = 2560
    static let photoTargetBytes = 2_621_440

    static let photoReadFailedMessage = "This photo could not be read. Use a JPEG, PNG, HEIC or WebP photo."

    // MARK: - Kinds and caps (the rulebook's)

    /// The rulebook's upload kind (`UPLOAD_KINDS`) for a family. Task files and health & safety files share one policy
    /// (photo or PDF, 10 MB); the exact kind of a Storage path is `uploadKindForStoragePath` at upload time.
    static func uploadKind(for family: StorageUploadFamily) -> String {
        switch family {
        case .profilePhoto: return "profile_photo"
        case .companyLogo: return "company_logo"
        case .qualificationCertificate: return "qualification_certificate"
        case .siteAuditPhoto: return "site_audit_photo"
        case .taskImage, .workFile: return "task_attachment"
        case .variationEvidence: return "variation_evidence"
        case .timesheetPDF: return "timesheet_export"
        }
    }

    /// `UPLOAD_ALLOWED_TYPES[kind].maxBytes` (`UPLOAD_DEFAULT_MAX_BYTES` 10 MB when the script did not answer).
    static func maxBytes(for family: StorageUploadFamily) -> Int {
        CanonicalBusinessEngine.uploadAllowedTypes[uploadKind(for: family)]?.maxBytes ?? 10 * 1024 * 1024
    }

    /// The photo and PDF kinds' cap (10 MB): claim evidence, personal audits, tasks, health & safety.
    static var standardMaxBytes: Int { maxBytes(for: .workFile) }
    /// Variation evidence (RULEBOOK 1.50.0: 10 MB, was 20 MB).
    static var variationMaxBytes: Int { maxBytes(for: .variationEvidence) }

    /// File picker types for a photo-or-PDF upload (tasks, health & safety, deadlines, variations): the photo types and
    /// PDF only — no SVG, GIF, Office, CSV or ZIP (RULEBOOK 1.50.0).
    static var workFileContentTypes: [UTType] {
        [.jpeg, .png, .heic, .heif, .webP, .pdf]
    }

    // MARK: - Object names

    static func unixMillisecondsNow(from date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// RULEBOOK 1.25.0 §24 `CanonicalBusinessEngine.storedFileObjectName`: `{uid}_{unixMilliseconds}.{ext}`, a new object
    /// for every upload. The original basename is never copied in. Nil without an allowed extension or a usable uid.
    static func generatedObjectName(uid: String, unixMilliseconds: Int64, fileExtension: String) -> String? {
        guard let ext = normalizedExtension(fileExtension) else { return nil }
        return CanonicalBusinessEngine.storedFileObjectName(
            uid: uid.trimmingCharacters(in: .whitespacesAndNewlines),
            unixMs: unixMilliseconds,
            fileExtension: ext
        )
    }

    static func generatedObjectName(uid: String, unixMilliseconds: Int64, originalFileName: String) -> String? {
        generatedObjectName(
            uid: uid,
            unixMilliseconds: unixMilliseconds,
            fileExtension: (originalFileName as NSString).pathExtension
        )
    }

    // MARK: - The one check before every upload

    /// RULEBOOK 1.50.0 §24: the check every `putData` passes. `uploadAllowed` for the path's kind
    /// (`uploadKindForStoragePath`), with the object name, the claimed type and the first bytes of the data exactly as
    /// it is uploaded. Returns the content type to write as `StorageMetadata.contentType` (the type read from the bytes,
    /// never `application/octet-stream`); throws the rulebook's message otherwise.
    static func checkedUploadContentType(storagePath: String, data: Data, declaredContentType: String?) throws -> String {
        guard let kind = CanonicalBusinessEngine.uploadKindForStoragePath(storagePath) else {
            throw failure(CanonicalBusinessEngine.uploadRefusalMessage(kind: "task_attachment", reason: "unknown_kind"), oversize: false)
        }
        let decision = CanonicalBusinessEngine.uploadAllowed(
            kind: kind,
            fileName: (storagePath as NSString).lastPathComponent,
            contentType: declaredContentType,
            sizeBytes: data.count,
            headBytes: data
        )
        guard decision.allowed, let type = decision.contentType, !type.isEmpty else {
            throw failure(decision.message ?? CanonicalBusinessEngine.uploadNoAnswerMessage, oversize: decision.reason == "too_large")
        }
        return type
    }

    // MARK: - Pick-time checks

    /// Pick-time check (no bytes yet): the rulebook's refusal for the claimed type and extension, and the size. A photo
    /// is redrawn and scaled before upload, so it is judged on `photoPrepareRefusal` (40 MB) here, not the kind's cap;
    /// the cap is checked again on the redrawn bytes by `checkedUploadContentType`.
    static func refusal(
        family: StorageUploadFamily,
        fileExtension: String,
        contentType: String?,
        byteCount: Int
    ) -> String? {
        let ext = fileExtension.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let photo = isPhotoExtension(ext) || (ext.isEmpty && contentType?.lowercased().hasPrefix("image/") == true)
        let decision = CanonicalBusinessEngine.uploadAllowed(
            kind: uploadKind(for: family),
            fileName: ext.isEmpty ? nil : "file.\(ext)",
            contentType: contentType,
            sizeBytes: photo ? (byteCount > 0 ? 1 : 0) : byteCount,
            headBytes: nil
        )
        if !decision.allowed {
            return decision.message ?? CanonicalBusinessEngine.uploadNoAnswerMessage
        }
        if photo {
            return CanonicalBusinessEngine.photoPrepareRefusal(sizeBytes: byteCount, width: nil, height: nil)
        }
        return nil
    }

    static func timesheetRefusal(data: Data, fileName: String) -> String? {
        let decision = CanonicalBusinessEngine.uploadAllowed(
            kind: uploadKind(for: .timesheetPDF),
            fileName: fileName,
            contentType: "application/pdf",
            sizeBytes: data.count,
            headBytes: data
        )
        return decision.allowed ? nil : (decision.message ?? CanonicalBusinessEngine.uploadNoAnswerMessage)
    }

    /// RULEBOOK 1.50.0 §24 (review L4): a photo over 40 MB, or over 50 megapixels by its header
    /// (`imageDimensionsFromHeader`, else ImageIO's properties — neither decodes it), is refused before it is decoded.
    /// Nil when it may be prepared.
    static func photoPrepareRefusal(data: Data) -> String? {
        if let early = CanonicalBusinessEngine.photoPrepareRefusal(sizeBytes: data.count, width: nil, height: nil) {
            return early
        }
        let size = CanonicalBusinessEngine.imageDimensionsFromHeader(data) ?? imagePropertySize(data)
        return CanonicalBusinessEngine.photoPrepareRefusal(sizeBytes: data.count, width: size?.width, height: size?.height)
    }

    /// `photoPrepareRefusal` for a photo the picker has already decoded (its pixel size).
    static func photoPrepareRefusal(image: UIImage) -> String? {
        let width = Int((image.size.width * image.scale).rounded())
        let height = Int((image.size.height * image.scale).rounded())
        return CanonicalBusinessEngine.photoPrepareRefusal(sizeBytes: 0, width: width, height: height)
    }

    /// A picked photo's bytes → an image ready to redraw: refused first (`photoPrepareRefusal(data:)`), then decoded
    /// downsampled to at most 2560 px (EXIF orientation applied). Throws the rulebook's message.
    static func preparablePhoto(from data: Data) throws -> UIImage {
        if let message = photoPrepareRefusal(data: data) {
            throw failure(message, oversize: true)
        }
        guard let image = downsampledImage(from: data, maxPixelDimension: photoMaxPixelDimension) else {
            throw failure(photoReadFailedMessage, oversize: false)
        }
        return image
    }

    /// RULEBOOK 1.50.0 §24 (review of #235): a photo from `UIImagePickerController` is checked before the app uses it.
    /// A library pick is read from its file (`imageURL`, memory-mapped, never decoded here) for the 40 MB / 50 MP
    /// refusal; a camera capture has no file, so its pixel size is checked. Nil when the photo may be used.
    static func pickerPhotoRefusal(_ info: [UIImagePickerController.InfoKey: Any]) -> String? {
        if let url = info[.imageURL] as? URL, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            return photoPrepareRefusal(data: data)
        }
        if let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) {
            return photoPrepareRefusal(image: image)
        }
        return nil
    }

    /// A `PHPickerViewController` result as an image ready to redraw, refused before it is decoded: the bytes are
    /// loaded (`loadDataRepresentation`), checked (`photoPrepareRefusal(data:)`) and decoded downsampled
    /// (`preparablePhoto(from:)`). The completion runs on the main queue.
    static func loadPreparablePhoto(_ provider: NSItemProvider, completion: @escaping (Result<UIImage, Error>) -> Void) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
            let loadError = error
            DispatchQueue.main.async {
                guard let data else {
                    completion(.failure(loadError ?? failure(photoReadFailedMessage, oversize: false)))
                    return
                }
                do {
                    completion(.success(try preparablePhoto(from: data)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Preparing the bytes

    static func prepareImage(
        _ image: UIImage,
        family: StorageUploadFamily,
        uid: String,
        unixMilliseconds: Int64,
        initialQuality: CGFloat,
        encodeFailedMessage: String,
        oversizedMessage: String
    ) throws -> PreparedStorageUpload {
        if let message = photoPrepareRefusal(image: image) {
            throw failure(message, oversize: true)
        }
        // RULEBOOK 1.50.0: a company logo is never turned into a JPEG (it keeps its transparency as PNG).
        let isLogo = family == .companyLogo
        let data: Data
        if isLogo {
            data = try pngDataFittingUploadLimit(image, maxBytes: maxBytes(for: family), oversizedMessage: oversizedMessage)
        } else {
            data = try jpegDataFittingUploadLimit(
                image,
                maxBytes: maxBytes(for: family),
                initialQuality: initialQuality,
                encodeFailedMessage: encodeFailedMessage,
                oversizedMessage: oversizedMessage
            )
        }
        let objectName: String
        if family == .profilePhoto {
            objectName = profileObjectName
        } else {
            guard let name = generatedObjectName(uid: uid, unixMilliseconds: unixMilliseconds, fileExtension: isLogo ? "png" : "jpg") else {
                throw failure("Could not name that upload.", oversize: false)
            }
            objectName = name
        }
        return PreparedStorageUpload(data: data, objectName: objectName, contentType: isLogo ? "image/png" : "image/jpeg")
    }

    /// A picked file → the bytes to upload. The file as picked must be a type its kind allows (`uploadAllowed` on its
    /// name, claimed type and first bytes — an SVG renamed `.jpg` is refused here). A PDF is kept as is; a photo is
    /// redrawn (EXIF / GPS dropped) and scaled. The cap is checked on the bytes that will be uploaded.
    static func prepareFileData(
        _ data: Data,
        originalFileName: String,
        declaredContentType: String?,
        family: StorageUploadFamily,
        uid: String,
        unixMilliseconds: Int64
    ) throws -> PreparedStorageUpload {
        let kind = uploadKind(for: family)
        // Size 1 here: a photo is judged on its size after the redraw (the cap is checked below and at upload).
        let picked = CanonicalBusinessEngine.uploadAllowed(
            kind: kind,
            fileName: originalFileName,
            contentType: declaredContentType,
            sizeBytes: data.isEmpty ? 0 : 1,
            headBytes: data
        )
        guard picked.allowed, let pickedType = picked.contentType else {
            throw failure(picked.message ?? CanonicalBusinessEngine.uploadNoAnswerMessage, oversize: false)
        }
        let output: OutputBytes
        if pickedType == "application/pdf" {
            output = OutputBytes(data: data, fileExtension: "pdf", contentType: pickedType)
        } else if pickedType.hasPrefix("image/") {
            output = try redrawnPhoto(data, sourceType: pickedType, family: family)
        } else {
            throw failure(CanonicalBusinessEngine.uploadRefusalMessage(kind: kind, reason: "type_not_allowed"), oversize: false)
        }
        if output.data.count > maxBytes(for: family) {
            throw failure(CanonicalBusinessEngine.uploadRefusalMessage(kind: kind, reason: "too_large"), oversize: true)
        }
        guard let objectName = generatedObjectName(
            uid: uid,
            unixMilliseconds: unixMilliseconds,
            fileExtension: output.fileExtension
        ) else {
            throw failure("Could not name that upload.", oversize: false)
        }
        return PreparedStorageUpload(data: output.data, objectName: objectName, contentType: output.contentType)
    }

    /// Draws into a new bitmap and encodes JPEG without copying the source property dictionaries.
    static func jpegDataByRedrawing(_ image: UIImage, compressionQuality: CGFloat = 0.9) -> Data? {
        bitmapCopy(image, opaque: true, maxPixelDimension: photoMaxPixelDimension).jpegData(compressionQuality: compressionQuality)
    }

    /// JPEG drawn on white (no EXIF / GPS), at most 2560 px, aiming at about 2.5 MB (`photoTargetBytes`) and never over
    /// `maxBytes`.
    static func jpegDataFittingUploadLimit(
        _ image: UIImage,
        maxBytes: Int,
        initialQuality: CGFloat,
        encodeFailedMessage: String,
        oversizedMessage: String
    ) throws -> Data {
        let target = min(maxBytes, photoTargetBytes)
        let stripped = bitmapCopy(image, opaque: true, maxPixelDimension: photoMaxPixelDimension)
        var smallestSoFar: Data?
        func consider(_ data: Data?) -> Data? {
            guard let data else { return nil }
            if let current = smallestSoFar, current.count <= data.count {
                // keep the smaller one
            } else {
                smallestSoFar = data
            }
            return data.count <= target ? data : nil
        }

        if let fit = consider(stripped.jpegData(compressionQuality: initialQuality)) { return fit }
        let lowerQualities: [CGFloat] = [0.6, 0.45, 0.3, 0.2, 0.12]
        for quality in lowerQualities where quality < initialQuality {
            if let fit = consider(stripped.jpegData(compressionQuality: quality)) { return fit }
        }

        let pixelLongest = max(stripped.size.width * stripped.scale, stripped.size.height * stripped.scale)
        if pixelLongest > 1 {
            var dimension = pixelLongest * 0.75
            for _ in 0..<6 {
                if dimension < 480 { break }
                let scaled = imageScaledToMaxPixelDimension(stripped, maxPixelDimension: dimension)
                for quality in [initialQuality] + lowerQualities {
                    if let fit = consider(scaled.jpegData(compressionQuality: quality)) { return fit }
                }
                dimension *= 0.7
            }
        }

        guard let best = smallestSoFar else {
            throw failure(encodeFailedMessage, oversize: false)
        }
        if best.count <= maxBytes {
            return best
        }
        throw failure(oversizedMessage, oversize: true)
    }

    static func failure(_ message: String, oversize: Bool) -> NSError {
        NSError(
            domain: "FirebaseBackend",
            code: oversize ? 413 : 400,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    // MARK: - Private

    private struct OutputBytes {
        var data: Data
        var fileExtension: String
        var contentType: String
    }

    /// Web `stripPhotoLocation`: PNG stays PNG (falls back to JPEG above about 2.5 MB); a logo is never made a JPEG
    /// unless it was one; everything else becomes JPEG. Certificates follow the same rule since the 1.50.0 Storage rules
    /// are live (web #333).
    private static func redrawnPhoto(_ data: Data, sourceType: String, family: StorageUploadFamily) throws -> OutputBytes {
        let image = try preparablePhoto(from: data)
        let cap = maxBytes(for: family)
        let kind = uploadKind(for: family)
        let tooLarge = CanonicalBusinessEngine.uploadRefusalMessage(kind: kind, reason: "too_large")
        let wantsPNG: Bool
        switch family {
        case .companyLogo:
            wantsPNG = sourceType != "image/jpeg"
        case .timesheetPDF:
            wantsPNG = false
        case .profilePhoto, .qualificationCertificate, .siteAuditPhoto, .taskImage, .workFile, .variationEvidence:
            wantsPNG = sourceType == "image/png"
        }
        if wantsPNG {
            if family == .companyLogo {
                let png = try pngDataFittingUploadLimit(image, maxBytes: cap, oversizedMessage: tooLarge)
                return OutputBytes(data: png, fileExtension: "png", contentType: "image/png")
            }
            if let png = try? pngDataFittingUploadLimit(image, maxBytes: min(cap, photoTargetBytes), oversizedMessage: tooLarge) {
                return OutputBytes(data: png, fileExtension: "png", contentType: "image/png")
            }
        }
        let jpeg = try jpegDataFittingUploadLimit(
            image,
            maxBytes: cap,
            initialQuality: 0.85,
            encodeFailedMessage: photoReadFailedMessage,
            oversizedMessage: tooLarge
        )
        return OutputBytes(data: jpeg, fileExtension: "jpg", contentType: "image/jpeg")
    }

    private static func pngDataFittingUploadLimit(
        _ image: UIImage,
        maxBytes: Int,
        oversizedMessage: String
    ) throws -> Data {
        let stripped = bitmapCopy(image, opaque: false, maxPixelDimension: photoMaxPixelDimension)
        if let data = stripped.pngData(), data.count <= maxBytes {
            return data
        }
        let pixelLongest = max(stripped.size.width * stripped.scale, stripped.size.height * stripped.scale)
        var dimension = pixelLongest * 0.75
        for _ in 0..<6 {
            if dimension < 480 { break }
            let scaled = imageScaledToMaxPixelDimension(stripped, maxPixelDimension: dimension, opaque: false)
            if let data = scaled.pngData(), data.count <= maxBytes {
                return data
            }
            dimension *= 0.7
        }
        throw failure(oversizedMessage, oversize: true)
    }

    /// A new bitmap (no source metadata), at most `maxPixelDimension` on its long edge; an opaque copy (for JPEG) is
    /// filled white first so transparency never turns black.
    private static func bitmapCopy(_ image: UIImage, opaque: Bool, maxPixelDimension: CGFloat) -> UIImage {
        let pixelWidth = max(1, image.size.width * image.scale)
        let pixelHeight = max(1, image.size.height * image.scale)
        let longest = max(pixelWidth, pixelHeight)
        let ratio = longest > maxPixelDimension ? maxPixelDimension / longest : 1
        let size = CGSize(width: max(1, floor(pixelWidth * ratio)), height: max(1, floor(pixelHeight * ratio)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            if opaque {
                UIColor.white.setFill()
                UIRectFill(CGRect(origin: .zero, size: size))
            }
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func imageScaledToMaxPixelDimension(
        _ image: UIImage,
        maxPixelDimension: CGFloat,
        opaque: Bool = true
    ) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxPixelDimension, longest > 0, maxPixelDimension > 0 else { return image }
        return bitmapCopy(image, opaque: opaque, maxPixelDimension: maxPixelDimension)
    }

    /// Decodes at most `maxPixelDimension` pixels on the long edge (ImageIO thumbnail, EXIF orientation applied), so a
    /// large photo is never decoded at full size.
    private static func downsampledImage(from data: Data, maxPixelDimension: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Width and height from ImageIO's properties (reads the header, does not decode).
    private static func imagePropertySize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return (width, height)
    }

    /// A photo extension the rulebook lists (`UPLOAD_ALLOWED_TYPES.profile_photo.extensions`).
    private static func isPhotoExtension(_ ext: String) -> Bool {
        guard !ext.isEmpty else { return false }
        return CanonicalBusinessEngine.uploadAllowedTypes["profile_photo"]?.extensions.contains(ext) ?? false
    }

    private static func normalizedExtension(_ raw: String) -> String? {
        let ext = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return ext
    }
}
