//
//  HolidayStore.swift
//  Project Planner
//

import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

@MainActor
class HolidayStore: ObservableObject {
    @Published var bookings: [HolidayBooking] = [] {
        didSet { revision &+= 1 }
    }
    /// Bumped on every change to `bookings`, so booking-flow conflict checks can be memoised per data version.
    private(set) var revision = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// The organisation whose annual leave last finished loading (read, listener snapshot, or failed).
    /// Warnings wait for it (`WarningInputsReadiness`): leave not read yet must not list people as unbooked.
    private(set) var finishedLoadOrganizationId: String?

    private var firebaseBackend: FirebaseBackend?
    private var smartCache: SmartCacheService?
    private var isLoadingInFlight = false

    init() {
        NotificationCenter.default.addObserver(
            forName: .organizationDidLoad,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.firebaseBackend?.hasBootstrappedOrgDataLoad == true else { return }
                // Bootstrap owns holiday loads; avoid a post-bootstrap duplicate fetch.
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func resolveOrganizationId() async throws -> String {
        guard let fb = firebaseBackend, fb.isAuthenticated else {
            throw NSError(domain: "HolidayStore", code: 401, userInfo: [NSLocalizedDescriptionKey: "You must be signed in to manage holidays."])
        }

        if let orgId = fb.currentOrganization?.firestoreDocumentId, !orgId.isEmpty {
            return orgId
        }

        if let userId = fb.currentUser?.uid {
            await fb.loadUserOrganizationWithRecovery(userId: userId)
        }

        if let orgId = fb.currentOrganization?.firestoreDocumentId, !orgId.isEmpty {
            return orgId
        }

        throw NSError(domain: "HolidayStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Organization not loaded yet. Please try again in a moment."])
    }

    func setFirebaseBackend(_ backend: FirebaseBackend) {
        firebaseBackend = backend
    }

    func setSmartCache(_ smartCache: SmartCacheService) {
        self.smartCache = smartCache
    }

    // MARK: Offline (RULEBOOK §2: annual leave requests are allowed offline)

    private var isOffline: Bool { smartCache?.isOnline == false }

    /// "Pending sync": this request has a queued change the server has not confirmed.
    func isPendingSync(_ booking: HolidayBooking) -> Bool {
        OfflineOutboxStore.shared.hasPendingSync(entityId: booking.documentId)
    }

    /// The signed-in person's own request: only those are queued offline. Deciding or booking leave for someone
    /// else is an approval (online only, `approvals.annual_leave`).
    private func isOwnRequest(_ booking: HolidayBooking) -> Bool {
        guard let uid = firebaseBackend?.currentUser?.uid, !uid.isEmpty else { return false }
        return booking.userId == uid
    }

    private func offlineOrganizationId() throws -> String {
        if let orgId = firebaseBackend?.currentOrganization?.firestoreDocumentId, !orgId.isEmpty { return orgId }
        if let orgId = firebaseBackend?.resolvedOrganizationIdForOfflineWrites(), !orgId.isEmpty { return orgId }
        throw NSError(domain: "HolidayStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Organization not loaded yet. Please try again in a moment."])
    }

    /// Offline and not the person's own request: refused with the online-only message.
    private func requireOnlineUnlessOwn(_ booking: HolidayBooking) throws {
        guard isOffline, !isOwnRequest(booking) else { return }
        throw NSError(domain: "HolidayStore", code: 503, userInfo: [NSLocalizedDescriptionKey: OfflinePolicy.onlineOnlyMessage])
    }

    /// Queues the person's own new request (`holidayRequestWriteFields`) and keeps it on screen as Pending sync.
    private func queueCreate(_ draft: HolidayBooking) throws -> HolidayBooking {
        let orgId = try offlineOrganizationId()
        guard let uid = firebaseBackend?.currentUser?.uid else {
            throw NSError(domain: "HolidayStore", code: 401, userInfo: [NSLocalizedDescriptionKey: "You must be signed in to manage holidays."])
        }
        let create = try FirebaseBackend.holidayRequestCreate(draft, organizationId: orgId)
        OfflineOutboxStore.shared.enqueueAnnualLeaveRequest(
            documentPath: "organizations/\(orgId)/holidayBookings/\(create.documentId)",
            fields: create.fields,
            isCreate: true,
            userId: uid,
            organizationId: orgId,
            entityId: create.documentId
        )
        bookings.removeAll { $0.id == create.stored.id }
        bookings.append(create.stored)
        return create.stored
    }

