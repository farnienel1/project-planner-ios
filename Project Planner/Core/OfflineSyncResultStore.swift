//
//  OfflineSyncResultStore.swift
//  Project Planner
//
//  RULEBOOK 1.86.0 §2 (owner decision 24 Nov): the refused queued actions shown on "Not synced". Kept on this phone only
//  (UserDefaults; never Firestore), per signed-in account, until the person taps "Got it". After a sync pass that
//  recorded new ones the phone schedules ONE local notification (`offlineSyncResultNotificationText`); when notifications
//  are off it shows `OFFLINE_SYNC_RESULT_BANNER` at the top instead.
//

import Foundation
import Combine
import FirebaseAuth
@preconcurrency import FirebaseFirestore
import UserNotifications

/// One refused queued action, as recorded on this phone (the input of `offlineSyncResultRows`).
struct OfflineSyncResultRecord: Codable, Identifiable, Equatable {
    let id: String
    let organizationId: String
    let userId: String?
    /// `replace`, `delete` or `edit`.
    let kind: String
    /// `changed`, `permission` or `missing`.
    let reason: String
    var attempted: OfflineSyncSummaryBooking?
    var replaced: [OfflineSyncSummaryBooking] = []
    /// The changed booking as the server has it now; nil with `liveRead` true means it is gone.
    var live: OfflineSyncSummaryBooking?
    var liveRead: Bool = false
    let atMs: Double
    var announced: Bool = false

    var ruleInput: [String: Any] {
        var out: [String: Any] = ["id": id, "kind": kind, "reason": reason, "atMs": atMs]
        if let attempted { out["attempted"] = attempted.json }
        if !replaced.isEmpty { out["replaced"] = replaced.map(\.json) }
        if liveRead { out["live"] = live?.json ?? NSNull() }
        return out
    }
}

/// The notification type the tap routes on (local only; not an inbox type).
nonisolated enum OfflineSyncResultNotification {
    static let type = "offline_sync_result"
    static let identifier = "offline_sync_result"
    /// Set by a tap before the app's shell is on screen; the banner opens "Not synced" when it appears.
    nonisolated(unsafe) static var pendingOpen = false
}

extension Notification.Name {
    /// Open the "Not synced" page (a tap on the local notification, the banner or the sync list row).
    static let openOfflineSyncResults = Notification.Name("openOfflineSyncResults")
}

@MainActor
final class OfflineSyncResultStore: ObservableObject {
    static let shared = OfflineSyncResultStore()

    @Published private(set) var records: [OfflineSyncResultRecord] = []
    /// Notifications were off when results were recorded: the banner shows on the next open until the page is seen.
    @Published var showsBanner: Bool = false

    private let storageKey: String
    private let bannerKey: String

    private init() {
        storageKey = "offline_sync_results_v1"
        bannerKey = "offline_sync_results_banner_v1"
        load()
    }

    #if DEBUG
    /// Tests only: an empty store under its own key.
    init(isolatedStorageKey: String) {
        storageKey = isolatedStorageKey
        bannerKey = isolatedStorageKey + "_banner"
        UserDefaults.standard.removeObject(forKey: isolatedStorageKey)
        UserDefaults.standard.removeObject(forKey: bannerKey)
    }
    #endif

    /// The signed-in account's records (another account's never show on this phone).
    func visibleRecords(userId: String?) -> [OfflineSyncResultRecord] {
        let uid = userId ?? ""
        return records.filter { ($0.userId ?? "").isEmpty || $0.userId == uid }
    }

    /// The page's rows, from the rulebook (`offlineSyncResultRows`).
    func rows(userId: String?) -> [RulebookOfflineSyncResultRow] {
        CanonicalBusinessEngine.offlineSyncResultRows(
            visibleRecords(userId: userId).map(\.ruleInput),
            timeZone: OrganizationRulebookContext.timeZoneIdentifier
        )
    }

    func record(_ record: OfflineSyncResultRecord) {
        records.removeAll { $0.id == record.id }
        records.append(record)
        persist()
    }

