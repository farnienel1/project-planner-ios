//
//  OfflineOutboxStore.swift
//  Project Planner
//
//  Persistent outbox for offline writes — survives app restarts.
//

import Foundation
import Combine
import FirebaseAuth

// MARK: - Operation payloads

struct OfflineSaveBookingPayload: Codable {
    let booking: Booking
    /// Stored fields this queued edit changed (`BookingWritePatch.labourFieldNames`). Nil means a
    /// create: the whole booking is written. Entries queued before this field existed decode as nil.
    var changedFields: [String]? = nil
    /// RULEBOOK 1.33.0: `bookingDeleteFingerprint` of the booking as last synced, before this queued edit. A later
    /// offline delete stores it (never the fingerprint of the unsynced edit). Nil for a create and older entries.
    var baselineFingerprint: String? = nil
}

/// A queued delete of a labour (`deleteBooking`) or manager schedule (`deleteManagerSiteBooking`) booking.
/// RULEBOOK 1.33.0 (owner decision 4 Nov "Offline delete on iOS"): it replays with its tombstone through
/// `offlineDeleteReplayDecision`. Every field after `bookingId` is optional, so an item queued by an older build
/// (`{ bookingId }` or `{ bookingId, documentId }`) still decodes (Q-G1: convert, no user action).
struct OfflineDeleteBookingPayload: Codable {
    let bookingId: UUID
    /// Firestore document id when it is not `bookingId.uuidString` (a lower-case or non-UUID id kept as stored).
    var documentId: String? = nil
    /// `bookings` or `managerSiteBookings`; nil in older items (the entry's operation says which).
    var collection: String? = nil
    /// `bookingDeleteFingerprint` of the booking as last synced from the server; nil in older items.
    var fingerprint: String? = nil
    /// The booking as it was, put back on Undo or when the replay is refused.
    var labourBooking: Booking? = nil
    var managerBooking: ManagerSiteBooking? = nil
}

struct OfflineSaveManagerSiteBookingPayload: Codable {
    let booking: ManagerSiteBooking
    /// Changed fields (`BookingWritePatch.managerFieldNames`); nil for a create.
    var changedFields: [String]? = nil
    /// RULEBOOK 1.33.0: as `OfflineSaveBookingPayload.baselineFingerprint`.
    var baselineFingerprint: String? = nil
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
        case saveDeadlines
        /// RULEBOOK §2 allowed offline: a leave request (create, edit own pending, ask to cancel).
        case saveAnnualLeaveRequest
        /// RULEBOOK §2 allowed offline: the signed-in user's own profile fields.
        case saveOwnProfileFields
        /// RULEBOOK §2 allowed offline: the signed-in user's own notification toggles.
        case saveOwnNotificationToggles
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
    /// The signed-in account that queued it. Replay drops the entry when another account is signed in.
    /// Nil only for entries queued before this field existed.
    var userId: String?

    var displayTitle: String {
        switch operation {
        case .saveBooking: return "Labour booking"
        case .deleteBooking: return "Delete labour booking"
        case .saveManagerSiteBooking: return "Schedule booking"
        case .deleteManagerSiteBooking: return "Delete schedule booking"
        case .saveMaterialItem: return "Material catalogue / job item"
        case .deleteMaterialItem: return "Remove material item"
        case .sendMaterialRequest: return "Material order"
        case .saveDeadlines: return "Deadlines"
        case .saveAnnualLeaveRequest: return "Annual leave request"
        case .saveOwnProfileFields: return "My profile"
        case .saveOwnNotificationToggles: return "My notifications"
        }
    }

    var displayDetail: String {
        if let lastError, !lastError.isEmpty {
            return lastError
        }
        return createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    init(
        id: UUID = UUID(),
        organizationId: String,
        operation: Operation,
        entityId: String,
        payload: Data,
        createdAt: Date = Date(),
        attemptCount: Int = 0,
        lastError: String? = nil,
        userId: String? = nil
    ) {
        self.id = id
        self.organizationId = organizationId
        self.operation = operation
        self.entityId = entityId
        self.payload = payload
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.userId = userId
    }

    /// Whether this entry may replay for `signedInUserId`: never with nobody signed in, never for another
    /// account. An entry queued before `userId` existed falls back to its partial-update payload's user,
    /// else it cannot be told apart and replays (the rules still check the writer).
    func mayReplay(signedInUserId: String?) -> Bool {
        let signedIn = signedInUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !signedIn.isEmpty else { return false }
        let owner = queuedByUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return owner.isEmpty || owner == signedIn
    }

    /// `userId`, else (older entries) the user stored in a partial-update payload.
    var queuedByUserId: String? {
        if let userId, !userId.isEmpty { return userId }
        switch operation {
        case .saveAnnualLeaveRequest, .saveOwnProfileFields, .saveOwnNotificationToggles:
            return (try? JSONDecoder().decode(OfflinePartialUpdatePayload.self, from: payload))?.userId
        default:
            return nil
        }
    }
}

// MARK: - Store

@MainActor
final class OfflineOutboxStore: ObservableObject {
    static let shared = OfflineOutboxStore()

