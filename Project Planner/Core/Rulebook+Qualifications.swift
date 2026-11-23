//
//  Rulebook+Qualifications.swift
//  Project Planner
//
//  RULEBOOK 1.73.0 §5 (owner 23 Nov, gap 1; web `lib/canonical/operativeQualifications.ts`): one qualification
//  expiry rule for both apps. Swift only maps its models into the script's plain inputs and reads the answer back:
//
//  - `qualificationExpiryDate(dates, qualificationId)` — `qualificationExpiryDates[id]`, the exact key first, else the
//    id in another letter case. The assignment row's own `endDate` is never an expiry.
//  - `withQualificationExpiry(dates, qualificationId, date)` — the map after the editor sets or clears one date (every
//    other spelling of the id removed).
//  - `assignedQualificationExpiries(row)` — one row's input to `qualificationExpiryRows` / `qualificationExpiryCount` /
//    `myProfileSummary`.
//  - `operativeRowsForPerson({ person, operatives, roster })` — every `operatives` row of the person (the person fold,
//    placeholder rows left out by `isPlaceholderOperativeRow`); never one row picked by email.
//  - `personQualifications({ rows, preferredRowId })` — the profile's list.
//
//  Dates go in as epoch MILLISECONDS (`timeIntervalSince1970 × 1000`), never seconds: a number in seconds reads as
//  January 1970 and zero or below is no expiry. Dates come back as ISO text (a returned Date is JSON text through the
//  bridge); `expiryIso` is read.
//

import Foundation

extension CanonicalBusinessEngine {
    /// A Date as the epoch milliseconds the qualification rules read.
    nonisolated static func epochMilliseconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded()
    }

    /// An expiry map with its dates as epoch milliseconds (the script's input).
    nonisolated static func qualificationExpiryInput(_ dates: [String: Date]) -> [String: Any] {
        dates.mapValues { epochMilliseconds($0) as Any }
    }

    nonisolated private static let expiryDateMemo = RulebookAnswerMemo<String, RulebookOptionalDate>(limit: 512)

    /// `qualificationExpiryDate(dates, qualificationId)`: the expiry of one qualification. Nil = the script did not
    /// answer (the caller must not read it as "no expiry"); `.date == nil` = no expiry.
    nonisolated static func qualificationExpiryLookup(dates: [String: Date], qualificationId: String) -> RulebookOptionalDate? {
        guard !dates.isEmpty else { return RulebookOptionalDate(date: nil) }
        let arguments: [Any] = [qualificationExpiryInput(dates), qualificationId]
        guard let key = rulebookMemoKey(arguments) else { return nil }
        return expiryDateMemo.value(for: key) {
            guard let answer = callJSON("qualificationExpiryDate", arguments: arguments) else { return nil }
            return RulebookOptionalDate(date: (answer as? String).flatMap { date(fromIso: $0) })
        }
    }

    /// `withQualificationExpiry(dates, qualificationId, date)`: the map after setting (or, with nil, clearing) one
    /// qualification's expiry — every other spelling of that id removed. Nil when the script did not answer.
    nonisolated static func withQualificationExpiry(
        dates: [String: Date],
        qualificationId: String,
        date: Date?
    ) -> [String: Date]? {
        let arguments: [Any] = [
            qualificationExpiryInput(dates),
            qualificationId,
            date.map { epochMilliseconds($0) as Any } ?? NSNull(),
        ]
        guard let answer = callJSON("withQualificationExpiry", arguments: arguments) as? [String: Any] else { return nil }
        return answer.reduce(into: [String: Date]()) { out, entry in
            if let ms = (entry.value as? NSNumber)?.doubleValue {
                out[entry.key] = Date(timeIntervalSince1970: ms / 1000)
            }
        }
    }
}

/// A memoised optional date (the memo stores only non-nil answers).
nonisolated struct RulebookOptionalDate: Sendable {
    let date: Date?
}

