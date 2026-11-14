//
//  FirebaseBackend+PayeClaims.swift
//  Project Planner
//
//  RULEBOOK 1.30.0 §26: PAYE price work, expenses, their saved report copies and personal site audits — reads and writes,
//  the iOS counterpart of web `lib/payeClaims/payeClaimsData.ts`. Every rule is in the packed script
//  (`Rulebook+PayeClaims.swift`): documents are read through the rulebook readers, writes are the rulebook's write fields
//  plus `createdAt` / `generatedAt` and the write metadata, and Storage paths are the rulebook's
//  (`payeClaimEvidencePath`, `personalSiteAuditImagePath`). Online only (no offline queue).
//

import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore
import FirebaseStorage

/// Why a claim or audit save was refused before any write (the rulebook's message).
nonisolated struct PayeClaimRefused: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Rows of several `userId ==` listeners merged in id order (plumbing only, no rule): the latest rows per id.
@MainActor
final class PayeClaimListenerMerge<Row> {
    /// The ids, empty ones dropped and each listed once (as web's `Array.from(new Set(ids.filter(Boolean)))`), then any
    /// extra query keys (`add`).
    private(set) var ids: [String]
    private var byId: [String: [Row]] = [:]

    init(ids: [String]) {
        var seen = Set<String>()
        self.ids = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func set(_ id: String, _ rows: [Row]) { byId[id] = rows }

    /// One more query key (1.33.0: the `personUserId ==` query), merged after the ids.
    func add(_ key: String) {
        if !ids.contains(key) { ids.append(key) }
    }

    func rows() -> [Row] { ids.flatMap { byId[$0] ?? [] } }

    func rows(uniqueBy key: (Row) -> String) -> [Row] {
        var seen = Set<String>()
        return rows().filter { seen.insert(key($0)).inserted }
    }
}

extension FirebaseBackend {
    private func payeClaimsOrganizationRef() throws -> DocumentReference {
        guard let orgId = currentOrganization?.firestoreDocumentId, !orgId.isEmpty else {
            throw PayeClaimRefused(message: "No organisation is open.")
        }
        return db.collection("organizations").document(orgId)
    }

    /// The open organisation's document id (the Storage and Firestore path segment), or nil.
    var payeClaimsOrganizationId: String? {
        guard let orgId = currentOrganization?.firestoreDocumentId, !orgId.isEmpty else { return nil }
        return orgId
    }

    /// The signed-in Auth uid: the only person who may write their own claims and audits.
    var payeClaimsUid: String? { Auth.auth().currentUser?.uid }

    // MARK: Price work and expenses (LIVE_COLLECTIONS: listen while the screen is open)

