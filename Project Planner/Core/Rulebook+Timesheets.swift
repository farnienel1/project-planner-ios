//
//  Rulebook+Timesheets.swift
//  Project Planner
//
//  Typed wrappers for the timesheet, hours and Daily Overview rules (docs/RULEBOOK.md §6, §7, §8).
//  Every answer comes from the packed script (web lib/canonical/payrollHours.ts, timesheetLines.ts,
//  timesheetEntryReviews.ts). Nothing here decides a rule in Swift.
//

import Foundation
import FirebaseFirestore

/// `workedHoursSplit(payrollHoursResult(input))`: hours worked inside and outside the standard
/// window, never multiplied (Daily Overview's Standard and Overtime figures), plus the result's
/// `outsideHours` and `outsideMultiplier` that web reads beside it.
nonisolated struct CanonicalWorkedHoursSplit: Equatable, Sendable {
    let standardWorkedHours: Double
    let outsideWorkedHours: Double
    /// `payrollHoursResult.workedHours`.
    let workedHours: Double
    /// `payrollHoursResult.outsideHours`.
    let outsideHours: Double
    /// `payrollHoursResult.outsideMultiplier`.
    let outsideMultiplier: Double
}

/// One booking for `overlappingBookingIds`.
nonisolated struct CanonicalOverlapBookingInput: Sendable {
    var id: String
    var dayKey: String
    var timeSlot: String
    var workStartTime: String?
    var workEndTime: String?
}

/// One `timesheetLeaveLines` row: an information line (no hours, no pay, no edit, never invoiced).
nonisolated struct CanonicalTimesheetLeaveLine: Identifiable, Hashable, Sendable {
    let id: String
    let leaveId: String
    let dayKey: String
    let timeSlot: String
    let label: String
    /// RULEBOOK 1.20.0 §9 `timeRange`: the leave half's clock range from `leaveHalfDayWindows` under the working day in
    /// effect that day ("06:30–10:30"; the whole day for full-day leave). Nil when no working day was passed.
    var timeRange: String? = nil

    /// The line with `timeRange` from `leaveHalfDayWindows(policy)` (RULEBOOK 1.20.0 §9).
    func withLeaveTimeRange(policy: OrgPayrollTimePolicy) -> CanonicalTimesheetLeaveLine {
        var line = self
        line.timeRange = CanonicalBusinessEngine.leaveSlotClockRange(timeSlot: timeSlot, policy: policy)
        return line
    }

    /// "Annual leave (AM) · 06:30–10:30" (web timesheet leave line).
    var displayLabel: String {
        guard let timeRange, !timeRange.isEmpty else { return label }
        return "\(label) · \(timeRange)"
    }
}

/// One leave record for `timesheetLeaveLines`.
nonisolated struct CanonicalTimesheetLeaveRecord: Sendable {
    var id: String
    var startDayKey: String
    var endDayKey: String?
    var timeSlot: String?
    var status: String?
}

nonisolated private final class WorkedHoursSplitMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [CanonicalPayrollHoursInput: CanonicalWorkedHoursSplit] = [:]
    private let limit = 512

    func value(
        for key: CanonicalPayrollHoursInput,
        compute: () -> CanonicalWorkedHoursSplit?
    ) -> CanonicalWorkedHoursSplit? {
        lock.lock()
        if let hit = store[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let value = compute() else { return nil }
        lock.lock()
        if store.count >= limit { store.removeAll(keepingCapacity: true) }
        store[key] = value
        lock.unlock()
        return value
    }
}

extension CanonicalBusinessEngine {
    nonisolated private static let workedHoursSplitMemo = WorkedHoursSplitMemo()

    // MARK: - Hours (§7, §8)

    /// `workedHoursSplit(payrollHoursResult(input))`. Web's Daily Overview
    /// (lib/daily-overview/buildDailyOverview.ts) and My Schedule total card read exactly this.
    /// Nil when the script did not answer.
    nonisolated static func workedHoursSplit(_ input: CanonicalPayrollHoursInput) -> CanonicalWorkedHoursSplit? {
        workedHoursSplitMemo.value(for: input) {
            guard let data = try? JSONEncoder().encode(input),
                  let inputObject = try? JSONSerialization.jsonObject(with: data),
                  let result = callJSON("payrollHoursResult", arguments: [inputObject]) as? [String: Any],
                  let split = callJSON("workedHoursSplit", arguments: [result]) as? [String: Any] else {
                return nil
            }
            func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
            return CanonicalWorkedHoursSplit(
                standardWorkedHours: number(split["standardWorkedHours"]),
                outsideWorkedHours: number(split["outsideWorkedHours"]),
                workedHours: number(result["workedHours"]),
                outsideHours: number(result["outsideHours"]),
                outsideMultiplier: number(result["outsideMultiplier"])
            )
        }
    }

