//
//  Rulebook+Warnings.swift
//  Project Planner
//
//  Typed calls for RULEBOOK §5 (warnings): the scan window (`coverageWindow`, `clashScanDays`), clash
//  approvals (`clashResolutionKey`, `clashApprovalWrites`, `resolvedWarningKeys`, `isWarningActive`,
//  `isClashApproved`), material cut-off rows (`materialCutOffWarningRows`) and the invoicing schedule
//  summary on the warning settings screen (`activePaymentRunSummary`). Nothing is decided in Swift.
//

import Foundation

/// `coverageWindow` result: the inclusive scan window and, for "Set number of days", why it is not what was saved.
nonisolated struct CanonicalCoverageWindow: Equatable, Sendable {
    let startDayKey: String
    let endDayKey: String
    /// `lookaheadDaysMissing` or `lookaheadDaysInvalid`; nil when the saved value was used.
    let fallbackReason: String?
}

/// `clashScanDays` result: every day key clashes are checked on, ascending.
nonisolated struct CanonicalClashScanDays: Equatable, Sendable {
    let startDayKey: String
    let endDayKey: String
    let dayKeys: [String]
    let fallbackReason: String?
}

/// One warning scan's days, all from the script.
nonisolated struct WarningScanWindow: Equatable, Sendable {
    let start: Date
    let end: Date
    let startDayKey: String
    let endDayKey: String
    /// `coverageWindow.fallbackReason`, else `parseWarningDetection.clashLookaheadDaysFallback`.
    let fallbackReason: String?
    /// Last day unbooked labour is checked on.
    let unbookedEnd: Date
    /// `clashScanDays.dayKeys`; nil when the script did not answer.
    let clashDayKeys: [String]?
    /// Last clash day (a booked Saturday or Sunday in Full week).
    let clashEnd: Date

    /// Last day any part of the scan reads bookings for.
    var dataEnd: Date { max(end, max(unbookedEnd, clashEnd)) }
}

/// `activePaymentRunSummary` for the warning settings screen.
nonisolated enum WarningsPaymentRunSummary: Equatable, Sendable {
    /// `{ notConfigured: true }`: the organisation has no payment runs.
    case notConfigured
    case configured(label: String, payDayKey: String?)
}

extension CanonicalBusinessEngine {
    // MARK: - Scan window (engine.ts)

    /// `CoverageWindowInput` as the script reads it.
    nonisolated static func coverageWindowPayload(
        reference: Date,
        timeZone: String,
        clashLookaheadMode: String,
        clashLookaheadDays: Int,
        paymentRunMode: String,
        ranges: [(startDay: Int, endDay: Int)],
        recurringRunStartDay: String,
        recurringRunEndDay: String
    ) -> [String: Any] {
        [
            "referenceIso": isoString(from: reference),
            "timeZone": timeZone,
            "clashLookaheadMode": clashLookaheadMode,
            "clashLookaheadDays": clashLookaheadDays,
            "paymentRunMode": paymentRunMode,
            "ranges": ranges.map { ["startDay": $0.startDay, "endDay": $0.endDay] },
            "recurringRunStartDay": recurringRunStartDay,
            "recurringRunEndDay": recurringRunEndDay,
        ]
    }

    /// `clashScanDays`: the coverage window, plus a booked Saturday or Sunday of this week in Full week.
    /// `bookedDayKeys` nil counts every weekend day of the week as booked. Nil when the script did not answer.
    nonisolated static func clashScanDays(
        reference: Date,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        clashLookaheadMode: String,
        clashLookaheadDays: Int,
        paymentRunMode: String,
        ranges: [(startDay: Int, endDay: Int)],
        recurringRunStartDay: String,
        recurringRunEndDay: String,
        bookedDayKeys: [String]?
    ) -> CanonicalClashScanDays? {
        var payload = coverageWindowPayload(
            reference: reference,
            timeZone: timeZone,
            clashLookaheadMode: clashLookaheadMode,
            clashLookaheadDays: clashLookaheadDays,
            paymentRunMode: paymentRunMode,
            ranges: ranges,
            recurringRunStartDay: recurringRunStartDay,
            recurringRunEndDay: recurringRunEndDay
        )
        payload["bookedDayKeys"] = bookedDayKeys.map { $0 as Any } ?? NSNull()
        guard let row = callJSON("clashScanDays", arguments: [payload]) as? [String: Any],
              let start = row["startDayKey"] as? String, !start.isEmpty,
              let end = row["endDayKey"] as? String, !end.isEmpty else { return nil }
        return CanonicalClashScanDays(
            startDayKey: start,
            endDayKey: end,
            dayKeys: row["dayKeys"] as? [String] ?? [],
            fallbackReason: row["fallbackReason"] as? String
        )
    }

