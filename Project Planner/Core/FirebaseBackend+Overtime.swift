//
//  FirebaseBackend+Overtime.swift
//  Project Planner
//
//  RULEBOOK 1.29.0 §4.5, §25: PAYE overtime reads and writes, the iOS counterpart of web `lib/overtime/overtimeData.ts`.
//  Every rule is in the packed script (`Rulebook+PayeOvertime.swift`); this file only reads documents through the
//  rulebook readers and turns the rulebook's write fields into Firestore calls with write metadata. Online only
//  (no offline queue; `offlineAvailability` of an unlisted action is online only).
//

import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

/// Why an approval was refused (`overtimeApprovalWrites` → `notPending` / `nothingApproved`, with the script's
/// `reviewApprovalMessage`): nothing was written.
nonisolated struct OvertimeApprovalRefused: LocalizedError {
    let message: String
    let bookingIds: [String]
    var errorDescription: String? { message }
}

/// What an approval applied, left waiting and left out (1.32.0 partial approval), and the script's `message`.
nonisolated struct OvertimeApprovalResult: Sendable {
    var appliedBookingIds: [String]
    var waitingBookingIds: [String]
    var droppedBookingIds: [String]
    var deletedBookingIds: [String]
    var unreadableBookingIds: [String]
    var foreignBookingIds: [String]
    var lineOutcomes: [String: String]
    /// True when the request is now approved (nothing left waiting); otherwise it stays `pending`.
    var complete: Bool
    /// `reviewApprovalMessage`: "Approved 2 of 5. …".
    var message: String
    var requesterUserId: String
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

    /// Send for approval: withdraws the person's pending request for the same range (`overtimeRequestsToReplace`) and
    /// creates the new one (`overtimeRequestWriteFields`) in one batch. Returns the new request id, or nil with no lines.
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
        for id in CanonicalBusinessEngine.overtimeRequestsToReplace(existing, userId: requester.id, rangeStart: rangeStart, rangeEnd: rangeEnd) {
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

    // MARK: Approval (line manager or admin, one transaction)

    /// Approve (web `approveOvertimeRequest`): bookings the decider cannot read are left out (never read inside the
    /// transaction); then one transaction re-reads the request and every booking and applies what `overtimeApprovalWrites`
    /// lets this decider apply (1.32.0 partial approval: a changed booking or a line that needs an admin stays waiting),
    /// writing the bookings, one review per applied line and the request (still `pending` until complete) together.
    /// Throws `OvertimeApprovalRefused` with the script's message when nothing applies.
    func approveOvertimeRequest(
        requestId: String,
        decisions: [String: OvertimeAction],
        organization: [String: Any],
        deciderId: String,
        requesterIds: [String],
        deciderIsAdmin: Bool,
        canWriteBooking: @escaping @Sendable (OvertimeBookingInput) -> Bool
    ) async throws -> OvertimeApprovalResult {
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
        return try await Self.runOvertimeApproval(
            db: db,
            org: org,
            requestRef: requestRef,
            decisions: decisions,
            organization: organization,
            deciderId: deciderId,
            requesterIds: requesterIds,
            deciderIsAdmin: deciderIsAdmin,
            unreadable: unreadable,
            uid: overtimeUid,
            canWriteBooking: canWriteBooking
        )
    }

    nonisolated private static func runOvertimeApproval(
        db: Firestore,
        org: DocumentReference,
        requestRef: DocumentReference,
        decisions: [String: OvertimeAction],
        organization: [String: Any],
        deciderId: String,
        requesterIds: [String],
        deciderIsAdmin: Bool,
        unreadable: [String],
        uid: String?,
        canWriteBooking: @escaping @Sendable (OvertimeBookingInput) -> Bool
    ) async throws -> OvertimeApprovalResult {
        let answer = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let requestSnap = try transaction.getDocument(requestRef)
                guard requestSnap.exists,
                      let request = CanonicalBusinessEngine.parseOvertimeRequestDocument(
                        docId: requestSnap.documentID,
                        data: FirebaseBackend.firestoreJSON(requestSnap.data() ?? [:]) as? [String: Any] ?? [:]
                      ) else {
                    errorPointer?.pointee = OvertimeApprovalRefused(message: "This request no longer exists.", bookingIds: []) as NSError
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
                guard let plan = CanonicalBusinessEngine.overtimeApprovalWrites(
                    request: request,
                    decisions: decisions,
                    bookings: live,
                    organization: organization,
                    deciderId: deciderId,
                    requesterIds: requesterIds,
                    deciderIsAdmin: deciderIsAdmin,
                    writableBookingIds: live.values.filter { canWriteBooking($0) }.map(\.id),
                    unreadableBookingIds: unreadable
                ) else {
                    errorPointer?.pointee = CanonicalWriteUnavailableError(function: "overtimeApprovalWrites") as NSError
                    return nil
                }
                guard plan.ok else {
                    errorPointer?.pointee = OvertimeApprovalRefused(message: plan.message, bookingIds: plan.bookingIds) as NSError
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
                    "waiting": plan.waitingBookingIds,
                    "dropped": plan.droppedBookingIds,
                    "deleted": plan.deletedBookingIds,
                    "unreadable": plan.unreadableBookingIds,
                    "foreign": plan.foreignBookingIds,
                    "outcomes": plan.lineOutcomes,
                    "complete": plan.complete,
                    "message": plan.message,
                    "userId": request.userId,
                ] as NSDictionary
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }
        let row = answer as? [String: Any] ?? [:]
        return OvertimeApprovalResult(
            appliedBookingIds: row["applied"] as? [String] ?? [],
            waitingBookingIds: row["waiting"] as? [String] ?? [],
            droppedBookingIds: row["dropped"] as? [String] ?? [],
            deletedBookingIds: row["deleted"] as? [String] ?? [],
            unreadableBookingIds: row["unreadable"] as? [String] ?? [],
            foreignBookingIds: row["foreign"] as? [String] ?? [],
            lineOutcomes: row["outcomes"] as? [String: String] ?? [:],
            complete: row["complete"] as? Bool ?? false,
            message: row["message"] as? String ?? "",
            requesterUserId: row["userId"] as? String ?? ""
        )
    }

    // MARK: Direct changes (PAYE admin, or a PAYE manager who may edit the booking)

    /// A direct tick, cross or cog (`overtimeDirectWrites`): the booking change and the line's review in one batch.
    /// Returns the plan's `hoursChanged` (then `booking_hours_changed_by_owner` goes out), or nil when not allowed.
    func applyDirectOvertime(
        booking: OvertimeBookingInput,
        action: OvertimeAction,
        person: AppUser,
        organization: [String: Any]
    ) async throws -> Bool? {
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
        if let write = plan.bookingWrite {
            var update = write.set
            for key in write.remove { update[key] = FieldValue.delete() }
            batch.updateData(WriteMetadata.stamped(update, userId: uid), forDocument: org.collection(write.collection).document(write.bookingId))
        }
        var review = plan.reviewWrite.fields
        review["reviewedAt"] = FieldValue.serverTimestamp()
        batch.setData(WriteMetadata.stamped(review, userId: uid), forDocument: org.collection("overtimeReviews").document(plan.reviewWrite.docId))
        try await batch.commit()
        return plan.hoursChanged
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
}
