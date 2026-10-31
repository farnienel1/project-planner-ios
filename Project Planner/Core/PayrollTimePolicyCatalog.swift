//
//  PayrollTimePolicyCatalog.swift
//  Project Planner
//
//  Date-aware payroll policy resolution and scheduled working-hours changes.
//

import Foundation

/// Future working-hours change queued on the organisation document.
nonisolated struct OrgPayrollTimePolicyScheduledChange: Codable, Hashable, Sendable {
    var policy: OrgPayrollTimePolicy
    /// Organisation-zone midnight of the day `policy` becomes live.
    var effectiveFrom: Date

    func asFirestoreDictionary() -> [String: Any] {
        [
            "policy": policy.asFirestoreDictionary(),
            "effectiveFrom": PayrollTimePolicyCatalog.dayKey(effectiveFrom),
        ]
    }

    /// `parsePayrollTimePolicyScheduled`: nil when the map has no policy or no usable `effectiveFrom`.
    /// Day keys are organisation-zone (`OrganizationRulebookContext`).
    static func fromFirestore(_ data: [String: Any]) -> OrgPayrollTimePolicyScheduledChange? {
        guard data["policy"] is [String: Any] else { return nil }
        let raw = FirebaseBackend.firestoreJSON(data)
        guard let parsed = CanonicalBusinessEngine.callJSON(
            "parsePayrollTimePolicyScheduled",
            arguments: [raw, OrganizationRulebookContext.timeZoneIdentifier]
        ) as? [String: Any],
              let policy = CanonicalBusinessEngine.payrollPolicy(fromJSON: parsed["policy"]),
              let key = parsed["effectiveFrom"] as? String,
              let day = OrganizationRulebookContext.date(fromDayKey: key) else { return nil }
        return OrgPayrollTimePolicyScheduledChange(policy: policy, effectiveFrom: day)
    }
}

enum PayrollTimePolicyCatalog {
    /// Visual standard window for schedule/timesheet timeline bars on a given day.
    struct DayTimelinePolicy: Equatable {
        enum DayKind: Equatable {
            case weekday
            case saturday
            case sunday
        }

        let dayKind: DayKind
        /// Blue “standard” band; nil when every hour is paid at the multiplier.
        let standardWindowStart: String?
        let standardWindowEnd: String?
        let allHoursAtMultiplier: Bool
        let outsideMultiplier: Double

        var standardWindowStartMinutes: Int? {
            guard let s = standardWindowStart else { return nil }
            return ManagerScheduleInterval.parseMinutes(s)
        }

        var standardWindowEndMinutes: Int? {
            guard let e = standardWindowEnd else { return nil }
            return ManagerScheduleInterval.parseMinutes(e)
        }
    }

    /// Organisation-zone `YYYY-MM-DD` (RULEBOOK §1), never the device zone.
    nonisolated static func dayKey(_ date: Date) -> String {
        OrganizationRulebookContext.dayKey(date)
    }

