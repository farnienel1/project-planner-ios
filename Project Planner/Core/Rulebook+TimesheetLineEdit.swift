//
//  Rulebook+TimesheetLineEdit.swift
//  Project Planner
//
//  RULEBOOK 1.46.0 (rates audit, §7, §8; web `lib/canonical/timesheetLineEdit.ts`, `timesheetEntryReviews.ts`). A line
//  manager's "Edit hours" re-prices the whole booking (`revisedPayrollLineAmounts`), the review stores the hours and
//  money of each part and the booking it was made against, a signed snapshot line keeps its own part
//  (`payrollLineReviewSnapshotParts`), and the weekly report prices each booking on its own (`bookingPaySlices`,
//  `mergeBookingPaySlice`). Every figure comes from the packed script through `CanonicalBusinessEngine`; Swift only maps
//  its models into the script's plain inputs and maps the answer back. There is no Swift copy of these rules.
//

import Foundation

// MARK: - Script shapes

/// `PayrollLineEditReviewFields`: what Edit hours stores on one line's review beside `decision: 'edited'`. Field names
/// are fixed for web and iOS.
nonisolated struct RulebookPayrollLineEditReviewFields: Hashable, Sendable {
    var revisedAmount: Double
    var revisedStandardHours: Double
    var revisedOvertimeHours: Double
    var revisedOvertimeClockHours: Double
    var revisedOvertimeMultiplier: Double?
    var revisedStandardAmount: Double
    var revisedOvertimeAmount: Double
    var reviewedBookingFingerprint: String

    init?(json: Any?) {
        guard let row = json as? [String: Any], let amount = (row["revisedAmount"] as? NSNumber)?.doubleValue else { return nil }
        func n(_ key: String) -> Double { (row[key] as? NSNumber)?.doubleValue ?? 0 }
        revisedAmount = amount
        revisedStandardHours = n("revisedStandardHours")
        revisedOvertimeHours = n("revisedOvertimeHours")
        revisedOvertimeClockHours = n("revisedOvertimeClockHours")
        revisedOvertimeMultiplier = (row["revisedOvertimeMultiplier"] as? NSNumber)?.doubleValue
        revisedStandardAmount = n("revisedStandardAmount")
        revisedOvertimeAmount = n("revisedOvertimeAmount")
        reviewedBookingFingerprint = row["reviewedBookingFingerprint"] as? String ?? ""
    }

    /// The review stored on the line: `{ decision: 'edited', ...fields }`. Main actor: the review model is an app type.
    @MainActor var editedReview: TimesheetPayrollLineReview {
        TimesheetPayrollLineReview(
            decision: .edited,
            revisedAmount: revisedAmount,
            revisedStandardHours: revisedStandardHours,
            revisedOvertimeHours: revisedOvertimeHours,
            revisedOvertimeClockHours: revisedOvertimeClockHours,
            revisedOvertimeMultiplier: revisedOvertimeMultiplier,
            revisedStandardAmount: revisedStandardAmount,
            revisedOvertimeAmount: revisedOvertimeAmount,
            reviewedBookingFingerprint: reviewedBookingFingerprint
        )
    }
}

/// `RevisedPayrollLineAmounts`: the edited booking priced again.
nonisolated struct RulebookRevisedPayrollLineAmounts: Hashable, Sendable {
    let standardHours: Double
    let overtimeHours: Double
    let overtimeClockHours: Double
    let overtimeMultiplier: Double
    let totalPaidHours: Double
    let standardDayHours: Double
    let isPayeDay: Bool
    let standardAmount: Double
    let overtimeAmount: Double
    let standardLineAmount: Double
    let overtimeLineAmount: Double?
    let standardFields: RulebookPayrollLineEditReviewFields
    let overtimeFields: RulebookPayrollLineEditReviewFields?
    let total: Double

    init?(json: Any?) {
        guard let row = json as? [String: Any],
              let total = (row["total"] as? NSNumber)?.doubleValue,
              let fields = row["reviewFields"] as? [String: Any],
              let standard = RulebookPayrollLineEditReviewFields(json: fields["standard"]) else { return nil }
        func n(_ key: String) -> Double { (row[key] as? NSNumber)?.doubleValue ?? 0 }
        standardHours = n("standardHours")
        overtimeHours = n("overtimeHours")
        overtimeClockHours = n("overtimeClockHours")
        overtimeMultiplier = n("overtimeMultiplier")
        totalPaidHours = n("totalPaidHours")
        standardDayHours = n("standardDayHours")
        isPayeDay = row["isPayeDay"] as? Bool ?? false
        standardAmount = n("standardAmount")
        overtimeAmount = n("overtimeAmount")
        standardLineAmount = n("standardLineAmount")
        overtimeLineAmount = (row["overtimeLineAmount"] as? NSNumber)?.doubleValue
        standardFields = standard
        overtimeFields = RulebookPayrollLineEditReviewFields(json: fields["overtime"])
        self.total = total
    }
}

