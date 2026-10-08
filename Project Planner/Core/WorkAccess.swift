import Foundation
import UserNotifications

/// Shared visibility + "live people on this job" helpers for Deadlines, Projects, Small Works, and Site Audit.
enum WorkAccess {
    enum JobCatalogue: Equatable {
        case projects
        case smallWorks
        case all

        func includes(_ project: Project) -> Bool {
            switch self {
            case .projects: return project.jobType != .smallWorks
            case .smallWorks: return project.jobType == .smallWorks
            case .all: return true
            }
        }
    }

    /// Admins and managers see every job in the catalogue, including jobs they are not assigned to.
    /// `permissions.projects` and `permissions.smallWorks` do not hide those lists. They only gate
    /// create and edit (`UserStore.canManageWorkCatalogue`). Super admin ignores those two toggles.
    /// A job explicitly hidden from a manager stays off that manager's list. Operatives still see
    /// only jobs they are booked onto.
    static func visibleWorks(
        from projects: [Project],
        catalogue: JobCatalogue,
        userStore: UserStore,
        operativeStore: OperativeStore,
        bookingStore: BookingStore,
        managerBookings: [ManagerSiteBooking],
        taskStore: ProjectTaskStore?,
        deadlineAssignedProjectIds: Set<UUID> = []
    ) -> [Project] {
        let scoped = projects.filter { catalogue.includes($0) }
        let user = userStore.displayUser ?? userStore.currentUser

        if userStore.isOperativeMode() {
            guard let user else { return [] }
            let assignedIds = operativeVisibleProjectIds(
                currentUser: user,
                operative: operativeMatching(email: user.email, in: operativeStore.allOperatives),
                operatives: operativeStore.allOperatives,
                managers: operativeStore.allManagers,
                bookingStore: bookingStore,
                taskStore: taskStore,
                deadlineAssignedProjectIds: deadlineAssignedProjectIds
            )
            return scoped.filter { assignedIds.contains($0.id) && !$0.hiddenOperativeUserIds.contains(user.id) }
        }

        guard let user else { return [] }
        if user.isExcludedFromManagerVisibilityHiding {
            return scoped
        }

        let notHidden = scoped.filter { !$0.hiddenManagerUserIds.contains(user.id) }
        let isManager = user.permissions.manager || user.role == .manager
        if isManager {
            return notHidden
        }
        return notHidden.filter { project in
            isAssignedOrBookedOnto(
                project,
                user: user,
                operativeStore: operativeStore,
                bookingStore: bookingStore,
                managerBookings: managerBookings
            )
        }
    }

    /// Variations: admins see every job. Managers see only jobs they are assigned on.
    /// Operatives never see the feature.
    static func canAccessVariations(
        project: Project,
        userStore: UserStore,
        operativeStore: OperativeStore
    ) -> Bool {
        if userStore.isOperativeMode() { return false }
        guard let user = userStore.displayUser ?? userStore.currentUser else { return false }
        if user.isSuperAdmin || user.permissions.adminAccess || user.role == .admin {
            return true
        }
        guard user.permissions.manager || user.role == .manager else { return false }
        return isAssignedManager(on: project, user: user, operativeStore: operativeStore)
    }

    static func isAssignedManager(
        on project: Project,
        user: AppUser,
        operativeStore: OperativeStore
    ) -> Bool {
        let assigned = Set(project.allAssignedManagerIds)
        let email = normalizedEmail(user.email)
        if let manager = operativeStore.allManagers.first(where: { normalizedEmail($0.email) == email }),
           assigned.contains(manager.id) {
            return true
        }
        return assigned.contains(ProjectManagerPickerSupport.stableManagerId(email: user.email))
    }

    static func isAssignedOrBookedOnto(
        _ project: Project,
        user: AppUser,
        operativeStore: OperativeStore,
        bookingStore: BookingStore,
        managerBookings: [ManagerSiteBooking]
    ) -> Bool {
        let email = normalizedEmail(user.email)

        if let manager = operativeStore.allManagers.first(where: { normalizedEmail($0.email) == email }),
           project.allAssignedManagerIds.contains(manager.id) {
            return true
        }

        if managerBookings.contains(where: { booking in
            booking.userId == user.id
                && (booking.locationType == .project || booking.locationType == .smallWork)
                && booking.locationId == project.id
        }) {
            return true
        }

        if let operative = operativeMatching(email: user.email, in: operativeStore.allOperatives),
           bookingStore.bookings.contains(where: {
               $0.operativeId == operative.id && $0.projectId == project.id && $0.status != .cancelled
           }) {
            return true
        }

        return false
    }

