//
//  HolidayStore.swift
//  Project Planner
//

import Foundation
import Combine
import FirebaseAuth

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
                await self?.loadData()
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
            let orgId = try await resolveOrganizationId()
            bookings = try await fb.loadHolidayBookings(organizationId: orgId)
        } catch {
            let nsError = error as NSError
            if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                errorMessage = "Holiday sync is currently blocked by Firebase permissions. Existing cached data may still be shown."
            } else {
                errorMessage = error.localizedDescription
            }
            // Keep currently loaded bookings on transient permission/network errors.
        }
    }

    func saveBooking(_ booking: HolidayBooking) async throws {
        guard let fb = firebaseBackend else { return }
        let orgId = try await resolveOrganizationId()
        try await fb.saveHolidayBooking(booking, organizationId: orgId)
        if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
            bookings[index] = booking
        } else {
            bookings.append(booking)
        }
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

    func approveBooking(_ booking: HolidayBooking, approvedByUserId: String) async {
        var updated = booking
        updated.status = .approved
        updated.approvedByUserId = approvedByUserId
        updated.approvedAt = Date()
        updated.updatedAt = Date()
        do {
            try await saveBooking(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rejectBooking(_ booking: HolidayBooking, rejectedByUserId: String) async {
        var updated = booking
        updated.status = .rejected
        updated.approvedByUserId = rejectedByUserId
        updated.approvedAt = Date()
        updated.updatedAt = Date()
        do {
            try await saveBooking(updated)
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

    func approvedBookings(covering date: Date) -> [HolidayBooking] {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        return bookings.filter { b in
            guard b.status == .approved else { return false }
            let start = cal.startOfDay(for: b.startDate)
            let end = cal.startOfDay(for: b.endDate)
            return day >= start && day <= end
        }
    }

    func myBookings(userId: String?, operativeId: UUID?) -> [HolidayBooking] {
        bookings.filter { b in
            if let uid = userId, b.userId == uid { return true }
            if let oid = operativeId, b.operativeId == oid { return true }
            return false
        }
    }
}