    // MARK: - Invoice lines (§8)

    /// `invoiceLines(lines)` over `(isPayeDay, isLeave)` flags: the indexes that go on a generated invoice, in
    /// input order. PAYE and annual-leave lines never do. Nil when the script did not answer.
    nonisolated static func invoiceLineIndexes(_ lines: [(isPayeDay: Bool, isLeave: Bool)]) -> [Int]? {
        var rows: [[String: Any]] = []
        for (index, line) in lines.enumerated() {
            rows.append(["lineIndex": index, "isPayeDay": line.isPayeDay, "isLeave": line.isLeave])
        }
        guard let kept = callJSON("invoiceLines", arguments: [rows]) as? [[String: Any]] else { return nil }
        return kept.compactMap { ($0["lineIndex"] as? NSNumber)?.intValue }
    }

    // MARK: - Timesheet lines (§6)

    /// `OVERLAPPING_BOOKING_NOTE`.
    nonisolated static var overlappingBookingNote: String {
        constant("OVERLAPPING_BOOKING_NOTE", as: String.self)
            ?? "Overlaps another booking — check with your manager"
    }

    /// `overlappingBookingIds(bookings, day)`: ids of bookings that overlap another booking on the
    /// same day key (touching times do not overlap). Every booking is still paid. Empty when the
    /// script did not answer.
    nonisolated static func overlappingBookingIds(
        _ bookings: [CanonicalOverlapBookingInput],
        day: CanonicalStandardDayInput
    ) -> Set<String> {
        let rows: [[String: Any]] = bookings.map { booking in
            var row: [String: Any] = [
                "id": booking.id,
                "dayKey": booking.dayKey,
                "timeSlot": booking.timeSlot
            ]
            if let start = booking.workStartTime, !start.isEmpty { row["workStartTime"] = start }
            if let end = booking.workEndTime, !end.isEmpty { row["workEndTime"] = end }
            return row
        }
        var dayObject: [String: Any] = [:]
        if let value = day.standardDayStart { dayObject["standardDayStart"] = value }
        if let value = day.standardDayEnd { dayObject["standardDayEnd"] = value }
        if let value = day.breakWindowStart { dayObject["breakWindowStart"] = value }
        if let value = day.breakWindowEnd { dayObject["breakWindowEnd"] = value }
        let ids = callJSON("overlappingBookingIds", arguments: [rows, dayObject]) as? [String] ?? []
        return Set(ids)
    }

    /// `timesheetLeaveLabel(timeSlot)`: "Annual leave (full day)", "(AM)" or "(PM)".
    nonisolated static func timesheetLeaveLabel(_ timeSlot: String?) -> String {
        callJSON("timesheetLeaveLabel", arguments: [timeSlot.map { $0 as Any } ?? NSNull()]) as? String ?? "Annual leave (full day)"
    }

    /// `timesheetLeaveLines(records, period, timeZone, nonWorkingDayKeys)`: one information row per
    /// approved leave day inside the period. Empty when the script did not answer. 1.20.0: the script's `dayPolicy`
    /// argument is a function, which cannot cross the bridge; callers set `timeRange` from `leaveHalfDayWindows` of the
    /// day's policy (`withLeaveTimeRanges`).
    nonisolated static func timesheetLeaveLines(
        _ records: [CanonicalTimesheetLeaveRecord],
        startDayKey: String,
        endDayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        nonWorkingDayKeys: [String] = []
    ) -> [CanonicalTimesheetLeaveLine] {
        let rows: [[String: Any]] = records.map { record in
            var row: [String: Any] = ["id": record.id, "startDayKey": record.startDayKey]
            if let end = record.endDayKey { row["endDayKey"] = end }
            if let slot = record.timeSlot { row["timeSlot"] = slot }
            if let status = record.status { row["status"] = status }
            return row
        }
        let period: [String: Any] = ["startDayKey": startDayKey, "endDayKey": endDayKey]
        guard let raw = callJSON(
            "timesheetLeaveLines",
            arguments: [rows, period, timeZone, nonWorkingDayKeys]
        ) as? [[String: Any]] else { return [] }
        return raw.compactMap { row in
            guard let id = row["id"] as? String, let dayKey = row["dayKey"] as? String else { return nil }
            let slot = row["timeSlot"] as? String ?? "FULL DAY"
            return CanonicalTimesheetLeaveLine(
                id: id,
                leaveId: row["leaveId"] as? String ?? "",
                dayKey: dayKey,
                timeSlot: slot,
                label: row["label"] as? String ?? timesheetLeaveLabel(row["timeSlot"] as? String)
            )
        }
    }

