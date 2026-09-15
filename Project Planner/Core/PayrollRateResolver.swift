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
            return rate * (paidHours / max(standardDayHours, 0.01)) * otMultiplier
        case .hourly:
            let rate = hourlyRate ?? 0
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
            guard let dayRate else { return nil }
            return "\(currencySymbol)\(String(format: "%.2f", dayRate))/day"
        case .hourly:
            guard let hourlyRate else { return nil }
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
            if user.dayRate != nil { return .dayRate }
            if user.hourlyRate != nil { return .hourly }
        }
        if let operative {
            if operative.dayRate != nil { return .dayRate }
            if operative.hourlyRate != nil { return .hourly }
        }
        return .dayRate
    }

    /// Returns the history rate in effect on `day`.
    /// - `nil` means no history entry yet (fall back to live profile rates).
    /// - `0` is a valid explicit £0 day rate.
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

        // Explicit history, including £0, wins over live roster rates.
        if let historical {
            switch basis {
            case .dayRate:
                return ResolvedPayrollRate(basis: .dayRate, dayRate: historical, hourlyRate: nil)
            case .hourly:
                return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: historical)
            }
        }

        switch basis {
        case .dayRate:
            if let dayRate = user?.dayRate ?? operative?.dayRate {
                return ResolvedPayrollRate(basis: .dayRate, dayRate: dayRate, hourlyRate: nil)
            }
            if let hourly = user?.hourlyRate ?? operative?.hourlyRate {
                return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: hourly)
            }
            return ResolvedPayrollRate(basis: .dayRate, dayRate: nil, hourlyRate: nil)

        case .hourly:
            if let hourly = user?.hourlyRate ?? operative?.hourlyRate {
                return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: hourly)
            }
            if let dayRate = user?.dayRate ?? operative?.dayRate {
                let hourly = dayRate / max(standardDayHours, 0.01)
                return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: hourly)
            }
            return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: nil)
        }
    }

    /// Current profile-card rate: prefer the signed-in account fields only so a blank user rate
    /// does not inherit a stale linked operative roster rate.
    static func resolveCurrentProfileRate(
        user: AppUser?,
        operative: Operative?,
        standardDayHours: Double = 8
    ) -> ResolvedPayrollRate {
        if let user {
            let hasDay = user.dayRate != nil
            let hasHourly = user.hourlyRate != nil
            if hasHourly && !hasDay {
                return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: user.hourlyRate)
            }
            if hasDay {
                return ResolvedPayrollRate(basis: .dayRate, dayRate: user.dayRate, hourlyRate: nil)
            }
            // Explicitly blank on the account — do not fall back to roster.
            return ResolvedPayrollRate(basis: .dayRate, dayRate: nil, hourlyRate: nil)
        }
        return resolve(user: nil, operative: operative, on: Date(), history: .empty, standardDayHours: standardDayHours)
    }
}