    /// `unbookedScanDays`: the days the unbooked-labour scan covers (weekdays, plus Saturday and Sunday when
    /// include-weekends is on; Full week then runs to Sunday). Nil when the script did not answer.
    nonisolated static func unbookedScanDays(
        reference: Date,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        clashLookaheadMode: String,
        clashLookaheadDays: Int,
        paymentRunMode: String,
        ranges: [(startDay: Int, endDay: Int)],
        recurringRunStartDay: String,
        recurringRunEndDay: String,
        includeWeekends: Bool
    ) -> CanonicalClashScanDays? {
        var payload = coverageWindowPayload(
            reference: reference,
            timeZone: timeZone,
            clashLookaheadMode: clashLookaheadMode,
            clashLookaheadDays: clashLookaheadDays,
            paymentRunMode: paymentRunMode,
            ranges: ranges,
            recurringRunStartDay: recurringRunStartDay,
            recurringRunEndDay: recurringRunEndDay
        )
        payload["includeWeekends"] = includeWeekends
        guard let row = callJSON("unbookedScanDays", arguments: [payload]) as? [String: Any],
              let start = row["startDayKey"] as? String, !start.isEmpty,
              let end = row["endDayKey"] as? String, !end.isEmpty else { return nil }
        return CanonicalClashScanDays(
            startDayKey: start,
            endDayKey: end,
            dayKeys: row["dayKeys"] as? [String] ?? [],
            fallbackReason: row["fallbackReason"] as? String
        )
    }