    // MARK: - Who writes what on a timesheet (§6)

    /// `timesheetWriterIsReviewer(input)`: admins always; otherwise someone other than the subject
    /// whose id (or a former invite id) is one of the subject's line managers. Nil when the script
    /// did not answer.
    nonisolated static func timesheetWriterIsReviewer(
        writerUserId: String?,
        subjectUserId: String?,
        writerIsAdmin: Bool,
        writerFormerIds: [String],
        subjectLineManagerIds: [String]
    ) -> Bool? {
        let input: [String: Any] = [
            "writerUserId": writerUserId ?? "",
            "subjectUserId": subjectUserId ?? "",
            "writerIsAdmin": writerIsAdmin,
            "writerFormerIds": writerFormerIds,
            "subjectLineManagerIds": subjectLineManagerIds
        ]
        return callJSON("timesheetWriterIsReviewer", arguments: [input]) as? Bool
    }

    /// The keys `timesheetOwnerWriteFields(fields, { subjectHasLineManager, managerSigned })` keeps.
    /// The function only removes keys, so it is asked with placeholder values and the caller keeps
    /// its own (non-JSON) Firestore values for the returned keys. Nil when the script did not answer.
    nonisolated static func timesheetOwnerWritableKeys(
        _ keys: [String],
        subjectHasLineManager: Bool,
        managerSigned: Bool
    ) -> Set<String>? {
        var probe: [String: Any] = [:]
        for key in keys { probe[key] = true }
        let options: [String: Any] = ["subjectHasLineManager": subjectHasLineManager, "managerSigned": managerSigned]
        guard let kept = callJSON("timesheetOwnerWriteFields", arguments: [probe, options]) as? [String: Any] else {
            return nil
        }
        return Set(kept.keys)
    }

    // MARK: - Entry decisions (§6)

    /// `timesheetEntryDecision(sheet, entry)`: the decision in effect for one price work or expense
    /// entry. `sheet` and `entry` are stored Firestore maps (Timestamps are passed as epoch ms).
    /// Nil when the script did not answer.
    nonisolated static func timesheetEntryDecision(
        sheet: [String: Any],
        entry: [String: Any]
    ) -> (decision: String, revisedAmount: Double?, source: String)? {
        guard let sheetJSON = timesheetJSONSafe(sheet),
              let entryJSON = timesheetJSONSafe(entry),
              let result = callJSON("timesheetEntryDecision", arguments: [sheetJSON, entryJSON]) as? [String: Any],
              let decision = result["decision"] as? String else { return nil }
        return (decision, (result["revisedAmount"] as? NSNumber)?.doubleValue, result["source"] as? String ?? "")
    }

    /// `timesheetEntryEffectiveAmount(decision, revisedAmount, amount)`. Nil when the script did not answer.
    nonisolated static func timesheetEntryEffectiveAmount(
        decision: String,
        revisedAmount: Double?,
        amount: Double
    ) -> Double? {
        let revised: Any = revisedAmount.map { $0 as Any } ?? NSNull()
        return (callJSON("timesheetEntryEffectiveAmount", arguments: [decision, revised, amount]) as? NSNumber)?.doubleValue
    }

    /// `timesheetEntryReviewWriteFields({ stored: parseTimesheetEntryReviews(sheet), entries, reviewedByUserId, reviewedAtMs })`:
    /// dotted `extraEntryReviews.{entryId}` update fields for every entry whose decision changed.
    /// For `updateData` only. Empty when nothing changed; nil when the script did not answer.
    nonisolated static func timesheetEntryReviewWriteFields(
        storedSheet: [String: Any]?,
        entries: [(id: String, amount: Double, managerDecision: String, managerRevisedAmount: Double?)],
        reviewedByUserId: String,
        reviewedAtMs: Double
    ) -> [String: Any]? {
        var stored: Any = NSNull()
        if let storedSheet, let sheetJSON = timesheetJSONSafe(storedSheet) {
            guard let parsed = callJSON("parseTimesheetEntryReviews", arguments: [sheetJSON]) else { return nil }
            stored = parsed
        }
        let entryRows: [[String: Any]] = entries.map { entry in
            [
                "id": entry.id,
                "amount": entry.amount,
                "managerDecision": entry.managerDecision,
                "managerRevisedAmount": entry.managerRevisedAmount.map { $0 as Any } ?? NSNull()
            ]
        }
        let input: [String: Any] = [
            "stored": stored,
            "entries": entryRows,
            "reviewedByUserId": reviewedByUserId,
            "reviewedAtMs": reviewedAtMs
        ]
        return callJSON("timesheetEntryReviewWriteFields", arguments: [input]) as? [String: Any]
    }

    /// A stored timesheet map as plain JSON for the script: Timestamps and Dates become epoch ms,
    /// other non-JSON values are dropped. A conversion, not a rule.
    nonisolated static func timesheetJSONSafe(_ map: [String: Any]) -> [String: Any]? {
        func convert(_ value: Any) -> Any? {
            switch value {
            case let timestamp as Timestamp:
                return timestamp.dateValue().timeIntervalSince1970 * 1000
            case let date as Date:
                return date.timeIntervalSince1970 * 1000
            case let text as String:
                return text
            case let number as NSNumber:
                return number
            case is NSNull:
                return NSNull()
            case let dict as [String: Any]:
                var out: [String: Any] = [:]
                for (key, inner) in dict {
                    if let converted = convert(inner) { out[key] = converted }
                }
                return out
            case let list as [Any]:
                return list.compactMap { convert($0) }
            default:
                return nil
            }
        }
        let converted = convert(map) as? [String: Any]
        guard let converted, JSONSerialization.isValidJSONObject(converted) else { return nil }
        return converted
    }
}

extension CanonicalBusinessEngine {
    // MARK: 1.9.0 timesheet diff

    /// `timesheetChangedFields(base, next)`: the partial update a timesheet save sends — the fields that differ
    /// between the sheet as this editor loaded it (`base`, stored field shape) and the sheet it would save (`next`).
    /// Write metadata and `createdAt` are ignored; `userId` is create-only. The caller writes its own native values
    /// for the set keys (`CanonicalDocumentWrite.firestoreFields`). Nil when the script did not answer.
    nonisolated static func timesheetChangedFields(base: [String: Any]?, next: [String: Any]) -> CanonicalDocumentWrite? {
        let baseJSON: Any = base.map { peopleDocumentJSON($0) as Any } ?? NSNull()
        return CanonicalDocumentWrite(callJSON("timesheetChangedFields", arguments: [baseJSON, peopleDocumentJSON(next)]))
    }
}

// MARK: - Rulebook 1.11.0 §8: PAYE days never make a timesheet

extension CanonicalBusinessEngine {
    /// `TimesheetPerson` for `timesheetDaysForPerson` / `showsMyTimesheets`.
    @MainActor static func timesheetPerson(_ user: AppUser) -> [String: Any] {
        [
            "isActive": user.isActive,
            "email": user.email,
            "name": user.fullName,
            "employmentType": user.employmentType.rawValue,
            "employmentTypeTransitionFrom": user.employmentTypeTransitionFrom?.rawValue ?? NSNull(),
            "employmentTypeEffectiveAt": user.employmentTypeEffectiveAt.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull(),
            "operativeMode": user.permissions.operativeMode,
        ]
    }

    /// `timesheetDaysForPerson(user, { startDayKey, endDayKey }, timeZone)`: the organisation-zone days of the period on
    /// which the person is self-employed — the only days that count on their timesheet. Nil when the script did not answer.
    nonisolated static func timesheetDaysForPerson(person: [String: Any], startDayKey: String, endDayKey: String, timeZone: String) -> [String]? {
        callJSON(
            "timesheetDaysForPerson",
            arguments: [person, ["startDayKey": startDayKey, "endDayKey": endDayKey], timeZone]
        ) as? [String]
    }

    /// `showsMyTimesheets(user, period, timeZone)`: a My Timesheets sheet exists for the period only when the person is
    /// self-employed on at least one day of it. A PAYE person never sees My Timesheets. Nil when the script did not answer.
    nonisolated static func showsMyTimesheets(person: [String: Any], startDayKey: String, endDayKey: String, timeZone: String) -> Bool? {
        callJSON(
            "showsMyTimesheets",
            arguments: [person, ["startDayKey": startDayKey, "endDayKey": endDayKey], timeZone]
        ) as? Bool
    }
}
