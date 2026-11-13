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
    /// Queued, online, a pass will try again shortly (the retry timer, foreground or reconnect).
    case waitingToRetry
    /// Queued, and the automatic tries have run out: the person taps Retry upload.
    case needsRetry

    static func resolve(
        isQueued: Bool,
        isUploading: Bool,
        isOnline: Bool,
        attemptCount: Int,
        maxAutoAttempts: Int
    ) -> SiteAuditUploadState {
        guard isQueued else { return .saved }
        if isUploading { return .uploading }
        if !isOnline { return .waitingForConnection }
        if attemptCount >= maxAutoAttempts { return .needsRetry }
        return .waitingToRetry
    }

    var isSaved: Bool { self == .saved }

    /// The short line under the PDF card.
    var statusText: String {
        switch self {
        case .saved: return "Saved"
        case .uploading: return "Uploading photos…"
        case .waitingForConnection: return "Waiting to upload — will upload when online"
        case .waitingToRetry: return "Waiting to upload — will try again shortly"
        case .needsRetry: return "Not uploaded yet — tap Retry upload"
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

    var showsRetryButton: Bool { self == .needsRetry }
}