    @Published private(set) var entries: [OfflineOutboxEntry] = []

    /// The last queued change the server refused for good (`bookingReplayRefusedIsFinal`), for the
    /// banner to show once. `BOOKING_REPLAY_REFUSED_MESSAGE` for a booking save.
    @Published var lastRefusalMessage: String?

    /// RULEBOOK 1.33.0: a notice after a change that went through (the signed-timesheet warning on a booking delete,
    /// `bookingDeleteSignedTimesheetWarning`), shown once by the offline banner.
    @Published var lastNoticeMessage: String?

    var pendingCount: Int { entries.count }

    /// RULEBOOK §2 "Pending sync": the outbox still holds a change for this entity (booking UUID string,
    /// material id, `deadlines_{projectId}`, or the entity id passed to an `enqueue...` call below).
    func hasPendingSync(entityId: String) -> Bool {
        let key = entityId.uppercased()
        return entries.contains { $0.entityId.uppercased() == key }
    }

    /// Same as `hasPendingSync(entityId:)` for a booking or manager schedule booking id.
    func hasPendingSync(bookingId: UUID) -> Bool {
        hasPendingSync(entityId: bookingId.uuidString)
    }

    /// Labour bookings this device has queued to create or edit in `organizationId` (newest queued copy each), and the
    /// ids it has queued to delete. A server snapshot is overlaid with these until the outbox replays (§2).
    func pendingLabourBookings(organizationId: String) -> (saves: [Booking], deletedIds: Set<UUID>) {
        var saves: [Booking] = []
        var deleted = Set<UUID>()
        for entry in entries where entry.organizationId == organizationId {
            switch entry.operation {
            case .saveBooking:
                if let payload = try? decoder.decode(OfflineSaveBookingPayload.self, from: entry.payload) {
                    saves.removeAll { $0.id == payload.booking.id }
                    saves.append(payload.booking)
                }
            case .deleteBooking:
                if let payload = try? decoder.decode(OfflineDeleteBookingPayload.self, from: entry.payload) {
                    deleted.insert(payload.bookingId)
                }
            default:
                break
            }
        }
        return (saves, deleted)
    }

