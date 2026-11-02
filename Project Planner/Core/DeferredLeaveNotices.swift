//
//  DeferredLeaveNotices.swift
//  Project Planner
//
//  RULEBOOK §2 / §9 / §13: a leave request (or a request to cancel approved leave) made offline is queued in the
//  outbox and shows "Pending sync". Its approvers (`holidayRequestRecipients`) are told only once the server has
//  confirmed the write; a refused write notifies nobody. The pending notices survive an app restart.
//

import Foundation

/// One `holiday_request_submitted` notice waiting for its outbox entry to be confirmed.
nonisolated struct DeferredLeaveNotice: Codable, Equatable, Sendable {
    /// The outbox entity id: the request's stored document id.
    var entityId: String
    var organizationId: String
    var bookingId: UUID
    var requesterUserId: String
    var requesterName: String
    var startDate: Date
    var endDate: Date
    var assignedManagerUserId: String?
    var cancellation: Bool

    func matches(entityId other: String, organizationId otherOrg: String) -> Bool {
        entityId.uppercased() == other.uppercased() && organizationId == otherOrg
    }
}

@MainActor
final class DeferredLeaveNoticeQueue {
    static let shared = DeferredLeaveNoticeQueue()

    private static let storageKey = "deferred_leave_notices_v1"
    private(set) var notices: [DeferredLeaveNotice] = []
    private weak var service: NotificationService?
    private var observers: [NSObjectProtocol] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([DeferredLeaveNotice].self, from: data) {
            notices = decoded
        }
    }

    /// Sends waiting notices through `service` when the outbox confirms their request.
    func attach(_ service: NotificationService) {
        self.service = service
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .offlineOutboxEntrySynced, object: nil, queue: .main) { note in
            let info = note.userInfo as? [String: String] ?? [:]
            Task { @MainActor in
                await DeferredLeaveNoticeQueue.shared.entryFinished(info: info, confirmed: true)
            }
        })
        observers.append(center.addObserver(forName: .offlineOutboxEntryRefused, object: nil, queue: .main) { note in
            let info = note.userInfo as? [String: String] ?? [:]
            Task { @MainActor in
                await DeferredLeaveNoticeQueue.shared.entryFinished(info: info, confirmed: false)
            }
        })
    }

    func enqueue(_ notice: DeferredLeaveNotice) {
        notices.removeAll { $0.matches(entityId: notice.entityId, organizationId: notice.organizationId) && $0.cancellation == notice.cancellation }
        notices.append(notice)
        persist()
    }

    /// The notices an outbox entry releases, removed from the queue. Pure over the stored list (tests).
    func take(entityId: String, organizationId: String) -> [DeferredLeaveNotice] {
        let released = notices.filter { $0.matches(entityId: entityId, organizationId: organizationId) }
        guard !released.isEmpty else { return [] }
        notices.removeAll { $0.matches(entityId: entityId, organizationId: organizationId) }
        persist()
        return released
    }

    private func entryFinished(info: [String: String], confirmed: Bool) async {
        guard info["operation"] == OfflineOutboxEntry.Operation.saveAnnualLeaveRequest.rawValue,
              let entityId = info["entityId"], let organizationId = info["organizationId"] else { return }
        let released = take(entityId: entityId, organizationId: organizationId)
        guard confirmed, let service else { return }
        for notice in released {
            await service.sendDeferredLeaveNotice(notice)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(notices) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

extension NotificationService {
    /// `holiday_request_submitted` for a request (or a cancellation request): sent now when the write is on the
    /// server, or held until the outbox confirms it when the request is still Pending sync (RULEBOOK §2).
    func notifyHolidayRequestSubmittedWhenSynced(_ notice: DeferredLeaveNotice, pendingSync: Bool) async {
        if pendingSync {
            DeferredLeaveNoticeQueue.shared.enqueue(notice)
            return
        }
        await sendDeferredLeaveNotice(notice, checksOrganization: false)
    }

    /// Recipients are `holidayRequestRecipients` (inside `notifyHolidayRequestSubmitted`) over the request's own
    /// organisation. The notice is written to `notice.organizationId` explicitly, also when another organisation
    /// is open by the time the outbox confirms the request (never to the open company, never dropped).
    /// `checksOrganization` is kept for callers; the organisation is always the notice's own.
    func sendDeferredLeaveNotice(_ notice: DeferredLeaveNotice, checksOrganization: Bool = true) async {
        await notifyHolidayRequestSubmitted(
            bookingId: notice.bookingId,
            operativeName: notice.requesterName,
            startDate: notice.startDate,
            endDate: notice.endDate,
            assignedManagerUserId: notice.assignedManagerUserId,
            requesterUserId: notice.requesterUserId,
            excludeUserIdMatchingRequester: notice.requesterUserId,
            cancellation: notice.cancellation,
            organizationId: notice.organizationId
        )
    }
}
