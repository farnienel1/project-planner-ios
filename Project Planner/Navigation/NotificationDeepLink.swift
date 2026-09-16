import Foundation

extension Notification.Name {
    /// iOS / in-app notification tap. `userInfo` uses `NotificationDeepLink` keys.
    static let openNotificationDeepLink = Notification.Name("openNotificationDeepLink")
}

enum NotificationDeepLink {
    static let typeKey = "pp_type"
    static let relatedIdKey = "pp_relatedId"
    static let userIdKey = "pp_userId"
    static let weekStartKey = "pp_weekStart"
    static let dateKey = "pp_date"

    static func userInfo(for notification: AppNotification) -> [String: Any] {
        userInfo(
            type: notification.type,
            relatedId: notification.relatedId,
            userId: notification.deepLinkUserId ?? notification.userId,
            weekStart: notification.deepLinkWeekStart
        )
    }

    static func userInfo(
        type: AppNotification.NotificationType,
        relatedId: UUID? = nil,
        userId: String? = nil,
        weekStart: Date? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [
            typeKey: type.rawValue
        ]
        if let relatedId {
            info[relatedIdKey] = relatedId.uuidString
        }
        if let userId, !userId.isEmpty {
            info[userIdKey] = userId
        }
        if let weekStart {
            info[weekStartKey] = weekStart.timeIntervalSince1970
        }
        return info
    }

    static func userInfo(from raw: [AnyHashable: Any]) -> [String: Any] {
        var info: [String: Any] = [:]
        for (key, value) in raw {
            info[String(describing: key)] = value
        }
        return info
    }

    /// Routes a notification tap onto existing Home / ContentView notification names.
    static func route(userInfo: [String: Any], isOperativeMode: Bool) {
        let typeRaw = (userInfo[typeKey] as? String) ?? (userInfo["type"] as? String)
        let type = typeRaw.flatMap(AppNotification.NotificationType.init(rawValue:))
        let relatedId = uuid(from: userInfo[relatedIdKey] ?? userInfo["relatedId"])
        let targetUserId = (userInfo[userIdKey] as? String) ?? (userInfo["targetUserId"] as? String)
        let weekStart: Date? = {
            if let date = userInfo[weekStartKey] as? Date ?? userInfo["weekStart"] as? Date {
                return date
            }
            if let interval = userInfo[weekStartKey] as? TimeInterval ?? userInfo["weekStart"] as? TimeInterval {
                return Date(timeIntervalSince1970: interval)
            }
            if let number = userInfo[weekStartKey] as? NSNumber ?? userInfo["weekStart"] as? NSNumber {
                return Date(timeIntervalSince1970: number.doubleValue)
            }
            return nil
        }()

        switch type {
        case .bookingCreated:
            if isOperativeMode {
                openSurface(.mySchedule)
            } else {
                openSurface(.dailyOverview)
            }
        case .operativeCreated, .managerCreated, .lineManagerPeerUpdate:
            openSurface(.manageUsers)
        case .clientCreated:
            openSurface(.clients)
        case .projectCreated:
            if let relatedId {
                NotificationCenter.default.post(
                    name: .openWorkCatalogueDetail,
                    object: nil,
                    userInfo: ["projectId": relatedId, "isSmallWorks": false]
                )
            } else {
                NotificationCenter.default.post(name: Notification.Name("selectProjectsTab"), object: nil)
            }
        case .smallWorksCreated:
            if let relatedId {
                NotificationCenter.default.post(
                    name: .openWorkCatalogueDetail,
                    object: nil,
                    userInfo: ["projectId": relatedId, "isSmallWorks": true]
                )
            } else {
                openSurface(.createSmallWorks)
            }
        case .bookingClash, .warningRemoved, .qualificationExpiry, .materialOrderCutOff:
            openSurface(.warnings)
            NotificationCenter.default.post(name: NSNotification.Name("navigateToWarnings"), object: nil)
        case .taskCompleted, .taskCreated, .deadlineAssigned, .deadlineReminder, .deadlineDue:
            NotificationCenter.default.post(name: NSNotification.Name("openTasksDetail"), object: nil)
        case .holidayRequestSubmitted:
            NotificationCenter.default.post(
                name: NSNotification.Name("openHoliday"),
                object: nil,
                userInfo: ["showRequests": true]
            )
        case .holidayRequestApproved, .holidayRequestDeclined:
            NotificationCenter.default.post(
                name: NSNotification.Name("openHoliday"),
                object: nil,
                userInfo: ["showRequests": false]
            )
        case .timesheetPendingManagerSignoff, .timesheetSignedByManager:
            var payload: [String: Any] = ["route": MainMenuSurfaceRoute.invoicing.rawValue]
            if let targetUserId, !targetUserId.isEmpty {
                payload["targetUserId"] = targetUserId
            }
            if let weekStart {
                payload["weekStart"] = weekStart
            }
            NotificationCenter.default.post(name: .mainMenuOpenSurface, object: nil, userInfo: payload)
        case .none:
            break
        }
        _ = relatedId
    }

    private static func openSurface(_ route: MainMenuSurfaceRoute) {
        NotificationCenter.default.post(
            name: .mainMenuOpenSurface,
            object: nil,
            userInfo: ["route": route.rawValue]
        )
    }

    private static func uuid(from value: Any?) -> UUID? {
        if let id = value as? UUID { return id }
        if let s = value as? String { return UUID(uuidString: s) }
        return nil
    }
}
