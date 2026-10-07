//
//  PayrollRateResolver.swift
//  Project Planner
//
//  Shared day-rate / hourly-rate resolution with effective-from history for timesheets and weekly reports.
//

import Foundation

/// Firestore `payBasis`. A person is one or the other, never both.
/// `day` pays a share of the standard day. `hourly` pays each worked hour, including 15-minute blocks.
enum PayrollRateBasis: String, Codable, Equatable {
    case dayRate = "day"
    case hourly = "hourly"

    var choiceTitle: String {
        switch self {
        case .dayRate: return "Day rate"
        case .hourly: return "Hourly rate"
        }
    }

    var amountUnit: String {
        switch self {
        case .dayRate: return "/day"
        case .hourly: return "/hr"
        }
    }
}

enum PayrollRateCodec {
    /// One stored amount. Legacy documents that wrote the same number into both fields stay on day rate.
    /// A legacy `0` with no `payBasis` means “not set”, because older operative saves used 0 for a blank rate.
    static func exclusive(
        dayRate: Double?,
        hourlyRate: Double?,
        payBasis: PayrollRateBasis?,
        treatZeroAsUnset: Bool
    ) -> (basis: PayrollRateBasis, dayRate: Double?, hourlyRate: Double?) {
        func meaningful(_ value: Double?) -> Double? {
            guard let value else { return nil }
            if treatZeroAsUnset, payBasis == nil, value == 0 { return nil }
            return value
        }
        let day = meaningful(dayRate)
        let hourly = meaningful(hourlyRate)
        if let payBasis {
            switch payBasis {
            case .dayRate:
                return (.dayRate, day, nil)
            case .hourly:
                return (.hourly, nil, hourly)
            }
        }
        if let day, day > 0 {
            return (.dayRate, day, nil)
        }
        if let hourly, hourly > 0 {
            return (.hourly, nil, hourly)
        }
        if let day {
            return (.dayRate, day, nil)
        }
        return (.dayRate, nil, nil)
    }
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
        let raw: Double
        switch basis {
        case .dayRate:
            let rate = dayRate ?? 0
            raw = rate * (paidHours / max(standardDayHours, 0.01)) * otMultiplier
        case .hourly:
            let rate = hourlyRate ?? 0
            raw = rate * paidHours * otMultiplier
        }
        return (raw * 100).rounded() / 100
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

enum PayrollQuantityUnit: Equatable {
    case hours
    case days
}

/// One pay row. Hourly quantity is hours. Day-rate quantity is hours ÷ the organisation day length.
struct PayrollPayLineDisplay: Equatable {
    let rateTypeLabel: String
    let quantity: Double
    let unit: PayrollQuantityUnit
    let rate: Double?
    let pay: Double

    var quantityText: String {
        PayrollPayLineFormatter.quantityText(quantity, unit: unit)
    }

    var rateText: String {
        PayrollPayLineFormatter.rateText(rate, unit: unit)
    }

    var equationText: String {
        PayrollPayLineFormatter.equation(quantity: quantity, unit: unit, rate: rate, pay: pay)
    }
}

enum PayrollPayLineFormatter {
    /// Organisation day length. A shorter setting (for example 7.5) stays 7.5. Never lifted to 8.
    static func orgDayHours(_ standardPaidHours: Double) -> Double {
        max(standardPaidHours, 0.01)
    }

    static func line(
        basis: PayrollRateBasis,
        paidHours: Double,
        standardDayHours: Double,
        rate: Double?,
        pay: Double,
        isOvertime: Bool = false,
        otMultiplier: Double? = nil,
        isPaye: Bool = false
    ) -> PayrollPayLineDisplay {
        let standard = orgDayHours(standardDayHours)
        let unit: PayrollQuantityUnit = basis == .hourly ? .hours : .days
        let quantity = basis == .hourly ? paidHours : paidHours / standard
        let kind = basis == .hourly ? "Hourly" : "Day"
        let label: String
        if isPaye {
            label = "\(kind) PAYE"
        } else if isOvertime {
            label = "\(kind) \(overtimeLabel(otMultiplier))"
        } else {
            label = kind
        }
        return PayrollPayLineDisplay(
            rateTypeLabel: label,
            quantity: quantity,
            unit: unit,
            rate: rate,
            pay: pay
        )
    }

    /// Clock span such as 07:30–16:00. Day-slot names ("FULL DAY") are not a pay quantity.
    static func scheduleCaption(_ details: String) -> String? {
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil else { return nil }
        return trimmed
    }

    static func quantityText(_ quantity: Double, unit: PayrollQuantityUnit) -> String {
        let number = String(format: "%.2f", quantity)
        switch unit {
        case .hours:
            return abs(quantity - 1) < 0.001 ? "\(number) hour" : "\(number) hours"
        case .days:
            return abs(quantity - 1) < 0.001 ? "\(number) day" : "\(number) days"
        }
    }

    static func rateText(_ rate: Double?, unit: PayrollQuantityUnit, currency: String = "£") -> String {
        guard let rate else { return "" }
        let amount = "\(currency)\(String(format: "%.2f", rate))"
        switch unit {
        case .hours: return "\(amount)/hr"
        case .days: return "\(amount)/day"
        }
    }

