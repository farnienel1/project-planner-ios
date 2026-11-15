//
//  Rulebook+UploadPolicy.swift
//  Project Planner
//
//  RULEBOOK 1.50.0 §24 (owner decisions 15 Nov; web `lib/canonical/uploadPolicy.ts`): what may be uploaded per kind
//  (photos — JPEG, PNG, HEIC/HEIF, WebP — and PDFs; never SVG, GIF, Word, Excel, ZIP or `application/octet-stream`),
//  the size cap per kind, the type read from a file's first bytes, the photo limits checked before a photo is decoded,
//  and which stored or typed URLs may be opened (`safeExternalUrl`). Every answer comes from the packed script through
//  `CanonicalBusinessEngine.callJSON` / `constant`; no list, cap or scheme test is kept in Swift.
//

import Foundation

/// `uploadAllowed(...)` → `{ allowed, reason, message, contentType, contentChecked }`.
nonisolated struct RulebookUploadDecision: Hashable, Sendable {
    let allowed: Bool
    /// `unknown_kind`, `empty`, `too_large`, `type_not_allowed`, `content_unknown`, `content_mismatch`; `no_answer` when
    /// the script did not run (refused).
    let reason: String?
    /// The rulebook's refusal message (nil when allowed).
    let message: String?
    /// The type to write as `StorageMetadata.contentType` (the type read from the bytes). Never octet-stream.
    let contentType: String?
}

/// One row of `UPLOAD_ALLOWED_TYPES`.
nonisolated struct RulebookUploadKindPolicy: Decodable, Hashable, Sendable {
    let contentTypes: [String]
    let extensions: [String]
    let maxBytes: Int
    let accepts: String
}

extension CanonicalBusinessEngine {
    /// Shown when the packed script did not answer: the upload is refused, never let through unchecked.
    nonisolated static let uploadNoAnswerMessage = "This file could not be checked. Try again."

    /// RULEBOOK 1.50.0 §24 `UPLOAD_ALLOWED_TYPES` (per kind: content types, extensions, `maxBytes`, `accepts`).
    nonisolated static var uploadAllowedTypes: [String: RulebookUploadKindPolicy] {
        constant("UPLOAD_ALLOWED_TYPES", as: [String: RulebookUploadKindPolicy].self) ?? [:]
    }

    /// `UPLOAD_HEAD_BYTES` (1024): how many leading bytes `uploadAllowed` reads.
    nonisolated static var uploadHeadBytes: Int {
        constant("UPLOAD_HEAD_BYTES", as: Int.self) ?? 1024
    }

    /// `UPLOAD_DIMENSION_HEAD_BYTES` (512 KB): how many leading bytes `imageDimensionsFromHeader` reads.
    nonisolated static var uploadDimensionHeadBytes: Int {
        constant("UPLOAD_DIMENSION_HEAD_BYTES", as: Int.self) ?? 512 * 1024
    }

    /// `UPLOAD_PHOTO_PICK_MAX_BYTES` (40 MB): a photo over this is refused before it is decoded.
    nonisolated static var uploadPhotoPickMaxBytes: Int {
        constant("UPLOAD_PHOTO_PICK_MAX_BYTES", as: Int.self) ?? 40 * 1024 * 1024
    }

    /// RULEBOOK 1.50.0 §24 `uploadKindForStoragePath(path)` → the stored-file kind, nil for a path no rule allows.
    nonisolated static func uploadKindForStoragePath(_ storagePath: String) -> String? {
        callJSON("uploadKindForStoragePath", arguments: [storagePath]) as? String
    }

