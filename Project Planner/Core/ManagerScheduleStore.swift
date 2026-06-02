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
    @Published var isOffline = false

    private var firebaseBackend: FirebaseBackend?
    private var smartCache: SmartCacheService?
    private var cancellables = Set<AnyCancellable>()
    private var pendingSemanticKeys: Set<String> = []
    private let didChangeNotificationName = Notification.Name("managerScheduleDidChange")
    private var lastLoadAt: Date?
    private let minReloadInterval: TimeInterval = 8

    var currentUserId: String? { firebaseBackend?.currentUser?.uid }

    init() {
        NotificationCenter.default.addObserver(
            forName: .syncOfflineChanges,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadData(force: true)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setFirebaseBackend(_ backend: FirebaseBackend) {
        firebaseBackend = backend
    }

    func setSmartCache(_ smartCache: SmartCacheService) {
        self.smartCache = smartCache
        self.isOffline = !smartCache.isOnline
        smartCache.$isOnline
            .receive(on: DispatchQueue.main)
            .sink { [weak self] online in
                self?.isOffline = !online
            }
            .store(in: &cancellables)
    }

    func loadData(force: Bool = false) {
        if !force, let lastLoadAt, Date().timeIntervalSince(lastLoadAt) < minReloadInterval {
            return
        }
        guard let fb = firebaseBackend, fb.isAuthenticated else {
            managerSiteBookings = []
            return
        }

        let orgId = fb.resolvedOrganizationIdForOfflineWrites()
        guard let orgId else {
            managerSiteBookings = []
            return
        }

        if smartCache?.isOnline == false {
            managerSiteBookings = deduplicated(OfflineManagerScheduleLocalStore.load(organizationId: orgId))
            return
        }

        isLoading = true
        errorMessage = nil
        Task {
            do {
                let list = try await fb.loadManagerSiteBookings(organizationId: orgId)
                let duplicates = duplicatesToDelete(from: list)
                managerSiteBookings = deduplicated(list)
                OfflineManagerScheduleLocalStore.save(managerSiteBookings, organizationId: orgId)
                lastLoadAt = Date()
                if !duplicates.isEmpty {
                    for duplicate in duplicates {
                        try? await fb.deleteManagerSiteBooking(duplicate, organizationId: orgId)
                    }
                }
                NotificationCenter.default.post(name: didChangeNotificationName, object: nil)
            } catch {
                let cached = OfflineManagerScheduleLocalStore.load(organizationId: orgId)
                if !cached.isEmpty {
                    managerSiteBookings = deduplicated(cached)
                    errorMessage = "Showing cached schedule. Reconnect to refresh."
                } else {
                    errorMessage = error.localizedDescription
                    managerSiteBookings = []
                }
            }
            isLoading = false
        }
    }

    func saveBooking(_ booking: ManagerSiteBooking) async {
        guard let fb = firebaseBackend else { return }
        guard let orgId = fb.resolvedOrganizationIdForOfflineWrites() else { return }

        let normalizedDate = Calendar.current.startOfDay(for: booking.date)
        var normalizedBooking = booking
        normalizedBooking.date = normalizedDate
        normalizedBooking.updatedAt = Date()
        let key = semanticKey(for: normalizedBooking)

        let clashesWithOther = managerSiteBookings.contains { other in
            other.id != normalizedBooking.id && semanticKey(for: other) == key
        }
        if pendingSemanticKeys.contains(key) || clashesWithOther {
            return
        }
        pendingSemanticKeys.insert(key)
        defer { pendingSemanticKeys.remove(key) }

        applyLocalSave(normalizedBooking, organizationId: orgId)

        if smartCache?.isOnline == false {
            OfflineOutboxStore.shared.enqueueSaveManagerSiteBooking(normalizedBooking, organizationId: orgId)
            return
        }

        do {
            try await fb.saveManagerSiteBooking(normalizedBooking, organizationId: orgId)
            loadData(force: true)
        } catch {
            if OfflineWriteSupport.shouldQueue(error: error, isOnline: smartCache?.isOnline ?? true) {
                OfflineOutboxStore.shared.enqueueSaveManagerSiteBooking(normalizedBooking, organizationId: orgId)
                errorMessage = "Saved locally. Will sync when you're back online."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteBooking(_ booking: ManagerSiteBooking) async {
        guard let fb = firebaseBackend else { return }
        guard let orgId = fb.resolvedOrganizationIdForOfflineWrites() else { return }

        managerSiteBookings.removeAll { $0.id == booking.id }
        OfflineManagerScheduleLocalStore.remove(bookingId: booking.id, organizationId: orgId)
        NotificationCenter.default.post(name: didChangeNotificationName, object: nil)

        if smartCache?.isOnline == false {
            OfflineOutboxStore.shared.enqueueDeleteManagerSiteBooking(booking.id, organizationId: orgId)
            return
        }

        do {
            try await fb.deleteManagerSiteBooking(booking, organizationId: orgId)
            loadData(force: true)
        } catch {
            if OfflineWriteSupport.shouldQueue(error: error, isOnline: smartCache?.isOnline ?? true) {
                OfflineOutboxStore.shared.enqueueDeleteManagerSiteBooking(booking.id, organizationId: orgId)
                errorMessage = "Removed locally. Will sync when you're back online."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyLocalSave(_ booking: ManagerSiteBooking, organizationId: String) {
        if !managerSiteBookings.contains(where: { $0.id == booking.id }) {
            managerSiteBookings.append(booking)
        } else {
            managerSiteBookings = managerSiteBookings.map { $0.id == booking.id ? booking : $0 }
        }
        managerSiteBookings = deduplicated(managerSiteBookings)
        OfflineManagerScheduleLocalStore.save(managerSiteBookings, organizationId: organizationId)
        NotificationCenter.default.post(name: didChangeNotificationName, object: nil)
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
