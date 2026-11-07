//
//  Rulebook+MyProfile.swift
//  Project Planner
//
//  RULEBOOK 1.35.0 §12 "Personal figures" (owner decisions 7 Nov; web `lib/canonical/myProfileSummary.ts`). The My
//  Profile "Your figures" card: annual leave left, hours booked this week, open tasks, qualifications expiring soon
//  and every line manager. Every figure is `myProfileSummary` in the packed script through
//  `CanonicalBusinessEngine.callJSON`, memoised by its exact input; Swift only maps the stores into the script's
//  plain rows and reads the answer back. No figure is worked out here.
//

import Foundation

/// The answer of `myProfileSummary`, as the card shows it.
nonisolated struct RulebookMyProfileSummary: Hashable, Sendable {
    nonisolated struct Leave: Hashable, Sendable {
        var hasAllowance = false
        var remaining: Double? = nil
        var taken: Double = 0
        var pending: Double = 0
        var usedThisYear: Double = 0
        var startDayKey = ""
        var endDayKey = ""
    }

    nonisolated struct LineManager: Hashable, Sendable {
        let id: String
        let name: String
        let resolved: Bool
    }

    var dayKey = ""
    var leave = Leave()
    var weekStartDayKey = ""
    var weekEndDayKey = ""
    var hoursThisWeek: Double = 0
    var openTasks = 0
    var overdueTasks = 0
    var tasksDueThisWeek = 0
    var qualificationsExpired = 0
    var qualificationsExpiringSoon = 0
    var qualificationsTotal = 0
    /// `lineManagerSummary(...).label` — "No line manager" / "Not set" when `lineManagers` is empty.
    var lineManagerLabel = ""
    /// Every line manager by name (owner Q5: never "First +N more").
    var lineManagers: [LineManager] = []
}

extension CanonicalBusinessEngine {
    nonisolated private static let myProfileMemo = RulebookAnswerMemo<String, RulebookMyProfileSummary>(limit: 16)

    /// RULEBOOK 1.35.0 §12 `myProfileSummary(input)`. Nil when the script did not answer.
    nonisolated static func myProfileSummary(_ input: [String: Any]) -> RulebookMyProfileSummary? {
        guard let key = rulebookMemoKey(input) else { return nil }
        return myProfileMemo.value(for: key) {
            guard let row = callJSON("myProfileSummary", arguments: [input]) as? [String: Any] else { return nil }
            return parseMyProfileSummary(row)
        }
    }

    /// Reads the script's answer into `RulebookMyProfileSummary`. A data mapping, not a rule.
    nonisolated static func parseMyProfileSummary(_ row: [String: Any]) -> RulebookMyProfileSummary {
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        var out = RulebookMyProfileSummary()
        out.dayKey = row["dayKey"] as? String ?? ""
        if let leave = row["leave"] as? [String: Any] {
            out.leave = RulebookMyProfileSummary.Leave(
                hasAllowance: leave["hasAllowance"] as? Bool ?? false,
                remaining: leave["remaining"] is NSNull ? nil : number(leave["remaining"]),
                taken: number(leave["taken"]) ?? 0,
                pending: number(leave["pending"]) ?? 0,
                usedThisYear: number(leave["usedThisYear"]) ?? 0,
                startDayKey: leave["startDayKey"] as? String ?? "",
                endDayKey: leave["endDayKey"] as? String ?? ""
            )
        }
        if let hours = row["hoursThisWeek"] as? [String: Any] {
            out.weekStartDayKey = hours["startDayKey"] as? String ?? ""
            out.weekEndDayKey = hours["endDayKey"] as? String ?? ""
            out.hoursThisWeek = number(hours["hours"]) ?? 0
        }
        if let tasks = row["tasks"] as? [String: Any] {
            out.openTasks = int(tasks["open"])
            out.overdueTasks = int(tasks["overdue"])
            out.tasksDueThisWeek = int(tasks["dueThisWeek"])
        }
        if let qualifications = row["qualifications"] as? [String: Any] {
            out.qualificationsExpired = int(qualifications["expired"])
            out.qualificationsExpiringSoon = int(qualifications["expiringSoon"])
            out.qualificationsTotal = int(qualifications["total"])
        }
        if let manager = row["lineManager"] as? [String: Any] {
            out.lineManagerLabel = manager["label"] as? String ?? ""
            out.lineManagers = (manager["ids"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                return RulebookMyProfileSummary.LineManager(
                    id: id,
                    name: entry["name"] as? String ?? "",
                    resolved: entry["resolved"] as? Bool ?? false
                )
            }
        }
        return out
    }
}

/// Maps the app's stores into `myProfileSummary`'s input. Plain data mapping only.
enum MyProfileSummaryInput {
    /// The signed-in person's users document fields the figures read (leave, line managers, alias ids).
    static func userRow(_ user: AppUser) -> [String: Any] {
        var row: [String: Any] = [
            "id": user.id,
            "email": user.email,
            "formerUserIds": user.formerUserIds,
            "sameEmailUserIds": user.sameEmailUserIds,
            "annualLeaveEnabled": user.annualLeaveEnabled,
            "annualLeaveDaysPerYear": user.annualLeaveDaysPerYear,
            "annualLeaveYearStartMonth": user.annualLeaveYearStartMonth,
            "annualLeaveYearEndMonth": user.annualLeaveYearEndMonth,
            "annualLeaveCarriesOver": user.annualLeaveCarriesOver,
            "assignedManagerUserIds": user.assignedManagerUserIds,
            "hasNoLineManager": user.hasNoLineManager,
            "isActive": user.isActive,
        ]
        if let single = user.assignedManagerUserId { row["assignedManagerUserId"] = single }
        if let allowance = user.annualLeaveYearAllowance, allowance.isFinite { row["annualLeaveYearAllowance"] = allowance }
        if let key = user.annualLeaveYearAllowanceKey { row["annualLeaveYearAllowanceKey"] = key }
        if let start = user.employmentStartDate, !start.isEmpty { row["employmentStartDate"] = start }
        return row
    }

