//
//  NotificationService.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import Foundation
import Combine
import UserNotifications
import FirebaseFirestore
import FirebaseAuth
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
class NotificationService: ObservableObject {
    @Published var notifications: [AppNotification] = []
    @Published var unreadCount: Int = 0
    @Published var bookingToastMessage: String?
    
    private(set) var firebaseBackend: FirebaseBackend?
    private var userStore: UserStore?
    private var operativeStore: OperativeStore?
    private var projectStore: ProjectStore?
    private var appSettingsStore: AppSettingsStore?
    private var holidayStore: HolidayStore?
    private var seenBookingNotificationIds: Set<UUID> = []
    private var seenHolidayRequestNotificationKeys: Set<String> = []
    private var seenHolidayDecisionNotificationKeys: Set<String> = []
    private var seenLocalAlertNotificationKeys: Set<String> = []
    private var notificationsListener: ListenerRegistration?
    private var listenerScopeKey: String?
    private var didPrimeNotificationStream = false
    /// Consecutive inbox listener errors. A failed listener is re-attached after a growing delay
    /// so one error does not leave only on-device rows for the rest of the session.
    private var notificationsListenerFailures = 0
    private var hasRequestedLocalNotificationPermission = false
    private var didLoadPersistedLocalAlertDedupKeys = false
    /// FIFO order for dedupe keys — must not use `Set`→`Array` truncation (order is undefined and evicts random keys).
    private var localAlertDedupOrderedKeys: [String] = []
    private var lastProcessedNotificationAt: Date?
    private static let persistedLocalAlertDedupKey = "NotificationService.localAlertDedupKeysV2"
    private static let persistedLastProcessedAtKey = "NotificationService.lastProcessedNotificationAtV1"
    private static let maxPersistedDedupKeys = 400
    private var materialCutoffRefreshTask: Task<Void, Never>?
    /// Deadline reminder/due docs whose `createdAt` is still in the future (inbox hides them until fire time).
    private var pendingScheduledDeadlineNotifications: [AppNotification] = []
    /// True after a launch-time badge warm or an explicit inbox load.
    private var hasLoadedNotificationsThisSession = false
    private var notificationAuthorizationTask: Task<Bool, Never>?
    private var didLogNotificationAuthorization = false
    /// Sets the app-icon badge to the unread inbox count when the app leaves the foreground (§13).
    private var appBackgroundObserver: NSObjectProtocol?
    /// Drops the inbox listener and rows when the account signs out (`.appDidSignOut`), as web `reset()` does.
    private var signOutObserver: NSObjectProtocol?
    /// True once the ordered inbox query failed with `failed-precondition` (its index is missing): listen to the
    /// unordered query (`userId ==` only) and sort on the device, rather than show an empty inbox (web 1.16.0).
    private var inboxUsesUnorderedQuery = false
    /// The pending listener retry, cancelled on reset so a signed-out or switched session never re-attaches.
    private var notificationsListenerRetryTask: Task<Void, Never>?

