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
    @Published var managerSiteBookings: [ManagerSiteBooking] = [] {
        didSet { revision &+= 1 }
    }
    /// Bumped on every change to `managerSiteBookings`, so booking-flow conflict checks can be memoised per data version.
    private(set) var revision = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// The last server read failed and nothing (or only a cached copy) is on screen.
    @Published private(set) var lastLoadFailed = false
    @Published var isOffline = false
    /// The organisation whose manager bookings load last finished (read, offline copy, or failed).
    /// Warnings wait for it (`WarningInputsReadiness`).
    private(set) var finishedLoadOrganizationId: String?

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
                guard self?.firebaseBackend?.hasBootstrappedOrgDataLoad == true else { return }
                self?.loadData(force: true)
            }
        }

        // RULEBOOK §2: a refused replay is final. Drop the local row the server will never accept.
        NotificationCenter.default.addObserver(
            forName: .offlineBookingReplayRefused,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let collection = note.userInfo?["collection"] as? String
            let bookingId = note.userInfo?["bookingId"] as? String
            let operation = note.userInfo?["operation"] as? String
            Task { @MainActor [weak self] in
                guard let self, collection == "managerSiteBookings", let bookingId,
                      operation == OfflineOutboxEntry.Operation.saveManagerSiteBooking.rawValue,
                      let id = UUID(uuidString: bookingId) else { return }
                self.dropLocalBooking(id: id)
            }
        }

        // RULEBOOK 1.33.0: a queued delete was undone from the sync list or refused on replay — the booking comes back.
        NotificationCenter.default.addObserver(
            forName: .offlineBookingDeleteRestored,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard note.userInfo?["collection"] as? String == "managerSiteBookings",
                  let booking = note.userInfo?["managerBooking"] as? ManagerSiteBooking else { return }
            Task { @MainActor [weak self] in
                guard let self, let orgId = self.firebaseBackend?.resolvedOrganizationIdForOfflineWrites() else { return }
                guard !self.managerSiteBookings.contains(where: { $0.id == booking.id }) else { return }
                self.applyLocalSave(booking, organizationId: orgId)
                ScheduleChangeNotifier.postBookingStoreDidChange()
            }
        }
    }

    /// RULEBOOK 1.33.0 §2 `bookingRemoveAction` for this manager schedule booking: Delete for exactly the people who
    /// may delete it (admins; a manager their own non-job bookings and bookings on jobs they manage), else nothing.
    func canDeleteBooking(_ booking: ManagerSiteBooking) -> Bool {
        let jobLocation = booking.locationType == .project || booking.locationType == .smallWork
        return JobAccessContext.bookingRemoveAction(
            collection: "managerSiteBookings",
            userId: booking.userId,
            locationType: booking.locationType.rawValue,
            locationId: jobLocation ? (booking.locationKey ?? booking.locationId.map { WorkDocumentKeys.storedId(for: $0) }) : nil
        ) == "delete"
    }

    /// The manager schedule bookings this device has queued to delete in `organizationId` stay gone until the
    /// outbox replays (a cache or server snapshot never brings them back first).
    private func withoutQueuedDeletes(_ list: [ManagerSiteBooking], organizationId: String) -> [ManagerSiteBooking] {
        let deleted = OfflineOutboxStore.shared.pendingDeletedBookingIds(collection: "managerSiteBookings", organizationId: organizationId)
        guard !deleted.isEmpty else { return list }
        return list.filter { !deleted.contains($0.id) }
    }

    /// RULEBOOK §2 "Pending sync" for a manager schedule booking row.
    func isPendingSync(_ booking: ManagerSiteBooking) -> Bool {
        OfflineOutboxStore.shared.hasPendingSync(bookingId: booking.id)
    }

    private func dropLocalBooking(id: UUID) {
        guard managerSiteBookings.contains(where: { $0.id == id }) else { return }
        managerSiteBookings.removeAll { $0.id == id }
        if let orgId = firebaseBackend?.resolvedOrganizationIdForOfflineWrites() {
            OfflineManagerScheduleLocalStore.remove(bookingId: id, organizationId: orgId)
        }
        NotificationCenter.default.post(name: didChangeNotificationName, object: nil)
        ScheduleChangeNotifier.postBookingStoreDidChange()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setFirebaseBackend(_ backend: FirebaseBackend) {
        guard LaunchStartupPolicy.shouldRewireStore(isSameInstance: firebaseBackend === backend) else { return }
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

    func discardInMemoryForOrganizationSwitch() {
        managerSiteBookings = []
        finishedLoadOrganizationId = nil
        lastLoadAt = nil
        errorMessage = nil
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
            return
        }

        if smartCache?.isOnline == false {
            managerSiteBookings = deduplicated(withoutQueuedDeletes(OfflineManagerScheduleLocalStore.load(organizationId: orgId), organizationId: orgId))
            finishedLoadOrganizationId = orgId
            return
        }

        isLoading = true
        errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                fb.prepareLaunchScheduleQueryIfNeeded()
                let queryStart = fb.scheduleBookingQueryStart()
                let list = try await fb.loadManagerSiteBookings(organizationId: orgId, startingOn: queryStart)
                let duplicates = self.duplicatesToDelete(from: list)
                self.managerSiteBookings = self.deduplicated(self.withoutQueuedDeletes(list, organizationId: orgId))
                OfflineManagerScheduleLocalStore.save(self.managerSiteBookings, organizationId: orgId)
                self.lastLoadAt = Date()
                self.lastLoadFailed = false
                self.smartCache?.markSynced()
                fb.listenManagerSiteBookings(organizationId: orgId, startingOn: queryStart) { [weak self] remote in
                    guard let self else { return }
                    guard WarningsBookingScanScheduler.acceptsListener(
                        listenerOrganizationId: orgId,
                        currentOrganizationId: self.firebaseBackend?.currentOrganization?.firestoreDocumentId,
                        sessionOrganizationId: self.firebaseBackend?.sessionOrganizationId
                    ) else {
                        return
                    }
                    self.applyRemoteManagerBookings(remote, organizationId: orgId)
                }
                if !duplicates.isEmpty {
                    // Defer duplicate cleanup — sequential deletes on launch freeze Simulator.
                    let orgIdForDeletes = orgId
                    let duplicatesToRemove = duplicates
                    let backend = fb
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 45_000_000_000)
                        print("🔥🔥🔥 DEBUG: ManagerSchedule deferred duplicate cleanup (\(duplicatesToRemove.count))…")
                        for duplicate in duplicatesToRemove {
                            try? await backend.deleteManagerSiteBooking(duplicate, organizationId: orgIdForDeletes)
                        }
                    }
                }
                NotificationCenter.default.post(name: self.didChangeNotificationName, object: nil)
            } catch {
                NSLog("MANAGER_BOOKINGS_LOAD_FAILED org=%@ error=%@", orgId, error.localizedDescription)
                self.lastLoadFailed = true
                let cached = OfflineManagerScheduleLocalStore.load(organizationId: orgId)
                if !cached.isEmpty {
                    self.managerSiteBookings = self.deduplicated(cached)
                    self.errorMessage = "Showing cached schedule. Reconnect to refresh."
                } else {
                    self.errorMessage = error.localizedDescription
                    self.managerSiteBookings = []
                }
            }
            self.isLoading = false
            self.finishedLoadOrganizationId = orgId
        }
    }

    /// RULEBOOK 1.10.0 §2, §16 (`canWriteBooking` / `canDeleteBooking`): a manager books themselves at a job they manage
    /// or at a place with no job; admins anyone anywhere; operatives never.
    private func writeRefusal(_ booking: ManagerSiteBooking, isDelete: Bool = false) -> String? {
        let jobLocation = booking.locationType == .project || booking.locationType == .smallWork
        return JobAccessContext.bookingWriteRefusal(
            collection: "managerSiteBookings",
            userId: booking.userId,
            locationType: booking.locationType.rawValue,
            locationId: jobLocation ? (booking.locationKey ?? booking.locationId.map { WorkDocumentKeys.storedId(for: $0) }) : nil,
            isDelete: isDelete
        )
    }

    func saveBooking(_ booking: ManagerSiteBooking) async {
        guard let fb = firebaseBackend else { return }
        guard let orgId = fb.resolvedOrganizationIdForOfflineWrites() else { return }
        if let refusal = writeRefusal(booking) {
            errorMessage = refusal
            return
        }

        // RULEBOOK §1: organisation-zone midnight of the picked day (`BookingDay`), never the phone's midnight.
        let normalizedDate = BookingDay.organizationMidnight(for: booking.date)
        var normalizedBooking = booking
        normalizedBooking.date = normalizedDate
        normalizedBooking.updatedAt = Date()
        let key = semanticKey(for: normalizedBooking)

        let clashesWithOther = managerSiteBookings.contains { other in
            other.id != normalizedBooking.id && semanticKey(for: other) == key
        }
        if pendingSemanticKeys.contains(key) {
            // The same booking is already being saved (a double tap): nothing more to do.
            return
        }
        if clashesWithOther {
            // Said, never silent (launch data audit #12).
            errorMessage = "This booking is already on the schedule for that day and slot."
            return
        }
        pendingSemanticKeys.insert(key)
        defer { pendingSemanticKeys.remove(key) }

        // RULEBOOK §1 partial writes: an edit writes only what changed against this device's copy;
        // a new booking writes every field.
        let previous = managerSiteBookings.first(where: { $0.id == normalizedBooking.id })
        let changedFields: Set<String>? = previous.map { BookingWritePatch.changedManagerFields(from: $0, to: normalizedBooking) }
        if let changedFields, changedFields.isEmpty { return }
        // RULEBOOK 1.33.0: the copy before this edit, kept with a queued edit for a later offline delete.
        let baseline = previous.map { BookingWritePatch.deleteFingerprint($0) }

        applyLocalSave(normalizedBooking, organizationId: orgId)

        if smartCache?.isOnline == false {
            OfflineOutboxStore.shared.enqueueSaveManagerSiteBooking(
                normalizedBooking, changedFields: changedFields, organizationId: orgId, baselineFingerprint: baseline
            )
            return
        }

        do {
            try await fb.saveManagerSiteBooking(normalizedBooking, organizationId: orgId, changedFields: changedFields)
            loadData(force: true)
        } catch {
            if OfflineWriteSupport.shouldQueue(error: error, isOnline: smartCache?.isOnline ?? true) {
                OfflineOutboxStore.shared.enqueueSaveManagerSiteBooking(
                    normalizedBooking, changedFields: changedFields, organizationId: orgId, baselineFingerprint: baseline
                )
                errorMessage = "Saved locally. Will sync when you're back online."
            } else if BookingWritePatch.isRefusedFinal(error) {
                // Tombstoned: deleted on another device. It cannot come back.
                dropLocalBooking(id: normalizedBooking.id)
                errorMessage = CanonicalBusinessEngine.bookingReplayRefusedMessage
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// RULEBOOK 1.33.0 §2 (owner decision 4 Nov "Offline delete on iOS"): deletes a manager schedule booking with its
    /// tombstone; offline it is queued with `bookingDeleteFingerprint` (under the stored document id, so a lower-case id
    /// web wrote is deleted under its own spelling) and shows "Pending sync". Created and deleted offline sends nothing.
    func deleteBooking(_ booking: ManagerSiteBooking) async {
        let action = OfflinePolicy.deleteAction(collection: "managerSiteBookings")
        guard OfflinePolicy.isEnabled(action, isOnline: smartCache?.isOnline ?? true) else {
            errorMessage = OfflinePolicy.onlineOnlyMessage
            return
        }
        guard let fb = firebaseBackend else { return }
        guard let orgId = fb.resolvedOrganizationIdForOfflineWrites() else { return }
        if let refusal = writeRefusal(booking, isDelete: true) {
            errorMessage = refusal
            return
        }
        let fingerprint = BookingWritePatch.deleteFingerprint(booking)

        managerSiteBookings.removeAll { $0.id == booking.id }
        OfflineManagerScheduleLocalStore.remove(bookingId: booking.id, organizationId: orgId)
        NotificationCenter.default.post(name: didChangeNotificationName, object: nil)
        ScheduleChangeNotifier.postBookingStoreDidChange()
        warnIfOnSignedTimesheet(booking, organizationId: orgId)

        if OfflinePolicy.queuesWhileOffline(action, isOnline: smartCache?.isOnline ?? true) {
            OfflineOutboxStore.shared.enqueueDeleteManagerSiteBooking(booking, fingerprint: fingerprint, organizationId: orgId)
            return
        }

        do {
            // Deletes and writes the `deletedBookings` tombstone in one batch (RULEBOOK §2).
            try await fb.deleteManagerSiteBooking(booking, organizationId: orgId)
            loadData(force: true)
        } catch {
            if OfflineWriteSupport.shouldQueue(error: error, isOnline: smartCache?.isOnline ?? true),
               OfflinePolicy.availability(action) == .allowedOffline {
                // The connection dropped: the delete waits in the outbox with its tombstone (§2).
                OfflineOutboxStore.shared.enqueueDeleteManagerSiteBooking(booking, fingerprint: fingerprint, organizationId: orgId)
                return
            }
            // Refused: the server still has it, so put it back on screen.
            errorMessage = error.localizedDescription
            applyLocalSave(booking, organizationId: orgId)
            ScheduleChangeNotifier.postBookingStoreDidChange()
        }
    }

    /// `bookingDeleteSignedTimesheetWarning` for the person's timesheets: shown once, the delete still goes ahead.
    private func warnIfOnSignedTimesheet(_ booking: ManagerSiteBooking, organizationId: String) {
        guard let fb = firebaseBackend else { return }
        let userId = booking.userId
        let dayKey = OrganizationRulebookContext.dayKey(booking.date)
        Task { @MainActor in
            let sheets = await fb.signedTimesheetCandidates(organizationId: organizationId, userId: userId)
            if let warning = CanonicalBusinessEngine.bookingDeleteSignedTimesheetWarning(dayKey: dayKey, sheets: sheets) {
                OfflineOutboxStore.shared.lastNoticeMessage = warning
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

    private func applyRemoteManagerBookings(_ remote: [ManagerSiteBooking], organizationId: String) {
        // RULEBOOK 1.33.0 §2: a queued delete stays gone until the outbox replays it.
        let remote = withoutQueuedDeletes(remote, organizationId: organizationId)
        if remote.isEmpty && !managerSiteBookings.isEmpty {
            let lowerBound = firebaseBackend?.scheduleBookingQueryStart()
            managerSiteBookings = managerSiteBookings.filter {
                LaunchStartupPolicy.launchBookingIncludes(date: $0.date, lowerBound: lowerBound)
            }
            return
        }
        let next = deduplicated(remote)
        let incoming = next.sorted { $0.id.uuidString < $1.id.uuidString }
        let current = managerSiteBookings.sorted { $0.id.uuidString < $1.id.uuidString }
        if incoming.count == current.count {
            let same = zip(incoming, current).allSatisfy { lhs, rhs in
                lhs.id == rhs.id && lhs.updatedAt == rhs.updatedAt && lhs.timeSlot == rhs.timeSlot
                    && lhs.locationType == rhs.locationType && lhs.locationId == rhs.locationId
                    && lhs.workStartTime == rhs.workStartTime && lhs.workEndTime == rhs.workEndTime
                    && lhs.userId == rhs.userId
            }
            if same { return }
        }
        managerSiteBookings = next
        OfflineManagerScheduleLocalStore.save(next, organizationId: organizationId)
        lastLoadAt = Date()
        NotificationCenter.default.post(name: didChangeNotificationName, object: nil)
        ScheduleChangeNotifier.postBookingStoreDidChange()
    }

    func bookings(for userId: String, on date: Date) -> [ManagerSiteBooking] {
        let cal = OrganizationRulebookContext.calendar
        return managerSiteBookings.filter {
            $0.userId == userId && cal.isDate($0.date, inSameDayAs: date)
        }
    }

    func myBookings(on date: Date, matching accountIds: Set<String> = []) -> [ManagerSiteBooking] {
        var ids = accountIds
        if let uid = firebaseBackend?.currentUser?.uid {
            let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { ids.insert(trimmed) }
        }
        guard !ids.isEmpty else { return [] }
        let cal = OrganizationRulebookContext.calendar
        return managerSiteBookings.filter {
            ids.contains($0.userId) && cal.isDate($0.date, inSameDayAs: date)
        }
    }

    /// RULEBOOK 1.20.2 §2: two stored bookings are the same booking only by `bookingRequestIdentity` (same person,
    /// day, slot, place and — for custom hours — the same start, finish and break). The stored-field key below is the
    /// fallback when the script did not answer.
    private func semanticKey(for booking: ManagerSiteBooking) -> String {
        if let identity = CanonicalBusinessEngine.bookingRequestIdentity(booking.bookingRequest) { return identity }
        return legacySemanticKey(for: booking)
    }

    private func legacySemanticKey(for booking: ManagerSiteBooking) -> String {
        let day = OrganizationRulebookContext.calendar.startOfDay(for: booking.date).timeIntervalSince1970
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
            let cal = OrganizationRulebookContext.calendar
            if cal.startOfDay(for: lhs.date) == cal.startOfDay(for: rhs.date) {
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
