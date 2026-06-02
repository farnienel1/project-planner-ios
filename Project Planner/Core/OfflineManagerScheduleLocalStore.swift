//
//  OfflineManagerScheduleLocalStore.swift
//  Project Planner
//
//  Local cache for manager/admin site bookings while offline.
//

import Foundation

@MainActor
enum OfflineManagerScheduleLocalStore {
    private static let storageKeyPrefix = "offline_manager_schedule_v1"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func save(_ bookings: [ManagerSiteBooking], organizationId: String) {
        guard let data = try? encoder.encode(bookings) else { return }
        UserDefaults.standard.set(data, forKey: key(organizationId: organizationId))
    }

    static func load(organizationId: String) -> [ManagerSiteBooking] {
        guard let data = UserDefaults.standard.data(forKey: key(organizationId: organizationId)),
              let bookings = try? decoder.decode([ManagerSiteBooking].self, from: data) else {
            return []
        }
        return bookings
    }

    static func upsert(_ booking: ManagerSiteBooking, organizationId: String) {
        var items = load(organizationId: organizationId)
        if let index = items.firstIndex(where: { $0.id == booking.id }) {
            items[index] = booking
        } else {
            items.append(booking)
        }
        save(items, organizationId: organizationId)
    }

    static func remove(bookingId: UUID, organizationId: String) {
        var items = load(organizationId: organizationId)
        items.removeAll { $0.id == bookingId }
        save(items, organizationId: organizationId)
    }

    private static func key(organizationId: String) -> String {
        "\(storageKeyPrefix)_\(organizationId)"
    }
}
