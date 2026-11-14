//
//  SiteAuditUploadState.swift
//  Project Planner
//
//  What the person sees after "Submit & generate PDF" (owner decision 12 Nov, item 5a). The PDF is built from the
//  photos on the phone and shown at once; the audit and its photos are queued in `SiteAuditOfflineStore` and upload in
//  the background. This says, from the queue, whether the audit is saved yet.
//

import Foundation

nonisolated enum SiteAuditUploadState: Equatable, Sendable {
    /// No longer queued: the audit is saved to the organisation.
    case saved
    /// A sync pass is uploading its photos and saving it now.
    case uploading
    /// Queued and the phone is offline.
    case waitingForConnection
    /// Queued, online, nothing has failed yet: the first upload is about to start.
    case waitingToUpload
    /// Queued, online, the last try failed (`lastError`); the queue tries again on its own (retry timer, foreground,
    /// reconnect) and Retry upload tries now.
    case failedWillRetry(lastError: String?)
    /// Queued, and the automatic tries have run out: only Retry upload (or Pending sync) tries again.
    case needsRetry(lastError: String?)

    static func resolve(
        isQueued: Bool,
        isUploading: Bool,
        isOnline: Bool,
        attemptCount: Int,
        maxAutoAttempts: Int,
        lastError: String? = nil
    ) -> SiteAuditUploadState {
        guard isQueued else { return .saved }
        if isUploading { return .uploading }
        if !isOnline { return .waitingForConnection }
        if attemptCount >= maxAutoAttempts { return .needsRetry(lastError: lastError) }
        if attemptCount > 0 || lastError != nil { return .failedWillRetry(lastError: lastError) }
        return .waitingToUpload
    }

    var isSaved: Bool { self == .saved }

    /// The short line under the headline.
    var statusText: String {
        switch self {
        case .saved: return "Saved"
        case .uploading: return "Uploading photos…"
        case .waitingForConnection: return "Waiting to upload — will upload when online"
        case .waitingToUpload: return "Waiting to upload"
        case .failedWillRetry: return "Not uploaded yet — it will try again automatically"
        case .needsRetry: return "Not uploaded — tap Retry upload"
        }
    }

    /// Why it did not upload (the last error), for an edit refused by the server as much as for a new audit.
    var errorText: String? {
        switch self {
        case .failedWillRetry(let message), .needsRetry(let message):
            guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "Last error: \(message)"
        default:
            return nil
        }
    }

    /// The reassurance under it while not saved yet.
    var detailText: String? {
        switch self {
        case .saved: return nil
        case .needsRetry:
            return "It is kept on this phone until it uploads. It also shows in Pending sync."
        default:
            return "It is kept on this phone until it uploads, even if you close the app."
        }
    }

    var showsRetryButton: Bool {
        switch self {
        case .failedWillRetry, .needsRetry: return true
        default: return false
        }
    }
}