    /// Live items of one person (`userId ==`, the query the read rules allow the person, their line managers and admins),
    /// read through `parsePriceWorkDocument` / `parseExpenseDocument` with the item owner's evidence filter.
    func listenPayeClaims(
        userId: String,
        kind: PayeClaimKind,
        onChange: @escaping ([PayeClaimItem]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration? {
        guard let org = try? payeClaimsOrganizationRef() else { return nil }
        let orgId = org.documentID
        return org.collection(kind.collection).whereField("userId", isEqualTo: userId).addSnapshotListener { snapshot, error in
            if let error {
                Task { @MainActor in onError(error) }
                return
            }
            let rows = (snapshot?.documents ?? []).compactMap { doc in
                CanonicalBusinessEngine.parsePayeClaimDocument(kind: kind, docId: doc.documentID, data: doc.data(), organizationId: orgId)
            }
            Task { @MainActor in onChange(rows) }
        }
    }

    /// RULEBOOK 1.32.0 (`overtimePersonIds`): live items of one person under every id they go by, one `userId ==` query
    /// per id, merged in id order (web `listenPersonPayeClaims`). The first id is the person's users id and its error is
    /// reported; a refused read under another id is left out silently. 1.33.0: plus the items stamped with the person's
    /// current users id (`personUserId ==` the first id, written on create and by the backfill) — the query the read
    /// rules allow the line manager for an item filed under another of the person's ids.
    func listenPersonPayeClaims(
        userIds: [String],
        kind: PayeClaimKind,
        onChange: @escaping ([PayeClaimItem]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> [ListenerRegistration] {
        let merge = PayeClaimListenerMerge<PayeClaimItem>(ids: userIds)
        var registrations: [ListenerRegistration] = []
        for (index, id) in merge.ids.enumerated() {
            let registration = listenPayeClaims(
                userId: id,
                kind: kind,
                onChange: { rows in
                    merge.set(id, rows)
                    onChange(merge.rows(uniqueBy: \.id))
                },
                onError: { error in
                    if index == 0 {
                        onError(error)
                    } else {
                        merge.set(id, [])
                        onChange(merge.rows(uniqueBy: \.id))
                    }
                }
            )
            if let registration { registrations.append(registration) }
        }
        // On the person's own screen the `personUserId ==` query is not needed (their `userId ==` queries cover it)
        // and the read rules refuse it, so it is added only when the viewer is someone else.
        if let personUserId = merge.ids.first, personUserId != payeClaimsUid, let org = try? payeClaimsOrganizationRef() {
            let key = "personUserId:\(personUserId)"
            merge.add(key)
            let orgId = org.documentID
            registrations.append(
                org.collection(kind.collection).whereField("personUserId", isEqualTo: personUserId).addSnapshotListener { snapshot, error in
                    let rows: [PayeClaimItem] = error != nil ? [] : (snapshot?.documents ?? []).compactMap { doc in
                        CanonicalBusinessEngine.parsePayeClaimDocument(kind: kind, docId: doc.documentID, data: doc.data(), organizationId: orgId)
                    }
                    Task { @MainActor in
                        merge.set(key, rows)
                        onChange(merge.rows(uniqueBy: \.id))
                    }
                }
            )
        }
        return registrations
    }

    /// RULEBOOK 1.32.0 §26 (LIVE_COLLECTIONS `payeClaimReviews`: listen while the screen is open): live reviews of one
    /// person's price work and expenses under every id they go by, read through `parsePayeClaimReviewDocument`
    /// (web `listenPayeClaimReviews`). A refused read under an id is left out. 1.33.0: plus the reviews carrying
    /// `personUserId ==` the person's users id (an item filed under another of their ids), deduplicated by id.
    func listenPayeClaimReviews(
        userIds: [String],
        onChange: @escaping ([PayeClaimReviewRecord]) -> Void
    ) -> [ListenerRegistration] {
        guard let org = try? payeClaimsOrganizationRef() else { return [] }
        let merge = PayeClaimListenerMerge<PayeClaimReviewRecord>(ids: userIds)
        let collection = CanonicalBusinessEngine.payeClaimReviewsCollection
        var queries: [(key: String, field: String, value: String)] = merge.ids.map { ($0, "userId", $0) }
        // Not on the person's own screen: the read rules refuse the `personUserId ==` query for the person themself.
        if let personUserId = merge.ids.first, personUserId != payeClaimsUid {
            let key = "personUserId:\(personUserId)"
            merge.add(key)
            queries.append((key, "personUserId", personUserId))
        }
        return queries.map { query in
            org.collection(collection).whereField(query.field, isEqualTo: query.value).addSnapshotListener { snapshot, error in
                let rows: [PayeClaimReviewRecord] = error != nil ? [] : (snapshot?.documents ?? []).compactMap { doc in
                    CanonicalBusinessEngine.parsePayeClaimReviewDocument(docId: doc.documentID, data: doc.data())
                }
                Task { @MainActor in
                    merge.set(query.key, rows)
                    onChange(merge.rows(uniqueBy: \.id))
                }
            }
        }
    }

    /// RULEBOOK 1.32.0 §26 Approve: every review of `payeClaimReviewWrites` in one batch, each with `reviewedAt` (server
    /// time) and the write metadata (web `savePayeClaimReviews`). Nothing is written when there are no writes.
    func savePayeClaimReviews(_ writes: [PayeClaimReviewWrite]) async throws {
        guard !writes.isEmpty else { return }
        let org = try payeClaimsOrganizationRef()
        guard let uid = payeClaimsUid else { throw PayeClaimRefused(message: "You must be signed in.") }
        let collection = CanonicalBusinessEngine.payeClaimReviewsCollection
        let batch = db.batch()
        for write in writes {
            var fields = write.fields
            fields["reviewedAt"] = FieldValue.serverTimestamp()
            batch.setData(WriteMetadata.stamped(fields, userId: uid), forDocument: org.collection(collection).document(write.docId))
        }
        try await batch.commit()
    }

    /// Saved report copies of one person (`parsePayeClaimReportDocument`). `listen: false`: read on open.
    func loadPayeClaimReports(userId: String) async throws -> [PayeClaimReportRecord] {
        let org = try payeClaimsOrganizationRef()
        let collection = CanonicalBusinessEngine.payeClaimText("PAYE_CLAIM_REPORTS_COLLECTION", fallback: "payeClaimReports")
        let snapshot = try await org.collection(collection).whereField("userId", isEqualTo: userId).getDocuments()
        return snapshot.documents.compactMap { doc in
            CanonicalBusinessEngine.parsePayeClaimReportDocument(docId: doc.documentID, data: doc.data())
        }
    }

    /// Uploads one evidence file into the signed-in person's claim folder (`payeClaimEvidencePath`) and returns its entry.
    /// Images are uploaded as JPEG and PDFs as PDF; the Storage rules refuse anything else (and SVG).
    func uploadPayeClaimEvidence(
        data: Data,
        name: String,
        contentType: String,
        kind: String,
        auditId: String? = nil
    ) async throws -> PayeClaimEvidence {
        guard let orgId = payeClaimsOrganizationId, let uid = payeClaimsUid else {
            throw PayeClaimRefused(message: "You must be signed in to upload evidence.")
        }
        let fileExtension = contentType == "application/pdf" ? "pdf" : "jpg"
        guard let path = CanonicalBusinessEngine.payeClaimEvidencePath(
            organizationId: orgId,
            userId: uid,
            unixMs: StorageUploadPolicy.unixMillisecondsNow(),
            fileExtension: fileExtension
        ) else {
            throw PayeClaimRefused(message: "You must be signed in to upload evidence.")
        }
        try await putPayeClaimData(data, path: path, contentType: contentType)
        return PayeClaimEvidence(path: path, name: name, kind: kind, contentType: contentType, auditId: auditId)
    }

    private func putPayeClaimData(_ data: Data, path: String, contentType: String) async throws {
        let storageRef = storage.reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = contentType
        let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StorageMetadata, Error>) in
            storageRef.putData(data, metadata: metadata) { metadata, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let metadata {
                    continuation.resume(returning: metadata)
                } else {
                    continuation.resume(throwing: NSError(domain: "StorageReference", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
    }

    /// Add Price Work: refused with the rulebook message (`priceWorkValidationError`), else created with
    /// `priceWorkWriteFields`. `person` / `roster` are the approver rows (`PayeClaimPeople`).
    func addPriceWork(draft: [String: Any], person: [String: Any], roster: [[String: Any]]) async throws -> String {
        let org = try payeClaimsOrganizationRef()
        guard let uid = payeClaimsUid else { throw PayeClaimRefused(message: "You must be signed in.") }
        if let message = CanonicalBusinessEngine.priceWorkValidationError(draft: draft, person: person, roster: roster, organizationId: org.documentID) {
            throw PayeClaimRefused(message: message)
        }
        guard var fields = CanonicalBusinessEngine.priceWorkWriteFields(
            userId: uid,
            draft: draft,
            person: person,
            roster: roster,
            currency: OrganizationRulebookContext.currencyCode,
            organizationId: org.documentID
        ) else { throw PayeClaimRefused(message: "This price work cannot be added.") }
        fields["createdAt"] = FieldValue.serverTimestamp()
        let ref = org.collection(PayeClaimKind.priceWork.collection).document()
        try await ref.setData(WriteMetadata.stamped(fields, userId: uid))
        return ref.documentID
    }

    /// Add Expense: needs at least one piece of evidence (`expenseValidationError`), created with `expenseWriteFields`.
    func addExpense(draft: [String: Any]) async throws -> String {
        let org = try payeClaimsOrganizationRef()
        guard let uid = payeClaimsUid else { throw PayeClaimRefused(message: "You must be signed in.") }
        if let message = CanonicalBusinessEngine.expenseValidationError(draft: draft, organizationId: org.documentID, userId: uid) {
            throw PayeClaimRefused(message: message)
        }
        guard var fields = CanonicalBusinessEngine.expenseWriteFields(
            userId: uid,
            draft: draft,
            currency: OrganizationRulebookContext.currencyCode,
            organizationId: org.documentID
        ) else { throw PayeClaimRefused(message: "This expense cannot be added.") }
        fields["createdAt"] = FieldValue.serverTimestamp()
        let ref = org.collection(PayeClaimKind.expense.collection).document()
        try await ref.setData(WriteMetadata.stamped(fields, userId: uid))
        return ref.documentID
    }

    /// Deletes the person's own just-uploaded claim files that `payeClaimEvidenceToDelete` allows (inside the §24 undo
    /// window); every other file is kept. A refused or failed delete keeps the file (§24).
    func discardPayeClaimEvidence(_ evidence: [PayeClaimEvidence]) async {
        guard let orgId = payeClaimsOrganizationId, let uid = payeClaimsUid, !evidence.isEmpty else { return }
        let paths = CanonicalBusinessEngine.payeClaimEvidenceToDelete(evidence, organizationId: orgId, viewerUserId: uid)
        for path in paths {
            do {
                try await storage.reference().child(path).delete()
            } catch {
                print("⚠️ [PayeClaims] evidence kept, delete refused or failed for \(path): \(error.localizedDescription)")
            }
        }
    }

    /// The person removes one of their own items (`canWritePayeClaim`); evidence uploaded within the undo window goes too.
    func removePayeClaim(_ item: PayeClaimItem) async throws {
        let org = try payeClaimsOrganizationRef()
        guard let uid = payeClaimsUid, CanonicalBusinessEngine.canWritePayeClaim(viewerId: uid, itemUserId: item.userId),
              let kind = PayeClaimKind(rawValue: item.kind) else {
            throw PayeClaimRefused(message: "Only the person can remove their own items.")
        }
        try await org.collection(kind.collection).document(item.id).delete()
        await discardPayeClaimEvidence(item.evidence)
    }

    /// RULEBOOK 1.45.0 §26: Save changes on the person's own item (`canEditPayeClaim`). The draft is checked as a new
    /// item; only the changed fields are written (`priceWorkUpdateWriteFields` / `expenseUpdateWriteFields`, a partial
    /// `updateData` with write metadata). Evidence the edit removed is deleted only inside the §24 undo window
    /// (`claimEvidenceRemoved` → `payeClaimEvidenceToDelete`); every other file is kept for recovery.
    func updatePayeClaim(
        _ item: PayeClaimItem,
        draft: [String: Any],
        newEvidence: [PayeClaimEvidence],
        person: [String: Any],
        roster: [[String: Any]]
    ) async throws {
        let org = try payeClaimsOrganizationRef()
        guard let uid = payeClaimsUid, CanonicalBusinessEngine.canEditPayeClaim(viewerId: uid, item: item),
              let kind = PayeClaimKind(rawValue: item.kind) else {
            throw PayeClaimRefused(message: "Only the person can change their own items.")
        }
        let refusal: String?
        let write: PayeClaimUpdateWrite?
        if kind == .priceWork {
            refusal = CanonicalBusinessEngine.priceWorkValidationError(draft: draft, person: person, roster: roster, organizationId: org.documentID)
            write = refusal == nil ? CanonicalBusinessEngine.priceWorkUpdateWriteFields(
                item: item, userId: uid, draft: draft, person: person, roster: roster, organizationId: org.documentID
            ) : nil
        } else {
            refusal = CanonicalBusinessEngine.expenseValidationError(draft: draft, organizationId: org.documentID, userId: uid)
            write = refusal == nil ? CanonicalBusinessEngine.expenseUpdateWriteFields(
                item: item, userId: uid, draft: draft, organizationId: org.documentID
            ) : nil
        }
        if let refusal { throw PayeClaimRefused(message: refusal) }
        guard let write else { throw PayeClaimRefused(message: "This item cannot be changed.") }
        if !write.isEmpty {
            var fields = write.set
            for key in write.remove { fields[key] = FieldValue.delete() }
            try await org.collection(kind.collection).document(item.id).updateData(WriteMetadata.stamped(fields, userId: uid))
        }
        await discardPayeClaimEvidence(CanonicalBusinessEngine.claimEvidenceRemoved(item.evidence, after: newEvidence))
    }

    /// RULEBOOK 1.45.0 §8 / §24: after an owner's timesheet save, the evidence files it removed that may go
    /// (`timesheetEntryEvidenceToDelete`: the viewer's own, inside the undo window); every other file is kept.
    func discardRemovedTimesheetEvidence(before: [PayeClaimEvidence], after: [PayeClaimEvidence]) async {
        guard let orgId = payeClaimsOrganizationId, let uid = payeClaimsUid, !before.isEmpty else { return }
        let paths = CanonicalBusinessEngine.timesheetEntryEvidenceToDelete(
            before: before, after: after, organizationId: orgId, viewerUserId: uid
        )
        for path in paths {
            do {
                try await storage.reference().child(path).delete()
            } catch {
                print("⚠️ [Timesheet] evidence kept, delete refused or failed for \(path): \(error.localizedDescription)")
            }
        }
    }

    /// Generate price work / expenses report: saves the frozen copy (`payeClaimReportSnapshot`, written once) and returns
    /// it as read back, so the PDF is built from the saved copy.
    func savePayeClaimReport(
        kind: PayeClaimKind,
        person: AppUser,
        companyName: String,
        rangeStart: String,
        rangeEnd: String,
        items: [PayeClaimItem]
    ) async throws -> PayeClaimReportRecord {
        let org = try payeClaimsOrganizationRef()
        guard let uid = payeClaimsUid else { throw PayeClaimRefused(message: "You must be signed in.") }
        let name = person.fullName.isEmpty ? person.email : person.fullName
        guard var snapshot = CanonicalBusinessEngine.payeClaimReportSnapshot(
            kind: kind,
            userId: person.id,
            userName: name,
            companyName: companyName,
            currency: OrganizationRulebookContext.currencyCode,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            items: items,
            generatedBy: uid
        ) else { throw PayeClaimRefused(message: "The report could not be made.") }
        let collection = CanonicalBusinessEngine.payeClaimText("PAYE_CLAIM_REPORTS_COLLECTION", fallback: "payeClaimReports")
        let ref = org.collection(collection).document()
        var readBack = snapshot
        snapshot["generatedAt"] = FieldValue.serverTimestamp()
        try await ref.setData(WriteMetadata.stamped(snapshot, userId: uid))
        readBack["generatedAt"] = Date().timeIntervalSince1970 * 1000
        guard let record = CanonicalBusinessEngine.parsePayeClaimReportDocument(docId: ref.documentID, data: readBack) else {
            throw PayeClaimRefused(message: "The report was saved but could not be read back.")
        }
        return record
    }

    /// A self-employed person's timesheets (`settings` where `userId ==`, ids `timesheet_*`), each read through
    /// `parseTimesheetEntries`, as `{ id, entries }` for `timesheetClaimRows`.
    func loadTimesheetClaimSheets(userId: String) async throws -> [[String: Any]] {
        let org = try payeClaimsOrganizationRef()
        let snapshot = try await org.collection("settings").whereField("userId", isEqualTo: userId).getDocuments()
        return snapshot.documents
            .filter { $0.documentID.hasPrefix("timesheet_") }
            .compactMap { doc -> [String: Any]? in
                guard let entries = CanonicalBusinessEngine.parseTimesheetEntries(
                    sheetDocumentId: doc.documentID,
                    sheet: doc.data(),
                    organizationId: org.documentID,
                    ownerUserIds: RulebookRosterSnapshot.personIds(forUserId: userId)
                ) else {
                    return nil
                }
                return ["id": doc.documentID, "entries": entries.raw]
            }
    }

    // MARK: Payrun Snapshot (RULEBOOK 1.33.0 §7, admins; web `loadPayrunSnapshotInputs`)

    /// Every price work item, expense item and claim report of the company, read once through the rulebook readers.
    func loadPayrunSnapshotClaims() async throws -> (priceWork: [PayeClaimItem], expenses: [PayeClaimItem], reports: [PayeClaimReportRecord]) {
        let org = try payeClaimsOrganizationRef()
        let orgId = org.documentID
        let reportsCollection = CanonicalBusinessEngine.payeClaimText("PAYE_CLAIM_REPORTS_COLLECTION", fallback: "payeClaimReports")
        async let priceSnap = org.collection(PayeClaimKind.priceWork.collection).getDocuments()
        async let expenseSnap = org.collection(PayeClaimKind.expense.collection).getDocuments()
        async let reportSnap = org.collection(reportsCollection).getDocuments()
        let (priceDocs, expenseDocs, reportDocs) = try await (priceSnap, expenseSnap, reportSnap)
        return (
            priceDocs.documents.compactMap {
                CanonicalBusinessEngine.parsePayeClaimDocument(kind: .priceWork, docId: $0.documentID, data: $0.data(), organizationId: orgId)
            },
            expenseDocs.documents.compactMap {
                CanonicalBusinessEngine.parsePayeClaimDocument(kind: .expense, docId: $0.documentID, data: $0.data(), organizationId: orgId)
            },
            reportDocs.documents.compactMap { CanonicalBusinessEngine.parsePayeClaimReportDocument(docId: $0.documentID, data: $0.data()) }
        )
    }

    /// The timesheets of the given people (`settings` where `userId ==`, one query per id, the query User Timesheets
    /// already makes), read through `parsePayrunSnapshotSheet`. A failed read leaves that person's sheets out.
    func loadPayrunSnapshotSheets(userIds: [String]) async -> [[String: Any]] {
        guard let org = try? payeClaimsOrganizationRef() else { return [] }
        var seen = Set<String>()
        let ids = userIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        var out: [[String: Any]] = []
        for id in ids {
            guard let snapshot = try? await org.collection("settings").whereField("userId", isEqualTo: id).getDocuments() else { continue }
            for doc in snapshot.documents {
                let data = FirebaseBackend.firestoreJSON(doc.data()) as? [String: Any] ?? [:]
                if let sheet = CanonicalBusinessEngine.parsePayrunSnapshotSheet(docId: doc.documentID, data: data) { out.append(sheet) }
            }
        }
        return out
    }

    /// The bytes of a stored file (the Storage rules decide who may read it). 25 MB cap.
    func payeClaimStoredFileData(path: String) async throws -> Data {
        let storageRef = storage.reference().child(path)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            storageRef.getData(maxSize: 25 * 1024 * 1024) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NSError(domain: "StorageReference", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
    }

    // MARK: Personal site audits (owner only)

    /// Live personal site audits of the signed-in person only (`ownerUserId ==`; nobody else can read them),
    /// newest first (`personalSiteAuditsFor`).
    func listenPersonalSiteAudits(
        onChange: @escaping ([PersonalSiteAudit]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration? {
        guard let org = try? payeClaimsOrganizationRef(), let uid = payeClaimsUid else { return nil }
        let collection = CanonicalBusinessEngine.payeClaimText("PERSONAL_SITE_AUDITS_COLLECTION", fallback: "personalSiteAudits")
        return org.collection(collection).whereField("ownerUserId", isEqualTo: uid).addSnapshotListener { snapshot, error in
            if let error {
                Task { @MainActor in onError(error) }
                return
            }
            let rows = (snapshot?.documents ?? []).compactMap { doc in
                CanonicalBusinessEngine.parsePersonalSiteAuditDocument(docId: doc.documentID, data: doc.data())
            }
            let sorted = CanonicalBusinessEngine.personalSiteAuditsFor(rows, viewerUserId: uid)
            Task { @MainActor in onChange(sorted) }
        }
    }

    /// Uploads one personal audit photo (JPEG) into the owner's folder (`personalSiteAuditImagePath`); returns its path.
    func uploadPersonalSiteAuditPhoto(auditId: String, jpegData: Data) async throws -> String {
        guard let orgId = payeClaimsOrganizationId, let uid = payeClaimsUid,
              let path = CanonicalBusinessEngine.personalSiteAuditImagePath(
                organizationId: orgId,
                ownerUserId: uid,
                auditId: auditId,
                unixMs: StorageUploadPolicy.unixMillisecondsNow(),
                fileExtension: "jpg"
              ) else {
            throw PayeClaimRefused(message: "You must be signed in to upload photos.")
        }
        try await putPayeClaimData(jpegData, path: path, contentType: "image/jpeg")
        return path
    }

    /// Deletes the owner's just-uploaded audit photos after a refused save (the uploader's §24 undo window, checked by
    /// `fileDeletePermission`). A refused or failed delete keeps the file.
    func discardPersonalSiteAuditPhotos(_ paths: [String]) async {
        guard let orgId = payeClaimsOrganizationId, let uid = payeClaimsUid else { return }
        for path in paths {
            let permission = CanonicalBusinessEngine.fileDeletePermission(
                storagePath: path,
                organizationId: orgId,
                viewerUserId: uid,
                viewerRole: CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: false, isManager: false, isOperativeMode: false)
            )
            guard permission.allowed else { continue }
            do {
                try await storage.reference().child(path).delete()
            } catch {
                print("⚠️ [PersonalSiteAudits] photo kept, delete refused or failed for \(path): \(error.localizedDescription)")
            }
        }
    }

    /// Create Personal Site Audit (`personalSiteAuditWriteFields`); the document id is the one its photos were filed under.
    func savePersonalSiteAudit(auditId: String, draft: [String: Any]) async throws {
        let org = try payeClaimsOrganizationRef()
        guard let uid = payeClaimsUid else { throw PayeClaimRefused(message: "You must be signed in.") }
        if let message = CanonicalBusinessEngine.personalSiteAuditValidationError(draft: draft, organizationId: org.documentID, ownerUserId: uid) {
            throw PayeClaimRefused(message: message)
        }
        guard var fields = CanonicalBusinessEngine.personalSiteAuditWriteFields(ownerUserId: uid, draft: draft, organizationId: org.documentID) else {
            throw PayeClaimRefused(message: "This audit cannot be saved.")
        }
        fields["createdAt"] = FieldValue.serverTimestamp()
        let collection = CanonicalBusinessEngine.payeClaimText("PERSONAL_SITE_AUDITS_COLLECTION", fallback: "personalSiteAudits")
        try await org.collection(collection).document(auditId).setData(WriteMetadata.stamped(fields, userId: uid))
    }

    /// Attach a personal site audit: upload its frozen PDF copy into the claim folder and return the evidence entry
    /// (`personalSiteAuditEvidence`).
    func attachPersonalSiteAuditCopy(_ audit: PersonalSiteAudit, pdfData: Data) async throws -> PayeClaimEvidence {
        let uploaded = try await uploadPayeClaimEvidence(
            data: pdfData,
            name: "audit.pdf",
            contentType: "application/pdf",
            kind: "personalSiteAudit",
            auditId: audit.id
        )
        return CanonicalBusinessEngine.personalSiteAuditEvidence(audit, path: uploaded.path) ?? uploaded
    }
}
