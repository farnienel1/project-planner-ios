import Foundation

/// Edit user's annual leave allowance draft, and the figures it was opened with (17 Nov, review of #258).
///
/// The editor compares its draft with the values it was **seeded** from — never with the roster row as it reads now —
/// and saves only the figures the person changed (rulebook §1 "Never re-save what you didn't change"). So:
///   - a stored days-per-year of 0 that nobody touched never blocks Save ("Enter a valid annual leave allowance");
///   - figures read before the organisation's leave defaults arrived (`annualLeaveDefaultsPending`, §8) are never
///     written when the row is re-read with the defaults: an unchanged figure is not written at all, and the save
///     still drops any pending figure the editor did not change (`annualLeavePendingOmitFields`).
struct AnnualLeaveEntitlementDraft: Equatable {
    static let daysField = "annualLeaveDaysPerYear"
    static let startMonthField = "annualLeaveYearStartMonth"
    static let endMonthField = "annualLeaveYearEndMonth"
    static let carriesOverField = "annualLeaveCarriesOver"

    var daysText: String
    var startMonth: Int
    var endMonth: Int
    var carriesOver: Bool

    /// The draft for `user` as Edit user shows it (`formatDays` is the editor's own number format).
    static func seeded(from user: AppUser, formatDays: (Double) -> String) -> AnnualLeaveEntitlementDraft {
        AnnualLeaveEntitlementDraft(
            daysText: formatDays(user.annualLeaveDaysPerYear),
            startMonth: user.annualLeaveYearStartMonth,
            endMonth: user.annualLeaveYearEndMonth,
            carriesOver: user.annualLeaveCarriesOver
        )
    }

    /// A typed days figure, or nil when it is not a number. Commas read as a decimal point.
    static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The users-document fields this draft changed against `seed` (the values the editor was opened with).
    func editedFields(since seed: AnnualLeaveEntitlementDraft) -> [String] {
        var fields: [String] = []
        let typed = daysText.trimmingCharacters(in: .whitespacesAndNewlines)
        let opened = seed.daysText.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed != opened {
            // "25" and "25.0" are the same figure; anything else the person typed is a change.
            let a = Self.number(typed)
            let b = Self.number(opened)
            if a == nil || b == nil || abs((a ?? 0) - (b ?? 0)) > 0.0001 { fields.append(Self.daysField) }
        }
        if startMonth != seed.startMonth { fields.append(Self.startMonthField) }
        if endMonth != seed.endMonth { fields.append(Self.endMonthField) }
        if carriesOver != seed.carriesOver { fields.append(Self.carriesOverField) }
        return fields
    }

    /// The fields a save writes: the edited ones, less any figure `annualLeavePendingOmitFields` leaves out while the
    /// person's figures are still the rulebook default (`annualLeaveDefaultsPending`).
    static func fieldsToWrite(edited: [String], user: AppUser) -> Set<String> {
        let omit = Set(CanonicalBusinessEngine.annualLeavePendingOmitFields(
            pending: user.annualLeaveDefaultsPending,
            storedKeys: user.annualLeaveStoredKeys,
            edited: edited
        ) ?? (user.annualLeaveDefaultsPending ? CanonicalBusinessEngine.userAnnualLeaveFigureFields : []))
        return Set(edited).subtracting(omit)
    }
}