    init() {
        #if canImport(UIKit)
        appBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncAppIconBadgeToUnreadCount()
            }
        }
        #endif
        // Leave requests made offline notify their approvers once the outbox confirms them (§2).
        DeferredLeaveNoticeQueue.shared.attach(self)
        signOutObserver = NotificationCenter.default.addObserver(
            forName: .appDidSignOut,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetInbox()
            }
        }
    }

    func setFirebaseBackend(_ backend: FirebaseBackend) {
        self.firebaseBackend = backend
        loadPersistedLocalAlertDedupKeysIfNeeded()
        loadLastProcessedNotificationDateIfNeeded()
        requestLocalNotificationPermissionIfNeeded()
    }
    
    func setUserStore(_ store: UserStore) {
        self.userStore = store
        store.notificationService = self
        // RULEBOOK 1.33.0: booking edits on this phone send the overtime reopen notice through this service.
        OvertimeReopenNotice.service = self
    }
    
    func setOperativeStore(_ store: OperativeStore) {
        self.operativeStore = store
    }

    func setProjectStore(_ store: ProjectStore) {
        self.projectStore = store
    }

    func setAppSettingsStore(_ store: AppSettingsStore) {
        self.appSettingsStore = store
    }

    func setHolidayStore(_ store: HolidayStore) {
        self.holidayStore = store
    }

    // MARK: - Recipients (RULEBOOK §13, `notificationRecipients`)

    /// The signed-in account as the recipient rules read it: the actor of every row this app writes
    /// (`actorUserId`). Its sign-in uid counts as one of its ids.
    private var actorPerson: Any {
        let uid = Auth.auth().currentUser?.uid ?? ""
        guard let me = userStore?.currentUser else { return uid }
        var person = RulebookPeople.person(me)
        if !uid.isEmpty, uid != me.id, !me.sameEmailUserIds.contains(uid), !me.formerUserIds.contains(uid) {
            person["sameEmailUserIds"] = me.sameEmailUserIds + [uid]
        }
        return person
    }

    /// The organisation roster for the recipient rules (`RulebookPeople.roster`).
    private var recipientRoster: [[String: Any]] {
        RulebookPeople.roster(userStore?.organizationUsers ?? [])
    }

    /// The operatives catalogue for the recipient rules (`NotificationCataloguePayload`): a booked or assigned
    /// operatives row id resolves to the person's account by its link or email (RULEBOOK 1.16.0 §13).
    private var recipientCatalogue: [[String: Any]] {
        NotificationCataloguePayload.rows(operativeStore?.allOperatives ?? [])
    }

    /// `excludeActor(ids, signed-in user, roster, catalogue)`. RULEBOOK 1.16.0: every id is resolved to the person's
    /// signed-in account (`notificationRecipientAccountId`) inside the rule; an id the roster cannot resolve is dropped.
    /// Empty when the script did not answer: nothing is written.
    private func idsWithoutActor(_ ids: [String]) -> [String] {
        CanonicalBusinessEngine.excludeActor(
            ids: ids,
            actor: actorPerson,
            roster: recipientRoster,
            catalogue: recipientCatalogue
        ) ?? []
    }

    /// Every id of the signed-in person (`personIdSet`), lower case, for "is this row / line manager me" checks.
    private var myIdKeys: Set<String> {
        guard let me = userStore?.currentUser else { return [] }
        var ids = RulebookPeople.ownerIds(for: me, users: userStore?.organizationUsers ?? [])
        if let uid = Auth.auth().currentUser?.uid, !uid.isEmpty { ids.append(uid) }
        return Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    /// True when the row's `userId` is one of the signed-in person's ids (the same test as
    /// `inboxNotificationVisibleToUser`, without the clock).
    private func isAddressedToMe(_ rowUserId: String) -> Bool {
        myIdKeys.contains(rowUserId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    func refreshDailyMaterialCutOffReminder() async {
        materialCutoffRefreshTask?.cancel()
        let task = Task { @MainActor in
            // Coalesce rapid launch/settings churn — only the last call within ~1s should schedule.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await performDailyMaterialCutOffReminderRefresh()
            guard !Task.isCancelled else { return }
            await performTimesheetSubmissionReminderRefresh()
        }
        materialCutoffRefreshTask = task
        await task.value
    }

    private func performDailyMaterialCutOffReminderRefresh() async {
        guard let userStore, let currentUser = userStore.currentUser else {
            await LocalNotificationService.shared.removeAllMaterialCutOffReminders()
            return
        }
        let roleCanReceive = !currentUser.permissions.operativeMode &&
            (currentUser.isSuperAdmin || currentUser.permissions.adminAccess || currentUser.permissions.manager || currentUser.role == .manager || currentUser.role == .admin)
        guard roleCanReceive else {
            await LocalNotificationService.shared.removeAllMaterialCutOffReminders()
            return
        }

        guard firebaseBackend?.currentOrganization != nil else { return }
        guard let clock = OrgMaterialCutOff.resolve(
            stored: firebaseBackend?.currentOrganization?.settings.materialCutOff,
            organizationLoaded: true
        ) else { return }

        let notificationsEnabled = deliveryAllowed(type: AppNotification.NotificationType.materialOrderCutOff.rawValue)
            && clock.materialOrderCutOff
        guard notificationsEnabled else {
            await LocalNotificationService.shared.removeAllMaterialCutOffReminders()
            return
        }

        await LocalNotificationService.shared.scheduleDailyMaterialCutOffReminder(
            hour: clock.materialCutOffHour,
            minute: clock.materialCutOffMinute,
            includeSaturday: clock.materialCutOffOnSaturday,
            includeSunday: clock.materialCutOffOnSunday
        )
    }

    func refreshTimesheetSubmissionReminders() async {
        await performTimesheetSubmissionReminderRefresh()
    }

    /// Inbox row once the notice is due. The device alert is the FCM send for that id, not a local banner.
    /// Only the signed-in person who already participates in timesheets. The toggle neither adds recipients nor
    /// removes the row; it only stops the push.
    private func performTimesheetSubmissionReminderRefresh() async {
        let noticeType = CanonicalBusinessEngine.timesheetSubmissionNoticeType
            ?? AppNotification.NotificationType.timesheetSubmissionReminder.rawValue
        guard let user = userStore?.currentUser, user.isActive, user.participatesInTimesheets() else {
            await LocalNotificationService.shared.removeTimesheetSubmissionReminders()
            return
        }
        // §13: the toggle stops the device push only (`devicePushAllowed`, enforced by the push function for this
        // row); the inbox row is written whatever the toggle says (`notificationShowsInInbox`).
        guard CanonicalBusinessEngine.notificationShowsInInbox(
            prefs: appSettingsStore?.settings.notifications.preferenceValues,
            type: noticeType
        ) else {
            await LocalNotificationService.shared.removeTimesheetSubmissionReminders()
            return
        }
        guard let firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            await LocalNotificationService.shared.removeTimesheetSubmissionReminders()
            return
        }
        let invoicing = firebaseBackend.currentOrganization?.settings.invoicing ?? .default
        let calendar = CanonicalBusinessEngine.businessCalendar
        let now = Date()
        var sawAnswer = false
        var notices: [String: CanonicalBusinessEngine.CanonicalTimesheetSubmissionNotice] = [:]
        var dueNow = Set<String>()
        for offset in [0, 14, 28, 42] {
            guard let anchor = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            guard let rows = CanonicalBusinessEngine.dueTimesheetSubmissionNotices(
                reference: anchor,
                invoicing: invoicing
            ) else { continue }
            sawAnswer = true
            for row in rows {
                notices[row.occurrenceKey] = row
                if offset == 0 { dueNow.insert(row.occurrenceKey) }
            }
        }
        guard sawAnswer else {
            await LocalNotificationService.shared.removeTimesheetSubmissionReminders()
            return
        }
        guard firebaseBackend.currentOrganization?.firestoreDocumentId == organizationId else { return }

        for notice in notices.values {
            guard !notice.title.isEmpty, !notice.message.isEmpty else { continue }
            guard let dedupKey = CanonicalBusinessEngine.timesheetSubmissionNoticeDedupKey(
                organizationId: organizationId,
                paymentDayKey: notice.paymentDayKey,
                runIndex: notice.runIndex,
                userId: user.id
            ) else { continue }
            guard dueNow.contains(notice.occurrenceKey), !notice.message.isEmpty else { continue }
            guard firebaseBackend.currentOrganization?.firestoreDocumentId == organizationId else { return }
            let notification = AppNotification(
                id: syntheticNotificationId(from: dedupKey),
                organizationId: organizationId,
                type: .timesheetSubmissionReminder,
                title: notice.title,
                message: notice.message,
                userId: user.id,
                isRead: false,
                createdAt: Date(),
                deepLinkWeekStart: CanonicalBusinessEngine.date(fromDayKey: notice.paymentDayKey),
                dayKey: notice.paymentDayKey
            )
            await saveNotification(
                notification,
                deliverLocalPush: false,
                preserveExistingReadState: true,
                onlyIfMissing: true,
                stampsActor: false
            )
        }
        await LocalNotificationService.shared.removeTimesheetSubmissionReminders()
    }

    /// Schedules local notifications 3 months, 1 month, 1 week and 1 day before each qualification expiry (09:00).
    /// Operative accounts get reminders for their own linked operative record; each assigned line manager
    /// (`lineManagerUserIds` / legacy `assignedManagerUserId`) gets one set per managed operative.
    func refreshQualificationExpiryReminders() async {
        guard let firebaseBackend,
              firebaseBackend.currentOrganization != nil,
              let userStore,
              let operativeStore,
              let currentUser = userStore.currentUser else {
            await LocalNotificationService.shared.removeQualificationExpiryReminders()
            return
        }

        // Organization users are usually already loaded for Home; avoid a second roster fetch on launch.
        if userStore.organizationUsers.isEmpty {
            await userStore.loadOrganizationUsers()
        }
        let orgUsers = userStore.organizationUsers

        await LocalNotificationService.shared.removeQualificationExpiryReminders()
        let authorized = await LocalNotificationService.shared.requestAuthorization()
        guard authorized else { return }
        guard deliveryAllowed(type: AppNotification.NotificationType.qualificationExpiry.rawValue) else { return }

        let myIds = myIdKeys

        if currentUser.permissions.operativeMode {
            let email = Self.normalizedEmail(currentUser.email)
            guard !email.isEmpty,
                  let op = operativeStore.allOperatives.first(where: { Self.normalizedEmail($0.email) == email }) else {
                return
            }
            await scheduleQualificationExpiryReminders(for: op, audience: .operative)
            return
        }

        for op in operativeStore.allOperatives {
            let opEmail = Self.normalizedEmail(op.email)
            guard let linked = orgUsers.first(where: { Self.normalizedEmail($0.email) == opEmail }) else { continue }
            guard linked.hasLineManager else { continue }
            // `lineManagerIds(user, roster)`: active line managers with alias ids resolved to the roster row.
            let managers = RulebookRosterSnapshot.lineManagerIds(linked) ?? linked.lineManagerUserIds
            let isMyDirectReport = managers.contains { myIds.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            guard isMyDirectReport else { continue }
            await scheduleQualificationExpiryReminders(for: op, audience: .lineManager)
        }
    }

    private enum QualificationExpiryReminderAudience {
        case operative
        case lineManager
    }

    private static func normalizedEmail(_ raw: String) -> String {
        raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleQualificationExpiryReminders(
        for operative: Operative,
        audience: QualificationExpiryReminderAudience
    ) async {
        let cal = Calendar.current
        let now = Date()
        let prefix = LocalNotificationService.qualificationExpiryIdentifierPrefix

        for (qualId, expiryDate) in operative.qualificationExpiryDates {
            let qualName = operative.qualifications.first(where: { $0.id == qualId })?.name ?? "Qualification"
            let expiryStart = cal.startOfDay(for: expiryDate)

            let schedules: [(suffix: String, titleWindow: String, reminderDay: Date?)] = [
                ("3m", "3 months", cal.date(byAdding: .month, value: -3, to: expiryStart)),
                ("1m", "1 month", cal.date(byAdding: .month, value: -1, to: expiryStart)),
                ("1w", "1 week", cal.date(byAdding: .day, value: -7, to: expiryStart)),
                ("1d", "1 day", cal.date(byAdding: .day, value: -1, to: expiryStart)),
            ]
            for schedule in schedules {
                guard let reminderDay = schedule.reminderDay else { continue }
                guard let fireAt = cal.date(bySettingHour: 9, minute: 0, second: 0, of: reminderDay) else { continue }
                guard fireAt > now else { continue }

                let expiryFormatted = expiryDate.formatted(date: .abbreviated, time: .omitted)
                let title = "Qualification expiring in \(schedule.titleWindow)"
                let body: String
                switch audience {
                case .operative:
                    body = "\(qualName) expires on \(expiryFormatted). Please renew before the expiry date."
                case .lineManager:
                    body = "\(operative.name): \(qualName) expires on \(expiryFormatted)."
                }
                let roleTag = audience == .operative ? "op" : "lm"
                let ident = "\(prefix)\(operative.id.uuidString)-\(qualId)-\(schedule.suffix)-\(roleTag)"
                await LocalNotificationService.shared.scheduleQualificationExpiryOneShot(
                    identifier: ident,
                    title: title,
                    body: body,
                    fireAt: fireAt
                )
            }
        }
    }
    
    // MARK: - Notification Creation
    
    func notifyBookingCreated(
        bookingId: UUID,
        operativeId: UUID,
        projectName: String,
        date: Date,
        createdBy: String,
        projectId: UUID? = nil,
        catalogue: String? = nil
    ) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        // Notify the specific person who was booked
        guard let userStore = userStore else { return }
        await userStore.loadOrganizationUsers()
        // RULEBOOK 1.16.0 §13 `bookingCreatedRecipients(bookedIds, booker, roster, catalogue)`: the booked id as stored
        // (an operatives row, a uid or a former id) resolves to the person's account; never the booker, so booking
        // yourself writes nothing.
        let storedOperativeId = Booking.storedOperativeId(for: operativeId)
        guard let canonicalUserId = CanonicalBusinessEngine.bookingCreatedRecipients(
            bookedIds: [storedOperativeId],
            booker: actorPerson,
            roster: recipientRoster,
            catalogue: recipientCatalogue
        )?.first else { return }
        let dedupeId = syntheticNotificationId(from: "bookingCreated|\(bookingId.uuidString)|\(canonicalUserId)")
        let notification = AppNotification(
            id: dedupeId,
            organizationId: organizationId,
            type: .bookingCreated,
            title: "You've Been Booked",
            message: "\(createdBy) booked you for \(projectName) on \(date.formatted(date: .abbreviated, time: .omitted))",
            userId: canonicalUserId,
            relatedId: projectId ?? bookingId,
            requiresPermission: nil,
            dayKey: CanonicalBusinessEngine.dayKey(for: date),
            catalogue: catalogue
        )
        await saveNotification(notification)
    }
    
    // RULEBOOK 1.10.0 §13: no ownerless "New Booking Created" row (a row without `userId` is not an inbox row).
    // Booked people are told by `notifyBookedUsers` (`bookingCreatedRecipients`).

    func notifyBookedUsers(
        projectName: String,
        bookedBy: String,
        recipients: [BookedUserRecipient],
        projectId: UUID? = nil,
        catalogue: String? = nil,
        organizationId expectedOrganizationId: String? = nil
    ) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId,
              let userStore,
              let operativeStore else { return }
        guard !recipients.isEmpty else { return }
        // 1.33.1: the bookings were saved in `expectedOrganizationId`. If another organisation is open now its roster
        // cannot name these people, so nothing is written there.
        if BookingStore.organizationChanged(captured: expectedOrganizationId, open: organizationId) {
            print("🔥🔥🔥 DEBUG: Booking notices skipped: the organisation changed since the save")
            return
        }
        
        if userStore.organizationUsers.isEmpty {
            await userStore.loadOrganizationUsers()
        }
        
        // RULEBOOK 1.16.0 §13 `bookingCreatedRecipients(bookedIds, booker, roster, catalogue)`: each booked id as
        // stored (operatives row, uid, former or same-email id) resolves to the person's signed-in account inside the
        // rule (`notificationRecipientAccountId`); never the booker, so booking yourself writes nothing.
        _ = operativeStore
        let booker = actorPerson
        let roster = recipientRoster
        let operativesCatalogue = recipientCatalogue
        for recipient in recipients {
            guard let canonicalUserId = CanonicalBusinessEngine.bookingCreatedRecipients(
                bookedIds: [Booking.storedOperativeId(for: recipient.operativeId)],
                booker: booker,
                roster: roster,
                catalogue: operativesCatalogue
            )?.first else { continue }
            let dateText = recipient.dates
                .sorted()
                .map { $0.formatted(date: .abbreviated, time: .omitted) }
                .joined(separator: ", ")
            let message = dateText.isEmpty
                ? "\(bookedBy) booked you for \(projectName)."
                : "\(bookedBy) booked you for \(projectName) on \(dateText)."
            let dedupeKey = "bookedUsers|\(canonicalUserId)|\(recipient.operativeId.uuidString)|\(projectName.lowercased())|\(dateText.lowercased())"
            let dedupeRelatedId = syntheticNotificationId(from: "bookedUsersRelated|\(dedupeKey)")
            
            let day = recipient.dates.sorted().first
            let notification = AppNotification(
                id: syntheticNotificationId(from: dedupeKey),
                organizationId: organizationId,
                type: .bookingCreated,
                title: "You've Been Booked",
                message: message,
                userId: canonicalUserId,
                relatedId: projectId ?? dedupeRelatedId,
                requiresPermission: nil,
                dayKey: day.map { CanonicalBusinessEngine.dayKey(for: $0) },
                catalogue: catalogue
            )
            await saveNotification(notification)
        }
    }
    
    struct BookedUserRecipient {
        let operativeId: UUID
        let dates: [Date]
    }
    
    /// Rulebook 1.4.0 §13: a company activity notice (`COMPANY_ACTIVITY_NOTICE_TYPES`) is one row per id from
    /// `companyActivityRecipients(actor, roster)` — the active admins outside operative mode, never the actor —
    /// each with `userId` and `actorUserId` (`saveNotification` stamps it). Never written without `userId`.
    /// `dedupeKey` names the event; each recipient's row id is derived from it.
    private func saveCompanyActivityNotice(
        type: AppNotification.NotificationType,
        title: String,
        message: String,
        relatedId: UUID?,
        dedupeKey: String
    ) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        if let userStore, userStore.organizationUsers.isEmpty {
            await userStore.loadOrganizationUsers()
        }
        // Nil when the script did not answer: nothing is written (never an ownerless row).
        guard let recipientIds = CanonicalBusinessEngine.companyActivityRecipients(
            actor: actorPerson,
            roster: recipientRoster
        ) else { return }
        for recipientId in recipientIds {
            let notification = AppNotification(
                id: syntheticNotificationId(from: "\(dedupeKey)|\(recipientId)"),
                organizationId: organizationId,
                type: type,
                title: title,
                message: message,
                userId: recipientId,
                relatedId: relatedId,
                requiresPermission: nil
            )
            await saveNotification(notification)
        }
    }

    func notifyOperativeCreated(operativeId: UUID, operativeName: String, createdBy: String) async {
        await saveCompanyActivityNotice(
            type: .operativeCreated,
            title: "New Operative Created",
            message: "\(createdBy) created a new operative: \(operativeName)",
            relatedId: operativeId,
            dedupeKey: "operativeCreated|\(operativeId.uuidString)"
        )
    }
    
    /// RULEBOOK 1.31.0 §13: an operative was deleted (`operative_deleted`, company activity, never the actor). Copy as
    /// web `lib/stores/userStore.ts` `deleteUser`.
    func notifyOperativeDeleted(userId: String, name: String) async {
        await saveCompanyActivityNotice(
            type: .operativeDeleted,
            title: "Operative deleted",
            message: "\(name) was deleted.",
            relatedId: nil,
            dedupeKey: "operativeDeleted|\(userId)"
        )
    }

    /// RULEBOOK 1.31.0 §11: a person stopped being a manager and was taken off `jobCount` jobs
    /// (`JOB_MANAGER_REMOVED_NOTICE_TYPE`, `jobManagerRemovedNoticeText`).
    func notifyJobManagerRemoved(personId: String, name: String, jobCount: Int) async {
        let text = CanonicalBusinessEngine.jobManagerRemovedNoticeText(name: name, jobCount: jobCount)
        await saveCompanyActivityNotice(
            type: .jobManagerRemoved,
            title: text.title,
            message: text.message,
            relatedId: nil,
            dedupeKey: "jobManagerRemoved|\(personId)|\(Int(Date().timeIntervalSince1970))"
        )
    }

    /// RULEBOOK 1.31.0 §13 (owner decision 7): an operative-level person was invited (`operative_created`), by an admin
    /// or a manager with the Operatives permission. Copy as web `lib/stores/inviteStore.ts`.
    func notifyOperativeInvited(userId: String, name: String) async {
        await saveCompanyActivityNotice(
            type: .operativeCreated,
            title: "Operative added",
            message: "\(name) was added as an operative.",
            relatedId: nil,
            dedupeKey: "operativeInvited|\(userId)"
        )
    }

    func notifyManagerCreated(managerId: UUID, managerName: String, createdBy: String) async {
        await saveCompanyActivityNotice(
            type: .managerCreated,
            title: "New Manager Created",
            message: "\(createdBy) created a new manager: \(managerName)",
            relatedId: managerId,
            dedupeKey: "managerCreated|\(managerId.uuidString)"
        )
    }
    
    func notifyClientCreated(clientId: UUID, clientName: String, createdBy: String) async {
        await saveCompanyActivityNotice(
            type: .clientCreated,
            title: "New Client Created",
            message: "\(createdBy) added a new client: \(clientName)",
            relatedId: clientId,
            dedupeKey: "clientCreated|\(clientId.uuidString)"
        )
    }
    
    func notifyProjectCreated(projectId: UUID, siteName: String, jobNumber: String, createdBy: String) async {
        let detail = jobNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? siteName
            : "\(jobNumber) · \(siteName)"
        await saveCompanyActivityNotice(
            type: .projectCreated,
            title: "New Project",
            message: "\(createdBy) added a new project: \(detail)",
            relatedId: projectId,
            dedupeKey: "projectCreated|\(projectId.uuidString)"
        )
    }
    
    func notifySmallWorksCreated(smallWorkId: UUID, siteName: String, jobNumber: String, createdBy: String) async {
        let detail = jobNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? siteName
            : "\(jobNumber) · \(siteName)"
        await saveCompanyActivityNotice(
            type: .smallWorksCreated,
            title: "New Small Works",
            message: "\(createdBy) added new small works: \(detail)",
            relatedId: smallWorkId,
            dedupeKey: "smallWorksCreated|\(smallWorkId.uuidString)"
        )
    }

    /// One notification per recipient when a variation is raised on iOS. Web must do the same on its create path — do not also add a Cloud Function or recipients get two.
    /// RULEBOOK §13: `receivesJobNotification` with the job's managers (their accounts, from
    /// `materialOrderRecipients`), then `excludeActor`. `createdByUserId` is the signed-in creator.
    func notifyVariationAdded(
        parentId: UUID,
        parentName: String,
        isSmallWorks: Bool,
        createdByUserId: String,
        jobManagerIds: [UUID] = [],
        variationId: String? = nil
    ) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let users = userStore?.organizationUsers ?? []
        let jobManagerUserIds = MaterialOrderRecipientsRulebook.recipientUserIds(
            jobManagerIds: jobManagerIds.map(\.uuidString),
            managers: operativeStore?.managers ?? [],
            accounts: users,
            adder: nil,
            adderUserId: nil
        ) ?? []
        var candidates: [String] = []
        for user in users {
            guard user.isActive else { continue }
            let notified = CanonicalBusinessEngine.receivesJobNotification(
                userId: user.id,
                role: UserStore.staffAccountRole(for: user),
                assignedManagerUserIds: jobManagerUserIds
            )
            if notified {
                candidates.append(user.id)
            }
        }
        let recipientIds = idsWithoutActor(candidates)
        print("🔥🔥🔥 DEBUG: [VARIATION NOTIFY] creator=\(createdByUserId) recipients=\(recipientIds.count)")
        for userId in recipientIds {
            let notification = AppNotification(
                organizationId: organizationId,
                type: .variationAdded,
                title: "New variation added",
                message: "New variation added to \(parentName)",
                userId: userId,
                // RULEBOOK 1.10.0 §13: `variation_added` carries the variation id (`notificationRelatedIdFor`).
                relatedKey: CanonicalBusinessEngine.callJSON("notificationRelatedIdFor", arguments: ["variation_added", variationId ?? parentId.uuidString]) as? String,
                deepLinkUserId: isSmallWorks ? VariationParentType.smallWork.rawValue : VariationParentType.project.rawValue
            )
            await saveNotification(notification)
        }
    }

    func notifyMaterialAdded(
        projectId: UUID,
        siteName: String,
        materialName: String,
        addedByName: String,
        addedByUserId: String?,
        extraRecipientUserIds: [String],
        rulebookRecipientUserIds: [String]? = nil
    ) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        // RULEBOOK §13: `materialOrderRecipients` (the job's managers only), then `excludeActor`. There is no
        // "all admins" fallback: a job with no managers, or no answer from the script, notifies nobody.
        guard let rulebookRecipientUserIds else {
            print("🔥🔥🔥 DEBUG: [MATERIAL NOTIFY] materialOrderRecipients did not answer; no notice written (adder=\(addedByUserId ?? "nil"), extra=\(extraRecipientUserIds.count))")
            return
        }
        let recipientIds = idsWithoutActor(rulebookRecipientUserIds)
        guard !recipientIds.isEmpty else { return }
        let trimmedMaterial = materialName.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = trimmedMaterial.isEmpty ? "a material" : trimmedMaterial
        for userId in recipientIds {
            let notification = AppNotification(
                organizationId: organizationId,
                type: .materialOrderPlaced,
                title: "Material added",
                message: "\(addedByName) added \(detail) on \(siteName).",
                userId: userId,
                relatedId: projectId
            )
            await saveNotification(notification)
        }
    }

    /// Writes one inbox row per recipient when a toolbox talk is issued. The issuer is excluded.
    /// Recipient ids are resolved across same-email accounts so the signed-in phone sees the alert.
    func notifyToolboxTalkIssued(
        projectId: UUID,
        siteName: String,
        talkTitle: String,
        issuedByName: String,
        issuedByUserId: String?,
        recipientUserIds: [String],
        issueId: String? = nil
    ) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        // `toolboxTalkRecipients`: the chosen people without the issuer (the signed-in user).
        let recipientIds = CanonicalBusinessEngine.toolboxTalkRecipients(
            ids: recipientUserIds,
            issuer: actorPerson,
            roster: recipientRoster
        ) ?? []
        guard !recipientIds.isEmpty else {
            print("🔥🔥🔥 DEBUG: [TOOLBOX NOTIFY] no recipients (issuer=\(issuedByUserId ?? "nil"))")
            return
        }
        let trimmedTitle = talkTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = trimmedTitle.isEmpty ? "a toolbox talk" : trimmedTitle
        let site = siteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = site.isEmpty ? "a job" : site
        for userId in recipientIds {
            let notification = AppNotification(
                organizationId: organizationId,
                type: .toolboxTalkIssued,
                title: "Toolbox talk issued",
                message: "\(issuedByName) issued \(detail) on \(place).",
                userId: userId,
                // RULEBOOK 1.10.0 §13: `toolbox_talk_issued` carries the issue id (`notificationRelatedIdFor`).
                relatedKey: issueId.flatMap { CanonicalBusinessEngine.callJSON("notificationRelatedIdFor", arguments: ["toolbox_talk_issued", $0]) as? String }
                    ?? projectId.uuidString
            )
            await saveNotification(notification)
        }
    }
    
    /// Notifies the admins (`companyActivityRecipients`, never the person who dismissed it) when a warning is
    /// dismissed. Appears in their notification centre.
    func notifyWarningRemoved(warning: Warning, removedBy: String) async {
        let detail = warning.removalNotificationDetail
        let typeLabel: String = {
            switch warning.type {
            case .operativeBookingClash: return "Operative booking clash"
            case .managerLocationClash: return warning.clashPersonKind?.bookingClashTitle ?? "Manager booking clash"
            case .unbookedLabour: return "Unbooked labour"
            case .annualLeave: return "Annual leave"
            case .materialsCutoff: return "Materials cut-off"
            case .qualificationExpiry: return "Qualification expiry"
            case .operativeNotVerified: return "Operative not verified"
            }
        }()
        // Unique per dismiss so repeated dismissals of different warnings never collapse in the inbox.
        let dismissId = UUID()
        await saveCompanyActivityNotice(
            type: .warningRemoved,
            title: "Warning dismissed by \(removedBy)",
            message: "\(removedBy) dismissed a \(typeLabel.lowercased()) warning. Dismissed warnings do not reappear.\n\n\(detail)",
            relatedId: nil,
            dedupeKey: "warningRemoved|\(dismissId.uuidString)"
        )
    }
    
    /// RULEBOOK 1.10.0 §13 `task_completed`: `taskCompletedRecipients(task, completer, roster)` — the task's creator
    /// (`createdByUserId`, else the one active person named `createdBy`), never the person who completed it.
    func notifyTaskCompleted(task: ProjectTask, completedBy: String) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let users = userStore?.organizationUsers ?? []
        let completer: Any
        if let me = userStore?.currentUser {
            completer = RulebookPeople.person(me)
        } else {
            completer = firebaseBackend.currentUser?.uid ?? ""
        }
        var roster = RulebookPeople.roster(users)
        for (index, user) in users.enumerated() where index < roster.count {
            roster[index]["firstName"] = user.firstName
            roster[index]["surname"] = user.surname
        }
        let taskRow: [String: Any] = [
            "createdByUserId": task.createdByUserId ?? NSNull(),
            "createdBy": task.createdBy,
        ]
        guard let recipients = CanonicalBusinessEngine.callJSON(
            "taskCompletedRecipients", arguments: [taskRow, completer, roster]
        ) as? [String] else { return }
        for recipient in recipients {
            let notification = AppNotification(
                id: syntheticNotificationId(from: "taskCompleted|\(task.id.uuidString)|\(recipient)"),
                organizationId: organizationId,
                type: .taskCompleted,
                title: "Task Completed",
                message: "\(completedBy) completed the task: \(task.title)",
                userId: recipient,
                relatedId: task.id,
                requiresPermission: nil
            )
            await saveNotification(notification)
        }
    }
    
    func notifyTaskCreated(taskId: UUID, taskTitle: String, createdBy: String, assignedOperativeIds: [UUID], assignedManagerIds: [UUID]) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        // Notify only the specific operatives assigned to this task
        // We need to match operative IDs to AppUser emails
        if let userStore = userStore, let operativeStore = operativeStore {
            // Load organization users to find operative user IDs
            await userStore.loadOrganizationUsers()
            
            // Get operatives from operativeStore to match by ID
            let operatives = operativeStore.allOperatives
            
            for operativeId in assignedOperativeIds {
                // Find the operative by ID
                if let operative = operatives.first(where: { $0.id == operativeId }) {
                    // Find the AppUser for this operative by matching email
                    if let operativeUser = userStore.organizationUsers.first(where: { user in
                        user.email.lowercased() == operative.email.lowercased() && user.permissions.operativeMode
                    }) {
                        // Catalog `task_created`: `excludeActor` (the assignees without the creator; the account resolved
                        // inside the rule, RULEBOOK 1.16.0).
                        guard let canonicalUserId = idsWithoutActor([operativeUser.id]).first else { continue }
                        let dedupeId = syntheticNotificationId(from: "taskCreated|\(taskId.uuidString)|\(canonicalUserId)")
                        // Create notification for this specific operative
                        let notification = AppNotification(
                            id: dedupeId,
                            organizationId: organizationId,
                            type: .taskCreated,
                            title: "New Task Assigned",
                            message: "\(createdBy) assigned you a new task: \(taskTitle)",
                            userId: canonicalUserId,
                            relatedId: taskId,
                            requiresPermission: nil // No permission check needed since it's user-specific
                        )
                        await saveNotification(notification)
                    }
                }
            }

            let managers = operativeStore.allManagers
            for managerId in assignedManagerIds {
                guard let manager = managers.first(where: { $0.id == managerId }) else { continue }
                if let managerUser = userStore.organizationUsers.first(where: { user in
                    user.email.lowercased() == manager.email.lowercased() && !user.permissions.operativeMode
                }) {
                    guard let canonicalUserId = idsWithoutActor([managerUser.id]).first else { continue }
                    let dedupeId = syntheticNotificationId(from: "taskCreated|\(taskId.uuidString)|\(canonicalUserId)")
                    let notification = AppNotification(
                        id: dedupeId,
                        organizationId: organizationId,
                        type: .taskCreated,
                        title: "New Task Assigned",
                        message: "\(createdBy) assigned you a new task: \(taskTitle)",
                        userId: canonicalUserId,
                        relatedId: taskId,
                        requiresPermission: nil
                    )
                    await saveNotification(notification)
                }
            }
        }
    }

    func notifyDeadlineAssigned(
        deadlineId: UUID,
        title: String,
        projectName: String,
        assignedUserIds: [String],
        createdBy: String
    ) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        // `deadlineAssignedRecipients`: the added assignees without the person who assigned them (each id resolved to
        // the person's account inside the rule, RULEBOOK 1.16.0).
        let recipients = CanonicalBusinessEngine.deadlineAssignedRecipients(
            addedIds: assignedUserIds,
            actor: actorPerson,
            roster: recipientRoster
        ) ?? []
        let storedDeadlineId = WorkDocumentKeys.storedId(for: deadlineId)
        for canonicalUserId in recipients {
            // Same key as web (`deadlineAssigned|{stored deadline id}|{userId}`): the deadline id in its stored case
            // (`WorkDocumentKeys.storedId`), so a web-created lower-case deadline gives both apps one row id.
            let dedupeId = syntheticNotificationId(from: "deadlineAssigned|\(storedDeadlineId)|\(canonicalUserId)")
            let notification = AppNotification(
                id: dedupeId,
                organizationId: organizationId,
                type: .deadlineAssigned,
                title: "Deadline assigned",
                message: "\(createdBy) assigned you a deadline on \(projectName): \(title)",
                userId: canonicalUserId,
                relatedId: deadlineId,
                requiresPermission: nil
            )
            await saveNotification(notification)
        }
    }

    /// Writes reminder + due-today inbox rows for every assignee so they appear in Notification Center,
    /// not only as OS banners. `createdAt` is the fire time; future rows stay hidden until then.
    func syncDeadlineInboxNotifications(items: [DLDeadline], projectName: String) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }

        for item in items {
            guard item.status != .complete else { continue }
            for rawId in item.assigneeUserIds {
                // Scheduled notice (nobody caused it): `notificationRecipientAccountId` — the assignee's signed-in
                // account; an id the roster cannot resolve is dropped (RULEBOOK 1.16.0 §13).
                guard let canonicalUserId = CanonicalBusinessEngine.notificationRecipientAccountId(
                    rawId,
                    roster: recipientRoster,
                    catalogue: recipientCatalogue
                ) else { continue }

                if let fireAt = DeadlineLocalNotifications.reminderFireDate(for: item) {
                    let notification = AppNotification(
                        id: syntheticNotificationId(from: "deadlineReminder|\(item.id.uuidString)|\(canonicalUserId)"),
                        organizationId: organizationId,
                        type: .deadlineReminder,
                        title: DeadlineNotificationCopy.reminderTitle(),
                        message: DeadlineNotificationCopy.reminderBody(projectName: projectName, item: item),
                        userId: canonicalUserId,
                        relatedId: item.id,
                        createdAt: fireAt,
                        requiresPermission: nil
                    )
                    await saveNotification(notification, deliverLocalPush: false, preserveExistingReadState: true, stampsActor: false)
                }

                if let dueMorning = DeadlineLocalNotifications.dueFireDate(for: item) {
                    let notification = AppNotification(
                        id: syntheticNotificationId(from: "deadlineDue|\(item.id.uuidString)|\(canonicalUserId)"),
                        organizationId: organizationId,
                        type: .deadlineDue,
                        title: DeadlineNotificationCopy.dueTitle(),
                        message: DeadlineNotificationCopy.dueBody(projectName: projectName, item: item),
                        userId: canonicalUserId,
                        relatedId: item.id,
                        createdAt: dueMorning,
                        requiresPermission: nil
                    )
                    await saveNotification(notification, deliverLocalPush: false, preserveExistingReadState: true, stampsActor: false)
                }
            }
        }
    }

    /// `excludeUserIdMatchingRequester` should be the Firebase Auth uid (or app user id) of the person who submitted the request.
    /// They must not receive the "someone requested leave" admin notification or OS banner.
    func notifyHolidayRequestSubmitted(
        bookingId: UUID,
        operativeName: String,
        startDate: Date,
        endDate: Date,
        assignedManagerUserId: String?,
        requesterUserId: String? = nil,
        excludeUserIdMatchingRequester: String? = nil,
        cancellation: Bool = false,
        organizationId requestedOrganizationId: String? = nil
    ) async {
        guard let firebaseBackend = firebaseBackend else { return }
        // The request's own organisation when given (a deferred notice released after a switch), else the open one.
        let openOrganizationId = firebaseBackend.currentOrganization?.firestoreDocumentId
        let requested = requestedOrganizationId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let organizationId = requested.isEmpty ? openOrganizationId : Optional(requested) else { return }
        let isOpenOrganization = organizationIdsMatch(openOrganizationId, organizationId)
        // Another organisation's recipients come from that organisation's own roster (read from the server),
        // never from the open company's list or a cache (rule 2).
        var otherRoster: [AppUser]? = nil
        if !isOpenOrganization {
            guard let roster = try? await firebaseBackend.getOrganizationUsers(organizationId: organizationId),
                  !roster.users.isEmpty else {
                print("🔥🔥🔥 DEBUG: [HOLIDAY NOTIFY SUBMIT] roster for \(organizationId) did not load; no request notice written")
                return
            }
            otherRoster = roster.users
        }
        // Same copy and key as web `buildHolidayRequestSubmittedNotifications` (request or cancellation).
        let dateRange = AnnualLeaveNoticeText.requestRange(start: startDate, end: endDate)
        let keyPrefix = cancellation ? "holidayCancellation" : "holidaySubmitted"
        let title = cancellation ? "Annual Leave Cancellation" : "Annual Leave Request"
        let what = cancellation ? "annual leave cancellation" : "annual leave"

        let recipients = await holidayRequestTargets(
            requesterUserId: requesterUserId ?? excludeUserIdMatchingRequester,
            assignedManagerUserId: assignedManagerUserId,
            users: otherRoster
        )
        print("🔥🔥🔥 DEBUG: [HOLIDAY NOTIFY SUBMIT] bookingId=\(bookingId.uuidString) operative=\(operativeName) assignedManager=\(assignedManagerUserId ?? "nil") recipients=\(recipients)")
        for targetId in recipients {
            let dedupeId = syntheticNotificationId(from: "\(keyPrefix)|\(bookingId.uuidString)|\(targetId)")
            let toManager = AppNotification(
                id: dedupeId,
                organizationId: organizationId,
                type: .holidayRequestSubmitted,
                title: title,
                message: "\(operativeName) requested \(what) \(dateRange). Tap to review.",
                userId: targetId,
                relatedId: bookingId,
                requiresPermission: nil
            )
            await saveNotification(
                toManager,
                deliverLocalPush: isOpenOrganization,
                organizationId: isOpenOrganization ? nil : organizationId
            )
        }
    }

    func notifyHolidayRequestSubmittedByUser(
        bookingId: UUID,
        requesterUserId: String,
        requesterName: String,
        startDate: Date,
        endDate: Date,
        assignedManagerUserId: String?
    ) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let dateRange = AnnualLeaveNoticeText.requestRange(start: startDate, end: endDate)
        let recipients = await holidayRequestTargets(
            requesterUserId: requesterUserId,
            assignedManagerUserId: assignedManagerUserId
        )
        print("🔥🔥🔥 DEBUG: [HOLIDAY NOTIFY SUBMIT_BY_USER] bookingId=\(bookingId.uuidString) requester=\(requesterName) assignedManager=\(assignedManagerUserId ?? "nil") recipients=\(recipients)")
        for targetId in recipients {
            let dedupeId = syntheticNotificationId(from: "holidaySubmitted|\(bookingId.uuidString)|\(targetId)")
            let toManager = AppNotification(
                id: dedupeId,
                organizationId: organizationId,
                type: .holidayRequestSubmitted,
                title: "Annual Leave Request",
                message: "\(requesterName) requested annual leave \(dateRange). Tap to review.",
                userId: targetId,
                relatedId: bookingId,
                requiresPermission: nil
            )
            await saveNotification(toManager)
        }
    }

    func notifyHolidayRequestDecisionToUser(userId: String, bookingId: UUID, approved: Bool, decidedByName: String, reason: String = "") async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        // `holidayDecisionRecipients`: the requester's account, unless they decided.
        guard let targetId = holidayDecisionTarget(userId) else { return }
        print("🔥🔥🔥 DEBUG: [HOLIDAY NOTIFY DECISION] bookingId=\(bookingId.uuidString) approved=\(approved) decidedBy=\(decidedByName) target=\(targetId) original=\(userId)")
        let dedupeId = syntheticNotificationId(from: "holidayDecision|\(bookingId.uuidString)|\(targetId)|\(approved)")
        let trimmedReason = CanonicalBusinessEngine.parseHolidayDecisionNote(reason) ?? ""
        let storedNote = CanonicalBusinessEngine.parseHolidayDecisionNote(
            holidayStore?.bookings.first(where: { $0.id == bookingId })?.decisionNote
        ) ?? ""
        let note = trimmedReason.isEmpty ? storedNote : trimmedReason
        let dateText = annualLeaveDateText(bookingId: bookingId)
        let when = dateText.isEmpty ? "" : " for \(dateText)"
        let decisionMessage: String
        if approved {
            decisionMessage = note.isEmpty
                ? "\(decidedByName) approved your annual leave request\(when)."
                : "\(decidedByName) approved your annual leave request\(when). \(note)"
        } else if note.isEmpty {
            decisionMessage = "\(decidedByName) declined your annual leave request\(when)."
        } else {
            decisionMessage = "\(decidedByName) declined your annual leave request\(when). \(note)"
        }
        let notification = AppNotification(
            id: dedupeId,
            organizationId: organizationId,
            type: approved ? .holidayRequestApproved : .holidayRequestDeclined,
            title: approved ? "Annual Leave Approved" : "Annual Leave Declined",
            message: decisionMessage,
            userId: targetId,
            relatedId: bookingId,
            requiresPermission: nil
        )
        await saveNotification(notification)
    }

    /// In-app notice and email when a line manager deletes or cancels someone's annual leave.
    func notifyAnnualLeaveCancelledByManager(
        userId: String,
        booking: HolidayBooking,
        managerName: String
    ) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        guard let targetId = holidayDecisionTarget(userId) else { return }
        let dateText = annualLeaveDateText(for: booking)
        let message = "\(managerName) has cancelled your annual leave request for \(dateText)."
        let dedupeId = syntheticNotificationId(from: "annualLeaveCancelled|\(booking.id.uuidString)|\(targetId)")
        let notification = AppNotification(
            id: dedupeId,
            organizationId: organizationId,
            // RULEBOOK 1.10.0 §13: its own type (was `holiday_request_declined`), to `holidayDecisionRecipients`.
            type: .holidayCancelledByManager,
            title: "Annual Leave Cancelled",
            message: message,
            userId: targetId,
            relatedId: booking.id,
            requiresPermission: nil
        )
        await saveNotification(notification)
        let email = userStore?.organizationUsers.first(where: { $0.id == targetId })?.email
            ?? userStore?.organizationUsers.first(where: { $0.id == userId })?.email
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedEmail.isEmpty else { return }
        let firstName = userStore?.organizationUsers.first(where: { $0.email.lowercased() == trimmedEmail.lowercased() })?.firstName ?? ""
        let greeting = firstName.isEmpty ? "Hello" : "Hello \(firstName)"
        let plain = """
        \(greeting),

        \(message)

        This was sent from Project Planner.
        """
        let html = MaterialRequestEmailBuilder.plainTextAsSimpleHTML(plain)
        let sent = await ResendEmailService().sendEmail(
            to: trimmedEmail,
            subject: ExportTextEscaping.sanitizeEmailSubject("Annual leave cancelled"),
            htmlContent: html
        )
        print("🔥🔥🔥 DEBUG: [HOLIDAY CANCEL EMAIL] to=\(trimmedEmail) sent=\(sent)")
    }

    /// RULEBOOK §13 `holiday_request_declined` (a cancellation refused): the requester is told their leave stays
    /// booked. Recipients are `holidayDecisionRecipients` (never the person who refused).
    func notifyAnnualLeaveCancellationRefused(
        userId: String,
        booking: HolidayBooking,
        decidedByName: String
    ) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        guard let targetId = holidayDecisionTarget(userId) else { return }
        let dateText = annualLeaveDateText(for: booking)
        let when = dateText.isEmpty ? "" : " for \(dateText)"
        let requestedAt = Int((booking.cancellationRequestedAt ?? Date()).timeIntervalSince1970)
        let notification = AppNotification(
            id: syntheticNotificationId(from: "annualLeaveCancellationRefused|\(booking.documentId)|\(targetId)|\(requestedAt)"),
            organizationId: organizationId,
            type: .holidayRequestDeclined,
            title: "Annual Leave Kept",
            message: "\(decidedByName) refused your request to cancel annual leave\(when). Your leave stays booked.",
            userId: targetId,
            relatedId: booking.id,
            requiresPermission: nil
        )
        await saveNotification(notification)
    }

    private func annualLeaveDateText(bookingId: UUID) -> String {
        guard let booking = holidayStore?.bookings.first(where: { $0.id == bookingId }) else { return "" }
        return annualLeaveDateText(for: booking)
    }

    /// Web `annualLeaveDecisionDateText` (same copy on both apps).
    private func annualLeaveDateText(for booking: HolidayBooking) -> String {
        AnnualLeaveNoticeText.decisionDateText(booking)
    }

    /// Sent when a manager/admin books approved annual leave on behalf of a team member.
    func notifyAnnualLeaveBookingConfirmation(
        userId: String,
        bookingId: UUID,
        bookedByName: String,
        startDate: Date,
        endDate: Date,
        timeSlot: HolidayTimeSlot
    ) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        // `holidayDecisionRecipients`: the person whose leave was booked, unless they booked it themselves.
        guard let targetId = holidayDecisionTarget(userId) else { return }
        let dateRange: String
        if OrganizationRulebookContext.calendar.isDate(startDate, inSameDayAs: endDate) {
            dateRange = startDate.formatted(date: .abbreviated, time: .omitted)
        } else {
            dateRange = "\(startDate.formatted(date: .abbreviated, time: .omitted)) – \(endDate.formatted(date: .abbreviated, time: .omitted))"
        }
        let dedupeId = syntheticNotificationId(from: "annualLeaveBooked|\(bookingId.uuidString)|\(targetId)")
        let notification = AppNotification(
            id: dedupeId,
            organizationId: organizationId,
            // RULEBOOK 1.10.0 §13: its own type (was `holiday_request_approved`), to `holidayDecisionRecipients`.
            type: .holidayBookedForYou,
            title: "Annual Leave Booking Confirmation",
            message: "\(bookedByName) booked your annual leave for \(dateRange) (\(timeSlot.rawValue)). Tap to view your annual leave.",
            userId: targetId,
            relatedId: bookingId,
            requiresPermission: nil
        )
        await saveNotification(notification)
    }

    /// Sent when a user signs their timesheet (RULEBOOK §13): one row per `timesheetSubmittedRecipients(subject,
    /// roster)` — the subject's active line managers, else the active admins; never the subject; nobody when the
    /// sheet is self-signed. Document ids come from `timesheetNotificationDedupeKey` (organisation-zone period start).
    func notifyTimesheetSubmitted(
        signedByUser: AppUser,
        weekStart: Date
    ) async {
        guard let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId else { return }
        if let userStore, userStore.organizationUsers.isEmpty {
            await userStore.loadOrganizationUsers()
        }
        let users = userStore?.organizationUsers ?? []
        guard let recipients = CanonicalBusinessEngine.timesheetSubmittedRecipients(
            subject: RulebookPeople.person(signedByUser),
            roster: RulebookPeople.roster(users)
        ) else {
            print("🔥🔥🔥 DEBUG: [TIMESHEET NOTIFY] timesheetSubmittedRecipients did not answer; no notice written")
            return
        }
        let periodStartDayKey = OrganizationRulebookContext.dayKey(weekStart)
        let weekDay = OrganizationRulebookContext.calendar.startOfDay(for: weekStart)
        let displayName = signedByUser.fullName.isEmpty ? signedByUser.email : signedByUser.fullName
        for managerId in recipients {
            guard let key = CanonicalBusinessEngine.timesheetNotificationDedupeKey(
                type: AppNotification.NotificationType.timesheetPendingManagerSignoff.rawValue,
                subjectId: signedByUser.id,
                periodStartDayKey: periodStartDayKey,
                timeZone: OrganizationRulebookContext.timeZoneIdentifier,
                recipientId: managerId
            ) else { continue }
            let notification = AppNotification(
                id: syntheticNotificationId(from: key),
                organizationId: organizationId,
                type: .timesheetPendingManagerSignoff,
                title: "Timesheet needs sign-off",
                message: "\(displayName) submitted a timesheet that needs your signature.",
                userId: managerId,
                relatedId: nil,
                isRead: false,
                createdAt: Date(),
                requiresPermission: nil,
                deepLinkUserId: signedByUser.id,
                deepLinkWeekStart: weekDay
            )
            await saveNotification(notification)
        }
    }

    /// Notifies other line managers when one manager has already actioned a shared request.
    /// `lineManagerPeerRecipients(subject, actor, roster)`: the subject's other active line managers, never the
    /// signed-in actor or the subject (RULEBOOK §13, inbox only).
    func notifyLineManagerPeerAction(
        actorName: String,
        actionSummary: String,
        subject: AppUser,
        actionVerb: String = "approved",
        message: String? = nil,
        relatedId: UUID? = nil
    ) async {
        guard let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId else { return }
        let peers = CanonicalBusinessEngine.lineManagerPeerRecipients(
            subject: RulebookPeople.person(subject),
            actor: actorPerson,
            roster: recipientRoster
        ) ?? []
        let body = message ?? "\(actorName) \(actionVerb): \(actionSummary)"
        for targetId in peers {
            let dedupeId = syntheticNotificationId(from: "lmPeer|\(actorName)|\(actionSummary)|\(targetId)|\(actionVerb)")
            let notification = AppNotification(
                id: dedupeId,
                organizationId: organizationId,
                type: .lineManagerPeerUpdate,
                title: "Line manager update",
                message: body,
                userId: targetId,
                relatedId: relatedId,
                requiresPermission: nil
            )
            await saveNotification(notification)
        }
    }

    /// Sent when line manager signs off a timesheet.
    func notifyTimesheetSignedByManager(
        targetUserId: String,
        signedByName: String,
        weekStart: Date
    ) async {
        // `timesheetSignedRecipients`: the subject's account, unless they are the signer (the signed-in user).
        guard let targetId = CanonicalBusinessEngine.timesheetSignedRecipients(
            subject: targetUserId,
            signer: actorPerson,
            roster: recipientRoster
        )?.first else { return }
        let weekDay = OrganizationRulebookContext.calendar.startOfDay(for: weekStart)
        guard let key = CanonicalBusinessEngine.timesheetNotificationDedupeKey(
            type: AppNotification.NotificationType.timesheetSignedByManager.rawValue,
            subjectId: targetId,
            periodStartDayKey: OrganizationRulebookContext.dayKey(weekStart),
            timeZone: OrganizationRulebookContext.timeZoneIdentifier
        ) else { return }
        let dedupeId = syntheticNotificationId(from: key)
        let notification = AppNotification(
            id: dedupeId,
            organizationId: firebaseBackend?.currentOrganization?.firestoreDocumentId ?? "",
            type: .timesheetSignedByManager,
            title: "Timesheet signed",
            message: "\(signedByName) signed your timesheet.",
            userId: targetId,
            relatedId: nil,
            isRead: false,
            createdAt: Date(),
            requiresPermission: nil,
            deepLinkUserId: targetId,
            deepLinkWeekStart: weekDay
        )
        await saveNotification(notification)
    }

    // MARK: - PAYE overtime (RULEBOOK 1.29.0 §13, §25)

    /// `overtime_request_submitted` to `overtimeRequestRecipients(requester, roster)` — the requester's active line
    /// managers and every active admin, never the requester. 1.33.0: the text is `overtimeRequestSubmittedMessage`;
    /// `deepLinkUserId` is the requester (opens Users' → that person → Overtime), `relatedId` the request and `dayKey`
    /// the range start (the payrun it opens, `overtimeNotificationRange`).
    func notifyOvertimeRequestSubmitted(requester: AppUser, requestId: String, rangeStart: String, rangeEnd: String) async {
        guard let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId else { return }
        guard let recipients = CanonicalBusinessEngine.overtimeRequestRecipients(
            requester: RulebookPeople.person(requester),
            roster: recipientRoster
        ) else { return }
        guard let notice = CanonicalBusinessEngine.overtimeRequestSubmittedMessage(
            requesterName: requester.fullName,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        ) else { return }
        for userId in recipients {
            let notification = AppNotification(
                organizationId: organizationId,
                type: .overtimeRequestSubmitted,
                title: notice.title,
                message: notice.message,
                userId: userId,
                relatedKey: requestId,
                deepLinkUserId: requester.id,
                dayKey: rangeStart
            )
            await saveNotification(notification)
        }
    }

    /// 1.33.0 `overtime_request_reviewed` after Return to `overtimeReturnedRecipients(requester, decider, roster)`:
    /// "Your line manager {name} has returned your overtime request" (`overtimeReturnedMessage`; an admin who is not the
    /// line manager: "{name} has returned …"). `dayKey` is the request's range start.
    func notifyOvertimeReturned(requesterId: String, requestId: String, rangeStart: String) async {
        guard let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId else { return }
        guard let recipients = CanonicalBusinessEngine.overtimeReturnedRecipients(
            requester: requesterId,
            decider: actorPerson,
            roster: recipientRoster
        ) else { return }
        let users = userStore?.organizationUsers ?? []
        let requester = users.first { $0.id == requesterId }
        let deciderIsLineManager = requester.map {
            CanonicalBusinessEngine.overtimeDeciderIsLineManager(decider: actorPerson, requester: RulebookPeople.person($0), roster: recipientRoster)
        } ?? false
        let deciderName = userStore?.currentUser?.fullName
        guard let notice = CanonicalBusinessEngine.overtimeReturnedMessage(
            deciderName: deciderName,
            deciderIsLineManager: deciderIsLineManager
        ) else { return }
        for userId in recipients {
            let notification = AppNotification(
                organizationId: organizationId,
                type: .overtimeRequestReviewed,
                title: notice.title,
                message: notice.message,
                userId: userId,
                relatedKey: requestId,
                dayKey: rangeStart.isEmpty ? nil : rangeStart
            )
            await saveNotification(notification)
        }
    }

    /// 1.33.0 reopen (web `lib/overtime/overtimeReopenNotice.ts`): a manager or admin changed or deleted a PAYE person's
    /// booking (`after` nil when deleted). When `overtimeLineReopened` says the overtime line reopened, the person — and
    /// their line managers when the line had been returned (`overtimeReopenedRecipients`) — hear
    /// `overtimeReopenedMessage`. The person's row opens their Overtime (`overtime_request_reviewed`); a line manager's
    /// opens Users' → that person (`overtime_request_submitted`), as web. Best effort: never blocks the booking edit.
    /// `organizationId` is the company the booking write went to (nil: the open one). A write to another company is
    /// skipped (`OvertimeReopenNotice.noticeMayBeSent`): every input below is the open company's.
    func notifyOvertimeLineReopened(
        before rawBefore: OvertimeBookingInput,
        after rawAfter: OvertimeBookingInput?,
        organizationId writtenOrganizationId: String? = nil
    ) async {
        guard let backend = firebaseBackend,
              let organizationId = backend.currentOrganization?.firestoreDocumentId,
              OvertimeReopenNotice.noticeMayBeSent(
                writtenOrganizationId: writtenOrganizationId,
                openOrganizationId: organizationId
              ) else { return }
        // Job number and name from the loaded jobs (the notice names the job).
        let jobs = (projectStore?.projects ?? []) + (projectStore?.smallWorks ?? [])
        let before = OvertimeBookingInputs.withJobs([rawBefore], jobs: jobs).first ?? rawBefore
        let after = rawAfter.map { OvertimeBookingInputs.withJobs([$0], jobs: jobs).first ?? $0 }
        let users = userStore?.organizationUsers ?? []
        guard let accountId = CanonicalBusinessEngine.notificationRecipientAccountId(
            before.personId,
            roster: recipientRoster,
            catalogue: recipientCatalogue
        ), let person = users.first(where: { $0.id == accountId }), person.isPayeEmployment else { return }
        // The editor may not read another person's overtime (only admins, the person and their line manager may).
        let records = await backend.readOvertimeRecords(userId: accountId)
        let organization = OvertimeOrganizationDocument.document(backend.currentOrganization)
        let outcome = CanonicalBusinessEngine.overtimeLineReopened(
            before: before,
            after: after,
            organization: organization,
            reviews: records?.reviews,
            requests: records?.requests
        )
        guard outcome.reopened else { return }
        let recipients = CanonicalBusinessEngine.overtimeReopenedRecipients(
            bookedId: before.personId,
            actor: actorPerson,
            roster: recipientRoster,
            operatives: (operativeStore?.allOperatives ?? []).map { ["id": $0.documentId, "email": $0.email] as [String: Any] },
            returned: outcome.returned
        )
        let personName = person.fullName.isEmpty ? person.email : person.fullName
        for userId in recipients {
            let forPerson = userId == accountId
            guard let notice = CanonicalBusinessEngine.overtimeReopenedMessage(
                dayKey: before.dayKey,
                jobNumber: before.jobNumber,
                forLineManager: !forPerson,
                personName: personName
            ) else { continue }
            let notification = AppNotification(
                organizationId: organizationId,
                type: forPerson ? .overtimeRequestReviewed : .overtimeRequestSubmitted,
                title: notice.title,
                message: notice.message,
                userId: userId,
                relatedKey: before.id,
                deepLinkUserId: forPerson ? nil : accountId,
                dayKey: before.dayKey
            )
            await saveNotification(notification)
        }
    }

    /// `booking_hours_changed_by_owner` (inbox only) to `bookingHoursChangedRecipients(owner, jobManagerIds, roster)`:
    /// the job's managers and the person's line managers, never the person.
    /// 1.33.0: `removed` when a red X deleted an all-overtime booking (web wording "removed their booking … (overtime not
    /// worked)").
    func notifyBookingHoursChangedByOwner(owner: AppUser, booking: OvertimeBookingInput, jobManagerIds: [String], removed: Bool = false) async {
        guard let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId else { return }
        guard let recipients = CanonicalBusinessEngine.bookingHoursChangedRecipients(
            owner: RulebookPeople.person(owner),
            jobManagerIds: jobManagerIds,
            roster: recipientRoster
        ) else { return }
        let name = owner.fullName.isEmpty ? "Someone" : owner.fullName
        let job = booking.jobNumber.isEmpty ? "" : " (\(booking.jobNumber))"
        for userId in recipients {
            let notification = AppNotification(
                organizationId: organizationId,
                type: .bookingHoursChangedByOwner,
                title: "Hours changed",
                message: removed
                    ? "\(name) removed their booking on \(booking.dayKey)\(job) (overtime not worked)."
                    : "\(name) changed the hours of their booking on \(booking.dayKey)\(job).",
                userId: userId,
                relatedKey: booking.id,
                dayKey: booking.dayKey
            )
            await saveNotification(notification)
        }
    }

    /// Settings → My notifications → Notifications check → "Send test notification" (rulebook 1.4.0 §13 `push_test`):
    /// one row to `pushTestRecipients(actor)` — the signed-in user — written through `notificationCreateFields`
    /// (`FirebaseBackend.saveNotification`) with `actorUserId` = the signed-in uid. The push function delivers it to its
    /// sender (`notificationPushesToActor`), so this checks the whole chain: token saved → row written → Cloud Function →
    /// APNs. Returns plain words for the screen; a failed write says why instead of claiming success.
    func sendTemporaryPushDiagnosticToCurrentUser() async -> String {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            return "Not sent: no organisation is open."
        }
        guard userStore?.currentUser != nil else {
            return "Not sent: you are not signed in."
        }
        guard let targetId = CanonicalBusinessEngine.pushTestRecipients(actor: actorPerson)?.first else {
            return "Not sent: the app's rules could not load. Try again."
        }

        // Make sure this phone's token is on the account before the push function looks for it.
        await firebaseBackend.reregisterPushTokenIfAvailable()
        let notification = AppNotification(
            organizationId: organizationId,
            type: .pushTest,
            title: "Test notification",
            message: "If you can read this on your phone, notifications are working.",
            userId: targetId,
            // `push_test` carries no relatedId (`NOTIFICATION_RELATED_ID`); never a random id.
            relatedId: nil,
            requiresPermission: nil
        )
        do {
            try await firebaseBackend.saveNotification(
                notification,
                organizationId: organizationId,
                actorUserId: Auth.auth().currentUser?.uid
            )
            print("🔥🔥🔥 DEBUG: [PUSH DIAGNOSTIC] push_test row \(notification.id.uuidString) written for \(targetId)")
            return "Sent — check your phone in a minute."
        } catch {
            print("🔥🔥🔥 DEBUG: [PUSH DIAGNOSTIC] push_test write failed: \(error.localizedDescription)")
            return "Not sent: \(error.localizedDescription)"
        }
    }

    // MARK: - Notification Management

    func discardForOrganizationSwitch() {
        resetInbox()
    }

    /// The inbox for no session (sign-out, organisation switch): listener removed, pending retry cancelled, rows and
    /// count cleared, the next listen starts from the ordered query again. Another company or account never shows
    /// the previous inbox's rows (web `notificationStore.reset`).
    func resetInbox() {
        notificationsListenerRetryTask?.cancel()
        notificationsListenerRetryTask = nil
        notificationsListener?.remove()
        notificationsListener = nil
        listenerScopeKey = nil
        notificationsListenerFailures = 0
        inboxUsesUnorderedQuery = false
        didPrimeNotificationStream = false
        hasLoadedNotificationsThisSession = false
        notifications = []
        unreadCount = 0
    }

    /// Attaches the inbox listener so the bell badge and list follow notification documents.
    /// Does not reload projects, people, or other company data.
    func startInboxListenerIfNeeded() {
        guard let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId,
              let userId = userStore?.currentUser?.id,
              !userId.isEmpty else { return }
        startNotificationsListenerIfNeeded(organizationId: organizationId, userId: userId)
    }

    /// Asks for alert permission once the signed-in shell is on screen, if the system has never been asked.
    /// A Settings toggle is not the same as this authorization status.
    @discardableResult
    func ensureSystemNotificationAuthorizationIfNeeded() async -> Bool {
        if let notificationAuthorizationTask {
            return await notificationAuthorizationTask.value
        }
        let task = Task { @MainActor () -> Bool in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if !self.didLogNotificationAuthorization {
                self.didLogNotificationAuthorization = true
                print("🔥🔥🔥 DEBUG: Notification authorization status=\(settings.authorizationStatus)")
            }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.registerForRemoteNotificationsIfPossible()
                return true
            case .denied:
                print("🔥🔥🔥 DEBUG: Notification authorization denied. Local banners and remote pushes stay off until Project Planner is allowed in Settings.")
                return false
            case .notDetermined:
                let granted = await LocalNotificationService.shared.requestAuthorization()
                print("🔥🔥🔥 DEBUG: Signed-in notification authorization granted=\(granted)")
                if granted {
                    self.registerForRemoteNotificationsIfPossible()
                }
                return granted
            @unknown default:
                return false
            }
        }
        notificationAuthorizationTask = task
        let granted = await task.value
        notificationAuthorizationTask = nil
        return granted
    }

    private func registerForRemoteNotificationsIfPossible() {
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// Lightweight inbox attach. The listener is the badge update; this does not fetch company data.
    func warmUnreadBadgeIfNeeded() async {
        startInboxListenerIfNeeded()
    }

    func loadNotifications() async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId,
              let currentUser = userStore?.currentUser else { return }

        hasLoadedNotificationsThisSession = true
        removeLegacyLocalInboxState(userId: currentUser.id)
        let fetched = try? await firebaseBackend.loadNotifications(
            organizationId: organizationId,
            userId: currentUser.id,
            limit: 150
        )
        let allNotifications = fetched ?? notifications
        print("🔥🔥🔥 DEBUG: [NOTIFY LOAD] currentUser=\(currentUser.id) totalLoaded=\(allNotifications.count)")
        capturePendingDeadlineNotifications(from: allNotifications, currentUser: currentUser)

        // RULEBOOK §13: the inbox is only the Firestore rows addressed to the person, with their stored read state
        // (`inboxNotificationVisibleToUser`, `unreadNotificationBadgeCount`). No derived rows, no device read state.
        let listed = listedInbox(allNotifications, userId: currentUser.id)
        print("🔥🔥🔥 DEBUG: [NOTIFY LOAD] listed=\(listed.count)")
        
        await MainActor.run {
            self.notifications = listed
            self.setUnreadCount(from: self.notifications)
            // Catch-up path: if app was closed/backgrounded and new notifications arrived,
            // alert once for notifications newer than the last processed timestamp.
            if let cutoff = self.lastProcessedNotificationAt {
                let catchUp = self.notifications.filter { $0.createdAt > cutoff }
                self.processBookingToasts(from: catchUp)
                self.processHolidayRequestAlerts(from: catchUp)
                self.processHolidayDecisionAlerts(from: catchUp)
                self.processGeneralLocalAlerts(from: catchUp)
            }
            self.advanceLastProcessedNotificationDate(using: self.notifications)
        }
        startNotificationsListenerIfNeeded(organizationId: organizationId, userId: currentUser.id)
        await scheduleOsAlertsForPendingDeadlines()
    }

    /// Moves due/reminder rows into the visible inbox once their fire time has passed. In-memory only.
    func promoteScheduledDeadlineNotifications() {
        let now = Date()
        let newlyVisible = pendingScheduledDeadlineNotifications.filter { $0.createdAt <= now }
        guard !newlyVisible.isEmpty else { return }
        pendingScheduledDeadlineNotifications.removeAll { $0.createdAt <= now }
        let known = Set(notifications.map(\.id))
        let merged = notifications + newlyVisible.filter { !known.contains($0.id) }
        let userId = userStore?.currentUser?.id ?? ""
        notifications = listedInbox(merged, userId: userId)
        setUnreadCount(from: notifications)
    }
    
    func markAsRead(_ notification: AppNotification) async {
        var updatedNotification = notification
        updatedNotification.isRead = true

        // Show the row as read straight away (also offline); the live listener then reflects the stored row.
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            notifications[index] = updatedNotification
            setUnreadCount(from: notifications)
        }

        guard !notification.isRead,
              let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }

        do {
            // RULEBOOK 1.8.0 §13: `notificationReadWriteFields` — `{ isRead: true }` only, never a rewrite of the row.
            try await firebaseBackend.markNotificationRead(updatedNotification, wasRead: notification.isRead, organizationId: organizationId)
        } catch {
            print("🔥🔥🔥 DEBUG: Error marking notification as read: \(error)")
        }
    }

    /// Marks every listed row read and writes that state. Opening the centre does not call this.
    func markAllAsRead() async {
        let unread = notifications.filter { !$0.isRead }
        guard !unread.isEmpty else { return }
        // Show every row as read straight away (also offline); the live listener then reflects the stored rows.
        notifications = notifications.map { row in
            var copy = row
            copy.isRead = true
            return copy
        }
        setUnreadCount(from: notifications)

        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            return
        }
        for notification in unread {
            var updated = notification
            updated.isRead = true
            do {
                // `notificationReadWriteFields`: `{ isRead: true }` only.
                try await firebaseBackend.markNotificationRead(updated, wasRead: false, organizationId: organizationId)
            } catch {
                print("🔥🔥🔥 DEBUG: Error marking notification as read: \(error)")
            }
        }
    }
    
    private func shouldShowNotification(_ notification: AppNotification, for user: AppUser) -> Bool {
        if isFutureScheduledDeadline(notification) {
            return false
        }
        // If notification is targeted to a specific user, only show if it's for them
        if let userId = notification.userId {
            guard isAddressedToMe(userId) || userId == user.id else { return false }
        } else if let requiredPermission = notification.requiresPermission {
            switch requiredPermission {
            case "hasAdminAccess":
                guard userStore?.hasAdminAccess() ?? false else { return false }
            case "canBookWork":
                guard userStore?.canBookWork() ?? false else { return false }
            case "canViewOperatives":
                guard userStore?.canViewOperatives() ?? false else { return false }
            case "canViewManagers":
                guard userStore?.canViewManagers() ?? false else { return false }
            case "canViewProjects":
                guard userStore?.canViewProjects() ?? false else { return false }
            case "superAdminOrAdmin":
                guard user.isSuperAdmin || user.permissions.adminAccess || user.role == .admin else { return false }
            case "operativeMode":
                guard user.permissions.operativeMode else { return false }
            default:
                break
            }
        }

        return deliveryAllowed(type: notification.typeText)
    }

    /// The signed-in user's toggles for a device push or local banner (`notificationPreferenceAllowsDelivery`).
    /// Never used to hide an inbox row. A type with no key stays allowed. A nil script result does not block.
    private func deliveryAllowed(type: String) -> Bool {
        guard let prefs = appSettingsStore?.settings.notifications.preferenceValues else { return true }
        return CanonicalBusinessEngine.notificationPreferenceAllowsDelivery(prefs: prefs, type: type) ?? true
    }

    /// `stampsActor`: the row carries `actorUserId` = the signed-in uid (RULEBOOK §13), the person who caused it.
    /// Scheduled rows nobody caused (the timesheet submission reminder to the signed-in person, deadline
    /// reminders) pass false, or the push function's actor guard would drop their device push.
    private func saveNotification(
        _ notification: AppNotification,
        deliverLocalPush: Bool = true,
        preserveExistingReadState: Bool = false,
        onlyIfMissing: Bool = false,
        stampsActor: Bool = true,
        organizationId explicitOrganizationId: String? = nil
    ) async {
        // `explicitOrganizationId`: write to that organisation (a notice that belongs to it) instead of the open one.
        guard let firebaseBackend = firebaseBackend,
              let organizationId = explicitOrganizationId ?? firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        // A toggle stops the push only; the inbox row is always written (§13, `notificationShowsInInbox`).
        // The local banner below still checks the toggle (`shouldShowNotification` → `notificationPreferenceAllowsDelivery`).
        
        do {
            try await firebaseBackend.saveNotification(
                notification,
                organizationId: organizationId,
                preserveExistingReadState: preserveExistingReadState,
                onlyIfMissing: onlyIfMissing,
                actorUserId: stampsActor ? Auth.auth().currentUser?.uid : nil
            )
            print("🔥🔥🔥 DEBUG: [NOTIFY SAVE OK] id=\(notification.id.uuidString) type=\(notification.type.rawValue) target=\(notification.userId ?? "broadcast") related=\(notification.relatedId?.uuidString ?? "none")")
            if deliverLocalPush, !isFutureScheduledDeadline(notification), !isDevicePush(notification.typeText) {
                deliverLocalPushIfNeeded(for: notification)
            }
        } catch {
            print("🔥🔥🔥 DEBUG: Error saving notification: \(error)")
            print("🔥🔥🔥 DEBUG: Notification target userId: \(notification.userId ?? "broadcast"), type: \(notification.type.rawValue), relatedId: \(notification.relatedId?.uuidString ?? "none")")
        }
    }

    /// Schedules an immediate local banner when this device is the intended recipient (mirrors material cut-off delivery).
    private func deliverLocalPushIfNeeded(for notification: AppNotification) {
        guard let currentUser = userStore?.currentUser else { return }
        guard shouldShowNotification(notification, for: currentUser) else { return }
        if let userId = notification.userId {
            guard isAddressedToMe(userId) || userId == currentUser.id else { return }
        }
        if notification.createdAt > Date(),
           notification.type == .deadlineReminder || notification.type == .deadlineDue {
            return
        }
        triggerLocalAlertIfNeeded(for: notification)
    }

    /// A Firestore listener stops for good after an error. Drop it and load again after 5, 10 … 60 seconds,
    /// unless the signed-in scope changed in the meantime. `loadNotifications` re-attaches the listener.
    /// RULEBOOK 1.16.0 (web `notificationStore`): an error is never final. `failed-precondition` on the ordered query
    /// (missing index) switches to the unordered query at once; any other error keeps the rows already shown and
    /// listens again after 5, 10 … 60 seconds. A reset (sign-out, organisation switch) cancels the retry.
    private func retryNotificationsListener(scopeKey: String, error: Error) {
        guard listenerScopeKey == scopeKey else { return }
        notificationsListener?.remove()
        notificationsListener = nil
        listenerScopeKey = nil
        let nsError = error as NSError
        if !inboxUsesUnorderedQuery,
           nsError.domain == "FIRFirestoreErrorDomain",
           nsError.code == 9 /* failed-precondition: the (userId, createdAt) index is missing */ {
            inboxUsesUnorderedQuery = true
            let parts = scopeKey.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                startNotificationsListenerIfNeeded(organizationId: parts[0], userId: parts[1])
            }
            return
        }
        notificationsListenerFailures += 1
        let delaySeconds = UInt64(min(60, 5 * notificationsListenerFailures))
        notificationsListenerRetryTask?.cancel()
        notificationsListenerRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.listenerScopeKey == nil else { return }
            self.notificationsListenerRetryTask = nil
            // Each retry starts from the ordered query again (web: `listen(ordered, unordered)`).
            self.inboxUsesUnorderedQuery = false
            await self.loadNotifications()
        }
    }

    private func startNotificationsListenerIfNeeded(organizationId: String, userId: String) {
        let key = "\(organizationId)|\(userId)"
        if listenerScopeKey == key, notificationsListener != nil {
            return
        }
        notificationsListener?.remove()
        listenerScopeKey = key
        didPrimeNotificationStream = false

        let scoped = Firestore.firestore()
            .collection("organizations")
            .document(organizationId)
            .collection("notifications")
            .whereField("userId", isEqualTo: userId)
        // Newest 150 (composite index userId ASC, createdAt DESC is deployed from web). Without the index the ordered
        // query fails with failed-precondition and the unordered one is used (rows sorted by `listedInbox`).
        let inboxQuery: Query = inboxUsesUnorderedQuery
            ? scoped
            : scoped.order(by: "createdAt", descending: true).limit(to: 150)
        notificationsListener = inboxQuery
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    print("🔥🔥🔥 DEBUG: Notifications listener error: \(error.localizedDescription)")
                    Task { @MainActor in
                        self?.retryNotificationsListener(scopeKey: key, error: error)
                    }
                    return
                }
                guard let snapshot else { return }
                Task { @MainActor in
                    guard let self else { return }
                    guard let currentUser = self.userStore?.currentUser else { return }
                    self.notificationsListenerFailures = 0

                    let parsed = snapshot.documents.compactMap { self.parseNotificationDocument($0) }
                    self.capturePendingDeadlineNotifications(from: parsed, currentUser: currentUser)
                    let changedParsed = snapshot.documentChanges.compactMap { change -> AppNotification? in
                        guard change.type == .added else { return nil }
                        return self.parseNotificationDocument(change.document)
                    }
                    .filter { self.shouldShowNotification($0, for: currentUser) }

                    // RULEBOOK §13: only the Firestore rows addressed to the person, read state as stored.
                    let merged = parsed
                    let listed = self.listedInbox(merged, userId: currentUser.id)
                    self.notifications = listed
                    self.setUnreadCount(from: listed)
                    self.hasLoadedNotificationsThisSession = true
                    if !self.didPrimeNotificationStream {
                        if let cutoff = self.lastProcessedNotificationAt {
                            let catchUp = merged.filter { $0.createdAt > cutoff }
                            self.processBookingToasts(from: catchUp)
                            self.processHolidayRequestAlerts(from: catchUp)
                            self.processHolidayDecisionAlerts(from: catchUp)
                            self.processGeneralLocalAlerts(from: catchUp)
                        }
                        self.primeLocalAlertDedup(with: merged)
                        self.didPrimeNotificationStream = true
                        self.advanceLastProcessedNotificationDate(using: merged)
                        await self.scheduleOsAlertsForPendingDeadlines()
                        return
                    }
                    self.processBookingToasts(from: changedParsed)
                    self.processHolidayRequestAlerts(from: changedParsed)
                    self.processHolidayDecisionAlerts(from: changedParsed)
                    self.processGeneralLocalAlerts(from: changedParsed)
                    self.advanceLastProcessedNotificationDate(using: merged)
                    await self.scheduleOsAlertsForPendingDeadlines()
                }
            }
    }

    /// RULEBOOK 1.8.0 §13: inbox rows through the rulebook's `parseNotificationDocument` (an unknown type, a
    /// non-UUID document or related id, a missing title / read flag / `createdAt` keep the row).
    private func parseNotificationDocument(_ doc: QueryDocumentSnapshot) -> AppNotification? {
        FirebaseBackend.appNotification(
            documentId: doc.documentID,
            // RULEBOOK 1.16.0: a row written with the server time reads its local estimate until the server confirms.
            data: doc.data(with: .estimate),
            organizationId: firebaseBackend?.currentOrganization?.firestoreDocumentId
        )
    }

    private func processBookingToasts(from notifications: [AppNotification]) {
        guard userStore?.isOperativeMode() == true else { return }
        let unseen = notifications.filter {
            $0.type == .bookingCreated && !$0.isRead && !seenBookingNotificationIds.contains($0.id)
        }
        guard let newest = unseen.max(by: { $0.createdAt < $1.createdAt }) else { return }
        for notification in unseen {
            seenBookingNotificationIds.insert(notification.id)
        }
        bookingToastMessage = newest.message
    }

    private func processHolidayRequestAlerts(from notifications: [AppNotification]) {
        let requests = notifications
            .filter { $0.type == .holidayRequestSubmitted }
            .sorted { $0.createdAt > $1.createdAt }
        for n in requests {
            let key = notificationDedupKey(for: n)
            guard !seenHolidayRequestNotificationKeys.contains(key) else { continue }
            seenHolidayRequestNotificationKeys.insert(key)
            triggerLocalAlertIfNeeded(for: n)
        }
    }

    private func processHolidayDecisionAlerts(from notifications: [AppNotification]) {
        let decisions = notifications
            .filter { [.holidayRequestApproved, .holidayRequestDeclined, .holidayCancelledByManager, .holidayBookedForYou].contains($0.type) }
            .sorted { $0.createdAt > $1.createdAt }
        for n in decisions {
            let key = notificationDedupKey(for: n)
            guard !seenHolidayDecisionNotificationKeys.contains(key) else { continue }
            seenHolidayDecisionNotificationKeys.insert(key)
            triggerLocalAlertIfNeeded(for: n)
        }
    }

    private func processGeneralLocalAlerts(from notifications: [AppNotification]) {
        // Holiday types are handled only by processHolidayRequestAlerts / processHolidayDecisionAlerts
        // so we do not double-schedule the same OS banner.
        let sorted = notifications.sorted { $0.createdAt > $1.createdAt }
        for notification in sorted {
            switch notification.type {
            case .holidayRequestSubmitted, .holidayRequestApproved, .holidayRequestDeclined, .holidayCancelledByManager, .holidayBookedForYou:
                continue
            case .deadlineReminder, .deadlineDue, .materialOrderCutOff, .qualificationExpiry, .timesheetSubmissionReminder:
                // Clocks and the timesheet FCM alert. Do not mirror them as an immediate local banner.
                continue
            default:
                triggerLocalAlertIfNeeded(for: notification)
            }
        }
    }

    private func scheduleLocalInAppMirrorAlert(title: String, message: String, dedupeIdentifier: String, userInfo: [AnyHashable: Any] = [:]) {
        Task {
            let granted = await ensureSystemNotificationAuthorizationIfNeeded()
            guard granted else {
                print("🔥🔥🔥 DEBUG: Local notification permission not granted; skipping banner")
                return
            }
            let sanitizedId = String(dedupeIdentifier
                .replacingOccurrences(of: "/", with: "-")
                .prefix(200))
            let identifier = "inapp-local-\(sanitizedId)"
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            if pending.contains(where: { $0.identifier == identifier }) {
                return
            }
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = .default
            content.interruptionLevel = .active
            content.userInfo = userInfo
            // OS banners are scheduled 1 second out so they appear while the app is in the
            // foreground (immediate triggers are delivered silently). Firestore itself is
            // realtime; any extra delay is network / APNs, not a polling interval.
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            do {
                try await center.add(request)
                print("🔥🔥🔥 DEBUG: Scheduled local notification: \(title)")
            } catch {
                print("🔥🔥🔥 DEBUG: Local in-app notification error: \(error.localizedDescription)")
            }
        }
    }

    /// `holidayRequestRecipients(requester, roster)` (§9, §13): `leaveApproverIds` without the requester under
    /// any of their ids; nobody when the leave is self-booked. A requester with no account found in the roster is
    /// sent with the stored manager id, so the script still routes it.
    /// `users` is another organisation's roster when the notice belongs there; nil means the open organisation's.
    private func holidayRequestTargets(
        requesterUserId: String?,
        assignedManagerUserId: String?,
        users otherRoster: [AppUser]? = nil
    ) async -> [String] {
        let users: [AppUser]
        if let otherRoster {
            users = otherRoster
        } else {
            guard let userStore else { return [] }
            if userStore.organizationUsers.isEmpty {
                await userStore.loadOrganizationUsers()
            }
            users = userStore.organizationUsers
        }
        let trimmedRequester = requesterUserId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requester = trimmedRequester.isEmpty ? nil : users.first(where: {
            $0.id == trimmedRequester || $0.sameEmailUserIds.contains(trimmedRequester) || $0.formerUserIds.contains(trimmedRequester)
        })
        var requesterPayload = AnnualLeaveApproval.requesterPayload(requester, fallbackUserId: trimmedRequester)
        if requester == nil,
           let legacy = assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacy.isEmpty {
            requesterPayload["assignedManagerUserId"] = legacy
        }
        guard let recipients = CanonicalBusinessEngine.holidayRequestRecipients(
            requester: requesterPayload,
            roster: RulebookPeople.roster(users)
        ) else {
            print("🔥🔥🔥 DEBUG: [HOLIDAY NOTIFY] holidayRequestRecipients did not answer; no request notice written")
            return []
        }
        return recipients
    }

    /// `holidayDecisionRecipients(requester, signed-in decider, roster)`: the requester's id, or nil when they
    /// are the decider (or the script did not answer).
    private func holidayDecisionTarget(_ requesterUserId: String) -> String? {
        CanonicalBusinessEngine.holidayDecisionRecipients(
            requester: requesterUserId,
            decider: actorPerson,
            roster: recipientRoster
        )?.first
    }

    private func scheduleLocalBookingAlert(message: String, dedupeIdentifier: String) {
        requestLocalNotificationPermissionIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "You've Been Booked"
        content.body = message
        content.sound = .default
        let sanitizedId = String(dedupeIdentifier
            .replacingOccurrences(of: "/", with: "-")
            .prefix(200))
        let request = UNNotificationRequest(
            identifier: "booking-local-\(sanitizedId)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("🔥🔥🔥 DEBUG: Local booking notification error: \(error.localizedDescription)")
            }
        }
    }

    private func requestLocalNotificationPermissionIfNeeded() {
        guard firebaseBackend?.isAuthenticated == true else { return }
        guard !hasRequestedLocalNotificationPermission else { return }
        hasRequestedLocalNotificationPermission = true
        Task {
            _ = await ensureSystemNotificationAuthorizationIfNeeded()
        }
    }

    private func localBannerEvent(for notification: AppNotification) -> LocalNotificationBannerPolicy.Event {
        LocalNotificationBannerPolicy.Event(
            id: notification.id.uuidString,
            type: notification.type,
            relatedId: notification.relatedKey,
            // The banner policy compares against the signed-in id: a row addressed to any of the person's ids counts.
            targetUserId: notification.userId.map { isAddressedToMe($0) ? (userStore?.currentUser?.id ?? $0) : $0 },
            isRead: notification.isRead,
            isSynthetic: false,
            isFutureScheduledDeadline: isFutureScheduledDeadline(notification)
        )
    }

    private func notificationDedupKey(for notification: AppNotification) -> String {
        LocalNotificationBannerPolicy.dedupeKey(for: localBannerEvent(for: notification))
    }

    private func triggerLocalAlertIfNeeded(for notification: AppNotification) {
        guard !isDevicePush(notification.typeText) else { return }
        guard let currentUser = userStore?.currentUser else { return }
        guard shouldShowNotification(notification, for: currentUser) else { return }
        loadPersistedLocalAlertDedupKeysIfNeeded()
        let event = localBannerEvent(for: notification)
        let me = currentUser.id
        guard LocalNotificationBannerPolicy.shouldScheduleBanner(
            for: event,
            currentUserId: me,
            seenKeys: seenLocalAlertNotificationKeys
        ) else { return }
        let key = LocalNotificationBannerPolicy.dedupeKey(for: event)
        recordLocalAlertDedupKey(key)
        scheduleLocalInAppMirrorAlert(
            title: notification.title,
            message: notification.message,
            dedupeIdentifier: key,
            userInfo: NotificationDeepLink.userInfo(for: notification)
        )
    }

    private func loadPersistedLocalAlertDedupKeysIfNeeded() {
        guard !didLoadPersistedLocalAlertDedupKeys else { return }
        didLoadPersistedLocalAlertDedupKeys = true
        if let stored = UserDefaults.standard.stringArray(forKey: Self.persistedLocalAlertDedupKey) {
            localAlertDedupOrderedKeys = stored
            seenLocalAlertNotificationKeys = Set(stored)
        }
    }

    private func loadLastProcessedNotificationDateIfNeeded() {
        guard lastProcessedNotificationAt == nil else { return }
        if let ts = UserDefaults.standard.object(forKey: Self.persistedLastProcessedAtKey) as? TimeInterval {
            lastProcessedNotificationAt = Date(timeIntervalSince1970: ts)
        }
    }

    private func recordLocalAlertDedupKey(_ key: String) {
        if seenLocalAlertNotificationKeys.contains(key) { return }
        seenLocalAlertNotificationKeys.insert(key)
        localAlertDedupOrderedKeys.append(key)
        while localAlertDedupOrderedKeys.count > Self.maxPersistedDedupKeys {
            let removed = localAlertDedupOrderedKeys.removeFirst()
            seenLocalAlertNotificationKeys.remove(removed)
        }
        UserDefaults.standard.set(localAlertDedupOrderedKeys, forKey: Self.persistedLocalAlertDedupKey)
    }

    private func advanceLastProcessedNotificationDate(using notifications: [AppNotification]) {
        guard let latest = notifications.map(\.createdAt).max() else { return }
        if let current = lastProcessedNotificationAt, latest <= current { return }
        lastProcessedNotificationAt = latest
        UserDefaults.standard.set(latest.timeIntervalSince1970, forKey: Self.persistedLastProcessedAtKey)
    }

    private func primeLocalAlertDedup(with notifications: [AppNotification]) {
        // Treat current visible unread notifications as already known at stream start.
        // This prevents banner storms when opening the app with a backlog.
        for notification in notifications where !notification.isRead {
            let key = notificationDedupKey(for: notification)
            recordLocalAlertDedupKey(key)
            if notification.type == .holidayRequestSubmitted {
                seenHolidayRequestNotificationKeys.insert(key)
            }
            if [.holidayRequestApproved, .holidayRequestDeclined, .holidayCancelledByManager, .holidayBookedForYou].contains(notification.type) {
                seenHolidayDecisionNotificationKeys.insert(key)
            }
            if notification.type == .bookingCreated {
                seenBookingNotificationIds.insert(notification.id)
            }
        }
    }

    private func syntheticNotificationId(from key: String) -> UUID {
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuidString = String(
            format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuidString: uuidString) ?? UUID()
    }

    /// Server-push types must not also schedule a local banner for the same inbox id.
    private func isDevicePush(_ type: String) -> Bool {
        CanonicalBusinessEngine.notificationDeliversDevicePush(type) == true
    }

    /// `devicePushAllowed(prefs, type)`: the type sends a device push and the signed-in user's toggle is on.
    private func devicePushAllowed(type: String) -> Bool {
        let prefs = appSettingsStore?.settings.notifications.preferenceValues ?? [:]
        return CanonicalBusinessEngine.devicePushAllowed(prefs: prefs, type: type)
            ?? (isDevicePush(type) && deliveryAllowed(type: type))
    }

    func foregroundPresentationOptions(isRemote: Bool, type: String?) -> UNNotificationPresentationOptions {
        if isRemote {
            guard let type, devicePushAllowed(type: type) else { return [] }
            clearAppIconBadgeIfNeeded()
            return [.banner, .sound, .list]
        }
        return [.banner, .sound, .list]
    }

    /// Home-screen icon on foreground. The script's `NOTIFICATION_ICON_BADGE_CLEARS_ON_FOREGROUND` (true)
    /// clears it while the app is open; the in-app number stays until the listed rows are read. When the
    /// script says it does not clear, the icon shows the unread inbox count.
    func clearAppIconBadgeIfNeeded() {
        if CanonicalBusinessEngine.notificationIconBadgeClearsOnForeground == true {
            setAppIconBadge(0)
        } else {
            setAppIconBadge(unreadCount)
        }
    }

    /// The app-icon badge counts the same unread inbox rows (§13). While the app is open and the script
    /// clears the icon on foreground, it stays clear.
    func syncAppIconBadgeToUnreadCount() {
        #if canImport(UIKit)
        let isActive = UIApplication.shared.applicationState == .active
        #else
        let isActive = false
        #endif
        if isActive, CanonicalBusinessEngine.notificationIconBadgeClearsOnForeground == true { return }
        setAppIconBadge(unreadCount)
    }

    private func setAppIconBadge(_ count: Int) {
        let value = max(0, count)
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(value) { _ in }
        } else {
            #if canImport(UIKit)
            UIApplication.shared.applicationIconBadgeNumber = value
            #endif
        }
    }

    /// Rows the centre shows. Visibility and newest-first order come from the script. A toggle never hides
    /// a row (`notificationShowsInInbox`).
    func listedInbox(_ allItems: [AppNotification], userId: String) -> [AppNotification] {
        let prefs = appSettingsStore?.settings.notifications.preferenceValues
        var inboxTypeShown: [String: Bool] = [:]
        let items = allItems.filter { item in
            let type = item.typeText
            if let known = inboxTypeShown[type] { return known }
            let shown = CanonicalBusinessEngine.notificationShowsInInbox(prefs: prefs, type: type)
            inboxTypeShown[type] = shown
            return shown
        }
        // `inboxNotificationVisibleToUser(row, ids)`: the row's `userId` is one of the person's ids (`personIdSet`).
        // Ownerless rows are not inbox rows. Asked once per distinct owner.
        // RULEBOOK 1.10.0 §13: with `now` — a row counts from its `createdAt` (asked per row).
        let ownerIds = inboxOwnerIds(for: userId)
        let now = Date()
        var visibleItems: [AppNotification] = []
        for item in items {
            // RULEBOOK 1.16.0: with the row type, only a scheduled type waits for its `createdAt`; other rows allow
            // `INBOX_CREATED_AT_SKEW_MS` of writer clock skew.
            guard let shown = CanonicalBusinessEngine.inboxNotificationVisibleToUser(
                rowUserId: item.userId,
                userIds: ownerIds,
                createdAtMs: item.createdAt.timeIntervalSince1970 * 1000,
                now: now,
                type: item.typeText
            ) else { return items }
            if shown { visibleItems.append(item) }
        }
        // Order only: `compareInboxNotificationsByCreatedAt` through the existing wrapper. Every row here already
        // passed visibility, so each is sent under the signed-in id for that call.
        let rows = visibleItems.map { item in
            CanonicalBusinessEngine.CanonicalInboxNotificationRow(
                id: item.id.uuidString,
                userId: userId,
                isRead: item.isRead,
                createdAt: item.createdAt.timeIntervalSince1970 * 1000
            )
        }
        guard let visible = CanonicalBusinessEngine.visibleSortedInboxNotifications(rows, userId: userId) else {
            return visibleItems
        }
        // A repeated id keeps the first row. uniqueKeysWithValues would crash on it.
        let byId = Dictionary(items.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        return visible.compactMap { byId[$0.id] }
    }

    private func setUnreadCount(_ count: Int) {
        unreadCount = max(0, count)
        syncAppIconBadgeToUnreadCount()
    }

    /// `unreadNotificationBadgeCount(rows, ids)`: unread rows addressed to one of the person's ids (RULEBOOK §13).
    func setUnreadCount(from items: [AppNotification]) {
        let userId = userStore?.currentUser?.id ?? ""
        let rows = items.map {
            CanonicalBusinessEngine.CanonicalUnreadNotificationRow(userId: $0.userId, isRead: $0.isRead)
        }
        guard let count = CanonicalBusinessEngine.unreadNotificationBadgeCount(
            rows: rows,
            userIds: inboxOwnerIds(for: userId),
            createdAtMs: items.map { $0.createdAt.timeIntervalSince1970 * 1000 },
            now: Date(),
            types: items.map(\.typeText)
        ) else { return }
        setUnreadCount(count)
    }

    /// Every id of the person (`personIdSet`): the inbox owner ids for visibility and the badge.
    private func inboxOwnerIds(for userId: String) -> [String] {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let users = userStore?.organizationUsers ?? []
        if let me = userStore?.currentUser, me.id == trimmed {
            return RulebookPeople.ownerIds(for: me, users: users)
        }
        if let row = users.first(where: { $0.id == trimmed }) {
            return RulebookPeople.ownerIds(for: row, users: users)
        }
        return [trimmed]
    }

    private func isDeadlineLifecycle(_ type: AppNotification.NotificationType) -> Bool {
        switch type {
        case .deadlineReminder, .deadlineDue:
            return true
        default:
            return false
        }
    }

    private func isFutureScheduledDeadline(_ notification: AppNotification) -> Bool {
        isDeadlineLifecycle(notification.type) && notification.createdAt > Date().addingTimeInterval(15)
    }

    private func capturePendingDeadlineNotifications(from items: [AppNotification], currentUser: AppUser) {
        pendingScheduledDeadlineNotifications = items.filter { notification in
            isFutureScheduledDeadline(notification) && shouldShowIgnoringSchedule(notification, for: currentUser)
        }
    }

    private func shouldShowIgnoringSchedule(_ notification: AppNotification, for user: AppUser) -> Bool {
        if let userId = notification.userId {
            return isAddressedToMe(userId) || userId == user.id
        }
        return true
    }

    private func scheduleOsAlertsForPendingDeadlines() async {
        guard let currentUser = userStore?.currentUser else { return }
        for notification in pendingScheduledDeadlineNotifications {
            guard shouldShowIgnoringSchedule(notification, for: currentUser) else { continue }
            guard notification.createdAt > Date() else { continue }
            guard let relatedId = notification.relatedId else { continue }
            let identifier = notification.type == .deadlineDue
                ? DeadlineLocalNotifications.dueIdentifier(deadlineId: relatedId)
                : DeadlineLocalNotifications.reminderIdentifier(deadlineId: relatedId)
            await LocalNotificationService.shared.scheduleQualificationExpiryOneShot(
                identifier: identifier,
                title: notification.title,
                body: notification.message,
                fireAt: notification.createdAt,
                userInfo: NotificationDeepLink.userInfo(for: notification)
            )
        }
    }

    /// Pre-1.9 builds kept device-local read state for derived inbox rows; drop those keys once per user.
    private func removeLegacyLocalInboxState(userId: String) {
        guard !userId.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: "NotificationService.dismissedSynthetic." + userId)
        UserDefaults.standard.removeObject(forKey: "NotificationService.dismissedSyntheticKey." + userId)
    }
}

extension Notification.Name {
    static let qualificationExpiryScheduleRefresh = Notification.Name("qualificationExpiryScheduleRefresh")
}