    /// The whole scan window for one scan: `coverageWindow` (with its fallback reason), the unbooked end
    /// (`unbookedScanDays`) and the clash days (`clashScanDays` over `bookedDayKeys`).
    /// Nil only when the script did not answer.
    nonisolated static func warningScanWindow(
        detection: OrgWarningDetectionSettings,
        invoicing: OrganizationInvoicingSettings,
        reference: Date = Date(),
        bookedDayKeys: [String]? = nil,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> WarningScanWindow? {
        let calendar = businessCalendar
        let ranges = invoicing.paymentRunDateRanges.map { (startDay: $0.startDay, endDay: $0.endDay) }
        guard let window = coverageWindow(
            reference: reference,
            timeZone: timeZone,
            clashLookaheadMode: detection.clashLookaheadMode.rawValue,
            clashLookaheadDays: detection.clashLookaheadDays,
            paymentRunMode: invoicing.paymentRunMode.rawValue,
            ranges: ranges,
            recurringRunStartDay: invoicing.recurringRunStartDay.rawValue,
            recurringRunEndDay: invoicing.recurringRunEndDay.rawValue
        ),
              let start = date(fromDayKey: window.startDayKey, calendar: calendar),
              let end = date(fromDayKey: window.endDayKey, calendar: calendar) else {
            return nil
        }
        let clash = clashScanDays(
            reference: reference,
            timeZone: timeZone,
            clashLookaheadMode: detection.clashLookaheadMode.rawValue,
            clashLookaheadDays: detection.clashLookaheadDays,
            paymentRunMode: invoicing.paymentRunMode.rawValue,
            ranges: ranges,
            recurringRunStartDay: invoicing.recurringRunStartDay.rawValue,
            recurringRunEndDay: invoicing.recurringRunEndDay.rawValue,
            bookedDayKeys: bookedDayKeys
        )
        let clashEnd = clash.flatMap { date(fromDayKey: $0.endDayKey, calendar: calendar) } ?? end
        // `unbookedScanDays`: Full week with include-weekends runs to Sunday of the same week.
        let unbooked = unbookedScanDays(
            reference: reference,
            timeZone: timeZone,
            clashLookaheadMode: detection.clashLookaheadMode.rawValue,
            clashLookaheadDays: detection.clashLookaheadDays,
            paymentRunMode: invoicing.paymentRunMode.rawValue,
            ranges: ranges,
            recurringRunStartDay: invoicing.recurringRunStartDay.rawValue,
            recurringRunEndDay: invoicing.recurringRunEndDay.rawValue,
            includeWeekends: detection.includeWeekendsForUnbookedLabour
        )
        let unbookedEnd = unbooked.flatMap { date(fromDayKey: $0.endDayKey, calendar: calendar) } ?? end
        return WarningScanWindow(
            start: start,
            end: end,
            startDayKey: window.startDayKey,
            endDayKey: window.endDayKey,
            fallbackReason: window.fallbackReason ?? detection.clashLookaheadDaysFallback,
            unbookedEnd: unbookedEnd,
            clashDayKeys: clash?.dayKeys,
            clashEnd: max(clashEnd, end)
        )
    }

    /// `parseWarningDetection(raw).clashLookaheadDaysFallback`: why a saved "Set number of days" value could
    /// not be used (`lookaheadDaysMissing`, `lookaheadDaysInvalid`). Nil when it could, or the script did not answer.
    nonisolated static func warningLookaheadDaysFallback(raw: [String: Any]?) -> String? {
        guard let parsed = callJSON("parseWarningDetection", arguments: [raw.map { $0 as Any } ?? NSNull()]) as? [String: Any] else {
            return nil
        }
        return parsed["clashLookaheadDaysFallback"] as? String
    }

    // MARK: - Clash approvals and resolutions (scheduleSources.ts)

    /// `clashResolutionKey`: the clash row's own key when it has one (manager clashes), else `clashPairKey`.
    nonisolated static func clashResolutionKey(bookingAId: String, bookingBId: String, resolutionKey: String? = nil) -> String? {
        var input: [String: Any] = ["bookingAId": bookingAId, "bookingBId": bookingBId]
        if let resolutionKey { input["resolutionKey"] = resolutionKey }
        guard let key = callJSON("clashResolutionKey", arguments: [input]) as? String, !key.isEmpty else { return nil }
        return key
    }

    /// `clashApprovalWrites`: the `acceptedBookingClashes/{clashPairKey}` document (add `acceptedAt`) and the
    /// `warningResolutions/{clashResolutionKey}` document with status `approved` (add `resolvedAt`). Either is nil
    /// when the script refused it. Nil overall when the script did not answer.
    nonisolated static func clashApprovalWrites(
        bookingAId: String,
        bookingBId: String,
        resolutionKey: String?,
        approvedByUserId: String
    ) -> (acceptedClash: (documentId: String, fields: [String: Any])?, resolution: (documentId: String, fields: [String: Any])?)? {
        var input: [String: Any] = [
            "bookingAId": bookingAId,
            "bookingBId": bookingBId,
            "approvedByUserId": approvedByUserId,
        ]
        if let resolutionKey { input["resolutionKey"] = resolutionKey }
        guard let row = callJSON("clashApprovalWrites", arguments: [input]) as? [String: Any] else { return nil }
        return (warningDocumentWrite(row["acceptedClash"]), warningDocumentWrite(row["resolution"]))
    }

    /// `resolvedWarningKeys`: keys of `warningResolutions` records whose status is approved or dismissed.
    nonisolated static func resolvedWarningKeys(_ records: [[String: Any]]) -> [String]? {
        callJSON("resolvedWarningKeys", arguments: [records]) as? [String]
    }

    /// `approvedWarningKeys`: keys of `warningResolutions` records whose status is approved (never dismissed).
    nonisolated static func approvedWarningKeys(_ records: [[String: Any]]) -> [String]? {
        callJSON("approvedWarningKeys", arguments: [records]) as? [String]
    }

    /// `WarningDecisions` as the script reads it. `approvedKeys` (from `approvedWarningKeys`) is what
    /// `isClashApproved` / `isClashGroupApproved` count; left out, they read `resolvedKeys`.
    nonisolated static func warningDecisions(
        resolvedKeys: [String],
        approvedKeys: [String]? = nil,
        acceptedClashes: [[String: Any]]
    ) -> [String: Any] {
        var decisions: [String: Any] = ["resolvedKeys": resolvedKeys, "acceptedClashes": acceptedClashes]
        if let approvedKeys { decisions["approvedKeys"] = approvedKeys }
        return decisions
    }

    /// `operativeClashGroups(input)`: `{ operativeBookings, people, managerIds, day }`. Nil when the script did not answer.
    nonisolated static func operativeClashGroups(_ input: [String: Any]) -> [[String: Any]]? {
        callJSON("operativeClashGroups", arguments: [input]) as? [[String: Any]]
    }

    /// `isClashGroupApproved({ pairs }, decisions)`: every overlapping pair of the cluster is approved.
    /// Nil when the script did not answer.
    nonisolated static func isClashGroupApproved(
        pairs: [(bookingAId: String, bookingBId: String)],
        decisions: [String: Any]
    ) -> Bool? {
        let group: [String: Any] = [
            "pairs": pairs.map { ["bookingAId": $0.bookingAId, "bookingBId": $0.bookingBId] },
        ]
        return callJSON("isClashGroupApproved", arguments: [group, decisions]) as? Bool
    }

    /// `isWarningActive`: the row still counts and is listed. Nil when the script did not answer.
    nonisolated static func isWarningActive(
        resolutionKey: String,
        bookingAId: String?,
        bookingBId: String?,
        decisions: [String: Any]
    ) -> Bool? {
        var row: [String: Any] = ["resolutionKey": resolutionKey]
        if let bookingAId, let bookingBId {
            row["bookingAId"] = bookingAId
            row["bookingBId"] = bookingBId
        }
        return callJSON("isWarningActive", arguments: [row, decisions]) as? Bool
    }

    /// `isClashApproved`: approved on any device (its resolution key or its booking pair). Nil when the script did not answer.
    nonisolated static func isClashApproved(
        bookingAId: String,
        bookingBId: String,
        resolutionKey: String?,
        decisions: [String: Any]
    ) -> Bool? {
        var row: [String: Any] = ["bookingAId": bookingAId, "bookingBId": bookingBId]
        if let resolutionKey { row["resolutionKey"] = resolutionKey }
        return callJSON("isClashApproved", arguments: [row, decisions]) as? Bool
    }

    nonisolated private static func warningDocumentWrite(_ value: Any?) -> (documentId: String, fields: [String: Any])? {
        guard let row = value as? [String: Any],
              let documentId = row["documentId"] as? String, !documentId.isEmpty,
              let fields = row["fields"] as? [String: Any] else { return nil }
        return (documentId, fields)
    }

    // MARK: - Material cut-off (materialCutOffWarnings.ts)

    /// `materialCutOffWarningRows(input)`: `{ now, timeZone, cutOff, projects, bookings, materials, sendRecords }`.
    /// Nil when the script did not answer.
    nonisolated static func materialCutOffWarningRows(_ input: [String: Any]) -> [[String: Any]]? {
        callJSON("materialCutOffWarningRows", arguments: [input]) as? [[String: Any]]
    }

    // MARK: - Invoicing schedule summary (paymentRuns.ts)

    /// `activePaymentRunSummary(invoicing, now, timeZone)` over the raw `organizations/{orgId}.invoicing` map
    /// (nil when the organisation has none). Nil when the script did not answer.
    nonisolated static func warningsPaymentRunSummary(
        invoicing: [String: Any]?,
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> WarningsPaymentRunSummary? {
        let map: Any = invoicing.map { $0 as Any } ?? NSNull()
        guard let row = callJSON("activePaymentRunSummary", arguments: [map, isoString(from: now), timeZone]) as? [String: Any] else {
            return nil
        }
        if (row["notConfigured"] as? Bool) == true { return .notConfigured }
        guard let label = row["label"] as? String, !label.isEmpty else { return nil }
        return .configured(label: label, payDayKey: row["payDate"] as? String)
    }
}
