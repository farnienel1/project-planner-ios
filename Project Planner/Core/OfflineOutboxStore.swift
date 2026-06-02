//
//  OfflineOutboxStore.swift
//  Project Planner
//
//  Persistent outbox for offline writes — survives app restarts.
//

import Foundation
import Combine

// MARK: - Operation payloads

struct OfflineSaveBookingPayload: Codable {
    let booking: Booking
}

struct OfflineDeleteBookingPayload: Codable {
    let bookingId: UUID
}

struct OfflineSaveManagerSiteBookingPayload: Codable {
    let booking: ManagerSiteBooking
}

struct OfflineDeleteManagerSiteBookingPayload: Codable {
    let bookingId: UUID
}

struct OfflineSaveMaterialItemPayload: Codable {
    let material: MaterialItem
}

struct OfflineDeleteMaterialItemPayload: Codable {
    let materialId: UUID
}

struct OfflineSendMaterialRequestPayload: Codable {
    let request: MaterialOrderRequest
    let sendRecord: MaterialSendRecord?
}

// MARK: - Outbox entry

struct OfflineOutboxEntry: Identifiable, Codable, Equatable {
    enum Operation: String, Codable {
        case saveBooking
        case deleteBooking
        case saveManagerSiteBooking
        case deleteManagerSiteBooking
        case saveMaterialItem
        case deleteMaterialItem
        case sendMaterialRequest
    }

    let id: UUID
    let organizationId: String
    let operation: Operation
    /// Stable id for deduplication (booking uuid, material uuid, send request id, etc.)
    let entityId: String
    let payload: Data
    let createdAt: Date
    var attemptCount: Int
    var lastError: String?

    init(
        id: UUID = UUID(),
        organizationId: String,
        operation: Operation,
        entityId: String,
        payload: Data,
        createdAt: Date = Date(),
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.organizationId = organizationId
        self.operation = operation
        self.entityId = entityId
        self.payload = payload
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastError = lastError
    }
}

// MARK: - Store

@MainActor
final class OfflineOutboxStore: ObservableObject {
    static let shared = OfflineOutboxStore()

    @Published private(set) var entries: [OfflineOutboxEntry] = []

    var pendingCount: Int { entries.count }
    var failedCount: Int { entries.filter { ($0.lastError ?? "").isEmpty == false }.count }

    private let storageKey = "offline_outbox_v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        loadFromDisk()
    }

    // MARK: - Enqueue helpers

    func enqueueSaveBooking(_ booking: Booking, organizationId: String) {
        guard let payload = try? encoder.encode(OfflineSaveBookingPayload(booking: booking)) else { return }
        enqueue(
            OfflineOutboxEntry(
                organizationId: organizationId,
                operation: .saveBooking,
                entityId: booking.id.uuidString,
                payload: payload
            ),
            dedupeSameEntity: true
        )
    }

    func enqueueDeleteBooking(_ bookingId: UUID, organizationId: String) {
        guard let payload = try? encoder.encode(OfflineDeleteBookingPayload(bookingId: bookingId)) else { return }
        removePending(forEntityId: bookingId.uuidString)
        enqueue(
            OfflineOutboxEntry(
                organizationId: organizationId,
                operation: .deleteBooking,
                entityId: bookingId.uuidString,
                payload: payload
            ),
            dedupeSameEntity: false
        )
    }

    func enqueueSaveManagerSiteBooking(_ booking: ManagerSiteBooking, organizationId: String) {
        guard let payload = try? encoder.encode(OfflineSaveManagerSiteBookingPayload(booking: booking)) else { return }
        enqueue(
            OfflineOutboxEntry(
                organizationId: organizationId,
                operation: .saveManagerSiteBooking,
                entityId: booking.id.uuidString,
                payload: payload
            ),
            dedupeSameEntity: true
        )
    }

    func enqueueDeleteManagerSiteBooking(_ bookingId: UUID, organizationId: String) {
        guard let payload = try? encoder.encode(OfflineDeleteManagerSiteBookingPayload(bookingId: bookingId)) else { return }
        removePending(forEntityId: bookingId.uuidString)
        enqueue(
            OfflineOutboxEntry(
                organizationId: organizationId,
                operation: .deleteManagerSiteBooking,
                entityId: bookingId.uuidString,
                payload: payload
            ),
            dedupeSameEntity: false
        )
    }

    func enqueueSaveMaterialItem(_ material: MaterialItem, organizationId: String) {
        guard let payload = try? encoder.encode(OfflineSaveMaterialItemPayload(material: material)) else { return }
        enqueue(
            OfflineOutboxEntry(
                organizationId: organizationId,
                operation: .saveMaterialItem,
                entityId: material.id.uuidString,
                payload: payload
            ),
            dedupeSameEntity: true
        )
    }

    func enqueueDeleteMaterialItem(_ materialId: UUID, organizationId: String) {
        guard let payload = try? encoder.encode(OfflineDeleteMaterialItemPayload(materialId: materialId)) else { return }
        removePending(forEntityId: materialId.uuidString)
        enqueue(
            OfflineOutboxEntry(
                organizationId: organizationId,
                operation: .deleteMaterialItem,
                entityId: materialId.uuidString,
                payload: payload
            ),
            dedupeSameEntity: false
        )
    }

    func enqueueSendMaterialRequest(
        _ request: MaterialOrderRequest,
        sendRecord: MaterialSendRecord?,
        organizationId: String
    ) {
        let entityId = sendRecord?.id.uuidString ?? UUID().uuidString
        guard let payload = try? encoder.encode(
            OfflineSendMaterialRequestPayload(request: request, sendRecord: sendRecord)
        ) else { return }
        enqueue(
            OfflineOutboxEntry(
                organizationId: organizationId,
                operation: .sendMaterialRequest,
                entityId: entityId,
                payload: payload
            ),
            dedupeSameEntity: false
        )
    }

    // MARK: - Queue management

    func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        persistToDisk()
    }

    func markFailed(id: UUID, error: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].attemptCount += 1
        entries[index].lastError = error
        persistToDisk()
    }

    func clearAll() {
        entries.removeAll()
        persistToDisk()
    }

    private func enqueue(_ entry: OfflineOutboxEntry, dedupeSameEntity: Bool) {
        if dedupeSameEntity {
            entries.removeAll { $0.entityId == entry.entityId && $0.operation == entry.operation }
        }
        entries.append(entry)
        entries.sort { $0.createdAt < $1.createdAt }
        persistToDisk()
        print("🔥🔥🔥 DEBUG: [OfflineOutbox] Queued \(entry.operation.rawValue) for \(entry.entityId) — \(entries.count) pending")
    }

    private func removePending(forEntityId entityId: String) {
        entries.removeAll {
            $0.entityId == entityId && (
                $0.operation == .saveBooking ||
                $0.operation == .saveManagerSiteBooking ||
                $0.operation == .saveMaterialItem
            )
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? decoder.decode([OfflineOutboxEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded.sorted { $0.createdAt < $1.createdAt }
        print("🔥🔥🔥 DEBUG: [OfflineOutbox] Loaded \(entries.count) pending entries from disk")
    }

    private func persistToDisk() {
        guard let data = try? encoder.encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        objectWillChange.send()
    }
}