    static func leaveDefaultsRow(_ defaults: OrganizationAnnualLeaveDefaults?) -> Any {
        guard let defaults else { return NSNull() }
        var row: [String: Any] = [
            "daysPerYear": defaults.daysPerYear,
            "startMonth": defaults.startMonth,
            "endMonth": defaults.endMonth,
            "carriesOver": defaults.carriesOver,
        ]
        row["maxCarryOverDays"] = defaults.maxCarryOverDays.map { $0 as Any } ?? NSNull()
        return row
    }

    static func build(
        user: AppUser,
        roster: [AppUser],
        operatives: [Operative],
        managers: [Manager],
        holidays: [HolidayBooking],
        tasks: [ProjectTask],
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        now: Date = Date()
    ) -> [String: Any] {
        func optional(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
        return [
            "nowMs": (now.timeIntervalSince1970 * 1000).rounded(),
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
            "viewer": ["id": user.id, "email": user.email],
            "user": userRow(user),
            "roster": roster.map(RulebookRosterLists.levelRow),
            "operatives": operatives.map(\.rulebookQualificationRow),
            "managers": managers.map { ["id": $0.id.uuidString, "email": $0.email] as [String: Any] },
            "leaveDefaults": leaveDefaultsRow(OrganizationRulebookContext.annualLeaveDefaults),
            "holidays": holidays.map(\.rulebookLeaveRecord.json),
            "nonWorkingDayKeys": OrganizationBankHolidays.dayKeys,
            "tasks": tasks.map { task -> [String: Any] in
                [
                    "status": task.status.rawValue,
                    "dueDate": task.dueDate.map { ($0.timeIntervalSince1970 * 1000).rounded() as Any } ?? NSNull(),
                    "assignedOperativeIds": task.assignedOperativeIds.map { Booking.storedOperativeId(for: $0) },
                    "assignedOperativeId": task.assignedOperativeId.map { Booking.storedOperativeId(for: $0) as Any } ?? NSNull(),
                    "assignedManagerIds": task.assignedManagerIds.map(\.uuidString),
                    "assignedManagerId": task.assignedManagerId.map { $0.uuidString as Any } ?? NSNull(),
                ]
            },
            "bookings": bookings.map { booking -> [String: Any] in
                [
                    "operativeId": Booking.storedOperativeId(for: booking.operativeId),
                    "dayKey": OrganizationRulebookContext.dayKey(booking.date),
                    "status": booking.status.rawValue,
                    "timeSlot": booking.timeSlot.rawValue,
                    "workStartTime": optional(booking.workStartTime),
                    "workEndTime": optional(booking.workEndTime),
                    "isBreakRemoved": booking.isBreakRemoved,
                ]
            },
            "managerSiteBookings": managerBookings.map { booking -> [String: Any] in
                [
                    "userId": booking.userId,
                    "dayKey": OrganizationRulebookContext.dayKey(booking.date),
                    "timeSlot": booking.timeSlot.rawValue,
                    "workStartTime": optional(booking.workStartTime),
                    "workEndTime": optional(booking.workEndTime),
                    "isBreakRemoved": booking.isBreakRemoved,
                ]
            },
            "policyState": CanonicalBusinessEngine.openOrganizationPayrollPolicyState ?? [:],
        ]
    }
}
