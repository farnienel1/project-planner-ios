//
//  FirebaseBackend+Overtime.swift
//  Project Planner
//
//  RULEBOOK 1.29.0 §4.5, §25: PAYE overtime reads and writes, the iOS counterpart of web `lib/overtime/overtimeData.ts`.
//  Every rule is in the packed script (`Rulebook+PayeOvertime.swift`); this file only reads documents through the
//  rulebook readers and turns the rulebook's write fields into Firestore calls with write metadata. Online only
//  (no offline queue; `offlineAvailability` of an unlisted action is online only).
//
//  RULEBOOK 1.33.0: Send for approval withdraws the requests it supersedes (`overtimeRequestsSuperseded`); Return
//  overtime is one transaction from `overtimeReturnWrites` (booking writes, booking deletes with their tombstone naming
//  the request, reviews, the request); a direct red X on an all-overtime day deletes the booking with its tombstone.
//

import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

/// Why a Return was refused (`overtimeReturnWrites` → `notPending` / `undecided`, with the script's message): nothing
/// was written.
nonisolated struct OvertimeReturnRefused: LocalizedError {
    let message: String
    let bookingIds: [String]
    var errorDescription: String? { message }
}

/// What a Return returned, sent back to the person and left out (1.33.0), and the script's `message`.
nonisolated struct OvertimeReturnResult: Sendable {
    var appliedBookingIds: [String]
    var staleBookingIds: [String]
    var deletedBookingIds: [String]
    var droppedBookingIds: [String]
    /// `overtimeReturnMessage`: "Returned 5 lines. …".
    var message: String
    var requesterUserId: String
    var rangeStart: String
}

/// The person's booking rows per query, joined on every snapshot.
final class OvertimeBookingParts {
    var parts: [String: [OvertimeBookingInput]] = [:]
}

/// Live listeners the Overtime screens hold while open. `stop()` removes them all.
final class OvertimeListeners {
    private var registrations: [ListenerRegistration] = []

    func add(_ registration: ListenerRegistration) { registrations.append(registration) }

    func stop() {
        registrations.forEach { $0.remove() }
        registrations = []
    }

    deinit { registrations.forEach { $0.remove() } }
}

extension FirebaseBackend {
    private func overtimeOrganizationRef() throws -> DocumentReference {
        guard let orgId = currentOrganization?.firestoreDocumentId, !orgId.isEmpty else {
            throw NSError(domain: "FirebaseBackend", code: 0, userInfo: [NSLocalizedDescriptionKey: "No organization loaded"])
        }
        return db.collection("organizations").document(orgId)
    }

    private var overtimeUid: String? { auth.currentUser?.uid }

    // MARK: Reads (LIVE_COLLECTIONS overtimeRequests / overtimeReviews listen while the screen is open)

