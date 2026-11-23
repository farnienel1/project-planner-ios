//
//  Rulebook+SignOffReminder.swift
//  Project Planner
//
//  RULEBOOK 1.78.0 §4.5, §8, §13 (owner decision 23 Nov, point 4; web `lib/canonical/timesheetSignOffReminder.ts`,
//  `organizationSettings.ts`): the line manager sign-off reminder before payday. The server writes the notice
//  (Cloud Function `timesheetSignOffReminders`); iOS shows the organisation setting (Settings → Payment runs &
//  timesheets, item 5) and routes the notice. Typed wrappers only: the choices, the default, the reading of a stored
//  value and the write fields are the packed script's (`CanonicalBusinessEngine.callJSON`); Swift keeps no copy.
//

import Foundation

extension CanonicalBusinessEngine {
    /// `LINE_MANAGER_REMINDER_DAYS_OPTIONS` — 1, 2, 3.
    nonisolated static var lineManagerReminderDaysOptions: [Int] {
        constant("LINE_MANAGER_REMINDER_DAYS_OPTIONS", as: [Int].self) ?? []
    }

    /// `LINE_MANAGER_REMINDER_LABEL` — "Line manager sign-off reminder".
    nonisolated static var lineManagerReminderLabel: String {
        constant("LINE_MANAGER_REMINDER_LABEL", as: String.self) ?? "Line manager sign-off reminder"
    }

    /// `LINE_MANAGER_REMINDER_DAYS_LABEL` — "Days before payday".
    nonisolated static var lineManagerReminderDaysLabel: String {
        constant("LINE_MANAGER_REMINDER_DAYS_LABEL", as: String.self) ?? "Days before payday"
    }

    /// `LINE_MANAGER_REMINDER_HELP` — the setting's description.
    nonisolated static var lineManagerReminderHelp: String {
        constant("LINE_MANAGER_REMINDER_HELP", as: String.self) ?? ""
    }

    /// `LINE_MANAGER_REMINDER_ADMIN_NOTE` — the note under item 5 (admins: no line manager, and 24 hours before payday).
    nonisolated static var lineManagerReminderAdminNote: String {
        constant("LINE_MANAGER_REMINDER_ADMIN_NOTE", as: String.self)
            ?? "Admins are also reminded about people with no line manager, and about any timesheet still not signed off 24 hours before payday."
    }

    /// `TIMESHEET_SIGNOFF_REMINDER_NOTICE_TITLE` — "Timesheets waiting for your sign-off" (the local fallback's title).
    nonisolated static var timesheetSignOffReminderNoticeTitle: String {
        constant("TIMESHEET_SIGNOFF_REMINDER_NOTICE_TITLE", as: String.self) ?? "Timesheets waiting for your sign-off"
    }

    /// `parseLineManagerReminderDays(stored)` — 1, 2 or 3 (missing or anything else reads as the default). Nil only when
    /// the script did not run.
    nonisolated static func parseLineManagerReminderDays(_ stored: Any?) -> Int? {
        callJSON("parseLineManagerReminderDays", arguments: [stored ?? NSNull()]) as? Int
    }

    /// `lineManagerReminderSummary(days)` — "Sent at 08:00, 2 days before payday."
    nonisolated static func lineManagerReminderSummary(_ days: Int) -> String? {
        callJSON("lineManagerReminderSummary", arguments: [days]) as? String
    }

    /// `lineManagerReminderWriteFields(storedInvoicing, days)` — `{ "invoicing.lineManagerReminderDaysBeforePayday": n }`,
    /// empty when the stored value already reads the same or `days` is not 1–3.
    nonisolated static func lineManagerReminderWriteFields(storedInvoicing: [String: Any]?, days: Int) -> [String: Any]? {
        callJSON("lineManagerReminderWriteFields", arguments: [storedInvoicing ?? [:], days]) as? [String: Any]
    }
}