/// `PayrollLineSnapshotPart`: one signed-snapshot labour line built from a live line and its Edit hours review.
nonisolated struct RulebookPayrollLineSnapshotPart: Hashable, Sendable {
    let id: String
    let isOvertime: Bool
    let paidHours: Double
    let otMultiplier: Double?
    let amount: Double
}

/// `BookingPaySlice`: one booking's standard or overtime part for the weekly report, priced and rounded.
nonisolated struct RulebookBookingPaySlice: Hashable, Sendable {
    var payBasis: String
    var isOvertime: Bool
    var otMultiplier: Double?
    var rate: Double?
    var paidHours: Double
    var pay: Double
    var isPaye: Bool
    var standardDayHours: Double
    var clockHours: Double?
    var breakHours: Double?

    init?(json: Any?) {
        guard let row = json as? [String: Any], let pay = (row["pay"] as? NSNumber)?.doubleValue else { return nil }
        payBasis = row["payBasis"] as? String ?? "day"
        isOvertime = row["isOvertime"] as? Bool ?? false
        otMultiplier = (row["otMultiplier"] as? NSNumber)?.doubleValue
        rate = (row["rate"] as? NSNumber)?.doubleValue
        paidHours = (row["paidHours"] as? NSNumber)?.doubleValue ?? 0
        self.pay = pay
        isPaye = row["isPaye"] as? Bool ?? false
        standardDayHours = (row["standardDayHours"] as? NSNumber)?.doubleValue ?? 0
        clockHours = (row["clockHours"] as? NSNumber)?.doubleValue
        breakHours = (row["breakHours"] as? NSNumber)?.doubleValue
    }

    /// The script argument (every known key; missing values are JSON null or left out as the script writes them).
    var json: [String: Any] {
        var row: [String: Any] = [
            "payBasis": payBasis,
            "isOvertime": isOvertime,
            "otMultiplier": RulebookJSON.orNull(otMultiplier),
            "rate": RulebookJSON.orNull(rate),
            "paidHours": paidHours,
            "pay": pay,
            "isPaye": isPaye,
            "standardDayHours": standardDayHours,
        ]
        if let clockHours { row["clockHours"] = clockHours }
        if let breakHours { row["breakHours"] = breakHours }
        return row
    }
}

// MARK: - Review model ↔ the stored / script shape

extension TimesheetPayrollLineReview {
    /// The review as stored in `payrollLineReviews[lineId]` and as the script reads it (web `timesheetStorage.ts`
    /// `payrollLineEditFieldsOf`): `decision`, `revisedAmount` (null when none) and, on an Edit hours review, its hours,
    /// parts and booking fingerprint. A field never stored is left out, so an older review keeps its stored shape.
    var storedFields: [String: Any] {
        var row: [String: Any] = [
            "decision": decision.rawValue,
            "revisedAmount": RulebookJSON.orNull(revisedAmount),
        ]
        if let revisedStandardHours { row["revisedStandardHours"] = revisedStandardHours }
        if let revisedOvertimeHours { row["revisedOvertimeHours"] = revisedOvertimeHours }
        if let revisedOvertimeClockHours { row["revisedOvertimeClockHours"] = revisedOvertimeClockHours }
        if let revisedOvertimeMultiplier {
            row["revisedOvertimeMultiplier"] = revisedOvertimeMultiplier
        } else if revisedStandardHours != nil {
            // Web writes null here on an Edit hours review that pays no overtime.
            row["revisedOvertimeMultiplier"] = NSNull()
        }
        if let revisedStandardAmount { row["revisedStandardAmount"] = revisedStandardAmount }
        if let revisedOvertimeAmount { row["revisedOvertimeAmount"] = revisedOvertimeAmount }
        if let reviewedBookingFingerprint { row["reviewedBookingFingerprint"] = reviewedBookingFingerprint }
        return row
    }