    static func equation(
        quantity: Double,
        unit: PayrollQuantityUnit,
        rate: Double?,
        pay: Double,
        currency: String = "£"
    ) -> String {
        let qty = quantityText(quantity, unit: unit)
        let payText = "\(currency)\(String(format: "%.2f", pay))"
        let ratePart = rateText(rate, unit: unit, currency: currency)
        if ratePart.isEmpty { return "\(qty) = \(payText)" }
        return "\(qty) × \(ratePart) = \(payText)"
    }

    static func overtimeLabel(_ otMultiplier: Double?) -> String {
        guard let otMultiplier else { return "OT" }
        if abs(otMultiplier - otMultiplier.rounded()) < 0.001 {
            return "OT x\(Int(otMultiplier.rounded()))"
        }
        return String(format: "OT x%.1f", otMultiplier)
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

    /// Returns the history entry in effect on `day`.
    /// - `nil` means no history entry yet (fall back to live profile rates).
    /// - `0` is a valid explicit £0 rate.
    /// The entry's `payBasis` is the basis that was in force that day, not the person's current choice.
    ///
    /// `userIds` includes every `users` document for this person (invite id and auth id share one email).
    /// A day-rate row must not hide an hourly row on the same calendar day when the live profile is hourly:
    /// operative-roster saves used to stamp `payBasis: day` later the same day. A day-rate row on a later
    /// calendar day still switches the person back.
    static func historyEntry(
        history: OperativeDayRateHistoryCollection,
        userId: String?,
        operativeId: UUID?,
        on day: Date,
        userIds: [String] = [],
        livePrefersHourly: Bool = false
    ) -> OperativeDayRateHistoryEntry? {
        var seen = Set<UUID>()
        var entries: [OperativeDayRateHistoryEntry] = []
        var ids: [String] = []
        if let userId, !userId.isEmpty { ids.append(userId) }
        for extra in userIds where !extra.isEmpty && !ids.contains(extra) {
            ids.append(extra)
        }
        for uid in ids {
            for entry in history.mergedEntries(userId: uid, operativeId: nil) where seen.insert(entry.id).inserted {
                entries.append(entry)
            }
        }
        if let operativeId {
            for entry in history.mergedEntries(userId: nil, operativeId: operativeId) where seen.insert(entry.id).inserted {
                entries.append(entry)
            }
        }
        let dayStart = calendarDayStart(day)
        let applicable = entries.filter { calendarDayStart($0.effectiveAt) <= dayStart }
        let sorted = applicable.sorted { lhs, rhs in
            if lhs.effectiveAt != rhs.effectiveAt { return lhs.effectiveAt < rhs.effectiveAt }
            return lhs.createdAt < rhs.createdAt
        }
        guard let latest = sorted.last else { return nil }
        guard livePrefersHourly, latest.payBasis == .dayRate else { return latest }
        let latestHourly = sorted.last { entry in
            entry.payBasis == .hourly && calendarDayStart(entry.effectiveAt) <= dayStart
        }
        guard let latestHourly else { return latest }
        let hourlyDay = calendarDayStart(latestHourly.effectiveAt)
        let switchedBackToDay = sorted.contains { entry in
            entry.payBasis == .dayRate && calendarDayStart(entry.effectiveAt) > hourlyDay
        }
        return switchedBackToDay ? latest : latestHourly
    }

    static func rateFromHistory(
        history: OperativeDayRateHistoryCollection,
        userId: String?,
        operativeId: UUID?,
        on day: Date
    ) -> Double? {
        historyEntry(history: history, userId: userId, operativeId: operativeId, on: day)?.dayRate
    }

    /// Resolves payroll rate for timesheets / weekly report on a calendar day.
    /// PAYE days always return zero amounts while still showing hours in the UI.
    static func resolveForTimesheetDay(
        user: AppUser?,
        operative: Operative?,
        on day: Date,
        history: OperativeDayRateHistoryCollection,
        standardDayHours: Double = 8,
        userIds: [String] = [],
        livePrefersHourly: Bool = false,
        preferredHourlyRate: Double? = nil
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
            standardDayHours: standardDayHours,
            userIds: userIds,
            livePrefersHourly: livePrefersHourly,
            preferredHourlyRate: preferredHourlyRate
        )
    }

    /// Resolves payroll rate for a person on a calendar day, honouring effective-from history.
    static func resolve(
        user: AppUser?,
        operative: Operative?,
        on day: Date,
        history: OperativeDayRateHistoryCollection,
        standardDayHours: Double = 8,
        userIds: [String] = [],
        livePrefersHourly: Bool = false,
        preferredHourlyRate: Double? = nil
    ) -> ResolvedPayrollRate {
        let basis = payrollBasis(user: user, operative: operative)
        let prefersHourly = livePrefersHourly || (user?.hourlyRate != nil && user?.dayRate == nil) || preferredHourlyRate != nil
        let historical = historyEntry(
            history: history,
            userId: user?.id,
            operativeId: operative?.id,
            on: day,
            userIds: userIds,
            livePrefersHourly: prefersHourly
        )

        // Explicit history, including £0, wins over live roster rates.
        // Use the basis stored on that entry so a later switch to hourly does not reprice old days.
        if let historical {
            switch historical.payBasis {
            case .dayRate:
                return ResolvedPayrollRate(basis: .dayRate, dayRate: historical.dayRate, hourlyRate: nil)
            case .hourly:
                return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: historical.dayRate)
            }
        }

        if prefersHourly, let hourly = preferredHourlyRate ?? user?.hourlyRate ?? operative?.hourlyRate {
            return ResolvedPayrollRate(basis: .hourly, dayRate: nil, hourlyRate: hourly)
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
