//
//  FirebaseBackend+SubcontractorDocuments.swift
//  Project Planner
//
//  RULEBOOK 1.80.0 §30: upload, unlink and re-date a subcontractor's insurance and RAMS documents. The rulebook
//  (`Rulebook+SubcontractorDocuments.swift`) decides the path and every list write; this file only uploads the file and
//  writes one field-path update of the firm document inside a transaction (an entry added elsewhere meanwhile is kept).
//

import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore
#if canImport(FirebaseStorage)
import FirebaseStorage
#endif

extension FirebaseBackend {
    /// What a list transaction did.
    nonisolated struct SubcontractorDocumentListOutcome: Sendable {
        let outcome: String
        let removedPath: String?
    }

    private func subcontractorFirmRef(organizationId: String, subcontractorId: String) -> DocumentReference {
        db.collection("organizations").document(organizationId)
            .collection("subcontractors").document(subcontractorId)
    }

    /// One transaction: read the stored firm, ask the rulebook for the list write, write it with write metadata.
    private func writeSubcontractorDocumentList(
        organizationId: String,
        subcontractorId: String,
        plan: @escaping @Sendable ([String: Any]) -> (write: RulebookSubcontractorDocumentWrite?, outcome: String, removedPath: String?)
    ) async throws -> SubcontractorDocumentListOutcome {
        let ref = subcontractorFirmRef(organizationId: organizationId, subcontractorId: subcontractorId)
        return try await Self.runSubcontractorDocumentList(db: db, ref: ref, userId: currentUser?.uid, plan: plan)
    }

    /// `nonisolated` so the transaction block never runs on the main actor (as the variation evidence transactions).
    nonisolated private static func runSubcontractorDocumentList(
        db: Firestore,
        ref: DocumentReference,
        userId: String?,
        plan: @escaping @Sendable ([String: Any]) -> (write: RulebookSubcontractorDocumentWrite?, outcome: String, removedPath: String?)
    ) async throws -> SubcontractorDocumentListOutcome {
        let answer = try await db.runTransaction { transaction, errorPointer -> Any? in
            let snapshot: DocumentSnapshot
            do {
                snapshot = try transaction.getDocument(ref)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
            // RULEBOOK 1.9.0: an edit of a firm deleted elsewhere is refused, never re-created.
            guard let stored = snapshot.data() else {
                errorPointer?.pointee = NSError(
                    domain: "FirebaseBackend", code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "This was deleted on another device."]
                )
                return nil
            }
            let result = plan(stored)
            if result.outcome == "no_answer" {
                errorPointer?.pointee = CanonicalWriteUnavailableError(function: "subcontractorDocuments") as NSError
                return nil
            }
            if let write = result.write {
                let fields: [String: Any] = [write.fieldPath: write.value, "updatedAt": FieldValue.serverTimestamp()]
                transaction.updateData(WriteMetadata.stamped(fields, userId: userId), forDocument: ref)
            }
            return ["outcome": result.outcome, "removedPath": result.removedPath ?? NSNull()] as [String: Any]
        }
        let row = answer as? [String: Any] ?? [:]
        return SubcontractorDocumentListOutcome(outcome: row["outcome"] as? String ?? "invalid", removedPath: row["removedPath"] as? String)
    }