    /// Queues a partial update of the person's own request (edit of a pending request, or asking to cancel).
    private func queueUpdate(_ booking: HolidayBooking, fields: [String: Any]) throws {
        guard !fields.isEmpty else { return }
        let orgId = try offlineOrganizationId()
        guard let uid = firebaseBackend?.currentUser?.uid,
              let queued = OfflineFieldValue.fields(fields) else {
            throw NSError(domain: "HolidayStore", code: 503, userInfo: [NSLocalizedDescriptionKey: OfflinePolicy.onlineOnlyMessage])
        }
        OfflineOutboxStore.shared.enqueueAnnualLeaveRequest(
            documentPath: "organizations/\(orgId)/holidayBookings/\(booking.documentId)",
            fields: queued,
            isCreate: false,
            userId: uid,
            organizationId: orgId,
            entityId: booking.documentId
        )
    }

    /// RULEBOOK §1, §5, §9, §10: one live listener on the organisation's `holidayBookings`, read through
    /// `parseHolidayDocuments` (`FirebaseBackend.holidayBookings(fromDocuments:)`). A decision or a request made
    /// on web shows on Annual leave, Daily Overview, My Schedule and timesheet leave lines, and the warnings
    /// scan runs again (`.liveWarningInputsDidChange`). Cached copy first; offline keeps the last copy.
    func startLiveUpdates(organizationId: String) {
        guard let fb = firebaseBackend else { return }
        fb.listenOrganizationQuery(
            key: "holidayBookings",
            organizationId: organizationId,
            query: { $0.collection("holidayBookings") }
        ) { [weak self] rows, fromCache in
            guard let self else { return }
            let parsed = FirebaseBackend.holidayBookings(fromDocuments: rows, organizationId: normalizedOrganizationId(organizationId))
            // Leave documents arrived but none could be read: keep the leave on screen (queued requests would
            // otherwise be all that is left).
            if LiveSnapshotMerge.refusesUnreadSnapshot(
                collection: "holidayBookings",
                rowCount: LiveSnapshotMerge.readableRowCount(rows),
                parsedCount: parsed.count,
                existingCount: self.bookings.count,
                fromCache: fromCache
            ) {
                return
            }
            // §2: a request queued offline stays on screen (Pending sync) until the outbox replays it.
            let pending = self.bookings.filter { self.isPendingSync($0) }
            let pendingIds = Set(pending.map(\.id))
            let incoming = parsed.filter { !pendingIds.contains($0.id) } + pending
            let firstDelivery = !organizationIdsMatch(self.finishedLoadOrganizationId, organizationId)
            self.finishedLoadOrganizationId = normalizedOrganizationId(organizationId)
            guard let next = LiveSnapshotMerge.apply(existing: self.bookings, incoming: incoming, fromCache: fromCache),
                  Set(next) != Set(self.bookings) else {
                if firstDelivery {
                    NotificationCenter.default.post(name: .liveWarningInputsDidChange, object: nil)
                }
                return
            }
            self.bookings = next
            NotificationCenter.default.post(name: .liveWarningInputsDidChange, object: nil)
        }
    }

