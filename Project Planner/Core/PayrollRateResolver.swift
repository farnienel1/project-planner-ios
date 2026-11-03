//
//  PayrollRateResolver.swift
//  Project Planner
//
//  Shared day-rate / hourly-rate resolution with effective-from history for timesheets and weekly reports.
//

import Foundation

enum PayrollRateBasis: Equatable {
    case dayRate
    case hourly
}

struct ResolvedPayrollRate: Equatable {
    let basis: PayrollRateBasis
    let dayRate: Double?
    let hourlyRate: Double?

    var hasRate: Bool {
        switch basis {
        case .dayRate: return dayRate != nil
        case .hourly: return hourlyRate != nil
        }
    }

    /// Pro-rata day-rate equivalent: a whole organisation day's pay (`payForHours` for `orgDayHours`).
    func effectiveDayRate(standardDayHours: Double) -> Double {
        switch basis {
        case .dayRate:
            return dayRate ?? 0
        case .hourly:
            let dayHours = CanonicalBusinessEngine.callJSON("orgDayHours", arguments: [standardDayHours]) as? Double ?? standardDayHours
            return payForHours(dayHours, standardDayHours: standardDayHours)
        }
    }

    /// RULEBOOK 1.10.0 §8: `payForHours({ payBasis, dayRate, hourlyRate, paidHours, standardDayHours, otMultiplier })`
    /// — hourly rate × hours, or day rate × (hours ÷ `orgDayHours`), × multiplier, `roundPennies`. 0 when the script
    /// did not answer (no Swift copy of the sum).
    func payForHours(_ paidHours: Double, standardDayHours: Double, otMultiplier: Double = 1) -> Double {
        payForHoursIfCalculated(paidHours, standardDayHours: standardDayHours, otMultiplier: otMultiplier) ?? 0
    }

    /// `payForHours`, or nil when the script did not answer — a pay that could not be calculated, never £0
    /// (money audit #15). Callers that total pay use this and say "could not calculate".
    func payForHoursIfCalculated(_ paidHours: Double, standardDayHours: Double, otMultiplier: Double = 1) -> Double? {
        let input: [String: Any] = [
            "payBasis": basis == .hourly ? "hourly" : "day",
            "dayRate": dayRate.map { ($0.isFinite ? $0 : 0) as Any } ?? NSNull(),
            "hourlyRate": hourlyRate.map { ($0.isFinite ? $0 : 0) as Any } ?? NSNull(),
            "paidHours": paidHours.isFinite ? paidHours : 0,
            "standardDayHours": standardDayHours.isFinite ? standardDayHours : 0,
            "otMultiplier": otMultiplier.isFinite ? otMultiplier : 1,
        ]
        return (CanonicalBusinessEngine.callJSON("payForHours", arguments: [input]) as? NSNumber)?.doubleValue
    }

    func splitPay(
        normalHours: Double,
        otHours: Double,
        standardDayHours: Double,
        otMultiplier: Double
    ) -> (normal: Double, overtime: Double) {
        let normal = payForHours(normalHours, standardDayHours: standardDayHours)
        let overtime = payForHours(otHours, standardDayHours: standardDayHours, otMultiplier: otMultiplier)
        return (normal, overtime)
    }

    /// `formatMoney` in the organisation currency, then `/day` or `/hr` (RULEBOOK §4.2).
    func displayRateLabel(currencyCode: String? = nil) -> String? {
        switch basis {
        case .dayRate:
            guard let dayRate else { return nil }
            return "\(OrgMoney.format(dayRate, currencyCode: currencyCode))/day"
        case .hourly:
            guard let hourlyRate else { return nil }
            return "\(OrgMoney.format(hourlyRate, currencyCode: currencyCode))/hr"
        }
    }

    /// Value shown in weekly report “Rate” column.
    func reportRateValue() -> Double? {
        switch basis {
        case .dayRate: return dayRate
        case .hourly: return hourlyRate
        }
    }
}