    #if canImport(FirebaseStorage)
    /// Upload one file (photos are redrawn; the bytes are checked with `uploadAllowed`) and link it. A file uploaded
    /// but not linked (list full, failed save) is deleted again by its uploader inside the §24 undo window.
    func uploadSubcontractorDocument(
        data: Data,
        fileName: String,
        contentType: String?,
        organizationId: String,
        subcontractorId: String,
        kind: String,
        expiresOn: String?
    ) async throws {
        guard let userId = currentUser?.uid else {
            throw NSError(domain: "FirebaseBackend", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])
        }
        let nowMs = StorageUploadPolicy.unixMillisecondsNow()
        let prepared = try StorageUploadPolicy.prepareFileData(
            data,
            originalFileName: fileName,
            declaredContentType: contentType,
            family: .subcontractorDocument,
            uid: userId,
            unixMilliseconds: nowMs
        )
        let ext = (prepared.objectName as NSString).pathExtension
        guard let path = CanonicalBusinessEngine.subcontractorDocumentStoragePath(
            organizationId: organizationId,
            subcontractorId: subcontractorId,
            uid: userId,
            unixMs: Int64(nowMs),
            fileExtension: ext
        ) else {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "This file cannot be uploaded here."])
        }
        let checkedType = try StorageUploadPolicy.checkedUploadContentType(
            storagePath: path, data: prepared.data, declaredContentType: prepared.contentType
        )
        _ = try await putVariationEvidenceData(prepared.data, path: path, contentType: checkedType)
        let displayName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? prepared.objectName : fileName
        let size = prepared.data.count
        let outcome: String
        do {
            outcome = try await writeSubcontractorDocumentList(organizationId: organizationId, subcontractorId: subcontractorId) { stored in
                let answer = CanonicalBusinessEngine.subcontractorDocumentAddWriteFields(
                    stored: stored,
                    kind: kind,
                    subcontractorId: subcontractorId,
                    organizationId: organizationId,
                    path: path,
                    name: displayName,
                    contentType: checkedType,
                    sizeBytes: size,
                    uploadedAtMs: Int64(nowMs),
                    uploadedBy: userId,
                    expiresOn: expiresOn
                )
                return (answer.write, answer.outcome, nil)
            }.outcome
        } catch {
            try? await storage.reference().child(path).delete()
            throw error
        }
        switch outcome {
        case "added", "alreadyLinked":
            return
        case "refused":
            try? await storage.reference().child(path).delete()
            throw NSError(domain: "FirebaseBackend", code: 409, userInfo: [NSLocalizedDescriptionKey: CanonicalBusinessEngine.subcontractorDocumentsFullMessage])
        default:
            try? await storage.reference().child(path).delete()
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "This document could not be saved. Try again."])
        }
    }

    /// The download URL of a stored document (Storage refuses anyone who is not staff of the organisation).
    func subcontractorDocumentDownloadURL(path: String) async throws -> URL {
        try await storage.reference().child(path).downloadURL()
    }

    /// Unlink one document; the Storage object is deleted only when `fileDeletePermission` allows it (§24).
    /// Returns whether the file was kept.
    func removeSubcontractorDocument(
        organizationId: String,
        subcontractorId: String,
        kind: String,
        entry: RulebookSubcontractorDocument,
        viewerRole: CanonicalBusinessEngine.CanonicalStaffAccountRole
    ) async throws -> Bool {
        let result = try await writeSubcontractorDocumentList(organizationId: organizationId, subcontractorId: subcontractorId) { stored in
            let answer = CanonicalBusinessEngine.subcontractorDocumentRemoveWriteFields(
                stored: stored, kind: kind, subcontractorId: subcontractorId, entryId: entry.id
            )
            return (answer.write, answer.answered ? "removed" : "no_answer", answer.removedPath)
        }
        guard let path = result.removedPath, !path.isEmpty else { return false }
        let outcome = await deleteVariationEvidenceFile(storagePath: path, viewerRole: viewerRole, uploadedAt: entry.uploadedAt)
        if case .deleted = outcome { return false }
        return true
    }
    #else
    func uploadSubcontractorDocument(
        data: Data, fileName: String, contentType: String?, organizationId: String,
        subcontractorId: String, kind: String, expiresOn: String?
    ) async throws {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available."])
    }

    func subcontractorDocumentDownloadURL(path: String) async throws -> URL {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available."])
    }

    func removeSubcontractorDocument(
        organizationId: String, subcontractorId: String, kind: String,
        entry: RulebookSubcontractorDocument, viewerRole: CanonicalBusinessEngine.CanonicalStaffAccountRole
    ) async throws -> Bool {
        throw NSError(domain: "FirebaseBackend", code: 501, userInfo: [NSLocalizedDescriptionKey: "FirebaseStorage is not available."])
    }
    #endif

    /// Change one document's expiry (nil clears it).
    func setSubcontractorDocumentExpiry(
        organizationId: String,
        subcontractorId: String,
        kind: String,
        entryId: String,
        expiresOn: String?
    ) async throws {
        let result = try await writeSubcontractorDocumentList(organizationId: organizationId, subcontractorId: subcontractorId) { stored in
            let answer = CanonicalBusinessEngine.subcontractorDocumentExpiryWriteFields(
                stored: stored, kind: kind, subcontractorId: subcontractorId, entryId: entryId, expiresOn: expiresOn
            )
            return (answer.write, answer.outcome, nil)
        }
        if result.outcome == "missing" {
            throw NSError(domain: "FirebaseBackend", code: 404, userInfo: [NSLocalizedDescriptionKey: "This document was removed on another device."])
        }
        if result.outcome == "invalid" {
            throw NSError(domain: "FirebaseBackend", code: 400, userInfo: [NSLocalizedDescriptionKey: "Enter the expiry date as a date, or leave it empty."])
        }
    }
}
