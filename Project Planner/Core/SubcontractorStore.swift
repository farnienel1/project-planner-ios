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
        // The firm's people on site by name, written with their ids (RULEBOOK 1.7.0 `subcontractorBookingWriteFields`).
        let firm = subcontractors.first { $0.id == booking.subcontractorId }
        let names = booking.bookedOperativeNames(subcontractor: firm)
        let operativeNames: [String]? = firm == nil && !booking.bookedContactIds.isEmpty ? nil : names
        do {
            try await firebaseBackend.saveSubcontractorBooking(booking, organizationId: orgId, operativeNames: operativeNames)
            var saved = booking
            // Saved: from now on this booking is edited in place at its document, never created again.
            saved.firestoreDocumentId = booking.documentId
            if let operativeNames { saved.storedOperativeNames = operativeNames }
            if let idx = bookings.firstIndex(where: { $0.id == booking.id }) {
                bookings[idx] = saved
            } else {
                bookings.append(saved)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteBooking(_ booking: SubcontractorBooking) async {
        guard let firebaseBackend,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            errorMessage = "Organization is not loaded yet. Please try again."
            return
        }
        bookings.removeAll { $0.id == booking.id }
        ScheduleChangeNotifier.postBookingStoreDidChange()
        do {
            try await firebaseBackend.deleteSubcontractorBooking(booking, organizationId: orgId)
        } catch {
            bookings.append(booking)
            ScheduleChangeNotifier.postBookingStoreDidChange()
            errorMessage = error.localizedDescription
        }
    }
}
