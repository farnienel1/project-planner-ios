import Foundation
import UserNotifications

/// Shared visibility + "live people on this job" helpers for Deadlines, Projects, Small Works, and Site Audit.
enum WorkAccess {
    static func operativeVisibleProjectIds(
        currentUser: AppUser?,
        operative: Operative?,
        operatives: [Operative],
        managers: [Manager] = [],
        bookingStore: BookingStore,
        taskStore: ProjectTaskStore,
        deadlineAssignedProjectIds: Set<UUID>
    ) -> Set<UUID> {
        var ids = Set<UUID>()
        if let operative {
            for booking in bookingStore.bookings where booking.operativeId == operative.id && booking.status != .cancelled {
                ids.insert(booking.projectId)
            }
        }
        ids.formUnion(taskAssignedProjectIds(
            currentUser: currentUser,
            taskStore: taskStore,
            operatives: operatives,
            managers: managers
        ))
        ids.formUnion(deadlineAssignedProjectIds)
        return ids
    }

    static func taskAssignedProjectIds(
        currentUser: AppUser?,
        taskStore: ProjectTaskStore,
        operatives: [Operative],
        managers: [Manager]
    ) -> Set<UUID> {
        guard let currentUser else { return [] }
        var ids = Set<UUID>()
        for task in taskStore.tasks {
            let asOp = task.isAssignedToUser(
                userEmail: currentUser.email,
                operatives: operatives,
                managers: managers,
                isOperativeMode: true
            )
            let asStaff = task.isAssignedToUser(
                userEmail: currentUser.email,
                operatives: operatives,
                managers: managers,
                isOperativeMode: false
            )
            if asOp || asStaff {
                ids.insert(task.projectId)
            }
        }
        return ids
    }

    /// User ids booked onto the job (any non-cancelled booking) or assigned a task on it.
    static func liveUserIds(
        projectId: UUID,
        userStore: UserStore,
        bookingStore: BookingStore,
        operativeStore: OperativeStore,
        managerScheduleStore: ManagerScheduleStore,
        taskStore: ProjectTaskStore
    ) -> Set<String> {
        var ids = Set<String>()
        let users = userStore.organizationUsers

        for booking in managerScheduleStore.managerSiteBookings
        where (booking.locationType == .project || booking.locationType == .smallWork) && booking.locationId == projectId {
            ids.insert(booking.userId)
        }

        let operativeById = Dictionary(uniqueKeysWithValues: operativeStore.allOperatives.map { ($0.id, $0) })
        for booking in bookingStore.bookings where booking.projectId == projectId && booking.status != .cancelled {
            guard let operative = operativeById[booking.operativeId] else { continue }
            if let user = userMatchingEmail(operative.email, in: users) {
                ids.insert(user.id)
            }
        }

        let managerById = Dictionary(uniqueKeysWithValues: operativeStore.allManagers.map { ($0.id, $0) })
        for task in taskStore.tasks where task.projectId == projectId {
            for opId in task.allAssignedOperativeIds {
                if let operative = operativeById[opId], let user = userMatchingEmail(operative.email, in: users) {
                    ids.insert(user.id)
                }
            }
            for mgrId in task.allAssignedManagerIds {
                if let manager = managerById[mgrId], let user = userMatchingEmail(manager.email, in: users) {
                    ids.insert(user.id)
                }
            }
        }
        return ids
    }

    static func peopleForJob(
        projectId: UUID,
        userStore: UserStore,
        bookingStore: BookingStore,
        operativeStore: OperativeStore,
        managerScheduleStore: ManagerScheduleStore,
        taskStore: ProjectTaskStore
    ) -> [DLPerson] {
        let liveIds = liveUserIds(
            projectId: projectId,
            userStore: userStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore,
            managerScheduleStore: managerScheduleStore,
            taskStore: taskStore
        )
        let users = userStore.organizationUsers.filter(\.isActive)
        return users
            .map { user in
                let trade = StaffTradeType.displayLabel(presetRaw: user.tradeTypePreset, custom: user.tradeTypeCustom)
                let live = liveIds.contains(user.id)
                let subtitle: String
                if live {
                    subtitle = trade == "—" ? "On this job" : "On this job · \(trade)"
                } else {
                    subtitle = trade == "—" ? (user.permissions.operativeMode ? "Operative" : "Staff") : trade
                }
                return DLPerson(id: user.id, name: user.fullName, subtitle: subtitle, isLive: live)
            }
            .sorted { a, b in
                if a.isLive != b.isLive { return a.isLive && !b.isLive }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    static func siteAuditRef(_ audit: SiteAudit) -> DLSiteAuditRef {
        let title = audit.customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return DLSiteAuditRef(
            id: audit.id,
            title: title.isEmpty ? audit.type.rawValue : title,
            typeLabel: audit.type.rawValue,
            date: audit.date,
            itemCount: audit.items.count,
            authorName: audit.authorName,
            jobLine: "\(audit.projectJobNumber) \(audit.projectName)"
        )
    }

    private static func userMatchingEmail(_ email: String, in users: [AppUser]) -> AppUser? {
        let needle = normalizedEmail(email)
        guard !needle.isEmpty else { return nil }
        return users.first { normalizedEmail($0.email) == needle }
    }

    private static func normalizedEmail(_ value: String?) -> String {
        value?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum DeadlineLocalNotifications {
    static let idPrefix = "deadline."

    static func reminderIdentifier(deadlineId: UUID) -> String {
        "\(idPrefix)\(deadlineId.uuidString).reminder"
    }

    static func dueIdentifier(deadlineId: UUID) -> String {
        "\(idPrefix)\(deadlineId.uuidString).due"
    }

    static func cancel(deadlineId: UUID) async {
        let ids = [reminderIdentifier(deadlineId: deadlineId), dueIdentifier(deadlineId: deadlineId)]
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func cancelAll(for items: [DLDeadline]) async {
        for item in items {
            await cancel(deadlineId: item.id)
        }
    }

    /// Schedules reminder + due-morning local alerts for open deadlines assigned to `userId`.
    static func sync(items: [DLDeadline], currentUserId: String?) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        guard let currentUserId, !currentUserId.isEmpty else { return }
        var cal = Calendar.current
        cal.timeZone = TimeZone.current

        for item in items {
            guard item.status != .complete else { continue }
            guard item.assigneeUserIds.contains(currentUserId) else { continue }
            let body = item.summaryLine()
            if let days = item.reminderDaysBefore,
               let reminderDay = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: item.due)),
               let fireAt = cal.date(bySettingHour: 8, minute: 0, second: 0, of: reminderDay) {
                await LocalNotificationService.shared.scheduleQualificationExpiryOneShot(
                    identifier: reminderIdentifier(deadlineId: item.id),
                    title: "Deadline reminder",
                    body: body,
                    fireAt: fireAt
                )
            }
            if let dueMorning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: cal.startOfDay(for: item.due)) {
                await LocalNotificationService.shared.scheduleQualificationExpiryOneShot(
                    identifier: dueIdentifier(deadlineId: item.id),
                    title: "Deadline due today",
                    body: body,
                    fireAt: dueMorning
                )
            }
        }
    }
}