/// One qualification of `personQualifications`.
nonisolated struct RulebookPersonQualification: Equatable, Sendable {
    let id: String
    let name: String
    let expiry: Date?
    let certificateUrl: String?
    let operativeId: String
}

extension Operative {
    /// This row as a `QualificationOperativeRow` (stored document id, assignments, expiry map in epoch ms, certificates).
    var rulebookQualificationOperativeRow: [String: Any] {
        [
            "id": documentId,
            "isActive": isActive,
            "qualifications": qualifications
                .sorted { $0.id < $1.id }
                .map { ["id": $0.id, "name": $0.name] as [String: Any] },
            "qualificationExpiryDates": CanonicalBusinessEngine.qualificationExpiryInput(qualificationExpiryDates),
            "qualificationCertificateURLs": qualificationCertificateURLs,
        ]
    }

    /// `assignedQualificationExpiries(row)`: this row's assigned qualifications that have an expiry, one per id
    /// without case — `{ qualificationId, name, expiryIso }`. Empty when the script did not answer.
    var rulebookAssignedQualificationExpiries: [[String: Any]] {
        guard !qualifications.isEmpty, !qualificationExpiryDates.isEmpty else { return [] }
        let row: [String: Any] = [
            "qualifications": qualifications
                .sorted { $0.id < $1.id }
                .map { ["id": $0.id, "name": $0.name] as [String: Any] },
            "qualificationExpiryDates": CanonicalBusinessEngine.qualificationExpiryInput(qualificationExpiryDates),
        ]
        guard let key = CanonicalBusinessEngine.rulebookMemoKey(row) else { return [] }
        let answer = CanonicalBusinessEngine.assignedExpiriesMemo.value(for: key) {
            (CanonicalBusinessEngine.callJSON("assignedQualificationExpiries", arguments: [row]) as? [[String: Any]])
                .map { RulebookJSONBox(object: ["rows": $0]) }
        }
        return (answer?.object["rows"] as? [[String: Any]]) ?? []
    }
}

extension CanonicalBusinessEngine {
    /// `assignedQualificationExpiries` answers by exact input (Home, the menu and the Warnings snapshot build a row
    /// per operative on every redraw).
    nonisolated static let assignedExpiriesMemo = RulebookAnswerMemo<String, RulebookJSONBox>(limit: 2048)
}

extension CanonicalBusinessEngine {
    /// `operativeRowsForPerson({ person, operatives, roster })`: the person's `operatives` rows (placeholder rows left
    /// out). Nil when the script did not answer — the caller shows nothing rather than a guess.
    @MainActor
    static func operativeRowsForPerson(person: AppUser, operatives: [Operative], roster: [AppUser]) -> [Operative]? {
        var users = roster
        if !users.contains(where: { $0.id.caseInsensitiveCompare(person.id) == .orderedSame }) { users.append(person) }
        let rosterRows: [[String: Any]] = users.map { user in
            [
                "id": user.id,
                "email": user.email,
                "formerUserIds": user.formerUserIds,
                "sameEmailUserIds": user.sameEmailUserIds,
                "ghost": user.isGhost,
            ]
        }
        let rows: [[String: Any]] = operatives.map { row in
            var out: [String: Any] = [
                "id": row.documentId,
                "email": row.email,
                "firstName": row.firstName,
                "lastName": row.lastName,
            ]
            if let linked = row.linkedUserId, !linked.isEmpty { out["linkedUserId"] = linked }
            return out
        }
        let input: [String: Any] = [
            "person": ["id": person.id, "email": person.email],
            "operatives": rows,
            "roster": rosterRows,
        ]
        guard let answer = callJSON("operativeRowsForPerson", arguments: [input]) as? [[String: Any]] else { return nil }
        let ids = Set(answer.compactMap { $0["id"] as? String })
        return operatives.filter { ids.contains($0.documentId) }
    }