    /// A stored review (Firestore map or the script's `payrollLineReview` answer). Numbers read as `NSNumber`, so a whole
    /// number Firestore returns as an integer still reads.
    init(stored payload: [String: Any], defaultDecision: TimesheetManagerDecision = .pending) {
        func n(_ key: String) -> Double? { (payload[key] as? NSNumber)?.doubleValue }
        self.init(
            decision: TimesheetManagerDecision(rawValue: payload["decision"] as? String ?? "") ?? defaultDecision,
            revisedAmount: n("revisedAmount"),
            revisedStandardHours: n("revisedStandardHours"),
            revisedOvertimeHours: n("revisedOvertimeHours"),
            revisedOvertimeClockHours: n("revisedOvertimeClockHours"),
            revisedOvertimeMultiplier: n("revisedOvertimeMultiplier"),
            revisedStandardAmount: n("revisedStandardAmount"),
            revisedOvertimeAmount: n("revisedOvertimeAmount"),
            reviewedBookingFingerprint: payload["reviewedBookingFingerprint"] as? String
        )
    }
}

// MARK: - Calls

extension CanonicalBusinessEngine {
    /// Web and iOS collectors give a booking its own overtime line only above this many overtime hours
    /// (web `TIMESHEET_OVERTIME_LINE_MIN_HOURS`). Kept as it is in 1.46.0 (an owner question); passed to
    /// `revisedPayrollLineAmounts` so Edit hours counts overtime exactly as the collector does.
    nonisolated static let timesheetOvertimeLineMinHours = 0.05

    /// `PAYROLL_LINE_EDIT_TIMES_MESSAGE`.
    nonisolated static var payrollLineEditTimesMessage: String {
        constant("PAYROLL_LINE_EDIT_TIMES_MESSAGE", as: String.self) ?? "Enter a start and a finish time that are different."
    }

    /// `revisedPayrollLineTimesError(start, end)`: why Edit hours cannot price these times, else nil. A script that does
    /// not answer refuses (nothing is priced on an unchecked guard).
    nonisolated static func revisedPayrollLineTimesError(startTime: String, endTime: String) -> String? {
        guard let answer = callJSON("revisedPayrollLineTimesError", arguments: [startTime, endTime]) else {
            return payrollLineEditTimesMessage
        }
        return answer as? String
    }