    /// Organisation-zone midnight for a `YYYY-MM-DD` key.
    nonisolated static func date(fromDayKey key: String) -> Date? {
        OrganizationRulebookContext.date(fromDayKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `payrollTimePolicyTimeline`: promotes a due scheduled change (current = scheduled, prior = the
    /// policy of the day before it). A future change stays pending. Falls back to the input unchanged
    /// when the script does not answer.
    nonisolated static func appliedPolicyState(
        current: OrgPayrollTimePolicy,
        prior: OrgPayrollTimePolicy?,
        effectiveFrom: Date,
        scheduled: OrgPayrollTimePolicyScheduledChange?
    ) -> (current: OrgPayrollTimePolicy, prior: OrgPayrollTimePolicy?, effectiveFrom: Date, scheduled: OrgPayrollTimePolicyScheduledChange?) {
        let doc = CanonicalBusinessEngine.payrollPolicyDocument(
            current: current,
            prior: prior,
            effectiveFromDayKey: dayKey(effectiveFrom),
            scheduledPolicy: scheduled?.policy,
            scheduledEffectiveFromDayKey: scheduled.map { dayKey($0.effectiveFrom) }
        )
        guard let state = CanonicalBusinessEngine.payrollTimePolicyTimeline(orgDocument: doc, todayKey: dayKey(Date())) else {
            return (current, prior, effectiveFrom, scheduled)
        }
        let nextEffective = state.effectiveFromDayKey.flatMap { date(fromDayKey: $0) } ?? effectiveFrom
        var nextScheduled: OrgPayrollTimePolicyScheduledChange?
        if let policy = state.scheduledPolicy,
           let key = state.scheduledEffectiveFromDayKey,
           let day = date(fromDayKey: key) {
            nextScheduled = OrgPayrollTimePolicyScheduledChange(policy: policy, effectiveFrom: day)
        }
        return (state.current, state.prior, nextEffective, nextScheduled)
    }

    /// The raw-document shape of an organisation's four payroll fields, for the script.
    static func payrollPolicyDocument(for org: Organization) -> [String: Any] {
        CanonicalBusinessEngine.payrollPolicyDocument(
            current: org.settings.payrollTimePolicy,
            prior: org.payrollTimePolicyPrior,
            effectiveFromDayKey: org.payrollTimePolicyEffectiveFrom.map { dayKey($0) },
            scheduledPolicy: org.payrollTimePolicyScheduled?.policy,
            scheduledEffectiveFromDayKey: org.payrollTimePolicyScheduled.map { dayKey($0.effectiveFrom) }
        )
    }

    /// `effectivePayrollTimePolicy` answers, keyed by the organisation's payroll state and day.
    private static var effectivePolicyCache: [String: OrgPayrollTimePolicy] = [:]

    /// Policy that applies to bookings / timesheets on `day`: `effectivePayrollTimePolicy(org, dayKey)`
    /// (scheduled from its day on, prior before `payrollTimePolicyEffectiveFrom`, otherwise current).
    static func policy(for day: Date, organization: Organization?) -> OrgPayrollTimePolicy {
        guard let org = organization else { return .default }
        let key = dayKey(day)
        var hasher = Hasher()
        hasher.combine(org.firestoreDocumentId)
        hasher.combine(org.settings.payrollTimePolicy)
        hasher.combine(org.payrollTimePolicyPrior)
        hasher.combine(org.payrollTimePolicyEffectiveFrom)
        hasher.combine(org.payrollTimePolicyScheduled)
        hasher.combine(OrganizationRulebookContext.timeZoneIdentifier)
        let cacheKey = "\(hasher.finalize())|\(key)"
        if let cached = effectivePolicyCache[cacheKey] { return cached }
        let resolved = CanonicalBusinessEngine.effectivePayrollTimePolicy(
            orgDocument: payrollPolicyDocument(for: org),
            dayKey: key
        ) ?? org.settings.payrollTimePolicy
        if effectivePolicyCache.count > 2000 { effectivePolicyCache.removeAll() }
        effectivePolicyCache[cacheKey] = resolved
        return resolved
    }

    static func policy(for day: Date, firebaseBackend: FirebaseBackend) -> OrgPayrollTimePolicy {
        policy(for: day, organization: firebaseBackend.currentOrganization)
    }

    static func resolvedSundaySettings(from policy: OrgPayrollTimePolicy) -> OrgWeekendDayPayrollSettings {
        if policy.sundaySameAsSaturday {
            return policy.saturday
        }
        return policy.sunday
    }

    static func weekendSettings(for day: Date, policy: OrgPayrollTimePolicy) -> OrgWeekendDayPayrollSettings {
        let wd = CanonicalBusinessEngine.businessCalendar.component(.weekday, from: day)
        if wd == 7 { return policy.saturday }
        return resolvedSundaySettings(from: policy)
    }

    static func isWeekend(_ day: Date, calendar: Calendar = .current) -> Bool {
        let wd = calendar.component(.weekday, from: day)
        return wd == 1 || wd == 7
    }

    static func isWeekday(_ day: Date, calendar: Calendar = .current) -> Bool {
        !isWeekend(day, calendar: calendar)
    }

    /// True when Saturday and Sunday org rules match (or Sunday mirrors Saturday).
    static func saturdayAndSundayMatch(in policy: OrgPayrollTimePolicy) -> Bool {
        if policy.sundaySameAsSaturday { return true }
        return policy.saturday.equivalentForBatchBooking(policy.sunday, fallbackCountsAs: policy.standardPaidHours)
    }

    static func timelinePolicy(for day: Date, policy: OrgPayrollTimePolicy) -> DayTimelinePolicy {
        let wd = CanonicalBusinessEngine.businessCalendar.component(.weekday, from: day)
        if wd >= 2 && wd <= 6 {
            return DayTimelinePolicy(
                dayKind: .weekday,
                standardWindowStart: policy.standardDayStart,
                standardWindowEnd: policy.standardDayEnd,
                allHoursAtMultiplier: false,
                outsideMultiplier: policy.weekdayOutsideStandardMultiplier
            )
        }
        let weekend = weekendSettings(for: day, policy: policy)
        let kind: DayTimelinePolicy.DayKind = wd == 7 ? .saturday : .sunday
        if weekend.allHoursAtMultiplierMode {
            return DayTimelinePolicy(
                dayKind: kind,
                standardWindowStart: nil,
                standardWindowEnd: nil,
                allHoursAtMultiplier: true,
                outsideMultiplier: weekend.allHoursMultiplier
            )
        }
        return DayTimelinePolicy(
            dayKind: kind,
            standardWindowStart: weekend.customStandardStart ?? policy.standardDayStart,
            standardWindowEnd: weekend.customStandardEnd ?? "13:00",
            allHoursAtMultiplier: false,
            outsideMultiplier: weekend.outsideStandardWindowMultiplier
        )
    }

    /// Multiplier applied to outside-window / all-hours segments for a booking on its calendar day.
    /// Resolves from org policy only — must not call `PayrollHoursEngine.compute` (that path uses this helper).
    static func effectiveMultiplier(for booking: Booking, policy: OrgPayrollTimePolicy) -> Double {
        if let override = booking.otMultiplierOverride, override > 0 { return override }
        return timelinePolicy(for: booking.date, policy: policy).outsideMultiplier
    }

    /// Multiplier applied to outside-window / all-hours segments for a manager booking on its calendar day.
    static func effectiveMultiplier(for booking: ManagerSiteBooking, policy: OrgPayrollTimePolicy) -> Double {
        timelinePolicy(for: booking.date, policy: policy).outsideMultiplier
    }

    static func defaultWeekendBookingChoice(policy: OrgPayrollTimePolicy, day: Date) -> OperativeDayBookingChoice {
        let weekend = weekendSettings(for: day, policy: policy)
        if weekend.allHoursAtMultiplierMode {
            return OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: policy.standardDayStart,
                workEndTime: policy.standardDayEnd,
                isBreakRemoved: true,
                otMultiplierOverride: weekend.allHoursMultiplier
            )
        }
        let start = weekend.customStandardStart ?? "07:30"
        let end = weekend.customStandardEnd ?? "13:00"
        return OperativeDayBookingChoice(
            timeSlot: .customHours,
            workStartTime: start,
            workEndTime: end,
            isBreakRemoved: true,
            otMultiplierOverride: nil
        )
    }
}

// Timestamp import for Firestore decode in same module as Firebase - use conditional
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif
