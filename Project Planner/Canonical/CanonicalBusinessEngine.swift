//
//  CanonicalBusinessEngine.swift
//  Project Planner
//
//  Evaluates lib/canonical from the web app. The JavaScript file is generated;
//  do not edit canonical-business.js by hand.
//

import Foundation
import JavaScriptCore

struct CanonicalDayWindow: Equatable {
    let startDayKey: String
    let endDayKey: String
}

enum CanonicalBusinessEngine {
    /// Organisation calendar. Device time zone must not decide pay periods or warning windows.
    static var businessCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        return calendar
    }

    private static let context: JSContext? = {
        let source: String?
        if let url = Bundle.main.url(forResource: "canonical-business", withExtension: "js") {
            source = try? String(contentsOf: url, encoding: .utf8)
        } else {
            source = nil
        }
        guard let source, !source.isEmpty else { return nil }
        let context = JSContext()
        context?.exceptionHandler = { _, value in
            NSLog("Canonical business script error: %@", value?.toString() ?? "")
        }
        context?.evaluateScript(source)
        return context
    }()

    static func coverageWindow(
        reference: Date,
        timeZone: String = "Europe/London",
        clashLookaheadMode: String,
        clashLookaheadDays: Int,
        paymentRunMode: String,
        ranges: [(startDay: Int, endDay: Int)],
        recurringRunStartDay: String,
        recurringRunEndDay: String
    ) -> CanonicalDayWindow? {
        guard context != nil else { return nil }
        let payload: [String: Any] = [
            "referenceIso": iso8601.string(from: reference),
            "timeZone": timeZone,
            "clashLookaheadMode": clashLookaheadMode,
            "clashLookaheadDays": clashLookaheadDays,
            "paymentRunMode": paymentRunMode,
            "ranges": ranges.map { ["startDay": $0.startDay, "endDay": $0.endDay] },
            "recurringRunStartDay": recurringRunStartDay,
            "recurringRunEndDay": recurringRunEndDay,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        let value = context?.evaluateScript("ProjectPlannerCanonical.coverageWindow(\(json))")
        guard let result = value?.toDictionary(),
              let start = result["startDayKey"] as? String,
              let end = result["endDayKey"] as? String,
              !start.isEmpty, !end.isEmpty else {
            return nil
        }
        return CanonicalDayWindow(startDayKey: start, endDayKey: end)
    }

    /// Warning scan bounds from the shared script, or the same London calendar if the script is missing.
    static func warningBounds(
        detection: OrgWarningDetectionSettings,
        invoicing: OrganizationInvoicingSettings,
        reference: Date = Date()
    ) -> (start: Date, end: Date) {
        let calendar = businessCalendar
        let ranges = invoicing.paymentRunDateRanges.map { (startDay: $0.startDay, endDay: $0.endDay) }
        if let window = coverageWindow(
            reference: reference,
            clashLookaheadMode: detection.clashLookaheadMode.rawValue,
            clashLookaheadDays: detection.clashLookaheadDays,
            paymentRunMode: invoicing.paymentRunMode.rawValue,
            ranges: ranges,
            recurringRunStartDay: invoicing.recurringRunStartDay.rawValue,
            recurringRunEndDay: invoicing.recurringRunEndDay.rawValue
        ),
           let start = date(fromDayKey: window.startDayKey, calendar: calendar),
           let end = date(fromDayKey: window.endDayKey, calendar: calendar) {
            return (start, end)
        }
        let today = calendar.startOfDay(for: reference)
        return (
            detection.coverageStart(from: today, invoicing: invoicing, calendar: calendar),
            detection.coverageEnd(from: today, invoicing: invoicing, calendar: calendar)
        )
    }

    static func date(fromDayKey key: String, calendar: Calendar = businessCalendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
