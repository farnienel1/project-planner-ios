//
//  FirebaseBackend+OrgCompliance.swift
//  Project Planner
//
//  RULEBOOK 1.83.0 §31: the organisation's insurance & accreditations (admins only). The rulebook
//  (`Rulebook+OrgCompliance.swift`) decides the path, the entry and every list write; this file uploads the file and
//  writes one section's list of `organizations/{orgId}/orgCompliance/documents` as a merge-set of a nested map inside
//  a transaction (an entry added on another device meanwhile is kept). The pattern of the 1.80.0 subcontractor
//  documents (`FirebaseBackend+SubcontractorDocuments.swift`).
//

import Foundation
import Combine
import FirebaseAuth
@preconcurrency import FirebaseFirestore
#if canImport(FirebaseStorage)
import FirebaseStorage
#endif

extension FirebaseBackend {
    func orgComplianceRef(organizationId: String) -> DocumentReference {
        db.collection("organizations").document(organizationId).collection("orgCompliance").document("documents")
    }

    /// One transaction: read the stored document (missing reads as empty), ask the rulebook for the section write,
    /// merge-set it with write metadata. Returns the plan.
    private func writeOrgComplianceSection(
        organizationId: String,
        plan: @escaping @Sendable ([String: Any]) -> RulebookOrgComplianceWritePlan
    ) async throws -> RulebookOrgComplianceWritePlan {
        try await Self.runOrgComplianceWrite(db: db, ref: orgComplianceRef(organizationId: organizationId), userId: currentUser?.uid, plan: plan)
    }

    /// `nonisolated` so the transaction block never runs on the main actor.
    nonisolated private static func runOrgComplianceWrite(
        db: Firestore,
        ref: DocumentReference,
        userId: String?,
        plan: @escaping @Sendable ([String: Any]) -> RulebookOrgComplianceWritePlan
    ) async throws -> RulebookOrgComplianceWritePlan {
        let answer = try await db.runTransaction { transaction, errorPointer -> Any? in
            let snapshot: DocumentSnapshot
            do {
                snapshot = try transaction.getDocument(ref)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
            let result = plan(snapshot.data() ?? [:])
            if result.outcome == "no_answer" {
                errorPointer?.pointee = CanonicalWriteUnavailableError(function: "orgCompliance") as NSError
                return nil
            }
            if var fields = result.payload {
                fields["updatedAt"] = FieldValue.serverTimestamp()
                transaction.setData(WriteMetadata.stamped(fields, userId: userId), forDocument: ref, merge: true)
            }
            return RulebookOrgComplianceWritePlanBox(plan: result)
        }
        guard let box = answer as? RulebookOrgComplianceWritePlanBox else {
            return RulebookOrgComplianceWritePlan(payload: nil, outcome: "invalid", error: nil, oldPath: nil)
        }
        return box.plan
    }

    private static func complianceError(_ message: String?, code: Int = 400) -> NSError {
        NSError(domain: "FirebaseBackend", code: code, userInfo: [NSLocalizedDescriptionKey: message ?? "This document could not be saved. Try again."])
    }

    #if canImport(FirebaseStorage)
    /// Prepare (photos redrawn, §24; bytes checked with `uploadAllowed`) and upload one file to a new compliance object.
    private func uploadOrgComplianceFile(data: Data, fileName: String, contentType: String?, organizationId: String) async throws -> OrgComplianceFileInput {
        guard let userId = currentUser?.uid else { throw Self.complianceError("User not authenticated", code: 401) }
        let nowMs = StorageUploadPolicy.unixMillisecondsNow()
        let prepared = try StorageUploadPolicy.prepareFileData(
            data,
            originalFileName: fileName,
            declaredContentType: contentType,
            family: .orgComplianceDocument,
            uid: userId,
            unixMilliseconds: nowMs
        )
        let ext = (prepared.objectName as NSString).pathExtension
        guard let path = CanonicalBusinessEngine.orgComplianceStoragePath(
            organizationId: organizationId, uid: userId, unixMs: Int64(nowMs), fileExtension: ext
        ) else { throw Self.complianceError("This file cannot be uploaded here.") }
        let checkedType = try StorageUploadPolicy.checkedUploadContentType(storagePath: path, data: prepared.data, declaredContentType: prepared.contentType)
        _ = try await putVariationEvidenceData(prepared.data, path: path, contentType: checkedType)
        return OrgComplianceFileInput(
            path: path,
            fileName: CanonicalBusinessEngine.orgComplianceFileName(pickedName: fileName, storedPath: path)
                ?? Self.subcontractorDocumentDisplayName(fileName: fileName, storedObjectName: prepared.objectName),
            contentType: checkedType,
            sizeBytes: prepared.data.count,
            uploadedAtMs: Int64(nowMs),
            uploadedBy: userId
        )
    }

    private func deleteComplianceObject(_ path: String?) async {
        guard let path, !path.isEmpty else { return }
        try? await storage.reference().child(path).delete()
    }

    /// After a transaction error the write may still have committed (§22 `alreadyLinked` pattern): re-read the document
    /// from the server and delete the new file only when no entry names it (`orgCompliancePathLinked`). A re-read that
    /// fails, or no answer from the rulebook, keeps the file.
    private func deleteUnlinkedComplianceObject(organizationId: String, path: String) async {
        guard let snapshot = try? await orgComplianceRef(organizationId: organizationId).getDocument(source: .server) else { return }
        guard CanonicalBusinessEngine.orgCompliancePathLinked(stored: snapshot.data(), path: path) == false else { return }
        await deleteComplianceObject(path)
    }

    func addOrgComplianceDocument(
        data: Data, fileName: String, contentType: String?, organizationId: String,
        section: String, details: OrgComplianceDetailsInput, todayKey: String
    ) async throws {
        let file = try await uploadOrgComplianceFile(data: data, fileName: fileName, contentType: contentType, organizationId: organizationId)
        let result: RulebookOrgComplianceWritePlan
        do {
            result = try await writeOrgComplianceSection(organizationId: organizationId) { stored in
                CanonicalBusinessEngine.orgComplianceAddWriteFields(
                    stored: stored, section: section, organizationId: organizationId, todayKey: todayKey, details: details, file: file
                )
            }
        } catch {
            await deleteUnlinkedComplianceObject(organizationId: organizationId, path: file.path)
            throw error
        }
        if result.outcome == "added" || result.outcome == "alreadyLinked" { return }
        await deleteComplianceObject(file.path)
        throw Self.complianceError(result.error)
    }

    /// A renewal: same document, new file. The old file is deleted (kept 30 days by the bucket's soft delete, §24).
    func replaceOrgComplianceFile(
        data: Data, fileName: String, contentType: String?, organizationId: String,
        section: String, entryId: String, details: OrgComplianceDetailsInput, todayKey: String
    ) async throws {
        let file = try await uploadOrgComplianceFile(data: data, fileName: fileName, contentType: contentType, organizationId: organizationId)
        let result: RulebookOrgComplianceWritePlan
        do {
            result = try await writeOrgComplianceSection(organizationId: organizationId) { stored in
                CanonicalBusinessEngine.orgComplianceReplaceWriteFields(
                    stored: stored, section: section, organizationId: organizationId, entryId: entryId,
                    todayKey: todayKey, details: details, file: file
                )
            }
        } catch {
            await deleteUnlinkedComplianceObject(organizationId: organizationId, path: file.path)
            throw error
        }
        guard result.outcome == "replaced" || result.outcome == "alreadyLinked" else {
            await deleteComplianceObject(file.path)
            throw Self.complianceError(result.error)
        }
        await deleteComplianceObject(result.oldPath)
    }

    /// Remove a document and its file (kept 30 days by the bucket's soft delete, §24).
    func removeOrgComplianceDocument(organizationId: String, section: String, entryId: String) async throws {
        let result = try await writeOrgComplianceSection(organizationId: organizationId) { stored in
            CanonicalBusinessEngine.orgComplianceRemoveWriteFields(stored: stored, section: section, organizationId: organizationId, entryId: entryId)
        }
        await deleteComplianceObject(result.oldPath)
    }

    /// The download URL of a stored certificate (Storage refuses anyone who is not an admin of the organisation).
    func orgComplianceDownloadURL(path: String) async throws -> URL {
        try await storage.reference().child(path).downloadURL()
    }

    /// The ticked documents as one zip in a temporary folder (names from `orgComplianceZipEntryNames`, the file from
    /// `orgComplianceZipFileName`, at most `orgComplianceZipMaxDocuments`). Built on the phone from files the admin may
    /// already read; nothing stored. The caller shares the returned file.
    func orgComplianceZip(entries: [RulebookOrgComplianceEntry], todayKey: String) async throws -> URL {
        guard !entries.isEmpty else { throw Self.complianceError("Choose at least one document.") }
        let max = CanonicalBusinessEngine.orgComplianceZipMaxDocuments
        guard entries.count <= max else { throw Self.complianceError("Choose up to \(max) documents.") }
        guard let names = CanonicalBusinessEngine.orgComplianceZipEntryNames(entries) else {
            throw CanonicalWriteUnavailableError(function: "orgComplianceZipEntryNames")
        }
        let fileManager = FileManager.default
        let work = OrgComplianceZipFiles.newWorkFolder()
        let folder = work.appendingPathComponent("Insurance-and-accreditations", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var total = 0
        for (index, entry) in entries.enumerated() {
            let data: Data
            do {
                data = try await storage.reference().child(entry.path).data(maxSize: 12 * 1024 * 1024)
            } catch {
                try? fileManager.removeItem(at: work)
                throw Self.complianceError("\(entry.title) could not be downloaded.")
            }
            total += data.count
            guard total <= CanonicalBusinessEngine.orgComplianceZipMaxBytes else {
                try? fileManager.removeItem(at: work)
                throw Self.complianceError(CanonicalBusinessEngine.orgComplianceZipTooLargeMessage)
            }
            try data.write(to: folder.appendingPathComponent(names[index]))
        }
        let output = work.appendingPathComponent(CanonicalBusinessEngine.orgComplianceZipFileName(todayKey: todayKey))
        var coordinatorError: NSError?
        var copyError: Error?
        // `.forUploading` gives a zip of the folder; it is removed when the block returns, so it is copied out.
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do { try fileManager.copyItem(at: zipped, to: output) } catch { copyError = error }
        }
        try? fileManager.removeItem(at: folder)
        if let error = coordinatorError ?? copyError {
            OrgComplianceZipFiles.remove(containing: output)
            throw error
        }
        return output
    }
    #else
    func addOrgComplianceDocument(
        data: Data, fileName: String, contentType: String?, organizationId: String,
        section: String, details: OrgComplianceDetailsInput, todayKey: String
    ) async throws { throw Self.complianceError("FirebaseStorage is not available.", code: 501) }

    func replaceOrgComplianceFile(
        data: Data, fileName: String, contentType: String?, organizationId: String,
        section: String, entryId: String, details: OrgComplianceDetailsInput, todayKey: String
    ) async throws { throw Self.complianceError("FirebaseStorage is not available.", code: 501) }

    func removeOrgComplianceDocument(organizationId: String, section: String, entryId: String) async throws {
        throw Self.complianceError("FirebaseStorage is not available.", code: 501)
    }

    func orgComplianceDownloadURL(path: String) async throws -> URL {
        throw Self.complianceError("FirebaseStorage is not available.", code: 501)
    }

    func orgComplianceZip(entries: [RulebookOrgComplianceEntry], todayKey: String) async throws -> URL {
        throw Self.complianceError("FirebaseStorage is not available.", code: 501)
    }
    #endif

    /// Edit one document's details (no file change).
    func updateOrgComplianceDocument(
        organizationId: String, section: String, entryId: String, details: OrgComplianceDetailsInput, todayKey: String
    ) async throws {
        let userId = currentUser?.uid ?? ""
        let nowMs = Int64(StorageUploadPolicy.unixMillisecondsNow())
        let result = try await writeOrgComplianceSection(organizationId: organizationId) { stored in
            CanonicalBusinessEngine.orgComplianceUpdateWriteFields(
                stored: stored, section: section, organizationId: organizationId, entryId: entryId,
                todayKey: todayKey, details: details, updatedAtMs: nowMs, updatedBy: userId
            )
        }
        if result.outcome == "missing" || result.outcome == "invalid" {
            throw Self.complianceError(result.error, code: result.outcome == "missing" ? 404 : 400)
        }
    }
}

/// Carries a plan out of the Firestore transaction block (it returns `Any?`).
nonisolated final class RulebookOrgComplianceWritePlanBox: @unchecked Sendable {
    let plan: RulebookOrgComplianceWritePlan
    init(plan: RulebookOrgComplianceWritePlan) { self.plan = plan }
}

/// Live listener on the open organisation's insurance & accreditations (rulebook §1: a screen showing shared data
/// listens). Admins only — the security rules refuse everyone else, so it is started only for them.
@MainActor
final class OrgComplianceStore: ObservableObject {
    @Published private(set) var documents: RulebookOrgComplianceDocuments?
    @Published private(set) var loadError: String?
    /// Removed in `stop()` and when the store goes away with the hub (the page pushed from the hub shares it).
    nonisolated(unsafe) private var listener: ListenerRegistration?
    private var organizationId: String?

