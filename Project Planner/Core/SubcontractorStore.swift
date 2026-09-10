import Foundation
import Combine

@MainActor
class SubcontractorStore: ObservableObject {
    @Published var subcontractors: [Subcontractor] = []
    @Published var bookings: [SubcontractorBooking] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private var firebaseBackend: FirebaseBackend?
    
    func setFirebaseBackend(_ backend: FirebaseBackend) {
        firebaseBackend = backend
    }
    
    func loadData() async {
        guard let firebaseBackend,
              firebaseBackend.isAuthenticated,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            subcontractors = []
            bookings = []
            return
        }
        isLoading = true
        errorMessage = nil
        print("🔥🔥🔥 DEBUG: SubcontractorStore.loadData starting for org \(orgId)…")
        do {
            async let loadedSubcontractors = firebaseBackend.loadSubcontractors(organizationId: orgId)
            async let loadedBookings = firebaseBackend.loadSubcontractorBookings(organizationId: orgId)
            let firms = try await loadedSubcontractors
            let firmBookings = try await loadedBookings
            // Deduplicate contact ids within each firm — duplicate ForEach ids crash SwiftUI.
            subcontractors = firms.map { firm in
                var copy = firm
                var seen = Set<UUID>()
                copy.contacts = firm.contacts.filter { seen.insert($0.id).inserted }
                return copy
            }
            bookings = firmBookings
            print("🔥🔥🔥 DEBUG: SubcontractorStore.loadData finished — \(subcontractors.count) firms, \(bookings.count) bookings")
        } catch {
            errorMessage = error.localizedDescription
            print("🔥🔥🔥 DEBUG: SubcontractorStore.loadData failed: \(error.localizedDescription)")
        }
        isLoading = false
    }
    
    func saveSubcontractor(_ subcontractor: Subcontractor) async {
        guard let firebaseBackend,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            errorMessage = "Organization is not loaded yet. Please try again."
            return
        }
        do {
            try await firebaseBackend.saveSubcontractor(subcontractor, organizationId: orgId)
            if let idx = subcontractors.firstIndex(where: { $0.id == subcontractor.id }) {
                subcontractors[idx] = subcontractor
            } else {
                subcontractors.append(subcontractor)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func saveBooking(_ booking: SubcontractorBooking) async {
        guard let firebaseBackend,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            errorMessage = "Organization is not loaded yet. Please try again."
            return
        }
        do {
            try await firebaseBackend.saveSubcontractorBooking(booking, organizationId: orgId)
            if let idx = bookings.firstIndex(where: { $0.id == booking.id }) {
                bookings[idx] = booking
            } else {
                bookings.append(booking)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