    /// Live overtime requests of one person (`parseOvertimeRequestDocument`), newest first.
    func listenOvertimeRequests(
        userId: String,
        onChange: @escaping ([OvertimeRequestRecord]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration? {
        guard let org = try? overtimeOrganizationRef() else { return nil }
        return org.collection("overtimeRequests").whereField("userId", isEqualTo: userId).addSnapshotListener { snapshot, error in
            if let error {
                Task { @MainActor in onError(error) }
                return
            }
            let rows = (snapshot?.documents ?? []).compactMap { doc in
                CanonicalBusinessEngine.parseOvertimeRequestDocument(
                    docId: doc.documentID,
                    data: FirebaseBackend.firestoreJSON(doc.data()) as? [String: Any] ?? [:]
                )
            }
            let sorted = rows.sorted { ($0.createdAtMs ?? 0) > ($1.createdAtMs ?? 0) }
            Task { @MainActor in onChange(sorted) }
        }
    }

    /// Live approved lines of one person (`parseOvertimeReviewDocument`).
    func listenOvertimeReviews(
        userId: String,
        onChange: @escaping ([OvertimeReviewRecord]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration? {
        guard let org = try? overtimeOrganizationRef() else { return nil }
        return org.collection("overtimeReviews").whereField("userId", isEqualTo: userId).addSnapshotListener { snapshot, error in
            if let error {
                Task { @MainActor in onError(error) }
                return
            }
            let rows = (snapshot?.documents ?? []).compactMap { doc in
                CanonicalBusinessEngine.parseOvertimeReviewDocument(
                    docId: doc.documentID,
                    data: FirebaseBackend.firestoreJSON(doc.data()) as? [String: Any] ?? [:]
                )
            }
            Task { @MainActor in onChange(rows) }
        }
    }

    /// Saved reports of one person (`parseOvertimeReportDocument`), newest first. `listen: false`: read on open.
    func loadOvertimeReports(userId: String) async throws -> [OvertimeReportRecord] {
        let org = try overtimeOrganizationRef()
        let snapshot = try await org.collection("overtimeReports").whereField("userId", isEqualTo: userId).getDocuments()
        return snapshot.documents
            .compactMap { doc in
                CanonicalBusinessEngine.parseOvertimeReportDocument(
                    docId: doc.documentID,
                    data: FirebaseBackend.firestoreJSON(doc.data()) as? [String: Any] ?? [:]
                )
            }
            .sorted { ($0.generatedAtMs ?? 0) > ($1.generatedAtMs ?? 0) }
    }

    /// Live bookings of one person for the Overtime screens (web `listenPersonOvertimeBookings`): labour bookings under
    /// each of their ids (`operativeId ==`, one query per id, as the read rules require) and their manager site bookings
    /// (`userId ==`), read through `parseBookingDocument` / `parseManagerSiteBookingDocument`. Job number and name come
    /// from `jobs`.
    func listenPersonOvertimeBookings(
        operativeIds: [String],
        userIds: [String],
        jobs: @escaping () -> [Project],
        into listeners: OvertimeListeners,
        onChange: @escaping ([OvertimeBookingInput]) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard let org = try? overtimeOrganizationRef() else { return }
        let box = OvertimeBookingParts()
        let emit: @MainActor () -> Void = {
            var seen = Set<String>()
            var out: [OvertimeBookingInput] = []
            for key in box.parts.keys.sorted() {
                for row in box.parts[key] ?? [] where seen.insert(row.lookupKey).inserted { out.append(row) }
            }
            onChange(OvertimeBookingInputs.withJobs(out, jobs: jobs()))
        }
        for id in Array(Set(operativeIds.filter { !$0.isEmpty })).sorted() {
            let key = "b:\(id)"
            listeners.add(org.collection("bookings").whereField("operativeId", isEqualTo: id).addSnapshotListener { snapshot, error in
                if let error {
                    Task { @MainActor in onError(error) }
                    return
                }
                let payload: [[String: Any]] = (snapshot?.documents ?? []).map {
                    ["id": $0.documentID, "data": FirebaseBackend.firestoreJSON($0.data())]
                }
                let rows = (CanonicalBusinessEngine.parseBookingDocuments(payload) ?? []).map { OvertimeBookingInputs.labour($0) }
                Task { @MainActor in
                    box.parts[key] = rows
                    emit()
                }
            })
        }
        for id in Array(Set(userIds.filter { !$0.isEmpty })).sorted() {
            let key = "m:\(id)"
            listeners.add(org.collection("managerSiteBookings").whereField("userId", isEqualTo: id).addSnapshotListener { snapshot, error in
                if let error {
                    Task { @MainActor in onError(error) }
                    return
                }
                let payload: [[String: Any]] = (snapshot?.documents ?? []).map {
                    ["id": $0.documentID, "data": FirebaseBackend.firestoreJSON($0.data())]
                }
                let rows = OvertimeBookingInputs.managerSite(documents: payload)
                Task { @MainActor in
                    box.parts[key] = rows
                    emit()
                }
            })
        }
    }

    // MARK: Requests (the PAYE person)

    /// Send for approval (web `sendOvertimeRequest`, 1.33.0): `lines` come from `overtimeSubmitLines`. Withdraws the
    /// person's pending requests every waiting line of which is sent again (`overtimeRequestsSuperseded`) and creates
    /// the new one (`overtimeRequestWriteFields`) in one batch. Returns the new request id, or nil with no lines.
    func sendOvertimeRequest(
        requester: AppUser,
        rangeStart: String,
        rangeEnd: String,
        lines: [[String: Any]],
        existing: [OvertimeRequestRecord],
        personIds: [String],
        bookings: [OvertimeBookingInput]
    ) async throws -> String? {
        let org = try overtimeOrganizationRef()
        guard let fields = CanonicalBusinessEngine.overtimeRequestWriteFields(
            userId: requester.id,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            lines: lines,
            personIds: personIds,
            bookings: bookings
        ) else { return nil }
        let uid = overtimeUid
        let batch = db.batch()
        let sentIds = lines.compactMap { $0["bookingId"] as? String }
        for id in CanonicalBusinessEngine.overtimeRequestsSuperseded(existing, userId: requester.id, bookingIds: sentIds) {
            batch.updateData(
                WriteMetadata.stamped(["status": "withdrawn", "withdrawnAt": FieldValue.serverTimestamp()], userId: uid),
                forDocument: org.collection("overtimeRequests").document(id)
            )
        }
        let ref = org.collection("overtimeRequests").document()
        var create = fields
        create["createdAt"] = FieldValue.serverTimestamp()
        batch.setData(WriteMetadata.stamped(create, userId: uid), forDocument: ref)
        try await batch.commit()
        return ref.documentID
    }

    /// The person withdraws their pending request (`overtimeRequestWithdrawWriteFields`).
    func withdrawOvertimeRequest(_ request: OvertimeRequestRecord) async throws {
        guard var fields = CanonicalBusinessEngine.overtimeRequestWithdrawWriteFields(request) else { return }
        fields["withdrawnAt"] = FieldValue.serverTimestamp()
        try await overtimeOrganizationRef().collection("overtimeRequests").document(request.id)
            .updateData(WriteMetadata.stamped(fields, userId: overtimeUid))
    }

    // MARK: Return (line manager or admin, one transaction)

    /// Return overtime (web `returnOvertimeRequest`, 1.33.0): bookings the decider cannot read are left out (never read
    /// inside the transaction); then one transaction re-reads the request and every booking and writes everything
    /// `overtimeReturnWrites` says together — booking changes, the deletes of all-overtime bookings an approved red X
    /// removes (each with its tombstone carrying `overtimeRequestId`), one review per returned line and the request
    /// (`approved`, `staleBookingIds`, `deletedBookingIds`). Throws `OvertimeReturnRefused` with the script's message.
    func returnOvertimeRequest(
        requestId: String,
        decisions: [String: OvertimeAction],
        organization: [String: Any],
        deciderId: String,
        requesterIds: [String]
    ) async throws -> OvertimeReturnResult {
        let org = try overtimeOrganizationRef()
        let requestRef = org.collection("overtimeRequests").document(requestId)
        var unreadable: [String] = []
        let before = try await requestRef.getDocument()
        if before.exists,
           let pre = CanonicalBusinessEngine.parseOvertimeRequestDocument(
            docId: before.documentID,
            data: FirebaseBackend.firestoreJSON(before.data() ?? [:]) as? [String: Any] ?? [:]
           ) {
            for line in pre.lines {
                do {
                    _ = try await org.collection(line.collection).document(line.bookingId).getDocument()
                } catch {
                    let nsError = error as NSError
                    // Firestore permission-denied (code 7): the rules do not let this decider read the booking.
                    if nsError.domain == "FIRFirestoreErrorDomain", nsError.code == 7 {
                        unreadable.append(line.bookingId)
                    } else {
                        throw error
                    }
                }
            }
        }
        return try await Self.runOvertimeReturn(
            db: db,
            org: org,
            requestRef: requestRef,
            decisions: decisions,
            organization: organization,
            deciderId: deciderId,
            requesterIds: requesterIds,
            unreadable: unreadable,
            uid: overtimeUid
        )
    }

    nonisolated private static func runOvertimeReturn(
        db: Firestore,
        org: DocumentReference,
        requestRef: DocumentReference,
        decisions: [String: OvertimeAction],
        organization: [String: Any],
        deciderId: String,
        requesterIds: [String],
        unreadable: [String],
        uid: String?
    ) async throws -> OvertimeReturnResult {
        let answer = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let requestSnap = try transaction.getDocument(requestRef)
                guard requestSnap.exists,
                      let request = CanonicalBusinessEngine.parseOvertimeRequestDocument(
                        docId: requestSnap.documentID,
                        data: FirebaseBackend.firestoreJSON(requestSnap.data() ?? [:]) as? [String: Any] ?? [:]
                      ) else {
                    errorPointer?.pointee = OvertimeReturnRefused(message: "This request no longer exists.", bookingIds: []) as NSError
                    return nil
                }
                var live: [String: OvertimeBookingInput] = [:]
                for line in request.lines where !unreadable.contains(line.bookingId) {
                    let snap = try transaction.getDocument(org.collection(line.collection).document(line.bookingId))
                    guard snap.exists, let data = snap.data() else { continue }
                    let payload: [[String: Any]] = [["id": snap.documentID, "data": FirebaseBackend.firestoreJSON(data)]]
                    let parsed: OvertimeBookingInput?
                    if line.collection == "managerSiteBookings" {
                        parsed = OvertimeBookingInputs.managerSite(documents: payload).first
                    } else {
                        parsed = CanonicalBusinessEngine.parseBookingDocuments(payload)?.first.map { OvertimeBookingInputs.labour($0) }
                    }
                    if let parsed { live[line.bookingId] = parsed }
                }
                guard let plan = CanonicalBusinessEngine.overtimeReturnWrites(
                    request: request,
                    decisions: decisions,
                    bookings: live,
                    organization: organization,
                    deciderId: deciderId,
                    requesterIds: requesterIds,
                    unreadableBookingIds: unreadable
                ) else {
                    errorPointer?.pointee = CanonicalWriteUnavailableError(function: "overtimeReturnWrites") as NSError
                    return nil
                }
                guard plan.ok else {
                    errorPointer?.pointee = OvertimeReturnRefused(message: plan.message, bookingIds: plan.bookingIds) as NSError
                    return nil
                }
                for write in plan.bookingWrites {
                    var update = write.set
                    for key in write.remove { update[key] = FieldValue.delete() }
                    transaction.updateData(
                        WriteMetadata.stamped(update, userId: uid),
                        forDocument: org.collection(write.collection).document(write.bookingId)
                    )
                }
                // 1.33.0 item f: the booking and its tombstone (naming the request) in the same transaction. The
                // tombstone carries only its own fields plus the server `deletedAt` (the rules allow nothing else).
                for delete in plan.bookingDeletes {
                    var tombstone = delete.tombstone
                    tombstone["deletedAt"] = FieldValue.serverTimestamp()
                    transaction.deleteDocument(org.collection(delete.collection).document(delete.bookingId))
                    transaction.setData(tombstone, forDocument: org.collection(CanonicalBusinessEngine.bookingTombstoneCollection).document(delete.bookingId))
                }
                for review in plan.reviewWrites {
                    var fields = review.fields
                    fields["reviewedAt"] = FieldValue.serverTimestamp()
                    transaction.setData(
                        WriteMetadata.stamped(fields, userId: uid),
                        forDocument: org.collection("overtimeReviews").document(review.docId)
                    )
                }
                var requestUpdate = plan.requestFields
                requestUpdate["decidedAt"] = FieldValue.serverTimestamp()
                transaction.updateData(WriteMetadata.stamped(requestUpdate, userId: uid), forDocument: requestRef)
                return [
                    "applied": plan.appliedBookingIds,
                    "stale": plan.staleBookingIds,
                    "deleted": plan.deletedBookingIds,
                    "dropped": plan.droppedBookingIds,
                    "message": plan.message,
                    "userId": request.userId,
                    "rangeStart": request.rangeStart,
                ] as NSDictionary
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }
        let row = answer as? [String: Any] ?? [:]
        return OvertimeReturnResult(
            appliedBookingIds: row["applied"] as? [String] ?? [],
            staleBookingIds: row["stale"] as? [String] ?? [],
            deletedBookingIds: row["deleted"] as? [String] ?? [],
            droppedBookingIds: row["dropped"] as? [String] ?? [],
            message: row["message"] as? String ?? "",
            requesterUserId: row["userId"] as? String ?? "",
            rangeStart: row["rangeStart"] as? String ?? ""
        )
    }

    // MARK: Direct changes (PAYE admin, or a PAYE manager who may edit the booking)

    /// A direct tick, cross or cog (`overtimeDirectWrites`): the booking change — 1.33.0 or its delete with the tombstone,
    /// for a red X on an all-overtime day — and the line's review in one batch. Returns the plan (its `hoursChanged`
    /// sends `booking_hours_changed_by_owner`), or nil when not allowed.
    func applyDirectOvertime(
        booking: OvertimeBookingInput,
        action: OvertimeAction,
        person: AppUser,
        organization: [String: Any]
    ) async throws -> OvertimeDirectPlan? {
        let org = try overtimeOrganizationRef()
        guard let plan = CanonicalBusinessEngine.overtimeDirectWrites(
            booking,
            action: action,
            userId: person.id,
            reviewerId: person.id,
            organization: organization
        ) else { return nil }
        let uid = overtimeUid
        let batch = db.batch()
        if let delete = plan.bookingDelete {
            var tombstone = delete.tombstone
            tombstone["deletedAt"] = FieldValue.serverTimestamp()
            batch.deleteDocument(org.collection(delete.collection).document(delete.bookingId))
            batch.setData(tombstone, forDocument: org.collection(CanonicalBusinessEngine.bookingTombstoneCollection).document(delete.bookingId))
        }
        if let write = plan.bookingWrite {
            var update = write.set
            for key in write.remove { update[key] = FieldValue.delete() }
            batch.updateData(WriteMetadata.stamped(update, userId: uid), forDocument: org.collection(write.collection).document(write.bookingId))
        }
        var review = plan.reviewWrite.fields
        review["reviewedAt"] = FieldValue.serverTimestamp()
        batch.setData(WriteMetadata.stamped(review, userId: uid), forDocument: org.collection("overtimeReviews").document(plan.reviewWrite.docId))
        try await batch.commit()
        return plan
    }

    // MARK: Reports

    /// Generate overtime report: saves the snapshot (`overtimeReportSnapshot`, written once) and returns it as read back.
    func saveOvertimeReport(
        person: AppUser,
        companyName: String,
        rangeStart: String,
        rangeEnd: String,
        lines: [OvertimeLine]
    ) async throws -> OvertimeReportRecord? {
        let org = try overtimeOrganizationRef()
        let name = person.fullName.isEmpty ? person.email : person.fullName
        guard var snapshot = CanonicalBusinessEngine.overtimeReportSnapshot(
            userId: person.id,
            userName: name,
            companyName: companyName,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            lines: lines,
            generatedBy: person.id
        ) else { return nil }
        let ref = org.collection("overtimeReports").document()
        let copy = snapshot
        snapshot["generatedAt"] = FieldValue.serverTimestamp()
        try await ref.setData(WriteMetadata.stamped(snapshot, userId: overtimeUid))
        var readBack = copy
        readBack["generatedAt"] = Date().timeIntervalSince1970 * 1000
        return CanonicalBusinessEngine.parseOvertimeReportDocument(docId: ref.documentID, data: readBack)
    }

    // MARK: One-off reads (reopen notice, Payrun Snapshot)

    /// One person's overtime reviews and requests, read once (`overtimeLineReopened`). Nil when this account may not
    /// read them (only admins, the person and their line manager may): the rule then treats any overtime change as
    /// reopened, as web `overtimeReopenNotice.ts`.
    func readOvertimeRecords(userId: String) async -> (reviews: [OvertimeReviewRecord], requests: [OvertimeRequestRecord])? {
        guard let org = try? overtimeOrganizationRef() else { return nil }
        do {
            async let reviewSnap = org.collection("overtimeReviews").whereField("userId", isEqualTo: userId).getDocuments()
            async let requestSnap = org.collection("overtimeRequests").whereField("userId", isEqualTo: userId).getDocuments()
            let (reviewDocs, requestDocs) = try await (reviewSnap, requestSnap)
            let reviews = reviewDocs.documents.compactMap { doc in
                CanonicalBusinessEngine.parseOvertimeReviewDocument(
                    docId: doc.documentID,
                    data: FirebaseBackend.firestoreJSON(doc.data()) as? [String: Any] ?? [:]
                )
            }
            let requests = requestDocs.documents.compactMap { doc in
                CanonicalBusinessEngine.parseOvertimeRequestDocument(
                    docId: doc.documentID,
                    data: FirebaseBackend.firestoreJSON(doc.data()) as? [String: Any] ?? [:]
                )
            }
            return (reviews, requests)
        } catch {
            return nil
        }
    }

    /// Payrun Snapshot (admins, web `loadPayrunSnapshotInputs`): every overtime request, review and report of the
    /// company, read once through the rulebook readers.
    func loadAllOvertimeRecords() async throws -> (
        requests: [OvertimeRequestRecord],
        reviews: [OvertimeReviewRecord],
        reports: [OvertimeReportRecord]
    ) {
        let org = try overtimeOrganizationRef()
        async let requestSnap = org.collection("overtimeRequests").getDocuments()
        async let reviewSnap = org.collection("overtimeReviews").getDocuments()
        async let reportSnap = org.collection("overtimeReports").getDocuments()
        let (requestDocs, reviewDocs, reportDocs) = try await (requestSnap, reviewSnap, reportSnap)
        func json(_ data: [String: Any]) -> [String: Any] { FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? [:] }
        return (
            requestDocs.documents.compactMap { CanonicalBusinessEngine.parseOvertimeRequestDocument(docId: $0.documentID, data: json($0.data())) },
            reviewDocs.documents.compactMap { CanonicalBusinessEngine.parseOvertimeReviewDocument(docId: $0.documentID, data: json($0.data())) },
            reportDocs.documents.compactMap { CanonicalBusinessEngine.parseOvertimeReportDocument(docId: $0.documentID, data: json($0.data())) }
        )
    }
}