/// Thin wrappers over `payRateOnDay` (RULEBOOK §8 "Rate on a day"). The rule lives in the packed
/// script; these keep the Swift signatures timesheets, the weekly report and profile cards call.
enum PayrollRateResolver {
    /// Organisation-zone midnight of `date` (RULEBOOK §1: one business time zone).
    static func calendarDayStart(_ date: Date, calendar: Calendar = OrganizationRulebookContext.calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Live profile basis as `readStoredRates` reads it: the user document first, then the operative row.
    static func payrollBasis(user: AppUser?, operative: Operative?) -> PayrollRateBasis {
        let resolved = resolve(user: user, operative: operative, on: Date(), history: .empty)
        return resolved.basis
    }

    private static func historyRows(
        _ history: OperativeDayRateHistoryCollection,
        userId: String?,
        operativeId: UUID?
    ) -> [CanonicalBusinessEngine.CanonicalPayHistoryRow] {
        // RULEBOOK 1.10.0 §8: the whole loaded history; `payRateOnDay` keeps the person's rows (every id of the
        // person through `person` + `roster`, and the operative row). No iOS pre-filter.
        _ = (userId, operativeId)
        return history.allEntries.map { entry in
            CanonicalBusinessEngine.CanonicalPayHistoryRow(
                id: entry.documentId ?? entry.id.uuidString,
                userId: entry.userId,
                // The in-app operative UUID, the same form `operativeIds` passes (rows are already this person's).
                operativeId: entry.operativeId?.uuidString,
                dayRate: entry.dayRate,
                payBasis: entry.payBasis,
                effectiveAt: entry.effectiveAt,
                createdAt: entry.createdAt
            )
        }
    }

    /// `payRateOnDay` for the person on the organisation-zone day of `day`.
    /// `includeEmployment` false leaves out the PAYE check (the caller decides PAYE itself).
    static func rateOnDay(
        user: AppUser?,
        operative: Operative?,
        on day: Date,
        history: OperativeDayRateHistoryCollection,
        includeEmployment: Bool
    ) -> CanonicalBusinessEngine.CanonicalPayRateOnDay? {
        let userIds = ([user?.id].compactMap { $0 } + (user?.formerUserIds ?? []) + (user?.sameEmailUserIds ?? []))
            .filter { !$0.isEmpty }
        let operativeIds = [operative?.id.uuidString].compactMap { $0 }
        var employment: (type: String?, transitionFrom: String?, effectiveAt: Date?)? = nil
        if includeEmployment, let user {
            employment = (
                type: user.employmentType.rawValue,
                transitionFrom: user.employmentTypeTransitionFrom?.rawValue,
                effectiveAt: user.employmentTypeEffectiveAt
            )
        }
        return CanonicalBusinessEngine.payRateOnDay(
            userId: user?.id,
            userPay: user?.canonicalStoredPay,
            employment: employment,
            operativeId: operative?.id.uuidString,
            operativePay: operative.map {
                CanonicalBusinessEngine.CanonicalStoredPay(payBasis: $0.payBasis, dayRate: $0.dayRate, hourlyRate: $0.hourlyRate)
            },
            history: historyRows(history, userId: user?.id, operativeId: operative?.id),
            userIds: userIds,
            operativeIds: operativeIds,
            dayKey: OrganizationRulebookContext.dayKey(day),
            person: user.map { RulebookPeople.person($0) },
            roster: RulebookRosterSnapshot.roster
        )
    }

    private static func resolved(from rate: CanonicalBusinessEngine.CanonicalPayRateOnDay?) -> ResolvedPayrollRate {
        guard let rate else {
            return ResolvedPayrollRate(basis: .dayRate, dayRate: nil, hourlyRate: nil)
        }
        if rate.payBasis == "hourly" {
            return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: rate.rate)
        }
        return ResolvedPayrollRate(basis: .dayRate, dayRate: rate.rate, hourlyRate: nil)
    }

    /// Returns the history rate in effect on `day` (`payRateOnDay` with `source == "history"`).
    /// - `nil` means no history entry yet (fall back to live profile rates).
    /// - `0` is a valid explicit zero rate.
    static func rateFromHistory(
        history: OperativeDayRateHistoryCollection,
        userId: String?,
        operativeId: UUID?,
        on day: Date
    ) -> Double? {
        let result = CanonicalBusinessEngine.payRateOnDay(
            userId: userId,
            userPay: nil,
            employment: nil,
            operativeId: operativeId?.uuidString,
            operativePay: nil,
            history: historyRows(history, userId: userId, operativeId: operativeId),
            userIds: [userId].compactMap { $0 },
            operativeIds: [operativeId?.uuidString].compactMap { $0 },
            dayKey: OrganizationRulebookContext.dayKey(day)
        )
        guard let result, result.source == "history" else { return nil }
        return result.rate
    }

    /// Resolves payroll rate for timesheets / weekly report on a calendar day.
    /// PAYE days always return zero amounts while still showing hours in the UI.
    static func resolveForTimesheetDay(
        user: AppUser?,
        operative: Operative?,
        on day: Date,
        history: OperativeDayRateHistoryCollection,
        standardDayHours: Double = 8
    ) -> ResolvedPayrollRate {
        let rate = rateOnDay(user: user, operative: operative, on: day, history: history, includeEmployment: true)
        if let rate, rate.isPaye {
            // Same shape as before: no amount, so the line keeps its hours and pays nothing.
            let basis: PayrollRateBasis = rate.payBasis == "hourly" ? .hourly : .dayRate
            return ResolvedPayrollRate(basis: basis, dayRate: nil, hourlyRate: nil)
        }
        return resolved(from: rate)
    }

    /// Resolves payroll rate for a person on a calendar day, honouring effective-from history.
    static func resolve(
        user: AppUser?,
        operative: Operative?,
        on day: Date,
        history: OperativeDayRateHistoryCollection,
        standardDayHours: Double = 8
    ) -> ResolvedPayrollRate {
        resolved(from: rateOnDay(user: user, operative: operative, on: day, history: history, includeEmployment: false))
    }

    /// Current profile-card rate: the account's stored pay (`readStoredRates`) only, so a blank user rate
    /// does not inherit a stale linked operative roster rate.
    static func resolveCurrentProfileRate(
        user: AppUser?,
        operative: Operative?,
        standardDayHours: Double = 8
    ) -> ResolvedPayrollRate {
        if let user {
            guard let stored = CanonicalBusinessEngine.readStoredRates(
                payBasis: user.payBasis,
                dayRate: user.dayRate,
                hourlyRate: user.hourlyRate
            ) else {
                return ResolvedPayrollRate(basis: .dayRate, dayRate: nil, hourlyRate: nil)
            }
            if stored.payBasis == "hourly" {
                return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: stored.hourlyRate)
            }
            return ResolvedPayrollRate(basis: .dayRate, dayRate: stored.dayRate, hourlyRate: nil)
        }
        return resolve(user: nil, operative: operative, on: Date(), history: .empty, standardDayHours: standardDayHours)
    }
}
