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
        case .dayRate: return (dayRate ?? 0) > 0
        case .hourly: return (hourlyRate ?? 0) > 0
        }
    }

    /// Pro-rata day-rate equivalent (hourly × standard paid hours when paid hourly).
    func effectiveDayRate(standardDayHours: Double) -> Double {
        switch basis {
        case .dayRate:
            return dayRate ?? 0
        case .hourly:
            return (hourlyRate ?? 0) * max(standardDayHours, 0.01)
        }
    }

    func payForHours(_ paidHours: Double, standardDayHours: Double, otMultiplier: Double = 1) -> Double {
        guard paidHours > 0 else { return 0 }
        switch basis {
        case .dayRate:
            let rate = dayRate ?? 0
            guard rate > 0 else { return 0 }
            return rate * (paidHours / max(standardDayHours, 0.01)) * otMultiplier
        case .hourly:
            let rate = hourlyRate ?? 0
            guard rate > 0 else { return 0 }
            return rate * paidHours * otMultiplier
        }
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

    func displayRateLabel(currencySymbol: String = "£") -> String? {
        switch basis {
        case .dayRate:
            guard let dayRate, dayRate > 0 else { return nil }
            return "\(currencySymbol)\(String(format: "%.2f", dayRate))/day"
        case .hourly:
            guard let hourlyRate, hourlyRate > 0 else { return nil }
            return "\(currencySymbol)\(String(format: "%.2f", hourlyRate))/hr"
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

enum PayrollRateResolver {
    static func calendarDayStart(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    static func payrollBasis(user: AppUser?, operative: Operative?) -> PayrollRateBasis {
        if let user {
            let hasDay = (user.dayRate ?? 0) > 0
            let hasHourly = (user.hourlyRate ?? 0) > 0
            if hasHourly && !hasDay { return .hourly }
            if hasDay { return .dayRate }
        }
        if let operative {
            if (operative.dayRate ?? 0) > 0 { return .dayRate }
            if (operative.hourlyRate ?? 0) > 0 { return .hourly }
        }
        return .dayRate
    }

    static func rateFromHistory(
        history: OperativeDayRateHistoryCollection,
        userId: String?,
        operativeId: UUID?,
        on day: Date
    ) -> Double? {
        let merged = history.mergedEntries(userId: userId, operativeId: operativeId)
        let dayStart = calendarDayStart(day)
        return merged.last(where: { calendarDayStart($0.effectiveAt) <= dayStart })?.dayRate
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
        if let user, user.employmentType(on: day) == .paye {
            let basis = payrollBasis(user: user, operative: operative)
            return ResolvedPayrollRate(basis: basis, dayRate: nil, hourlyRate: nil)
        }
        return resolve(
            user: user,
            operative: operative,
            on: day,
            history: history,
            standardDayHours: standardDayHours
        )
    }

    /// Resolves payroll rate for a person on a calendar day, honouring effective-from history.
    static func resolve(
        user: AppUser?,
        operative: Operative?,
        on day: Date,
        history: OperativeDayRateHistoryCollection,
        standardDayHours: Double = 8
    ) -> ResolvedPayrollRate {
        let basis = payrollBasis(user: user, operative: operative)
        let historical = rateFromHistory(
            history: history,
            userId: user?.id,
            operativeId: operative?.id,
            on: day
        )

        switch basis {
        case .dayRate:
            if let historical, historical > 0 {
                return ResolvedPayrollRate(basis: .dayRate, dayRate: historical, hourlyRate: nil)
            }
            if let dayRate = user?.dayRate ?? operative?.dayRate, dayRate > 0 {
                return ResolvedPayrollRate(basis: .dayRate, dayRate: dayRate, hourlyRate: nil)
            }
            if let hourly = user?.hourlyRate ?? operative?.hourlyRate, hourly > 0 {
                return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: hourly)
            }
            return ResolvedPayrollRate(basis: .dayRate, dayRate: nil, hourlyRate: nil)

        case .hourly:
            if let historical, historical > 0 {
                return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: historical)
            }
            if let hourly = user?.hourlyRate ?? operative?.hourlyRate, hourly > 0 {
                return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: hourly)
            }
            if let dayRate = user?.dayRate ?? operative?.dayRate, dayRate > 0 {
                let hourly = dayRate / max(standardDayHours, 0.01)
                return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: hourly)
            }
            return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: nil)
        }
    }
}