    /// `personQualifications({ rows, preferredRowId })`: one entry per qualification id without case, from every row
    /// of the person (active rows first, then the row the editor saves to, then the fullest). Nil when the script
    /// did not answer.
    @MainActor
    static func personQualifications(rows: [Operative], preferredRowId: String?) -> [RulebookPersonQualification]? {
        let input: [String: Any] = [
            "rows": rows.map(\.rulebookQualificationOperativeRow),
            "preferredRowId": preferredRowId ?? NSNull(),
        ]
        guard let answer = callJSON("personQualifications", arguments: [input]) as? [[String: Any]] else { return nil }
        return answer.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return RulebookPersonQualification(
                id: id,
                name: item["name"] as? String ?? "",
                expiry: (item["expiryIso"] as? String).flatMap { date(fromIso: $0) },
                certificateUrl: item["certificateUrl"] as? String,
                operativeId: item["operativeId"] as? String ?? ""
            )
        }
    }
}

// MARK: - Half-day unbooked (RULEBOOK 1.73.0 §5, owner 23 Nov batch 3 item 3)

extension CanonicalBusinessEngine {
    /// `LEAVE_COVER_WARNING_TITLE` ("Half-day unbooked"): the half-day leave cover card's title on Warnings and Daily
    /// Overview. When the script did not answer, a neutral "Annual leave" (the pattern of the other constants here:
    /// a non-empty fallback; not a second copy of the rulebook's words).
    nonisolated static var leaveCoverWarningTitle: String {
        constant("LEAVE_COVER_WARNING_TITLE", as: String.self) ?? "Annual leave"
    }

    /// `LEAVE_CLASH_WARNING_TITLE` ("Booked during annual leave").
    nonisolated static var leaveClashWarningTitle: String {
        constant("LEAVE_CLASH_WARNING_TITLE", as: String.self) ?? "Annual leave"
    }
}

// MARK: - Daily Overview standard-hours label (RULEBOOK 1.73.0 §6, owner 23 Nov item 31)

nonisolated struct RulebookStandardHoursLabel: Equatable, Sendable {
    let label: String
    let hint: String?
}

extension CanonicalBusinessEngine {
    nonisolated private static let standardHoursLabelMemo = RulebookAnswerMemo<String, RulebookStandardHoursLabelBox>(limit: 64)

    /// `dailyOverviewStandardHoursLabel({ policyOrState, dayKey, timeZone, loaded })`: "Weekend window hrs" with the
    /// hint "07:30–14:00 counts as a full day" on a set-window weekend day under the working hours in effect that day,
    /// else "Standard hrs". Pass the policy STATE (history included); nil = the organisation has not loaded
    /// (`loaded: false`). Nil when the script did not answer.
    nonisolated static func dailyOverviewStandardHoursLabel(
        policyState: [String: Any]?,
        dayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookStandardHoursLabel? {
        let input: [String: Any] = [
            "policyOrState": policyState ?? NSNull(),
            "dayKey": dayKey,
            "timeZone": timeZone,
            "loaded": policyState != nil,
        ]
        guard let key = rulebookMemoKey(input) else { return nil }
        return standardHoursLabelMemo.value(for: key) {
            guard let row = callJSON("dailyOverviewStandardHoursLabel", arguments: [input]) as? [String: Any],
                  let label = row["label"] as? String else { return nil }
            return RulebookStandardHoursLabelBox(value: RulebookStandardHoursLabel(label: label, hint: row["hint"] as? String))
        }?.value
    }

    /// `DAILY_OVERVIEW_STANDARD_HOURS_LABEL` ("Standard hrs"); a neutral "Hours" when the script did not answer.
    nonisolated static var dailyOverviewStandardHoursText: String {
        constant("DAILY_OVERVIEW_STANDARD_HOURS_LABEL", as: String.self) ?? "Hours"
    }
}

nonisolated struct RulebookStandardHoursLabelBox: Sendable {
    let value: RulebookStandardHoursLabel
}
