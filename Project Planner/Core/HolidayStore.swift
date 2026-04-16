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

    func setFirebaseBackend(_ backend: FirebaseBackend) {
        firebaseBackend = backend
    }

    func loadData() async {
        guard let fb = firebaseBackend,
              fb.isAuthenticated,
              let orgId = fb.currentOrganization?.firestoreDocumentId else {
            bookings = []
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            bookings = try await fb.loadHolidayBookings(organizationId: orgId)
        } catch {
            errorMessage = error.localizedDescription
            bookings = []
        }
        isLoading = false
    }

    func saveBooking(_ booking: HolidayBooking) async throws {
        guard let fb = firebaseBackend,
              let orgId = fb.currentOrganization?.firestoreDocumentId else { return }
        try await fb.saveHolidayBooking(booking, organizationId: orgId)
        if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
            bookings[index] = booking
        } else {
            bookings.append(booking)
        }
    }

    func deleteBooking(_ booking: HolidayBooking) async {
        guard let fb = firebaseBackend,
              let orgId = fb.currentOrganization?.firestoreDocumentId else { return }
        do {
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
        bookings.filter { $0.status == .pending && ($0.operativeId != nil || $0.userId != nil) }
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