    /// `revisedPayrollLineAmounts(input)` with the policy in effect on the line's day. Nil when the times cannot be
    /// priced or the script did not answer.
    nonisolated static func revisedPayrollLineAmounts(
        dayKey: String,
        policy: OrgPayrollTimePolicy,
        startTime: String,
        endTime: String,
        isBreakRemoved: Bool,
        otMultiplierOverride: Double?,
        payBasis: String,
        dayRate: Double?,
        hourlyRate: Double?,
        employment: [String: Any]?,
        bookingHasOvertimeLine: Bool,
        overtimeLineMinHours: Double = timesheetOvertimeLineMinHours,
        bookingFingerprint: String?,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookRevisedPayrollLineAmounts? {
        guard let policyJSON = payrollPolicyJSON(policy) else { return nil }
        let input: [String: Any] = [
            "dayKey": dayKey,
            "timeZone": timeZone,
            "policy": policyJSON,
            "startTime": startTime,
            "endTime": endTime,
            "isBreakRemoved": isBreakRemoved,
            "otMultiplierOverride": RulebookJSON.orNull(otMultiplierOverride),
            "payBasis": payBasis,
            "dayRate": RulebookJSON.orNull(dayRate),
            "hourlyRate": RulebookJSON.orNull(hourlyRate),
            "employment": RulebookJSON.orNull(employment),
            "bookingHasOvertimeLine": bookingHasOvertimeLine,
            "overtimeLineMinHours": overtimeLineMinHours,
            "bookingFingerprint": RulebookJSON.orNull(bookingFingerprint),
        ]
        return RulebookRevisedPayrollLineAmounts(json: callJSON("revisedPayrollLineAmounts", arguments: [input]))
    }

    /// `payrollLineReviewSnapshotParts(line, review)`: the signed-snapshot lines for one line with an Edit hours review,
    /// or nil when the review carries no edited hours (older reviews: the caller keeps today's line). `review` must be
    /// the line's `payrollLineReview` (stale reviews already nil). Main actor: the review model is an app type.
    @MainActor static func payrollLineReviewSnapshotParts(
        lineId: String,
        isOvertimeLine: Bool,
        review: TimesheetPayrollLineReview?
    ) -> [RulebookPayrollLineSnapshotPart]? {
        payrollLineReviewSnapshotPartsChecked(lineId: lineId, isOvertimeLine: isOvertimeLine, review: review).parts
    }

    /// `payrollLineReviewSnapshotParts` that also says whether the script failed to answer (`failed`), so a sign or save
    /// refuses instead of signing the line without its review's parts.
    @MainActor static func payrollLineReviewSnapshotPartsChecked(
        lineId: String,
        isOvertimeLine: Bool,
        review: TimesheetPayrollLineReview?
    ) -> (parts: [RulebookPayrollLineSnapshotPart]?, failed: Bool) {
        guard let review else { return (nil, false) }
        let line: [String: Any] = ["id": lineId, "isOvertimeLine": isOvertimeLine]
        guard let answer = callJSON("payrollLineReviewSnapshotParts", arguments: [line, review.storedFields]) else { return (nil, true) }
        guard let rows = answer as? [[String: Any]] else { return (nil, false) }
        var parts: [RulebookPayrollLineSnapshotPart] = []
        for row in rows {
            guard let id = row["id"] as? String else { return (nil, true) }
            parts.append(RulebookPayrollLineSnapshotPart(
                id: id,
                isOvertime: row["isOvertime"] as? Bool ?? false,
                paidHours: (row["paidHours"] as? NSNumber)?.doubleValue ?? 0,
                otMultiplier: (row["otMultiplier"] as? NSNumber)?.doubleValue,
                amount: (row["amount"] as? NSNumber)?.doubleValue ?? 0
            ))
        }
        return (parts, false)
    }

    /// `bookingPaySlices({ hours: payrollHoursResult(hoursInput), standardDayHours, payBasis, dayRate, hourlyRate,
    /// isPaye })`: one booking's standard and overtime parts for the weekly report, each priced and rounded. Nil when the
    /// script did not answer.
    nonisolated static func bookingPaySlices(
        hoursInput: RulebookPayrollHoursInput,
        standardDayHours: Double,
        payBasis: String,
        dayRate: Double?,
        hourlyRate: Double?,
        isPaye: Bool
    ) -> [RulebookBookingPaySlice]? {
        // Memoised by the exact input: the weekly report prices many bookings with the same times, rate and day.
        let key = BookingPaySlicesKey(
            hoursInput: hoursInput, standardDayHours: standardDayHours, payBasis: payBasis,
            dayRate: dayRate, hourlyRate: hourlyRate, isPaye: isPaye
        )
        return bookingPaySlicesMemo.value(for: key) {
            unmemoisedBookingPaySlices(
                hoursInput: hoursInput, standardDayHours: standardDayHours, payBasis: payBasis,
                dayRate: dayRate, hourlyRate: hourlyRate, isPaye: isPaye
            )
        }
    }

    nonisolated private struct BookingPaySlicesKey: Hashable, Sendable {
        let hoursInput: RulebookPayrollHoursInput
        let standardDayHours: Double
        let payBasis: String
        let dayRate: Double?
        let hourlyRate: Double?
        let isPaye: Bool
    }

    nonisolated private static let bookingPaySlicesMemo = RulebookAnswerMemo<BookingPaySlicesKey, [RulebookBookingPaySlice]>(limit: 4096)

    nonisolated private static func unmemoisedBookingPaySlices(
        hoursInput: RulebookPayrollHoursInput,
        standardDayHours: Double,
        payBasis: String,
        dayRate: Double?,
        hourlyRate: Double?,
        isPaye: Bool
    ) -> [RulebookBookingPaySlice]? {
        guard let argument = hoursInput.scriptArgument(),
              let hours = callJSON("payrollHoursResult", arguments: [argument]) as? [String: Any] else { return nil }
        let input: [String: Any] = [
            "hours": hours,
            "standardDayHours": standardDayHours,
            "payBasis": payBasis,
            "dayRate": RulebookJSON.orNull(dayRate),
            "hourlyRate": RulebookJSON.orNull(hourlyRate),
            "isPaye": isPaye,
        ]
        guard let rows = callJSON("bookingPaySlices", arguments: [input]) as? [Any] else { return nil }
        // Every part must read back; a part that does not is a failed answer, never dropped pay.
        let slices = rows.compactMap { RulebookBookingPaySlice(json: $0) }
        return slices.count == rows.count ? slices : nil
    }

    /// `mergeBookingPaySlice(row, slice)`: a booking's slice added to a row of the same kind — hours and each booking's
    /// rounded pay summed, never re-priced. Nil when the script did not answer.
    nonisolated static func mergeBookingPaySlice(_ row: RulebookBookingPaySlice, _ slice: RulebookBookingPaySlice) -> RulebookBookingPaySlice? {
        RulebookBookingPaySlice(json: callJSON("mergeBookingPaySlice", arguments: [row.json, slice.json]))
    }

    /// `payrollLineReviewKey(review)`: the identity of the review applied to a signed line (`appliedReviewKey`); '' for
    /// none. Pass the review as `payrollLineReview` returned it. Nil when the script did not answer.
    @MainActor static func payrollLineReviewKey(_ review: TimesheetPayrollLineReview?) -> String? {
        let argument: Any = review.map { $0.storedFields as Any } ?? NSNull()
        return callJSON("payrollLineReviewKey", arguments: [argument]) as? String
    }

    /// `payrollLineBookingKey(line)`: the booking a payroll line comes from (its collection and `bookingId`, else the line
    /// id without `-normal` / `-ot`; ids without case). Nil when the script did not answer.
    nonisolated static func payrollLineBookingKey(lineId: String, bookingId: String?, bookingCollection: String?) -> String? {
        let line: [String: Any] = [
            "id": lineId,
            "bookingId": RulebookJSON.orNull(bookingId),
            "bookingCollection": RulebookJSON.orNull(bookingCollection),
        ]
        return callJSON("payrollLineBookingKey", arguments: [line]) as? String
    }

    /// `overtimeFingerprintsMatch(a, b)`: whether two booking fingerprints name the same booking state, reading the slot
    /// of both canonically (a web `CUSTOM` and an iOS `CUSTOM_HOURS`, or a stored pre-1.46 `CUSTOM HOURS`, are one).
    /// Never compare fingerprints with `==` in Swift. False when the script did not answer, or either side is empty.
    nonisolated static func overtimeFingerprintsMatch(_ a: String?, _ b: String?) -> Bool {
        callJSON("overtimeFingerprintsMatch", arguments: [RulebookJSON.orNull(a), RulebookJSON.orNull(b)]) as? Bool ?? false
    }

    nonisolated private static let payrollLineFingerprintMemo = RulebookAnswerMemo<OvertimeBookingInput, String>(limit: 4096)

    /// RULEBOOK 1.46.0: a timesheet payroll line's `bookingFingerprint` — the rulebook's `overtimeBookingFingerprint`
    /// (never built in Swift), memoised by its exact input because the collector runs on every redraw. Nil when the
    /// script did not answer (the line is then not checked for staleness, as a line without a fingerprint on web).
    nonisolated static func payrollLineBookingFingerprint(_ booking: OvertimeBookingInput) -> String? {
        payrollLineFingerprintMemo.value(for: booking) {
            let answer = overtimeBookingFingerprint(booking)
            return answer.isEmpty ? nil : answer
        }
    }

    /// `orgDayHours(hours)`: the paid day a day rate divides by (never below the rulebook's floor). Nil when the script
    /// did not answer.
    nonisolated static func orgDayHours(_ hours: Double) -> Double? {
        (callJSON("orgDayHours", arguments: [hours]) as? NSNumber)?.doubleValue
    }

    /// `roundPennies(value)`. Falls back to the value itself when the script did not answer.
    nonisolated static func roundPennies(_ value: Double) -> Double {
        (callJSON("roundPennies", arguments: [value]) as? NSNumber)?.doubleValue ?? value
    }
}
