//
//  ManagerScheduleStore.swift
//  Project Planner
//
//  Holds manager/admin site bookings (where I'm working – AM, PM, Full Day, Office).
//

import Foundation
import Combine
import FirebaseAuth

@MainActor
class ManagerScheduleStore: ObservableObject {
    @Published var managerSiteBookings: [ManagerSiteBooking] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var firebaseBackend: FirebaseBackend?

    var currentUserId: String? { firebaseBackend?.currentUser?.uid }

    func setFirebaseBackend(_ backend: FirebaseBackend) {
        firebaseBackend = backend
    }

    func loadData() {
        guard let fb = firebaseBackend,
              fb.isAuthenticated,
              let orgId = fb.currentOrganization?.firestoreDocumentId else {
            managerSiteBookings = []
            return
        }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let list = try await fb.loadManagerSiteBookings(organizationId: orgId)
                managerSiteBookings = list
            } catch {
                errorMessage = error.localizedDescription
                managerSiteBookings = []
            }
            isLoading = false
        }
    }

    func saveBooking(_ booking: ManagerSiteBooking) async {
        guard let fb = firebaseBackend,
              let orgId = fb.currentOrganization?.firestoreDocumentId else { return }
        do {
            try await fb.saveManagerSiteBooking(booking, organizationId: orgId)
            if !managerSiteBookings.contains(where: { $0.id == booking.id }) {
                managerSiteBookings.append(booking)
            } else {
                managerSiteBookings = managerSiteBookings.map { $0.id == booking.id ? booking : $0 }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteBooking(_ booking: ManagerSiteBooking) async {
        guard let fb = firebaseBackend,
              let orgId = fb.currentOrganization?.firestoreDocumentId else { return }
        do {
            try await fb.deleteManagerSiteBooking(booking, organizationId: orgId)
            managerSiteBookings.removeAll { $0.id == booking.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func bookings(for userId: String, on date: Date) -> [ManagerSiteBooking] {
        let cal = Calendar.current
        return managerSiteBookings.filter {
            $0.userId == userId && cal.isDate($0.date, inSameDayAs: date)
        }
    }

    func myBookings(on date: Date) -> [ManagerSiteBooking] {
        guard let uid = firebaseBackend?.currentUser?.uid else { return [] }
        return bookings(for: uid, on: date)
    }
}