    /// Booking ids this device has queued to delete in `organizationId` for `collection` (`bookings` or
    /// `managerSiteBookings`). A server or cache snapshot is filtered by these until the delete replays (§2).
    func pendingDeletedBookingIds(collection: String, organizationId: String) -> Set<UUID> {
        let operation: OfflineOutboxEntry.Operation = collection == "managerSiteBookings" ? .deleteManagerSiteBooking : .deleteBooking
        var ids = Set<UUID>()
        for entry in entries where entry.organizationId == organizationId && entry.operation == operation {
            if let payload = try? decoder.decode(OfflineDeleteBookingPayload.self, from: entry.payload) {
                ids.insert(payload.bookingId)
            } else if let id = UUID(uuidString: entry.entityId) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// The queued delete for an entity, if any (the outbox sheet's Undo).
    func queuedDelete(entryId: UUID) -> (entry: OfflineOutboxEntry, payload: OfflineDeleteBookingPayload)? {
        guard let entry = entries.first(where: { $0.id == entryId }),
              entry.operation == .deleteBooking || entry.operation == .deleteManagerSiteBooking,
              let payload = try? decoder.decode(OfflineDeleteBookingPayload.self, from: entry.payload) else { return nil }
        return (entry, payload)
    }

    /// Every entity id with a queued change.
    var pendingEntityIds: Set<String> {
        Set(entries.map { $0.entityId.uppercased() })
    }
    var failedCount: Int { entries.filter { ($0.lastError ?? "").isEmpty == false }.count }

    private let storageKey = "offline_outbox_v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        loadFromDisk()
    }

    // MARK: - Enqueue helpers

    /// Queues a booking save. `changedFields` nil queues a create (the whole booking); otherwise only
    /// those fields are written on replay. A second edit before replay adds its fields to the first;
    /// an edit after a queued create stays a create with the newer values.
    func enqueueSaveBooking(
        _ booking: Booking,
        changedFields: Set<String>? = nil,
        organizationId: String,
        baselineFingerprint: String? = nil
    ) {
        var fields: [String]? = changedFields.map { Array($0).sorted() }
        // RULEBOOK 1.33.0: the first queued edit keeps the fingerprint of the copy last synced from the server.
        var baseline = changedFields == nil ? nil : baselineFingerprint
        if let existing = entries.first(where: { $0.entityId == booking.id.uuidString && $0.operation == .saveBooking }),
           let old = try? decoder.decode(OfflineSaveBookingPayload.self, from: existing.payload) {
            fields = Self.mergedChangedFields(old.changedFields, fields)
            baseline = fields == nil ? nil : (old.baselineFingerprint ?? baseline)
        }
        guard let payload = try? encoder.encode(
            OfflineSaveBookingPayload(booking: booking, changedFields: fields, baselineFingerprint: baseline)
        ) else { return }
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

    /// What queuing an offline delete did (RULEBOOK 1.33.0).
    enum OfflineDeleteQueueResult: Equatable {
        /// Queued with the fingerprint of the copy last synced; replays with its tombstone.
        case queued
        /// The booking was created offline and never reached the server: its queued create is removed and nothing
        /// is sent (`offlineDeleteReplayDecision` `dropLocal`).
        case droppedLocal
    }

    /// What `discardQueuedBookingSaves` removed (1.33.1 review item 5).
    enum QueuedBookingSave: Equatable {
        case nothing
        /// A create queued offline: it never reached the server.
        case create
        /// A queued edit, with the fingerprint of the copy last synced (its baseline) when it has one.
        case edit(baseline: String?)
    }

    /// 1.33.1 review item 5: a labour or manager schedule booking deleted through Firestore (not the outbox). Its
    /// queued changes are removed, as `enqueueDeleteBooking` / `enqueueDeleteManagerSiteBooking` replace a queued edit
    /// (RULEBOOK §2): left in place, a queued edit would replay after the delete and be refused against its tombstone.
    @discardableResult
    func discardQueuedBookingSaves(bookingId: UUID) -> QueuedBookingSave {
        let entityId = bookingId.uuidString
        let saves = entries.filter {
            $0.entityId.caseInsensitiveCompare(entityId) == .orderedSame
                && ($0.operation == .saveBooking || $0.operation == .saveManagerSiteBooking)
        }
        guard !saves.isEmpty else { return .nothing }
        var result = QueuedBookingSave.edit(baseline: nil)
        for entry in saves {
            var isCreate = false
            var baseline: String?
            if entry.operation == .saveBooking, let old = try? decoder.decode(OfflineSaveBookingPayload.self, from: entry.payload) {
                isCreate = old.changedFields == nil
                baseline = old.baselineFingerprint
            } else if entry.operation == .saveManagerSiteBooking,
                      let old = try? decoder.decode(OfflineSaveManagerSiteBookingPayload.self, from: entry.payload) {
                isCreate = old.changedFields == nil
                baseline = old.baselineFingerprint
            }
            if isCreate {
                result = .create
                break
            }
            if case .edit(baseline: nil) = result, let baseline { result = .edit(baseline: baseline) }
        }
        let ids = Set(saves.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        persistToDisk()
        return result
    }

    /// RULEBOOK 1.33.0 (owner decision 4 Nov "Offline delete on iOS"): queues the delete of a labour booking with
    /// `fingerprint` (`bookingDeleteFingerprint` of this device's copy). A queued create of the same booking is dropped
    /// instead (created and deleted offline sends nothing); a queued edit is replaced, and its baseline (the copy
    /// last synced) is the fingerprint kept.
    @discardableResult
    func enqueueDeleteBooking(_ booking: Booking, fingerprint: String, organizationId: String) -> OfflineDeleteQueueResult {
        let entityId = booking.id.uuidString
        var baseline = fingerprint
        if let existing = entries.first(where: { $0.entityId == entityId && $0.operation == .saveBooking }),
           let old = try? decoder.decode(OfflineSaveBookingPayload.self, from: existing.payload) {
            if old.changedFields == nil {
                removePending(forEntityId: entityId)
                persistToDisk()
                return .droppedLocal
            }
            baseline = old.baselineFingerprint ?? fingerprint
        }
        let model = OfflineDeleteBookingPayload(
            bookingId: booking.id,
            documentId: booking.documentKey,
            collection: "bookings",
            fingerprint: baseline,
            labourBooking: booking
        )
        guard let payload = try? encoder.encode(model) else { return .queued }
        removePending(forEntityId: entityId)
        enqueue(
            OfflineOutboxEntry(organizationId: organizationId, operation: .deleteBooking, entityId: entityId, payload: payload),
            dedupeSameEntity: true
        )
        return .queued
    }

    /// As `enqueueDeleteBooking` for a manager schedule booking. The document id is kept as stored, so a lower-case
    /// id written by web is deleted under its own spelling (1.33.0: the lower-case schedule id fix).
    @discardableResult
    func enqueueDeleteManagerSiteBooking(_ booking: ManagerSiteBooking, fingerprint: String, organizationId: String) -> OfflineDeleteQueueResult {
        let entityId = booking.id.uuidString
        var baseline = fingerprint
        if let existing = entries.first(where: { $0.entityId == entityId && $0.operation == .saveManagerSiteBooking }),
           let old = try? decoder.decode(OfflineSaveManagerSiteBookingPayload.self, from: existing.payload) {
            if old.changedFields == nil {
                removePending(forEntityId: entityId)
                persistToDisk()
                return .droppedLocal
            }
            baseline = old.baselineFingerprint ?? fingerprint
        }
        let model = OfflineDeleteBookingPayload(
            bookingId: booking.id,
            documentId: booking.documentKey,
            collection: "managerSiteBookings",
            fingerprint: baseline,
            managerBooking: booking
        )
        guard let payload = try? encoder.encode(model) else { return .queued }
        removePending(forEntityId: entityId)
        enqueue(
            OfflineOutboxEntry(organizationId: organizationId, operation: .deleteManagerSiteBooking, entityId: entityId, payload: payload),
            dedupeSameEntity: true
        )
        return .queued
    }

    /// Queues a manager schedule booking save; `changedFields` as in `enqueueSaveBooking`.
    func enqueueSaveManagerSiteBooking(
        _ booking: ManagerSiteBooking,
        changedFields: Set<String>? = nil,
        organizationId: String,
        baselineFingerprint: String? = nil
    ) {
        var fields: [String]? = changedFields.map { Array($0).sorted() }
        var baseline = changedFields == nil ? nil : baselineFingerprint
        if let existing = entries.first(where: { $0.entityId == booking.id.uuidString && $0.operation == .saveManagerSiteBooking }),
           let old = try? decoder.decode(OfflineSaveManagerSiteBookingPayload.self, from: existing.payload) {
            fields = Self.mergedChangedFields(old.changedFields, fields)
            baseline = fields == nil ? nil : (old.baselineFingerprint ?? baseline)
        }
        guard let payload = try? encoder.encode(
            OfflineSaveManagerSiteBookingPayload(booking: booking, changedFields: fields, baselineFingerprint: baseline)
        ) else { return }
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

    func enqueueSaveDeadlines(
        projectId: UUID,
        isSmallWorks: Bool,
        items: [DLDeadline],
        baseUpdatedAt: Date?,
        organizationId: String
    ) {
        let entityId = "deadlines_\(projectId.uuidString)"
        var preservedBase = baseUpdatedAt
        if let existing = entries.first(where: { $0.entityId == entityId && $0.operation == .saveDeadlines }),
           let old = try? JSONDecoder().decode(OfflineSaveDeadlinesPayload.self, from: existing.payload) {
            preservedBase = old.baseUpdatedAt ?? baseUpdatedAt
        }
        let payloadModel = OfflineSaveDeadlinesPayload(
            projectId: projectId,
            isSmallWorks: isSmallWorks,
            baseUpdatedAt: preservedBase,
            items: OfflineDeadlineCodec.records(from: items)
        )
        guard let payload = try? encoder.encode(payloadModel) else { return }
        enqueue(
            OfflineOutboxEntry(
                organizationId: organizationId,
                operation: .saveDeadlines,
                entityId: entityId,
                payload: payload
            ),
            dedupeSameEntity: true
        )
    }

    /// RULEBOOK §2: queue an annual leave request write. `fields` are the changed fields only
    /// (dotted keys allowed unless `isCreate`). `isCreate` is true only for a new request document.
    /// `entityId` defaults to the request id (last path segment), for `hasPendingSync(entityId:)`.
    func enqueueAnnualLeaveRequest(
        documentPath: String,
        fields: [String: OfflineFieldValue],
        isCreate: Bool,
        userId: String,
        organizationId: String,
        entityId: String? = nil
    ) {
        enqueuePartialUpdate(
            operation: .saveAnnualLeaveRequest,
            documentPath: documentPath,
            fields: fields,
            isCreate: isCreate,
            userId: userId,
            organizationId: organizationId,
            entityId: entityId
        )
    }

    /// RULEBOOK §2: queue the signed-in user's own profile fields on `users/{userId}` (partial update).
    /// Pay, role, line manager, active flag, employment type and permissions are not "own profile
    /// fields" (§16) and must not be passed here.
    /// `replacesDocument`: the fields are the whole document (`users/{uid}/private/taxIds`), replayed as a set.
    /// `stampsWriteMetadata` false for a document whose rules allow only its own keys.
    func enqueueOwnProfileFields(
        userId: String,
        fields: [String: OfflineFieldValue],
        organizationId: String,
        documentPath: String? = nil,
        replacesDocument: Bool = false,
        stampsWriteMetadata: Bool = true,
        entityId: String? = nil
    ) {
        enqueuePartialUpdate(
            operation: .saveOwnProfileFields,
            documentPath: documentPath ?? "users/\(userId)",
            fields: fields,
            isCreate: replacesDocument,
            userId: userId,
            organizationId: organizationId,
            entityId: entityId ?? "profile_\(userId)",
            stampsWriteMetadata: stampsWriteMetadata
        )
    }

    /// RULEBOOK §2: queue the signed-in user's own notification toggles, e.g. dotted
    /// `notificationPreferences.{key}` on `users/{userId}` (partial update).
    func enqueueOwnNotificationToggles(
        userId: String,
        fields: [String: OfflineFieldValue],
        organizationId: String,
        documentPath: String? = nil
    ) {
        enqueuePartialUpdate(
            operation: .saveOwnNotificationToggles,
            documentPath: documentPath ?? "users/\(userId)",
            fields: fields,
            isCreate: false,
            userId: userId,
            organizationId: organizationId,
            entityId: "notifications_\(userId)"
        )
    }

    /// One outbox row per document: a later change merges its fields into the queued one.
    private func enqueuePartialUpdate(
        operation: OfflineOutboxEntry.Operation,
        documentPath: String,
        fields: [String: OfflineFieldValue],
        isCreate: Bool,
        userId: String,
        organizationId: String,
        entityId: String?,
        stampsWriteMetadata: Bool = true
    ) {
        guard !fields.isEmpty, !documentPath.isEmpty, !userId.isEmpty else { return }
        let key = entityId ?? documentPath.split(separator: "/").last.map(String.init) ?? documentPath
        var merged = fields
        var create = isCreate
        if let existing = entries.first(where: { $0.entityId == key && $0.operation == operation }),
           let old = try? decoder.decode(OfflinePartialUpdatePayload.self, from: existing.payload),
           old.documentPath == documentPath {
            merged = old.fields.merging(fields) { _, new in new }
            create = old.isCreate || isCreate
        }
        let payloadModel = OfflinePartialUpdatePayload(
            documentPath: documentPath,
            fields: merged,
            isCreate: create,
            userId: userId,
            stampsWriteMetadata: stampsWriteMetadata ? nil : false
        )
        guard let payload = try? encoder.encode(payloadModel) else { return }
        enqueue(
            OfflineOutboxEntry(
                organizationId: organizationId,
                operation: operation,
                entityId: key,
                payload: payload
            ),
            dedupeSameEntity: true
        )
    }

    /// A queued create stays a create (nil); two edits add up.
    private static func mergedChangedFields(_ old: [String]?, _ new: [String]?) -> [String]? {
        guard let old, let new else { return nil }
        return Array(Set(old).union(new)).sorted()
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

    /// Retry after the attempt limit: the entry is tried again from the start.
    func resetAttempts(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].attemptCount = 0
        entries[index].lastError = nil
        persistToDisk()
    }

    func clearAll() {
        entries.removeAll()
        lastRefusalMessage = nil
        persistToDisk()
    }

    /// A refused replay is final (RULEBOOK §2): the item leaves the queue, it is not retried.
    func removeRefused(id: UUID, message: String) {
        entries.removeAll { $0.id == id }
        lastRefusalMessage = message
        persistToDisk()
    }

    private func enqueue(_ entry: OfflineOutboxEntry, dedupeSameEntity: Bool) {
        var entry = entry
        if (entry.userId ?? "").isEmpty {
            // Every entry records who queued it, so it never replays for another account.
            entry.userId = Auth.auth().currentUser?.uid
        }
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
