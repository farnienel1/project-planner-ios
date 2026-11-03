//
//  StoredFileLink.swift
//  Project Planner
//
//  How the app opens a stored file reference (health & safety RAMS and other documents, uploaded toolbox talks,
//  deadline attachments). Same behaviour as web `lib/healthSafety/storedFile.ts` / `openStoredFile.ts` (PR #227):
//
//  - `.url`: an http(s) address that already carries its access token (or any non-Firebase http(s) URL): open as is.
//  - `.storage`: a Storage object path — from a `gs://` URL (what older iOS builds stored when `downloadURL()` failed
//    after an upload), a bare `organizations/...` path, or a Firebase download URL without a token. The app asks
//    Storage for a fresh download URL (the signed-in member's read rule) before opening it.
//  - nil: nothing the app can open (blank, a `file://` path from another device, an unknown scheme).
//
//  The Storage path comes from the rulebook's `fileReportStoragePath` through `CanonicalBusinessEngine`; no business
//  rule is decided here.
//

import Foundation
#if canImport(FirebaseStorage)
import FirebaseStorage
#endif

enum StoredFileTarget: Equatable {
    case url(URL)
    case storage(String)

    /// The target for a stored `fileURL`, or nil when nothing can be opened.
    nonisolated static func target(for fileRef: String?) -> StoredFileTarget? {
        let raw = (fileRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            let isFirebaseObject = raw.range(of: #"/v0/b/[^/]+/o/[^?#]+"#, options: .regularExpression) != nil
            let hasToken = raw.range(of: #"[?&]token="#, options: .regularExpression) != nil
            if isFirebaseObject, !hasToken, let path = CanonicalBusinessEngine.fileReportStoragePath(raw), !path.isEmpty {
                return .storage(path)
            }
            guard let url = URL(string: raw) else { return nil }
            return .url(url)
        }
        guard let path = CanonicalBusinessEngine.fileReportStoragePath(raw), !path.isEmpty else { return nil }
        return .storage(path)
    }

    /// True when the reference can be opened (a row with no openable file says "No file").
    nonisolated static func canOpen(_ fileRef: String?) -> Bool {
        target(for: fileRef) != nil
    }
}

enum StoredFileLink {
    struct Unopenable: LocalizedError {
        var errorDescription: String? { "This file could not be opened. Try again." }
    }

    /// An address the app can download: the URL itself, or a fresh Storage download URL for a Storage path.
    static func resolvedURL(for fileRef: String?) async throws -> URL {
        switch StoredFileTarget.target(for: fileRef) {
        case .url(let url):
            return url
        case .storage(let path):
            #if canImport(FirebaseStorage)
            return try await Storage.storage().reference(withPath: path).downloadURL()
            #else
            throw Unopenable()
            #endif
        case nil:
            throw Unopenable()
        }
    }

    /// `resolvedURL(for:)` for a URL the app already parsed from a stored reference (`storedFileURL`).
    static func resolvedURL(_ url: URL) async throws -> URL {
        try await resolvedURL(for: url.absoluteString)
    }
}
