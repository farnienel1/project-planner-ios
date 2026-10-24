import Foundation

extension Notification.Name {
    /// iOS / in-app notification tap. `userInfo` uses `NotificationDeepLink` keys.
    static let openNotificationDeepLink = Notification.Name("openNotificationDeepLink")
    /// A scheduled timesheet reminder reached notify-at while this app could run.
    static let timesheetSubmissionNoticeFired = Notification.Name("timesheetSubmissionNoticeFired")
}

enum NotificationDeepLink {
    nonisolated static let typeKey = "pp_type"
    static let relatedIdKey = "pp_relatedId"
    static let userIdKey = "pp_userId"
    static let weekStartKey = "pp_weekStart"
    static let dateKey = "pp_date"
    static let dayKeyKey = "pp_dayKey"
    static let catalogueKey = "pp_catalogue"

    static func userInfo(for notification: AppNotification) -> [String: Any] {
        let paymentDay = notification.type == .timesheetSubmissionReminder ? notification.dayKey : nil
        return userInfo(
            type: notification.type,
            relatedId: notification.relatedId,
            relatedIdText: paymentDay,
            userId: notification.deepLinkUserId ?? notification.userId,
            weekStart: notification.deepLinkWeekStart,
            dayKey: notification.dayKey,
            catalogue: notification.catalogue
        )
    }

