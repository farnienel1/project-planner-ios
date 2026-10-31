//
//  OfflinePolicy.swift
//  Project Planner
//
//  docs/RULEBOOK.md §2 "Offline rules". The table (`OFFLINE_ACTIONS` / `offlineAvailability`), its three
//  messages and the "Last updated" label (`offlineLastUpdatedLabel`) come from the packed script. The Swift
//  enums below are only the stable ids. No Firebase, no SwiftUI here.
//

import Foundation

/// What a control may do while the device is offline (RULEBOOK §2).
nonisolated enum OfflineAvailability: String, Sendable, CaseIterable {
    /// Queued on the device and pushed when the connection returns; shows "Pending sync" until confirmed.
    case allowedOffline = "allowed_offline"
    /// Disabled offline with "Connect to the internet to change this".
    case onlineOnly = "online_only"
    /// Shows the last synced data, labelled "Last updated [date/time]"; never recalculated from unsynced changes.
    case readOnlyOffline = "read_only_offline"
}

/// Every action RULEBOOK §2 names. Raw values are stable ids for the Android port.
nonisolated enum OfflineAction: String, Sendable, CaseIterable {
    // Allowed offline
    case createBooking = "booking.create"
    case editBooking = "booking.edit"
    case cancelBooking = "booking.cancel"
    /// Online only since rulebook 1.2.0: the delete and its tombstone are not queued.
    case deleteBooking = "booking.delete"
    case annualLeaveRequest = "annual_leave.request"
    case ownProfileFields = "profile.own_fields"
    case ownNotificationToggles = "notifications.own_toggles"

    // Online only: organisation settings
    case companyDetails = "settings.company_details"
    case currency = "settings.currency"
    case workingHoursAndOvertime = "settings.working_hours_overtime"
    case warningSettings = "settings.warnings"
    case paymentRuns = "settings.payment_runs"
    case materialOrderCutOff = "settings.material_order_cut_off"
    case scheduleOptions = "settings.schedule_options"

    // Online only: Manage Users
    case userRole = "users.role"
    case userLineManager = "users.line_manager"
    case userEmploymentStatus = "users.employment_status"
    case userPayRate = "users.pay_rate"
    case userExclusions = "users.exclusions"
    case userInactiveFlag = "users.inactive"
    case userInvites = "users.invites"

    // Online only: approvals
    case annualLeaveApproval = "approvals.annual_leave"
    case timesheetSigning = "approvals.timesheet_signing"
    case clashApproval = "approvals.clash"

    // Online only: account actions
    case signIn = "account.sign_in"
    case passwordChange = "account.password"
    case switchOrganization = "account.switch_organization"

    // Read-only offline
    case dailyOverview = "view.daily_overview"
    case warnings = "view.warnings"
    case weeklyReport = "view.weekly_report"
    case mySchedule = "view.my_schedule"
}

nonisolated enum OfflinePolicy {
    /// `OFFLINE_PENDING_SYNC_LABEL`.
    static let pendingSyncMessage: String =
        CanonicalBusinessEngine.constant("OFFLINE_PENDING_SYNC_LABEL", as: String.self) ?? ""
    /// `OFFLINE_ONLINE_ONLY_MESSAGE`.
    static let onlineOnlyMessage: String =
        CanonicalBusinessEngine.constant("OFFLINE_ONLINE_ONLY_MESSAGE", as: String.self) ?? ""
    /// `OFFLINE_LAST_UPDATED_PREFIX`.
    static let lastUpdatedPrefix: String =
        CanonicalBusinessEngine.constant("OFFLINE_LAST_UPDATED_PREFIX", as: String.self) ?? ""

    /// `OFFLINE_ACTIONS`: action id → `allowedOffline` / `onlineOnly` / `readOnlyOffline`. Read once.
    private static let table: [String: String] =
        CanonicalBusinessEngine.constant("OFFLINE_ACTIONS", as: [String: String].self) ?? [:]

    /// `offlineAvailability(actionId)`. An id the table does not list is online only, as the script says.
    static func availability(_ action: OfflineAction) -> OfflineAvailability {
        let value = table[action.rawValue]
            ?? (CanonicalBusinessEngine.callJSON("offlineAvailability", arguments: [action.rawValue]) as? String)
        return OfflineAvailability(canonical: value) ?? .onlineOnly
    }

    /// True when the control for `action` is usable now.
    static func isEnabled(_ action: OfflineAction, isOnline: Bool) -> Bool {
        isOnline || availability(action) != .onlineOnly
    }

    /// True when an offline change to `action` goes to the outbox instead of the server.
    static func queuesWhileOffline(_ action: OfflineAction, isOnline: Bool) -> Bool {
        !isOnline && availability(action) == .allowedOffline
    }

    /// The message shown next to the control while offline, or nil when none is needed.
    static func offlineMessage(_ action: OfflineAction, isOnline: Bool, lastSyncedAt: Date?) -> String? {
        guard !isOnline else { return nil }
        switch availability(action) {
        case .allowedOffline: return nil
        case .onlineOnly: return onlineOnlyMessage
        case .readOnlyOffline: return lastUpdatedMessage(lastSyncedAt)
        }
    }

    /// `offlineLastUpdatedLabel(iso, timeZone)`: "Last updated 31 Oct 2026, 14:05" in the organisation's
    /// business time zone. Nil before any sync.
    static func lastUpdatedMessage(_ date: Date?) -> String? {
        guard let date else { return nil }
        return CanonicalBusinessEngine.callJSON(
            "offlineLastUpdatedLabel",
            arguments: [CanonicalBusinessEngine.isoString(from: date), OrganizationRulebookContext.timeZoneIdentifier]
        ) as? String
    }
}

extension OfflineAvailability {
    /// The script's camelCase availability (`OFFLINE_AVAILABILITIES`).
    nonisolated init?(canonical value: String?) {
        guard let value else { return nil }
        switch value {
        case "allowedOffline": self = .allowedOffline
        case "onlineOnly": self = .onlineOnly
        case "readOnlyOffline": self = .readOnlyOffline
        default: return nil
        }
    }
}
