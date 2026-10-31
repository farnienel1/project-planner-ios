//
//  OfflinePolicy.swift
//  Project Planner
//
//  docs/RULEBOOK.md §2 "Offline rules" as one table, kept apart from screens so Android can port it
//  line for line. Every action the rulebook names has exactly one row. No Firebase, no SwiftUI here.
//
//  RULEBOOK-GAP(offlinePolicyTable): the table and its three messages are rulebook text, not yet a
//  packed-script export. Replace this table with the canonical export when web ships it.
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
    /// Removing a booking queues the delete and its tombstone (§2 Conflicts).
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
    static let pendingSyncMessage = "Pending sync"
    static let onlineOnlyMessage = "Connect to the internet to change this"
    static let lastUpdatedPrefix = "Last updated"

    /// The table. One row per action.
    static func availability(_ action: OfflineAction) -> OfflineAvailability {
        switch action {
        case .createBooking, .editBooking, .cancelBooking, .deleteBooking,
             .annualLeaveRequest, .ownProfileFields, .ownNotificationToggles:
            return .allowedOffline
        case .companyDetails, .currency, .workingHoursAndOvertime, .warningSettings,
             .paymentRuns, .materialOrderCutOff, .scheduleOptions,
             .userRole, .userLineManager, .userEmploymentStatus, .userPayRate,
             .userExclusions, .userInactiveFlag, .userInvites,
             .annualLeaveApproval, .timesheetSigning, .clashApproval,
             .signIn, .passwordChange, .switchOrganization:
            return .onlineOnly
        case .dailyOverview, .warnings, .weeklyReport, .mySchedule:
            return .readOnlyOffline
        }
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

    /// "Last updated [date/time]", in the organisation's business time zone. Nil before any sync.
    static func lastUpdatedMessage(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = OrganizationRulebookContext.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(lastUpdatedPrefix) \(formatter.string(from: date))"
    }
}