    /// RULEBOOK 1.50.0 §24 `uploadAllowed({ kind, fileName, contentType, sizeBytes, headBytes })`: the kind, the size
    /// (above 0, at most the kind's cap), the claimed type and the extension, then the type read from `headBytes` (the
    /// first `UPLOAD_HEAD_BYTES` of the data as it will be uploaded). `headBytes` nil is a pick-time check only.
    nonisolated static func uploadAllowed(
        kind: String,
        fileName: String?,
        contentType: String?,
        sizeBytes: Int,
        headBytes: Data?
    ) -> RulebookUploadDecision {
        var input: [String: Any] = [
            "kind": kind,
            "fileName": fileName ?? "",
            "contentType": contentType ?? "",
            "sizeBytes": sizeBytes,
        ]
        if let headBytes {
            input["headBytes"] = headBytes.prefix(uploadHeadBytes).map { Int($0) }
        }
        guard let row = callJSON("uploadAllowed", arguments: [input]) as? [String: Any],
              let allowed = row["allowed"] as? Bool else {
            return RulebookUploadDecision(allowed: false, reason: "no_answer", message: uploadNoAnswerMessage, contentType: nil)
        }
        return RulebookUploadDecision(
            allowed: allowed,
            reason: row["reason"] as? String,
            message: row["message"] as? String,
            contentType: row["contentType"] as? String
        )
    }

    /// RULEBOOK 1.50.0 §24 `uploadRefusalMessage(kind, reason)`, e.g. "This file is too large. Use a photo (JPEG, PNG,
    /// HEIC or WebP) or a PDF, up to 10 MB."
    nonisolated static func uploadRefusalMessage(kind: String, reason: String) -> String {
        callJSON("uploadRefusalMessage", arguments: [kind, reason]) as? String ?? uploadNoAnswerMessage
    }

    /// RULEBOOK 1.50.0 §24 `imageDimensionsFromHeader(bytes)`: a photo's width and height read from its header (PNG,
    /// JPEG, WebP, HEIC/HEIF) without decoding it. Nil when the header does not say.
    nonisolated static func imageDimensionsFromHeader(_ data: Data) -> (width: Int, height: Int)? {
        let head = data.prefix(uploadDimensionHeadBytes).map { Int($0) }
        guard let row = callJSON("imageDimensionsFromHeader", arguments: [head]) as? [String: Any],
              let width = (row["width"] as? NSNumber)?.intValue,
              let height = (row["height"] as? NSNumber)?.intValue else { return nil }
        return (width, height)
    }

    /// RULEBOOK 1.50.0 §24 `photoPrepareRefusal({ sizeBytes, width, height })`: the message when a photo is over 40 MB or
    /// over 50 megapixels (`PHOTO_TOO_LARGE_TO_PREPARE_MESSAGE` / `PHOTO_TOO_MANY_PIXELS_MESSAGE`); nil when it may be
    /// prepared.
    nonisolated static func photoPrepareRefusal(sizeBytes: Int, width: Int?, height: Int?) -> String? {
        var input: [String: Any] = ["sizeBytes": sizeBytes]
        if let width { input["width"] = width }
        if let height { input["height"] = height }
        guard let value = callJSON("photoPrepareRefusal", arguments: [input]) else {
            return uploadNoAnswerMessage
        }
        return (value as? [String: Any])?["message"] as? String
    }

    /// RULEBOOK 1.50.0 §24 `safeExternalUrl(url, { allowHttp })`: the URL when it may be opened or loaded — `https:`, or
    /// `http:` to localhost / 127.0.0.1 / [::1] (the emulator) — else nil (no link). `allowHttp` is passed only for a
    /// material supplier `websiteURL`.
    nonisolated static func safeExternalUrl(_ url: String?, allowHttp: Bool = false) -> String? {
        guard let url else { return nil }
        return callJSON("safeExternalUrl", arguments: [url, ["allowHttp": allowHttp]]) as? String
    }

    /// `safeExternalUrl` as a `URL`; nil when the rulebook says no link.
    nonisolated static func safeExternalURL(_ url: String?, allowHttp: Bool = false) -> URL? {
        safeExternalUrl(url, allowHttp: allowHttp).flatMap { URL(string: $0) }
    }

    /// `safeExternalUrl` for a `URL` the app already holds.
    nonisolated static func safeExternalURL(_ url: URL, allowHttp: Bool = false) -> URL? {
        safeExternalURL(url.absoluteString, allowHttp: allowHttp)
    }
}