    static func userInfo(
        type: AppNotification.NotificationType,
        relatedId: UUID? = nil,
        relatedIdText: String? = nil,
        userId: String? = nil,
        weekStart: Date? = nil,
        dayKey: String? = nil,
        catalogue: String? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [
            typeKey: type.rawValue
        ]
        if let relatedIdText, !relatedIdText.isEmpty {
            info[relatedIdKey] = relatedIdText
        } else if let relatedId {
            info[relatedIdKey] = relatedId.uuidString
        }
        if let userId, !userId.isEmpty {
            info[userIdKey] = userId
        }
        if let weekStart {
            info[weekStartKey] = weekStart.timeIntervalSince1970
        }
        if let dayKey, !dayKey.isEmpty {
            info[dayKeyKey] = dayKey
        }
        if let catalogue, !catalogue.isEmpty {
            info[catalogueKey] = catalogue
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

    /// Asks the script for a destination, then opens the existing screen for that kind.
    /// A nil script result does not invent a route.
    static func route(userInfo: [String: Any], user: AppUser?) {
        let typeRaw = (userInfo[typeKey] as? String) ?? (userInfo["type"] as? String) ?? ""
        guard !typeRaw.isEmpty, let user else { return }
        guard let role = CanonicalBusinessEngine.accountKindFromFlags(
            isSuperAdmin: user.isSuperAdmin,
            role: user.role.rawValue,
            adminAccess: user.permissions.adminAccess,
            manager: user.permissions.manager,
            operativeMode: user.permissions.operativeMode
        ) else { return }

        let related = string(from: userInfo[relatedIdKey] ?? userInfo["relatedId"])
        let dayKey = string(from: userInfo[dayKeyKey] ?? userInfo["dayKey"])
        let catalogue = string(from: userInfo[catalogueKey] ?? userInfo["catalogue"])
        let targetUserId = string(from: userInfo[userIdKey] ?? userInfo["targetUserId"])
        guard let destination = CanonicalBusinessEngine.notificationDestination(
            type: typeRaw,
            relatedId: related,
            dayKey: dayKey,
            catalogue: catalogue,
            role: role,
            deepLinkUserId: targetUserId
        ) else { return }

        open(destination, weekStart: weekStart(from: userInfo))
    }

    private static func open(_ destination: CanonicalBusinessEngine.CanonicalNotificationDestination, weekStart: Date?) {
        switch destination.kind {
        case "dailyOverviewDay":
            var payload: [String: Any] = ["route": MainMenuSurfaceRoute.dailyOverview.rawValue]
            if let dayKey = destination.dayKey { payload["dayKey"] = dayKey }
            postSurface(payload)
        case "projectScheduling":
            openJob(destination, section: "scheduling")
        case "smallWorksScheduling":
            openJob(destination, section: "scheduling")
        case "mySchedule":
            var payload: [String: Any] = ["route": MainMenuSurfaceRoute.mySchedule.rawValue]
            if let dayKey = destination.dayKey { payload["dayKey"] = dayKey }
            postSurface(payload)
        case "annualLeave":
            NotificationCenter.default.post(
                name: NSNotification.Name("openHoliday"),
                object: nil,
                userInfo: ["showRequests": false]
            )
        case "annualLeavePending":
            NotificationCenter.default.post(
                name: NSNotification.Name("openHoliday"),
                object: nil,
                userInfo: ["showRequests": true]
            )
        case "projectDetail":
            openJob(destination, isSmallWorks: false, section: nil)
        case "projectsList":
            NotificationCenter.default.post(
                name: NSNotification.Name("selectTab"),
                object: nil,
                userInfo: ["tab": 1]
            )
        case "smallWorksDetail":
            openJob(destination, isSmallWorks: true, section: nil)
        case "smallWorksList":
            NotificationCenter.default.post(
                name: NSNotification.Name("selectTab"),
                object: nil,
                userInfo: ["tab": 2]
            )
        case "warnings":
            postSurface(["route": MainMenuSurfaceRoute.warnings.rawValue])
            NotificationCenter.default.post(name: NSNotification.Name("navigateToWarnings"), object: nil)
        case "materialOrders":
            postSurface(["route": MainMenuSurfaceRoute.wholesalers.rawValue])
        case "clients":
            postSurface(["route": MainMenuSurfaceRoute.clients.rawValue])
        case "manageUsers":
            postSurface(["route": MainMenuSurfaceRoute.manageUsers.rawValue])
        case "userEdit":
            var payload: [String: Any] = ["route": MainMenuSurfaceRoute.manageUsers.rawValue]
            if let relatedId = destination.relatedId, !relatedId.isEmpty {
                payload["editUserId"] = relatedId
            }
            postSurface(payload)
        case "tasks":
            NotificationCenter.default.post(name: NSNotification.Name("openTasksDetail"), object: nil)
        case "healthSafety":
            openJob(destination, section: "healthSafety")
        case "timesheetMine":
            var payload: [String: Any] = [
                "route": MainMenuSurfaceRoute.invoicing.rawValue,
                "timesheetSurface": "mine",
            ]
            if let dayKey = destination.dayKey { payload["dayKey"] = dayKey }
            if let weekStart { payload["weekStart"] = weekStart }
            postSurface(payload)
        case "timesheetTeamAwaiting":
            postTimesheetTeam(destination, surface: "teamAwaiting", weekStart: weekStart)
        case "timesheetTeamSigned":
            postTimesheetTeam(destination, surface: "teamSigned", weekStart: weekStart)
        case "qualifications":
            postSurface(["route": MainMenuSurfaceRoute.qualifications.rawValue])
        case "home":
            NotificationCenter.default.post(
                name: NSNotification.Name("selectTab"),
                object: nil,
                userInfo: ["tab": 0]
            )
        case "notifications":
            postSurface(["route": MainMenuSurfaceRoute.notifications.rawValue])
        default:
            postSurface(["route": MainMenuSurfaceRoute.notifications.rawValue])
        }
    }

    private static func postTimesheetTeam(
        _ destination: CanonicalBusinessEngine.CanonicalNotificationDestination,
        surface: String,
        weekStart: Date?
    ) {
        var payload: [String: Any] = [
            "route": MainMenuSurfaceRoute.invoicing.rawValue,
            "timesheetSurface": surface,
        ]
        if let userId = destination.userId, !userId.isEmpty {
            payload["targetUserId"] = userId
        }
        if let weekStart {
            payload["weekStart"] = weekStart
        } else if let dayKey = destination.dayKey,
                  let date = CanonicalBusinessEngine.date(fromDayKey: dayKey) {
            payload["weekStart"] = date
        }
        postSurface(payload)
    }

    private static func openJob(
        _ destination: CanonicalBusinessEngine.CanonicalNotificationDestination,
        isSmallWorks: Bool? = nil,
        section: String?
    ) {
        let smallWorks = isSmallWorks ?? (destination.kind == "smallWorksScheduling" || destination.kind == "smallWorksDetail")
        guard let relatedId = destination.relatedId, let projectId = UUID(uuidString: relatedId) else {
            NotificationCenter.default.post(
                name: NSNotification.Name("selectTab"),
                object: nil,
                userInfo: ["tab": smallWorks ? 2 : 1]
            )
            return
        }
        var info: [String: Any] = [
            "projectId": projectId,
            "isSmallWorks": smallWorks,
        ]
        if let dayKey = destination.dayKey { info["dayKey"] = dayKey }
        if let section { info["section"] = section }
        NotificationCenter.default.post(name: .openWorkCatalogueDetail, object: nil, userInfo: info)
    }

    private static func postSurface(_ payload: [String: Any]) {
        NotificationCenter.default.post(name: .mainMenuOpenSurface, object: nil, userInfo: payload)
    }

    private static func string(from value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let id = value as? UUID { return id.uuidString }
        return nil
    }

    private static func weekStart(from userInfo: [String: Any]) -> Date? {
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
    }
}
