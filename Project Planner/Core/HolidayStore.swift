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
    @Published var bookings: [HolidayBooking] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var firebaseBackend: FirebaseBackend?
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
        defer {
            isLoading = false
            isLoadingInFlight = false
        }
        errorMessage = nil
        do {
            print("🔥🔥🔥 DEBUG: HolidayStore loadData starting…")
            let orgId = try await resolveOrganizationId()
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
        let orgId = try await resolveOrganizationId()
        if let previous = bookings.first(where: { $0.id == booking.id }) {
            let fields = Self.changedFields(from: previous, to: booking)
            try await fb.updateHolidayBookingFields(bookingId: booking.id, fields: fields, organizationId: orgId)
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
        let orgId = try await resolveOrganizationId()
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

    /// Removes self-booked approved annual leave when a user moves off the self-book path.
    func deleteSelfBookedApprovedHolidaysFor(userId: String) async {
        let trimmedUid = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        let toDelete = bookings.filter { booking in
            guard booking.userId == trimmedUid else { return false }
            guard booking.status == .approved, booking.cancellationRequestedAt == nil else { return false }
            if let approver = booking.approvedByUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !approver.isEmpty,
               approver != trimmedUid {
                return false
            }
            return true
        }
        for booking in toDelete {
            await deleteBooking(booking)
        }
    }

    /// Removes **pending** holiday rows for a person moving off the approval/request flow (see `UserRoleTransitionPolicy`).
    func deletePendingHolidayRequestsFor(userId: String, operativeId: UUID?) async {
        let trimmedUid = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingForPerson = bookings.filter { booking in
            guard booking.status == .pending else { return false }
            if booking.userId == trimmedUid { return true }
            if let oid = operativeId, booking.operativeId == oid { return true }
            return false
        }
        for booking in pendingForPerson {
            await deleteBooking(booking)
        }
    }

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

    /// Approved records whose leave days (`leaveRecordDayKeys`) include the organisation day of `date`.
    func approvedBookings(covering date: Date) -> [HolidayBooking] {
        let dayKey = OrganizationRulebookContext.dayKey(date)
        return bookings.filter { b in
            b.status == .approved && LeaveRecordDays.covers(b, dayKey: dayKey)
        }
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
