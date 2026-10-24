//
//  StorageUploadPolicy.swift
//  Project Planner
//
//  Type, size, and object-name checks for Firebase Storage uploads.
//  Download URLs already stored on Firestore documents are not rewritten here.
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

    static let profileMaxBytes = 2 * 1024 * 1024
    static let logoMaxBytes = 5 * 1024 * 1024
    static let standardMaxBytes = 10 * 1024 * 1024
    static let variationMaxBytes = 20 * 1024 * 1024

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "gif", "heic", "heif", "webp",
        "bmp", "tif", "tiff", "svg", "ico", "avif"
    ]
    private static let jpegExtensions: Set<String> = ["jpg", "jpeg", "jpe", "jfif"]
    private static let passthroughImageExtensions: Set<String> = ["gif", "svg"]
    private static let workExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "gif", "heic", "heif", "webp",
        "bmp", "tif", "tiff", "svg", "ico", "avif",
        "pdf", "xls", "xlsx", "xlsm", "doc", "docx", "csv", "zip"
    ]
    private static let jpegContentTypes: Set<String> = ["image/jpeg", "image/jpg", "image/pjpeg"]
    private static let disallowedCertificateExtensions: Set<String> = ["png", "heic", "heif"]
    private static let disallowedCertificateTypes: Set<String> = ["image/png", "image/heic", "image/heif"]

    static var workFileContentTypes: [UTType] {
        var types: [UTType] = [.image, .pdf, .zip, .commaSeparatedText]
        let identifiers = [
            "com.microsoft.excel.xls",
            "org.openxmlformats.spreadsheetml.sheet",
            "org.openxmlformats.spreadsheetml.sheet.macroenabled.12",
            "com.microsoft.excel.sheet.macroEnabled.12",
            "com.microsoft.word.doc",
            "org.openxmlformats.wordprocessingml.document",
            "public.comma-separated-values-text"
        ]
        for identifier in identifiers {
            if let type = UTType(identifier) {
                types.append(type)
            }
        }
        for ext in ["xls", "xlsx", "xlsm", "doc", "docx", "csv", "zip"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }

    static func unixMillisecondsNow(from date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// `{uid}_{unixMilliseconds}.{ext}`. The original basename is not copied into the object name.
    static func generatedObjectName(uid: String, unixMilliseconds: Int64, fileExtension: String) -> String? {
        let safeUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = normalizedExtension(fileExtension)
        guard !safeUID.isEmpty,
              safeUID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              unixMilliseconds >= 0,
              let ext else {
            return nil
        }
        return "\(safeUID)_\(unixMilliseconds).\(ext)"
    }

    static func generatedObjectName(uid: String, unixMilliseconds: Int64, originalFileName: String) -> String? {
        generatedObjectName(
            uid: uid,
            unixMilliseconds: unixMilliseconds,
            fileExtension: (originalFileName as NSString).pathExtension
        )
    }

    /// Declared type and size. Image uploads that still need compression use `prepareImage` instead of this gate on the raw bitmap.
    static func refusal(
        family: StorageUploadFamily,
        fileExtension: String,
        contentType: String?,
        byteCount: Int
    ) -> String? {
        if byteCount <= 0 {
            return "File is empty"
        }
        let ext = fileExtension.lowercased()
        let type = normalizedContentType(contentType)
        if let message = typeRefusal(family: family, ext: ext, contentType: type) {
            return message
        }
        if byteCount > maxBytes(for: family) {
            return sizeMessage(for: family)
        }
        return nil
    }

    static func timesheetRefusal(data: Data, fileName: String) -> String? {
        if let message = refusal(
            family: .timesheetPDF,
            fileExtension: (fileName as NSString).pathExtension,
            contentType: "application/pdf",
            byteCount: data.count
        ) {
            return message
        }
        if !isPDF(data) {
            return "Timesheet export must be a PDF."
        }
        return nil
    }

    static func prepareImage(
        _ image: UIImage,
        family: StorageUploadFamily,
        uid: String,
        unixMilliseconds: Int64,
        initialQuality: CGFloat,
        encodeFailedMessage: String,
        oversizedMessage: String
    ) throws -> PreparedStorageUpload {
        let data = try jpegDataFittingUploadLimit(
            image,
            maxBytes: maxBytes(for: family),
            initialQuality: initialQuality,
            encodeFailedMessage: encodeFailedMessage,
            oversizedMessage: oversizedMessage
        )
        let objectName: String
        if family == .profilePhoto {
            objectName = profileObjectName
        } else {
            guard let name = generatedObjectName(uid: uid, unixMilliseconds: unixMilliseconds, fileExtension: "jpg") else {
                throw failure("Could not name that upload.", oversize: false)
            }
            objectName = name
        }
        return PreparedStorageUpload(data: data, objectName: objectName, contentType: "image/jpeg")
    }

    static func prepareFileData(
        _ data: Data,
        originalFileName: String,
        declaredContentType: String?,
        family: StorageUploadFamily,
        uid: String,
        unixMilliseconds: Int64
    ) throws -> PreparedStorageUpload {
        let ext = (originalFileName as NSString).pathExtension.lowercased()
        if let message = refusal(
            family: family,
            fileExtension: ext,
            contentType: declaredContentType,
            byteCount: data.count
        ) {
            throw failure(message, oversize: data.count > maxBytes(for: family))
        }
        let output = try outputBytes(
            data,
            ext: ext,
            declaredContentType: declaredContentType,
            family: family
        )
        if output.data.count > maxBytes(for: family) {
            throw failure(sizeMessage(for: family), oversize: true)
        }
        guard let objectName = generatedObjectName(
            uid: uid,
            unixMilliseconds: unixMilliseconds,
            fileExtension: output.fileExtension
        ) else {
            throw failure(typeMessage(for: family), oversize: false)
        }
        return PreparedStorageUpload(data: output.data, objectName: objectName, contentType: output.contentType)
    }

    /// Draws into a new bitmap and encodes JPEG without copying the source property dictionaries.
    static func jpegDataByRedrawing(_ image: UIImage, compressionQuality: CGFloat = 0.9) -> Data? {
        bitmapCopy(image, opaque: true).jpegData(compressionQuality: compressionQuality)
    }

    static func jpegDataFittingUploadLimit(
        _ image: UIImage,
        maxBytes: Int,
        initialQuality: CGFloat,
        encodeFailedMessage: String,
        oversizedMessage: String
    ) throws -> Data {
        let stripped = bitmapCopy(image, opaque: true)
        var producedData = false
        if let initial = stripped.jpegData(compressionQuality: initialQuality) {
            producedData = true
            if initial.count <= maxBytes {
                return initial
            }
        }

        let lowerQualities: [CGFloat] = [0.6, 0.45, 0.3, 0.2, 0.12]
        for quality in lowerQualities where quality < initialQuality {
            if let data = stripped.jpegData(compressionQuality: quality) {
                producedData = true
                if data.count <= maxBytes {
                    return data
                }
            }
        }

        let pixelLongest = max(stripped.size.width * stripped.scale, stripped.size.height * stripped.scale)
        if pixelLongest > 1 {
            var dimension = pixelLongest * 0.75
            for _ in 0..<6 {
                if dimension < 480 { break }
                let scaled = imageScaledToMaxPixelDimension(stripped, maxPixelDimension: dimension)
                for quality in [initialQuality] + lowerQualities {
                    if let data = scaled.jpegData(compressionQuality: quality) {
                        producedData = true
                        if data.count <= maxBytes {
                            return data
                        }
                    }
                }
                dimension *= 0.7
            }
        }

        if !producedData {
            throw failure(encodeFailedMessage, oversize: false)
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

    private static func outputBytes(
        _ data: Data,
        ext: String,
        declaredContentType: String?,
        family: StorageUploadFamily
    ) throws -> OutputBytes {
        let type = normalizedContentType(declaredContentType)
        let keepsAnimatedOrVector = family == .workFile || family == .variationEvidence
        if keepsAnimatedOrVector && (isGIF(data) || ext == "gif" || type == "image/gif" || ext == "svg" || type == "image/svg+xml") {
            let kept = ext == "svg" || type == "image/svg+xml" ? "svg" : "gif"
            return OutputBytes(data: data, fileExtension: kept, contentType: contentType(forExtension: kept))
        }
        if isPDF(data) || ext == "pdf" || type == "application/pdf" {
            guard isPDF(data) else {
                throw failure(typeMessage(for: family), oversize: false)
            }
            return OutputBytes(data: data, fileExtension: "pdf", contentType: "application/pdf")
        }
        if shouldRedraw(ext: ext, contentType: type, data: data, family: family) {
            return try redrawnImage(data, ext: ext, contentType: type, family: family)
        }
        let kept = normalizedExtension(ext) ?? ext
        return OutputBytes(data: data, fileExtension: kept, contentType: contentType(forExtension: kept))
    }

    private static func shouldRedraw(ext: String, contentType: String?, data: Data, family: StorageUploadFamily) -> Bool {
        if passthroughImageExtensions.contains(ext) { return false }
        if family == .qualificationCertificate && (isJPEG(data) || jpegExtensions.contains(ext)) {
            return true
        }
        if isJPEG(data) || isPNG(data) || isHEIC(ext: ext, contentType: contentType) {
            return true
        }
        if imageExtensions.contains(ext), !passthroughImageExtensions.contains(ext), ext != "pdf" {
            return contentType?.hasPrefix("image/") == true || contentType == nil || contentType == "application/octet-stream"
        }
        return false
    }

    private static func redrawnImage(
        _ data: Data,
        ext: String,
        contentType: String?,
        family: StorageUploadFamily
    ) throws -> OutputBytes {
        let keepJPEGBytes = isJPEG(data)
            && family != .qualificationCertificate
            && !imageHasGPSOrExif(data)
            && data.count <= maxBytes(for: family)
        if keepJPEGBytes {
            return OutputBytes(data: data, fileExtension: "jpg", contentType: "image/jpeg")
        }
        guard let image = UIImage(data: data) else {
            throw failure(
                isHEIC(ext: ext, contentType: contentType)
                    ? "Could not read that HEIC image."
                    : "Failed to process image",
                oversize: false
            )
        }
        if isPNG(data) || ext == "png" {
            guard familyAllowsPNG(family) else {
                throw failure(typeMessage(for: family), oversize: false)
            }
            let png = try pngDataFittingUploadLimit(
                image,
                maxBytes: maxBytes(for: family),
                oversizedMessage: sizeMessage(for: family)
            )
            return OutputBytes(data: png, fileExtension: "png", contentType: "image/png")
        }
        let jpeg = try jpegDataFittingUploadLimit(
            image,
            maxBytes: maxBytes(for: family),
            initialQuality: 0.82,
            encodeFailedMessage: "Failed to process image",
            oversizedMessage: sizeMessage(for: family)
        )
        return OutputBytes(data: jpeg, fileExtension: "jpg", contentType: "image/jpeg")
    }

    private static func familyAllowsPNG(_ family: StorageUploadFamily) -> Bool {
        switch family {
        case .qualificationCertificate, .timesheetPDF:
            return false
        case .profilePhoto, .companyLogo, .siteAuditPhoto, .taskImage, .workFile, .variationEvidence:
            return true
        }
    }

    private static func pngDataFittingUploadLimit(
        _ image: UIImage,
        maxBytes: Int,
        oversizedMessage: String
    ) throws -> Data {
        let stripped = bitmapCopy(image, opaque: false)
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

    private static func bitmapCopy(_ image: UIImage, opaque: Bool) -> UIImage {
        let pixelWidth = max(1, image.size.width * image.scale)
        let pixelHeight = max(1, image.size.height * image.scale)
        let size = CGSize(width: pixelWidth, height: pixelHeight)
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
        let ratio = maxPixelDimension / longest
        let newSize = CGSize(width: max(1, floor(pixelWidth * ratio)), height: max(1, floor(pixelHeight * ratio)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            if opaque {
                UIColor.white.setFill()
                UIRectFill(CGRect(origin: .zero, size: newSize))
            }
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func imageHasGPSOrExif(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return true
        }
        return props[kCGImagePropertyGPSDictionary] != nil || props[kCGImagePropertyExifDictionary] != nil
    }

    private static func maxBytes(for family: StorageUploadFamily) -> Int {
        switch family {
        case .profilePhoto: return profileMaxBytes
        case .companyLogo: return logoMaxBytes
        case .variationEvidence: return variationMaxBytes
        case .qualificationCertificate, .siteAuditPhoto, .taskImage, .workFile, .timesheetPDF:
            return standardMaxBytes
        }
    }

    private static func sizeMessage(for family: StorageUploadFamily) -> String {
        switch family {
        case .profilePhoto:
            return "Profile photo is too large. It must be 2 MB or smaller."
        case .companyLogo:
            return "Company logo is too large. It must be 5 MB or smaller."
        case .qualificationCertificate, .workFile:
            return "File is too large. Please upload a file smaller than 10MB."
        case .siteAuditPhoto:
            return "Site audit photo is too large. It must be 10 MB or smaller."
        case .taskImage:
            return "Image is too large. It must be 10 MB or smaller."
        case .variationEvidence:
            return "That file is too large. Evidence must be 20 MB or smaller."
        case .timesheetPDF:
            return "Timesheet export is too large. Please use a PDF smaller than 10MB."
        }
    }

    private static func typeMessage(for family: StorageUploadFamily) -> String {
        switch family {
        case .profilePhoto:
            return "Profile photos must be an image."
        case .companyLogo:
            return "Company logos must be an image or a PDF."
        case .qualificationCertificate:
            return "Only PDF or JPEG certificates are allowed."
        case .siteAuditPhoto:
            return "Site audit photos must be images."
        case .taskImage:
            return "Task photos must be images."
        case .workFile, .variationEvidence:
            return "That file type is not allowed. Use an image, PDF, Excel, Word, CSV, or ZIP."
        case .timesheetPDF:
            return "Timesheet export must be a PDF."
        }
    }

    private static func typeRefusal(family: StorageUploadFamily, ext: String, contentType: String?) -> String? {
        switch family {
        case .profilePhoto, .siteAuditPhoto, .taskImage:
            return isAllowedImage(ext: ext, contentType: contentType) ? nil : typeMessage(for: family)
        case .companyLogo:
            if isPDFType(ext: ext, contentType: contentType) || isAllowedImage(ext: ext, contentType: contentType) {
                return nil
            }
            return typeMessage(for: family)
        case .qualificationCertificate:
            if disallowedCertificateExtensions.contains(ext) || disallowedCertificateTypes.contains(contentType ?? "") {
                return typeMessage(for: family)
            }
            if isPDFType(ext: ext, contentType: contentType) || isJPEGType(ext: ext, contentType: contentType) {
                return nil
            }
            return typeMessage(for: family)
        case .workFile, .variationEvidence:
            if ext == "txt" || contentType == "text/plain" && ext != "csv" {
                return typeMessage(for: family)
            }
            return isWorkFile(ext: ext, contentType: contentType) ? nil : typeMessage(for: family)
        case .timesheetPDF:
            return isPDFType(ext: ext, contentType: contentType) ? nil : typeMessage(for: family)
        }
    }

    private static func isAllowedImage(ext: String, contentType: String?) -> Bool {
        guard imageExtensions.contains(ext) else { return false }
        if contentType == nil || contentType == "application/octet-stream" || contentType?.hasPrefix("image/") == true {
            return true
        }
        return false
    }

    private static func isJPEGType(ext: String, contentType: String?) -> Bool {
        if disallowedCertificateExtensions.contains(ext) || disallowedCertificateTypes.contains(contentType ?? "") {
            return false
        }
        guard jpegExtensions.contains(ext) else { return false }
        if contentType == nil || contentType == "application/octet-stream" || jpegContentTypes.contains(contentType ?? "") {
            return true
        }
        return contentType?.hasPrefix("image/") != true
    }

    private static func isPDFType(ext: String, contentType: String?) -> Bool {
        if ext == "pdf" {
            return contentType == nil || contentType == "application/pdf" || contentType == "application/octet-stream"
        }
        return false
    }

    private static func isWorkFile(ext: String, contentType: String?) -> Bool {
        guard workExtensions.contains(ext), ext != "txt" else { return false }
        if contentType == nil || contentType == "application/octet-stream" {
            return true
        }
        if contentType == "text/plain" {
            return ext == "csv"
        }
        if contentType?.hasPrefix("image/") == true {
            return imageExtensions.contains(ext)
        }
        return true
    }

    private static func isHEIC(ext: String, contentType: String?) -> Bool {
        ext == "heic" || ext == "heif" || contentType == "image/heic" || contentType == "image/heif"
    }

    private static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "heic":
            return "image/heic"
        case "heif":
            return "image/heif"
        case "webp":
            return "image/webp"
        case "bmp":
            return "image/bmp"
        case "tif", "tiff":
            return "image/tiff"
        case "svg":
            return "image/svg+xml"
        case "pdf":
            return "application/pdf"
        case "doc":
            return "application/msword"
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls":
            return "application/vnd.ms-excel"
        case "xlsx":
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "xlsm":
            return "application/vnd.ms-excel.sheet.macroEnabled.12"
        case "csv":
            return "text/csv"
        case "zip":
            return "application/zip"
        default:
            return "application/octet-stream"
        }
    }

    private static func normalizedExtension(_ raw: String) -> String? {
        let ext = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return ext
    }

    private static func normalizedContentType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let type = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return type.isEmpty ? nil : type
    }

    private static func isPDF(_ data: Data) -> Bool {
        data.count >= 4 && data[0] == 0x25 && data[1] == 0x50 && data[2] == 0x44 && data[3] == 0x46
    }

    private static func isJPEG(_ data: Data) -> Bool {
        data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.count >= 4 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47
    }

    private static func isGIF(_ data: Data) -> Bool {
        guard data.count >= 6 else { return false }
        let header = String(data: data.prefix(6), encoding: .ascii)
        return header == "GIF87a" || header == "GIF89a"
    }
}