    func loadData() async {
        guard let fb = firebaseBackend else {
            errorMessage = "Holiday service unavailable. Please reopen the app."
            isLoading = false
            return
        }
        guard fb.isAuthenticated else {
            errorMessage = "Please sign in again to load holidays."
            isLoading = false
            return
        }
        guard !isLoadingInFlight else { return }
        isLoadingInFlight = true
        isLoading = true
        var attemptedOrganizationId = fb.currentOrganization?.firestoreDocumentId
        defer {
            isLoading = false
            isLoadingInFlight = false
            if let attemptedOrganizationId, !attemptedOrganizationId.isEmpty {
                finishedLoadOrganizationId = attemptedOrganizationId
            }
        }
        errorMessage = nil
        do {
            print("🔥🔥🔥 DEBUG: HolidayStore loadData starting…")
            let orgId = try await resolveOrganizationId()
            attemptedOrganizationId = orgId
            print("🔥🔥🔥 DEBUG: HolidayStore resolved org \(orgId); fetching holidayBookings…")
            bookings = try await fb.loadHolidayBookings(organizationId: orgId)
            print("🔥🔥🔥 DEBUG: HolidayStore loaded \(bookings.count) holiday bookings")
            // Do not auto-purge weekends on load — sequential deletes freeze Simulator launch.
            // Purge remains available via `purgeInvalidWeekendBookingsIfNeeded()` for explicit cleanup.
        } catch {
            let nsError = error as NSError
            print("🔥🔥🔥 DEBUG: HolidayStore loadData failed: \(error.localizedDescription)")
            if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                errorMessage = "Holiday sync is currently blocked by Firebase permissions. Existing cached data may still be shown."
            } else {
                errorMessage = error.localizedDescription
            }
            // Keep currently loaded bookings on transient permission/network errors.
        }
    }

    /// A new booking creates one document (`holidayRequestWriteFields`). A booking already in the store
    /// writes only the fields that changed (partial update + `WriteMetadata`), never a full merge-set.
    func saveBooking(_ booking: HolidayBooking) async throws {
        guard let fb = firebaseBackend else { return }
        try requireOnlineUnlessOwn(booking)
        if isOffline {
            // RULEBOOK §2: the person's own request is queued and shows Pending sync.
            if let previous = bookings.first(where: { $0.id == booking.id }) {
                try queueUpdate(booking, fields: Self.changedFields(from: previous, to: booking))
                if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
                    bookings[index] = booking
                }
            } else {
                _ = try queueCreate(booking)
            }
            return
        }
        let orgId = try await resolveOrganizationId()
        if let previous = bookings.first(where: { $0.id == booking.id }) {
            let fields = Self.changedFields(from: previous, to: booking)
            try await fb.updateHolidayBookingFields(documentId: booking.documentId, fields: fields, organizationId: orgId)
            if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
                bookings[index] = booking
            }
            return
        }
        let stored = try await fb.saveHolidayBooking(booking, organizationId: orgId)
        bookings.removeAll { $0.id == stored.id }
        bookings.append(stored)
    }

    /// One document per request range (`holidayRequestRanges` → `holidayRequestWriteFields`, §9).
    /// `picks` are the chosen days (any time of day; the organisation-zone day key is used) with their slot.
    /// Returns the saved bookings in date order.
    @discardableResult
    func createRequests(
        picks: [(day: Date, timeSlot: HolidayTimeSlot)],
        userId: String?,
        operativeId: UUID?,
        status: HolidayStatus,
        approvedByUserId: String?
    ) async throws -> [HolidayBooking] {
        guard let fb = firebaseBackend else { return [] }
        let signedIn = fb.currentUser?.uid
        let ownRequest = signedIn != nil && userId == signedIn
        if isOffline && !ownRequest {
            throw NSError(domain: "HolidayStore", code: 503, userInfo: [NSLocalizedDescriptionKey: OfflinePolicy.onlineOnlyMessage])
        }
        let orgId: String
        if isOffline {
            orgId = try offlineOrganizationId()
        } else {
            orgId = try await resolveOrganizationId()
        }
        let keyed = picks.map { (dayKey: OrganizationRulebookContext.dayKey($0.day), timeSlot: $0.timeSlot.rawValue) }
        guard let ranges = CanonicalBusinessEngine.holidayRequestRanges(picks: keyed) else {
            throw NSError(domain: "HolidayStore", code: 500, userInfo: [NSLocalizedDescriptionKey: "Annual leave could not be prepared. Please try again."])
        }
        var saved: [HolidayBooking] = []
        for range in ranges {
            guard let start = OrganizationRulebookContext.date(fromDayKey: range.startDayKey),
                  let end = OrganizationRulebookContext.date(fromDayKey: range.endDayKey) else { continue }
            let draft = HolidayBooking(
                organizationId: orgId,
                userId: userId,
                operativeId: operativeId,
                startDate: start,
                endDate: end,
                status: status,
                timeSlot: HolidayTimeSlot(rawValue: range.timeSlot) ?? .fullDay,
                approvedByUserId: status == .approved ? approvedByUserId : nil
            )
            if isOffline {
                // RULEBOOK §2: queued; approver notices wait for the server (`isPendingSync`).
                saved.append(try queueCreate(draft))
                continue
            }
            let stored = try await fb.saveHolidayBooking(draft, organizationId: orgId)
            bookings.removeAll { $0.id == stored.id }
            bookings.append(stored)
            saved.append(stored)
        }
        return saved.sorted { $0.startDate < $1.startDate }
    }

    /// Firestore values for the keys that differ between two versions of one booking.
    private static func changedFields(from old: HolidayBooking, to new: HolidayBooking) -> [String: Any] {
        func timestamp(_ date: Date?) -> Any { date.map { Timestamp(date: $0) as Any } ?? NSNull() }
        func text(_ value: String?) -> Any {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? (NSNull() as Any) : (trimmed as Any)
        }
        var fields: [String: Any] = [:]
        if old.startDate != new.startDate { fields["startDate"] = timestamp(new.startDate) }
        if old.endDate != new.endDate { fields["endDate"] = timestamp(new.endDate) }
        if old.timeSlot != new.timeSlot { fields["timeSlot"] = new.timeSlot.rawValue }
        if old.status != new.status { fields["status"] = new.status.rawValue }
        if old.approvedByUserId != new.approvedByUserId { fields["approvedByUserId"] = text(new.approvedByUserId) }
        if old.approvedAt != new.approvedAt { fields["approvedAt"] = timestamp(new.approvedAt) }
        if old.cancellationRequestedAt != new.cancellationRequestedAt {
            fields["cancellationRequestedAt"] = timestamp(new.cancellationRequestedAt)
        }
        if old.cancellationRequestedByUserId != new.cancellationRequestedByUserId {
            fields["cancellationRequestedByUserId"] = text(new.cancellationRequestedByUserId)
        }
        if old.decisionNote != new.decisionNote {
            fields["decisionNote"] = CanonicalBusinessEngine.parseHolidayDecisionNote(new.decisionNote).map { $0 as Any } ?? NSNull()
        }
        return fields
    }

    func deleteBooking(_ booking: HolidayBooking) async {
        guard let fb = firebaseBackend else { return }
        do {
            let orgId = try await resolveOrganizationId()
            try await fb.deleteHolidayBooking(booking, organizationId: orgId)
            bookings.removeAll { $0.id == booking.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes single-day annual leave records that fall on a weekend (early-days cleanup; restores allowance).
    /// A multi-day record (one document per request, §9) may span a weekend and is kept.
    func purgeInvalidWeekendBookingsIfNeeded() async {
        let cal = OrganizationRulebookContext.calendar
        let invalid = bookings.filter {
            cal.isDate($0.startDate, inSameDayAs: $0.endDate) &&
            AnnualLeaveCalendarRules.bookingContainsWeekend($0, calendar: cal)
        }
        for booking in invalid {
            await deleteBooking(booking)
        }
    }

    // Owner decision 4 Nov ("Never delete leave"): changing Annual Leave Management, the line manager or the account
    // type never deletes a person's approved or pending leave. The toggle only decides whether *future* leave saves
    // approved or is requested (`canSelfBookAnnualLeave`). The two helpers that deleted it are gone.

    /// Approve in one partial update (`holidayDecisionWriteFields`).
    func approveBooking(_ booking: HolidayBooking, approvedByUserId: String) async {
        await decide(booking, status: .approved, approverUid: approvedByUserId, note: nil)
    }

    /// Decline in one partial update (`holidayDecisionWriteFields`). A blank reason clears the note.
    func rejectBooking(_ booking: HolidayBooking, rejectedByUserId: String, reason: String = "") async {
        await decide(booking, status: .rejected, approverUid: rejectedByUserId, note: reason)
    }

    private func decide(_ booking: HolidayBooking, status: HolidayStatus, approverUid: String, note: String?) async {
        guard let fb = firebaseBackend else { return }
        do {
            let orgId = try await resolveOrganizationId()
            let decision = try await fb.decideHolidayBooking(
                booking,
                status: status,
                approverUid: approverUid,
                decisionNote: note,
                organizationId: orgId
            )
            var updated = booking
            updated.status = HolidayStatus(rawValue: decision.status) ?? status
            updated.approvedByUserId = decision.approvedByUserId
            updated.approvedAt = Date()
            updated.decisionNote = decision.decisionNote
            updated.updatedAt = Date()
            if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
                bookings[index] = updated
            } else {
                bookings.append(updated)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var pendingRequests: [HolidayBooking] {
        bookings.filter {
            ($0.status == .pending || $0.cancellationRequestedAt != nil) &&
            ($0.operativeId != nil || $0.userId != nil)
        }
    }

    func requestCancellation(_ booking: HolidayBooking, by userId: String) async {
        var updated = booking
        updated.cancellationRequestedAt = Date()
        updated.cancellationRequestedByUserId = userId
        updated.updatedAt = Date()
        do {
            try await saveBooking(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// An approver refuses a cancellation request (RULEBOOK §9): the leave stays approved and the request fields are
    /// cleared in one partial update. Returns false when the write failed (`errorMessage` is set).
    @discardableResult
    func refuseCancellation(_ booking: HolidayBooking) async -> Bool {
        guard booking.cancellationRequestedAt != nil else { return false }
        var updated = booking
        updated.cancellationRequestedAt = nil
        updated.cancellationRequestedByUserId = nil
        updated.updatedAt = Date()
        do {
            try await saveBooking(updated)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Approved records whose leave days (`leaveRecordDayKeys` over the reader's `startDayKey` / `endDayKey`)
    /// include the organisation day of `date`.
    func approvedBookings(covering date: Date) -> [HolidayBooking] {
        let dayKey = OrganizationRulebookContext.dayKey(date)
        return bookings.filter { b in
            b.isApproved && LeaveRecordDays.covers(b, dayKey: dayKey)
        }
    }

    /// RULEBOOK 1.9.0 §9, §10: this account's leave — `leaveRecordsForAccount` (a record whose `userId` or
    /// `operativeId` is any of the account's ids: uid, former and same-email ids, catalogue rows on its email; without
    /// case, never by name). With no account, the records on `operativeId` (a catalogue-only person). Falls back to
    /// `myBookings(userId:operativeId:email:)` only when the script did not answer.
    func myBookings(account: AppUser?, operatives: [Operative], operativeId: UUID? = nil) -> [HolidayBooking] {
        guard let account else {
            guard let operativeId else { return [] }
            return bookings.filter { $0.operativeId == operativeId }
        }
        let indexes = CanonicalBusinessEngine.leaveRecordsForAccount(
            records: bookings.map { (userId: $0.userId, operativeId: $0.operativeIdRaw) },
            account: CanonicalBusinessEngine.CanonicalBookingPersonAccount(
                id: account.id,
                email: account.email,
                formerIds: account.formerUserIds,
                aliasIds: account.sameEmailUserIds
            ),
            operatives: operatives.map { CanonicalBusinessEngine.CanonicalBookingPersonOperative(id: $0.documentId, email: $0.email) }
        )
        guard let indexes else {
            return myBookings(userId: account.id, operativeId: operativeId, email: account.email)
        }
        let all = bookings
        return indexes.filter { $0 >= 0 && $0 < all.count }.map { all[$0] }
    }

    func myBookings(userId: String?, operativeId: UUID?, email: String? = nil) -> [HolidayBooking] {
        bookings.filter { b in
            if AnnualLeavePolicy.holidayUserMatches(bookingUserId: b.userId, profileUserId: userId, profileEmail: email) {
                return true
            }
            if let oid = operativeId, b.operativeId == oid { return true }
            return false
        }
    }
}
