//
//  Rulebook+StoredFiles.swift
//  Project Planner
//
//  RULEBOOK 1.25.0 §24 "Uploaded files" (web `lib/canonical/storedFiles.ts`): who may delete an uploaded file, where it
//  lives, who uploaded it and what a new upload is called. Every answer comes from the packed script through
//  `CanonicalBusinessEngine.callJSON`; `storage.rules` enforces the same rule on the server.
//

import Foundation

/// `fileDeletePermission(...)` → `{ allowed, reason, undoEndsAtMs }`.
nonisolated struct RulebookFileDeletePermission: Hashable, Sendable {
    let allowed: Bool
    /// `admin`, `own_profile_photo`, `uploader_undo`, `undo_expired`, `not_uploader`, `admin_only`, `other_organization`,
    /// `unknown_path`, `signed_out`.
    let reason: String
    let undoEndsAtMs: Double?
}

extension CanonicalBusinessEngine {
    /// RULEBOOK 1.25.0 §24 `fileDeletePermission({ storagePath, organizationId, viewerUserId, viewerRole, nowMs,
    /// uploadedAtMs? })`: an admin or super admin of that organisation outside operative mode; a profile photo's person;
    /// every other file's uploader within `FILE_UNDO_WINDOW_MINUTES` of the upload; nobody else. Refused (never allowed)
    /// when the script did not answer.
    nonisolated static func fileDeletePermission(
        storagePath: String,
        organizationId: String,
        viewerUserId: String,
        viewerRole: CanonicalStaffAccountRole,
        now: Date = Date(),
        uploadedAt: Date? = nil
    ) -> RulebookFileDeletePermission {
        var input: [String: Any] = [
            "storagePath": storagePath,
            "organizationId": organizationId,
            "viewerUserId": viewerUserId,
            "viewerRole": [
                "isSuperAdmin": viewerRole.isSuperAdmin, "isAdmin": viewerRole.isAdmin,
                "isManager": viewerRole.isManager, "isOperativeMode": viewerRole.isOperativeMode,
            ],
            "nowMs": (now.timeIntervalSince1970 * 1000).rounded(),
        ]
        if let uploadedAt { input["uploadedAtMs"] = (uploadedAt.timeIntervalSince1970 * 1000).rounded() }
        guard let row = callJSON("fileDeletePermission", arguments: [input]) as? [String: Any],
              let allowed = row["allowed"] as? Bool else {
            return RulebookFileDeletePermission(allowed: false, reason: "no_answer", undoEndsAtMs: nil)
        }
        return RulebookFileDeletePermission(
            allowed: allowed,
            reason: row["reason"] as? String ?? "",
            undoEndsAtMs: (row["undoEndsAtMs"] as? NSNumber)?.doubleValue
        )
    }

    /// RULEBOOK 1.25.0 §24 `storedFileKind(path)` → the kind (`STORED_FILE_KINDS`), or nil for a path no rule allows.
    nonisolated static func storedFileKind(_ storagePath: String) -> String? {
        (callJSON("storedFileKind", arguments: [storagePath]) as? [String: Any])?["kind"] as? String
    }

    /// RULEBOOK 1.25.0 §24 `storedFileUploader(path)`: the uploader's uid and upload time read from the object name. Nil
    /// for a name that does not follow `storedFileObjectName` (older uploads, timesheet exports).
    nonisolated static func storedFileUploader(_ storagePath: String) -> (uploaderUserId: String, uploadedAtMs: Double?)? {
        guard let row = callJSON("storedFileUploader", arguments: [storagePath]) as? [String: Any],
              let uid = row["uploaderUserId"] as? String else { return nil }
        return (uid, (row["uploadedAtMs"] as? NSNumber)?.doubleValue)
    }

    /// RULEBOOK 1.25.0 §24 `storedFileObjectName({ uid, unixMs, extension })` → `{uid}_{unixMs}.{ext}`. Nil when the uid
    /// cannot be part of a name (or the script did not answer).
    nonisolated static func storedFileObjectName(uid: String, unixMs: Int64, fileExtension: String?) -> String? {
        let input: [String: Any] = ["uid": uid, "unixMs": unixMs, "extension": fileExtension.map { $0 as Any } ?? NSNull()]
        return callJSON("storedFileObjectName", arguments: [input]) as? String
    }

    /// `FILE_KEPT_ON_REMOVE_COPY`: shown when a file is removed from a record but the viewer may not delete it.
    nonisolated static var fileKeptOnRemoveCopy: String {
        constant("FILE_KEPT_ON_REMOVE_COPY", as: String.self)
            ?? "Removed from this list. The file itself is kept so an admin can restore it."
    }

    /// RULEBOOK 1.27.0 §24 `FILE_RECOVERY_RETENTION_DAYS`: how long a deleted or replaced file is kept for recovery.
    nonisolated static var fileRecoveryRetentionDays: Int {
        constant("FILE_RECOVERY_RETENTION_DAYS", as: Int.self) ?? 30
    }

    /// RULEBOOK 1.27.0 §24 `DELETED_DATA_RETENTION_NOTICE`: the sentence the privacy policy (7. Retention) and the DPA
    /// (14. Deletion and Return) carry word for word on every platform.
    nonisolated static var deletedDataRetentionNotice: String {
        constant("DELETED_DATA_RETENTION_NOTICE", as: String.self)
            ?? "A deleted company can be restored for 30 days, after which its data is erased. Deleted files, including the files of an erased company, are kept for up to 30 days so they can be recovered, then permanently removed."
    }
}

/// What removing a file from a record did (RULEBOOK 1.25.0 §24): deleted (`fileDeletePermission` allowed it), kept
/// (not allowed: the record only drops its link), or a delete the server refused or that failed (the file is kept).
nonisolated enum StoredFileRemoval: Equatable, Sendable {
    case deleted
    case kept
    case failed(String)
}
