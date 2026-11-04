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
    static let organizationIdKey = "pp_organizationId"
    static let notificationIdKey = "pp_notificationId"

    /// RULEBOOK 1.16.0 §13: a tap on a push or row from another company waits here while the app switches to that
    /// company (`notificationOrganizationSwitch`), then routes once that organisation has loaded.
    static var pendingAfterOrganizationSwitch: (organizationId: String, userInfo: [String: Any])?

    static func userInfo(for notification: AppNotification) -> [String: Any] {
        let paymentDay = notification.type == .timesheetSubmissionReminder ? notification.dayKey : nil
        return userInfo(
            type: notification.type,
            relatedId: notification.relatedId,
            relatedIdText: paymentDay ?? notification.relatedKey,
            userId: notification.deepLinkUserId ?? notification.userId,
            weekStart: notification.deepLinkWeekStart,
            dayKey: notification.dayKey,
            catalogue: notification.catalogue,
            organizationId: notification.organizationId,
            notificationId: notification.id.uuidString
        )
    }

    static func userInfo(
        type: AppNotification.NotificationType,
        relatedId: UUID? = nil,
        relatedIdText: String? = nil,
        userId: String? = nil,
        weekStart: Date? = nil,
        dayKey: String? = nil,
        catalogue: String? = nil,
        organizationId: String? = nil,
        notificationId: String? = nil
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
        if let organizationId, !organizationId.isEmpty {
            info[organizationIdKey] = organizationId
        }
        if let notificationId, !notificationId.isEmpty {
            info[notificationIdKey] = notificationId
        }
        return info
    }

    /// The tap's fields through `pushPayloadFields` (RULEBOOK 1.16.0 §13: one payload shape for every platform —
    /// `notificationId`, `type`, `relatedId`, `dayKey`, `catalogue`, `userId`, `organizationId`). A push carries those
    /// keys; an in-app row tap carries the `pp_` keys, read as the same fields. Nil when the script did not answer.
    static func payloadFields(from userInfo: [String: Any]) -> [String: String]? {
        func value(_ keys: String...) -> Any {
            for key in keys {
                if let text = string(from: userInfo[key]) { return text }
            }
            return NSNull()
        }
        let row: [String: Any] = [
            "notificationId": value(notificationIdKey, "notificationId"),
            "type": value(typeKey, "type"),
            "relatedId": value(relatedIdKey, "relatedId"),
            "dayKey": value(dayKeyKey, "dayKey"),
            "catalogue": value(catalogueKey, "catalogue"),
            "userId": value(userIdKey, "userId", "targetUserId"),
            "organizationId": value(organizationIdKey, "organizationId"),
        ]
        return CanonicalBusinessEngine.pushPayloadFields(row)
    }

    /// `notificationOrganizationSwitch`: the company to open before routing this tap, or nil to route in the open one.
    static func organizationToOpen(
        for userInfo: [String: Any],
        openOrganizationId: String?,
        membershipIds: [String]
    ) -> String? {
        guard let rowOrganizationId = payloadFields(from: userInfo)?["organizationId"] else { return nil }
        return CanonicalBusinessEngine.notificationOrganizationSwitch(
            rowOrganizationId: rowOrganizationId,
            openOrganizationId: openOrganizationId,
            membershipIds: membershipIds
        )
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
        // RULEBOOK 1.16.0: the push payload fields (`pushPayloadFields`) route the same way as tapping the row.
        let fields = payloadFields(from: userInfo)
        let typeRaw = fields?["type"] ?? (userInfo[typeKey] as? String) ?? (userInfo["type"] as? String) ?? ""
        guard !typeRaw.isEmpty, let user else { return }
        guard let role = CanonicalBusinessEngine.accountKindFromFlags(
            isSuperAdmin: user.isSuperAdmin,
            role: user.role.rawValue,
            adminAccess: user.permissions.adminAccess,
            manager: user.permissions.manager,
            operativeMode: user.permissions.operativeMode
        ) else { return }

        let related = fields.map { $0["relatedId"] } ?? string(from: userInfo[relatedIdKey] ?? userInfo["relatedId"])
        let dayKey = fields.map { $0["dayKey"] } ?? string(from: userInfo[dayKeyKey] ?? userInfo["dayKey"])
        let catalogue = fields.map { $0["catalogue"] } ?? string(from: userInfo[catalogueKey] ?? userInfo["catalogue"])
        let targetUserId = fields.map { $0["userId"] } ?? string(from: userInfo[userIdKey] ?? userInfo["targetUserId"])
        guard let destination = CanonicalBusinessEngine.notificationDestination(
            type: typeRaw,
            relatedId: related,
            dayKey: dayKey,
            catalogue: catalogue,
            role: role,
            deepLinkUserId: targetUserId
        ) else { return }

        open(destination, weekStart: weekStart(from: userInfo), variationParentType: targetUserId)
    }

    private static func open(
        _ destination: CanonicalBusinessEngine.CanonicalNotificationDestination,
        weekStart: Date?,
        variationParentType: String? = nil
    ) {
        switch destination.kind {
        // RULEBOOK 1.10.0 §13 (`notificationDestination`): a variation notice opens Variations, as web
        // (`hrefForNotificationDestination`). `variations` names the job; `variationDetail` names the variation, whose
        // job is read from the variation itself. iOS keeps variations under each job, so both open that job's
        // Variations; with no job they open the Projects tab (web's company list has no iOS screen).
        case "variations":
            openVariations(jobId: destination.relatedId, parentType: variationParentType)
        case "variationDetail":
            guard let variationId = destination.relatedId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !variationId.isEmpty,
                  let orgId = OrganizationRulebookContext.organizationId else {
                openVariations(jobId: nil, parentType: variationParentType)
                return
            }
            Task { @MainActor in
                let parent = await FirebaseBackend.variationParent(organizationId: orgId, variationId: variationId)
                openVariations(jobId: parent?.parentId, parentType: parent?.parentType.rawValue ?? variationParentType)
            }
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
        // RULEBOOK 1.29.0 §25: the person's own Overtime page; Users' → that person → Overtime
        // (kinds from CanonicalBusinessEngine.notificationDestination).
        case "overtimeMine":
            postSurface([
                "route": MainMenuSurfaceRoute.invoicing.rawValue,
                "timesheetSurface": "overtimeMine",
            ])
        case "overtimeUser":
            var payload: [String: Any] = [
                "route": MainMenuSurfaceRoute.invoicing.rawValue,
                "timesheetSurface": "overtimeUser",
            ]
            if let userId = destination.userId, !userId.isEmpty { payload["targetUserId"] = userId }
            postSurface(payload)
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

    /// The job's Variations tile (`WorkCatalogueDeepLink` section `variations`), or the job list when no job is known.
    private static func openVariations(jobId: String?, parentType: String?) {
        let smallWorks = parentType == VariationParentType.smallWork.rawValue
        guard let raw = jobId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            NotificationCenter.default.post(
                name: NSNotification.Name("selectTab"),
                object: nil,
                userInfo: ["tab": smallWorks ? 2 : 1]
            )
            return
        }
        let info: [String: Any] = [
            "projectId": JobKeys.inAppId(raw),
            "isSmallWorks": smallWorks,
            "section": "variations",
        ]
        NotificationCenter.default.post(name: .openWorkCatalogueDetail, object: nil, userInfo: info)
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
        // RULEBOOK 1.8.0: a job's related id is its stored document id (any case, UUID or not); `JobKeys` maps it to
        // the job's in-app id.
        guard let relatedId = destination.relatedId?.trimmingCharacters(in: .whitespacesAndNewlines), !relatedId.isEmpty else {
            NotificationCenter.default.post(
                name: NSNotification.Name("selectTab"),
                object: nil,
                userInfo: ["tab": smallWorks ? 2 : 1]
            )
            return
        }
        let projectId = JobKeys.inAppId(relatedId)
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