    /// Home “active projects”: live jobs whose dates include today, including the last day.
    /// Admins see every such job. Managers see every such job except ones hidden from them.
    /// Operatives see only jobs they are booked onto.
    static func homeActiveProjectCount(
        projects: [Project],
        user: AppUser?,
        isOperativeMode: Bool,
        seesEveryJob: Bool,
        isManager: Bool,
        operatives: [Operative],
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking]
    ) -> Int {
        let active = projects.filter { $0.status == .active }
        guard let user else { return 0 }
        if isOperativeMode {
            let operative = signedInOperative(
                email: user.email,
                firstName: user.firstName,
                surname: user.surname,
                operatives: operatives
            )
            var bookedIds = Set<UUID>()
            if let operative {
                for booking in bookings where booking.operativeId == operative.id && booking.status != .cancelled {
                    bookedIds.insert(booking.projectId)
                }
            }
            for booking in managerBookings where booking.userId == user.id {
                guard booking.locationType == .project || booking.locationType == .smallWork,
                      let locationId = booking.locationId else { continue }
                bookedIds.insert(locationId)
            }
            return active.filter {
                bookedIds.contains($0.id) && !$0.hiddenOperativeUserIds.contains(user.id)
            }.count
        }
        if seesEveryJob {
            return active.count
        }
        if isManager {
            return active.filter { !$0.hiddenManagerUserIds.contains(user.id) }.count
        }
        return active.filter { !$0.hiddenManagerUserIds.contains(user.id) }.count
    }

    /// Roster row for the signed-in account. Email first, then first and last name.
    static func signedInOperative(
        email: String?,
        firstName: String?,
        surname: String?,
        operatives: [Operative]
    ) -> Operative? {
        let needle = normalizedEmail(email)
        if !needle.isEmpty,
           let match = operatives.first(where: { normalizedEmail($0.email) == needle }) {
            return match
        }
        let first = firstName?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = surname?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !first.isEmpty || !last.isEmpty else { return nil }
        return operatives.first { operative in
            operative.firstName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == first
                && operative.lastName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == last
        }
    }

    /// Every operative profile for this email. Bookings are stored on one profile;
    /// My Schedule has to read the others as the same person.
    static func signedInOperativeIds(
        email: String?,
        firstName: String?,
        surname: String?,
        operatives: [Operative]
    ) -> Set<UUID> {
        let needle = normalizedEmail(email)
        if !needle.isEmpty {
            let matches = Set(operatives.filter { normalizedEmail($0.email) == needle }.map(\.id))
            if !matches.isEmpty { return matches }
        }
        if let one = signedInOperative(email: email, firstName: firstName, surname: surname, operatives: operatives) {
            return [one.id]
        }
        return []
    }

    /// Auth uid plus every `users` document id for the same email.
    /// An invited account can keep a legacy document id, and bookings are often stored against that id.
    static func signedInAccountIds(
        authUid: String?,
        currentUser: AppUser?,
        organizationUsers: [AppUser],
        email: String? = nil
    ) -> Set<String> {
        var ids = Set<String>()
        func add(_ raw: String?) {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { ids.insert(trimmed) }
        }
        add(authUid)
        add(currentUser?.id)
        let rawEmail = currentUser?.email ?? email ?? ""
        let needle = rawEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ids }
        for user in organizationUsers where user.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == needle {
            add(user.id)
            for alias in user.sameEmailUserIds { add(alias) }
        }
        for alias in currentUser?.sameEmailUserIds ?? [] { add(alias) }
        return ids
    }

    private static func operativeMatching(email: String, in operatives: [Operative]) -> Operative? {
        signedInOperative(email: email, firstName: nil, surname: nil, operatives: operatives)
    }

    static func operativeVisibleProjectIds(
        currentUser: AppUser?,
        operative: Operative?,
        operatives: [Operative],
        managers: [Manager] = [],
        bookingStore: BookingStore,
        taskStore: ProjectTaskStore?,
        deadlineAssignedProjectIds: Set<UUID>
    ) -> Set<UUID> {
        var ids = Set<UUID>()
        if let operative {
            for booking in bookingStore.bookings where booking.operativeId == operative.id && booking.status != .cancelled {
                ids.insert(booking.projectId)
            }
        }
        if let taskStore {
            ids.formUnion(taskAssignedProjectIds(
                currentUser: currentUser,
                taskStore: taskStore,
                operatives: operatives,
                managers: managers
            ))
        }
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

enum DeadlineNotificationCopy {
    static func headline(projectName: String, item: DLDeadline) -> String {
        let project = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = item.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var prefix = project
        if !location.isEmpty {
            prefix = prefix.isEmpty ? location : "\(prefix) · \(location)"
        }
        if prefix.isEmpty { return item.title }
        return "\(prefix): \(item.title)"
    }

    static func reminderTitle() -> String { "Deadline reminder" }

    /// Absolute due date — never "due today" / "tomorrow", which go stale if baked at schedule time.
    static func reminderBody(projectName: String, item: DLDeadline) -> String {
        "\(headline(projectName: projectName, item: item)) is due \(DLFormat.day(item.due))"
    }

    static func dueTitle() -> String { "Deadline due today" }

    static func dueBody(projectName: String, item: DLDeadline) -> String {
        headline(projectName: projectName, item: item)
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

    static func parsedIdentifier(_ identifier: String) -> (deadlineId: UUID, isDue: Bool)? {
        guard identifier.hasPrefix(idPrefix) else { return nil }
        let rest = String(identifier.dropFirst(idPrefix.count))
        if rest.hasSuffix(".reminder") {
            let uuid = String(rest.dropLast(".reminder".count))
            return UUID(uuidString: uuid).map { ($0, false) }
        }
        if rest.hasSuffix(".due") {
            let uuid = String(rest.dropLast(".due".count))
            return UUID(uuidString: uuid).map { ($0, true) }
        }
        return nil
    }

    static func deadlineCalendar() -> Calendar {
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        return cal
    }

    static func reminderFireDate(for item: DLDeadline) -> Date? {
        let cal = deadlineCalendar()
        guard let days = item.reminderDaysBefore,
              let reminderDay = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: item.due)) else {
            return nil
        }
        return cal.date(bySettingHour: 8, minute: 0, second: 0, of: reminderDay)
    }

    static func dueFireDate(for item: DLDeadline) -> Date? {
        let cal = deadlineCalendar()
        return cal.date(bySettingHour: 8, minute: 0, second: 0, of: cal.startOfDay(for: item.due))
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
    /// Body copy is computed for the fire date (not "now"), and always includes the project name.
    static func sync(items: [DLDeadline], currentUserId: String?, projectName: String) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        guard let currentUserId, !currentUserId.isEmpty else { return }

        for item in items {
            guard item.status != .complete else { continue }
            guard item.assigneeUserIds.contains(currentUserId) else { continue }
            if let fireAt = reminderFireDate(for: item) {
                let title = DeadlineNotificationCopy.reminderTitle()
                let body = DeadlineNotificationCopy.reminderBody(projectName: projectName, item: item)
                await LocalNotificationService.shared.scheduleQualificationExpiryOneShot(
                    identifier: reminderIdentifier(deadlineId: item.id),
                    title: title,
                    body: body,
                    fireAt: fireAt,
                    userInfo: NotificationDeepLink.userInfo(
                        type: .deadlineReminder,
                        relatedId: item.id,
                        userId: currentUserId
                    )
                )
            }
            if let dueMorning = dueFireDate(for: item) {
                let title = DeadlineNotificationCopy.dueTitle()
                let body = DeadlineNotificationCopy.dueBody(projectName: projectName, item: item)
                await LocalNotificationService.shared.scheduleQualificationExpiryOneShot(
                    identifier: dueIdentifier(deadlineId: item.id),
                    title: title,
                    body: body,
                    fireAt: dueMorning,
                    userInfo: NotificationDeepLink.userInfo(
                        type: .deadlineDue,
                        relatedId: item.id,
                        userId: currentUserId
                    )
                )
            }
        }
    }
}
