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
    private var pendingSemanticKeys: Set<String> = []
    private let didChangeNotificationName = Notification.Name("managerScheduleDidChange")

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
                let duplicates = duplicatesToDelete(from: list)
                managerSiteBookings = deduplicated(list)
                if !duplicates.isEmpty {
                    for duplicate in duplicates {
                        try? await fb.deleteManagerSiteBooking(duplicate, organizationId: orgId)
                    }
                }
                NotificationCenter.default.post(name: didChangeNotificationName, object: nil)
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
        
        let normalizedDate = Calendar.current.startOfDay(for: booking.date)
        var normalizedBooking = booking
        normalizedBooking.date = normalizedDate
        normalizedBooking.updatedAt = Date()
        let key = semanticKey(for: normalizedBooking)
        
        // Hard stop for duplicate slot+day+location taps (including rapid multi-taps).
        if pendingSemanticKeys.contains(key) ||
            managerSiteBookings.contains(where: { semanticKey(for: $0) == key }) {
            return
        }
        pendingSemanticKeys.insert(key)
        defer { pendingSemanticKeys.remove(key) }
        
        do {
            try await fb.saveManagerSiteBooking(normalizedBooking, organizationId: orgId)
            if !managerSiteBookings.contains(where: { $0.id == normalizedBooking.id }) {
                managerSiteBookings.append(normalizedBooking)
            } else {
                managerSiteBookings = managerSiteBookings.map { $0.id == normalizedBooking.id ? normalizedBooking : $0 }
            }
            managerSiteBookings = deduplicated(managerSiteBookings)
            NotificationCenter.default.post(name: didChangeNotificationName, object: nil)
            loadData()
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
            NotificationCenter.default.post(name: didChangeNotificationName, object: nil)
            loadData()
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
    
    private func semanticKey(for booking: ManagerSiteBooking) -> String {
        let day = Calendar.current.startOfDay(for: booking.date).timeIntervalSince1970
        let locationKey = booking.locationId?.uuidString ?? (booking.customLocationName?.lowercased() ?? booking.locationType.rawValue)
        let ws = booking.workStartTime ?? ""
        let we = booking.workEndTime ?? ""
        let br = booking.isBreakRemoved ? "1" : "0"
        return "\(booking.userId)|\(Int(day))|\(booking.timeSlot.rawValue)|\(booking.locationType.rawValue)|\(locationKey)|\(ws)|\(we)|\(br)"
    }
    
    private func deduplicated(_ bookings: [ManagerSiteBooking]) -> [ManagerSiteBooking] {
        var latestByKey: [String: ManagerSiteBooking] = [:]
        for booking in bookings {
            let key = semanticKey(for: booking)
            if let existing = latestByKey[key] {
                latestByKey[key] = booking.updatedAt >= existing.updatedAt ? booking : existing
            } else {
                latestByKey[key] = booking
            }
        }
        let policy = OrgPayrollTimePolicy.default
        return latestByKey.values.sorted { lhs, rhs in
            if Calendar.current.startOfDay(for: lhs.date) == Calendar.current.startOfDay(for: rhs.date) {
                let ka = lhs.minutesSortKey(policy: policy)
                let kb = rhs.minutesSortKey(policy: policy)
                if ka != kb { return ka < kb }
                return lhs.timeSlot.rawValue < rhs.timeSlot.rawValue
            }
            return lhs.date < rhs.date
        }
    }
    
    private func duplicatesToDelete(from bookings: [ManagerSiteBooking]) -> [ManagerSiteBooking] {
        var grouped: [String: [ManagerSiteBooking]] = [:]
        for booking in bookings {
            let key = semanticKey(for: booking)
            grouped[key, default: []].append(booking)
        }
        
        var duplicates: [ManagerSiteBooking] = []
        for (_, entries) in grouped where entries.count > 1 {
            let sorted = entries.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.createdAt > rhs.createdAt
            }
            duplicates.append(contentsOf: sorted.dropFirst())
        }
        return duplicates
    }
}
