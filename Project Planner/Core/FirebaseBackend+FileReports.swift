//
//  FirebaseBackend+FileReports.swift
//  Project Planner
//

import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

/// Where a reported file is shown and what it belongs to. The surface code and the file reference
/// go to the rulebook unchanged; it refuses anything it does not recognise.
struct FileReportTarget: Identifiable, Equatable {
    let id = UUID()
    /// One of `FILE_REPORT_SURFACES` in the rulebook.
    let surface: String
    /// Audit, task, H&S document or talk, deadline, variation, or operative id.
    let parentId: String
    /// Download URL, gs:// URL or Storage path. `fileReportStoragePath` turns it into the path.
    let fileRef: String
    var fileName: String = ""
}

enum FileReportError: Error {
    case noOrganization
    case notSignedIn
    case notAFile
    case refused(String)
    case scriptUnavailable
}

extension FirebaseBackend {
    /// Writes one `organizations/{orgId}/fileReports/{UUID}` document built by `fileReportWriteFields`.
    /// Reporters cannot read reports back, so nothing is re-read after the write.
    func submitFileReport(_ target: FileReportTarget, reason: String, details: String) async throws {
        guard let organizationId = currentOrganization.map({ normalizedOrganizationId($0.firestoreDocumentId) }),
              !organizationId.isEmpty else {
            throw FileReportError.noOrganization
        }
        guard let uid = currentUser?.uid ?? Auth.auth().currentUser?.uid else {
            throw FileReportError.notSignedIn
        }
        guard let storagePath = CanonicalBusinessEngine.fileReportStoragePath(target.fileRef) else {
            throw FileReportError.notAFile
        }
        let input = CanonicalBusinessEngine.CanonicalFileReportInput(
            organizationId: organizationId,
            storagePath: storagePath,
            surface: target.surface,
            parentId: target.parentId,
            fileName: target.fileName,
            reason: reason,
            details: details,
            reportedByUserId: uid
        )
        guard let write = CanonicalBusinessEngine.fileReportWriteFields(input),
              let collectionPath = CanonicalBusinessEngine.fileReportCollectionPath(organizationId: organizationId) else {
            throw FileReportError.scriptUnavailable
        }
        switch write {
        case .refused(let error):
            throw FileReportError.refused(error)
        case .fields(var fields):
            fields["createdAt"] = FieldValue.serverTimestamp()
            try await db.collection(collectionPath).document(UUID().uuidString).setData(fields)
        }
    }
}