    deinit { listener?.remove() }

    func start(organizationId: String, db: Firestore) {
        guard organizationId != self.organizationId || listener == nil else { return }
        stop()
        self.organizationId = organizationId
        let ref = db.collection("organizations").document(organizationId).collection("orgCompliance").document("documents")
        listener = ref.addSnapshotListener { [weak self] snapshot, error in
            let failed = error != nil
            let parsed = failed ? nil : CanonicalBusinessEngine.parseOrgComplianceDocuments(data: snapshot?.data(), organizationId: organizationId)
            Task { @MainActor [weak self] in
                // Never show another organisation's documents after a switch.
                guard let self, self.organizationId == organizationId else { return }
                if failed {
                    self.loadError = "Insurance & accreditations did not load. Check the connection and try again."
                    return
                }
                self.loadError = nil
                self.documents = parsed ?? RulebookOrgComplianceDocuments()
            }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        organizationId = nil
        documents = nil
        loadError = nil
    }
}

/// The temporary folders a compliance zip is built in (security review of #288): removed when the share sheet closes
/// and at every start, so certificates never stay in the app's temporary folder.
nonisolated enum OrgComplianceZipFiles {
    static let prefix = "compliance-zip-"

    static func newWorkFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
    }

    /// Remove the work folder that holds `file` (a zip this app made); anything else is left alone.
    static func remove(containing file: URL) {
        let folder = file.deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix(prefix),
              folder.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Remove every compliance zip work folder (at start).
    static func removeAll() {
        let fileManager = FileManager.default
        let temp = fileManager.temporaryDirectory
        guard let names = try? fileManager.contentsOfDirectory(atPath: temp.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: temp.appendingPathComponent(name, isDirectory: true))
        }
    }
}