    /// "Got it".
    func dismiss(id: String) {
        records.removeAll { $0.id == id }
        if records.isEmpty { showsBanner = false }
        persist()
    }

    /// The page was opened: the banner has done its job.
    func markSeen() {
        showsBanner = false
        persist()
    }

    /// After a sync pass: one local notification for the records not announced yet, or the banner when notifications
    /// are off (or the notification could not be scheduled).
    func announceNew(userId: String? = Auth.auth().currentUser?.uid) async {
        let fresh = visibleRecords(userId: userId).filter { !$0.announced }
        guard !fresh.isEmpty else { return }
        let ids = Set(fresh.map(\.id))
        records = records.map { var r = $0; if ids.contains(r.id) { r.announced = true }; return r }
        persist()
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            showsBanner = true
            persist()
            return
        }
        let text = CanonicalBusinessEngine.offlineSyncResultNotificationText(count: visibleRecords(userId: userId).count)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.userInfo = [NotificationDeepLink.typeKey: OfflineSyncResultNotification.type]
        let request = UNNotificationRequest(identifier: OfflineSyncResultNotification.identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            showsBanner = true
            persist()
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([OfflineSyncResultRecord].self, from: data) {
            records = decoded
        }
        showsBanner = UserDefaults.standard.bool(forKey: bannerKey) && !records.isEmpty
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        UserDefaults.standard.set(showsBanner, forKey: bannerKey)
    }
}

// MARK: - Summary bookings

/// The labels the summary shows for a booking (display only).
enum OfflineSyncSummary {
    /// Job label by lower-cased document id ("J-1042 · Station Road"), kept by `JobAccessContext.updateJobs`.
    nonisolated(unsafe) static var jobLabelsById: [String: String] = [:]

    static func jobLabel(_ jobId: String?) -> String? {
        let key = (jobId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return jobLabelsById[key] ?? "Deleted job"
    }

    static func placeLabel(locationType: String?, locationId: String?, customName: String?) -> String? {
        switch locationType {
        case "project", "small_work": return jobLabel(locationId)
        case "office": return "Office"
        case "working_from_home": return "Working from home"
        case "site_survey": return "Site survey"
        case "custom":
            let name = (customName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        default: return nil
        }
    }

    static func booking(_ booking: Booking) -> OfflineSyncSummaryBooking {
        OfflineSyncSummaryBooking(
            dayKey: OrganizationRulebookContext.dayKey(booking.date),
            place: jobLabel(booking.storedProjectId),
            startTime: booking.workStartTime,
            endTime: booking.workEndTime,
            timeSlot: booking.timeSlot.rawValue
        )
    }

    static func booking(_ booking: ManagerSiteBooking) -> OfflineSyncSummaryBooking {
        OfflineSyncSummaryBooking(
            dayKey: OrganizationRulebookContext.dayKey(booking.date),
            place: placeLabel(
                locationType: booking.locationType.rawValue,
                locationId: booking.storedLocationId,
                customName: booking.customLocationName
            ),
            startTime: booking.workStartTime,
            endTime: booking.workEndTime,
            timeSlot: booking.timeSlot.rawValue
        )
    }

    /// A stored document (the live copy read after a refusal).
    static func stored(_ data: [String: Any], collection: String) -> OfflineSyncSummaryBooking {
        var day: String?
        if let stamp = data["date"] as? Timestamp {
            day = OrganizationRulebookContext.dayKey(stamp.dateValue())
        } else if let date = data["date"] as? Date {
            day = OrganizationRulebookContext.dayKey(date)
        }
        let place = collection == "managerSiteBookings"
            ? placeLabel(
                locationType: data["locationType"] as? String,
                locationId: data["locationId"] as? String,
                customName: data["customLocationName"] as? String
            )
            : jobLabel(data["projectId"] as? String)
        return OfflineSyncSummaryBooking(
            dayKey: day,
            place: place,
            startTime: data["workStartTime"] as? String,
            endTime: data["workEndTime"] as? String,
            timeSlot: data["timeSlot"] as? String
        )
    }
}
