//
//  Rulebook+BookingOvertimeRate.swift
//  Project Planner
//
//  RULEBOOK 1.32.0 (§2 "Booking screens offer exactly what the rule allows", §25 "The rate when booking", owner
//  decisions 4 Nov, decision A, review fix r274): typed wrappers for web `lib/canonical/staffAccess.ts`
//  (`canBookOtherLocationsFor`) and `lib/canonical/payeOvertime.ts` (`overtimeRateCreateControl`,
//  `overtimeMultiplierCreateFields`, `overtimeMultiplierMoveFields`), called through
//  `CanonicalBusinessEngine.callJSON`. Swift only builds the inputs and reads the answers. Nothing is decided here.
//

import Foundation

// MARK: - Types (the script's shapes)

/// `overtimeRateCreateControl` → `{ organizationMultiplier, prefill, options }`: the rate on a custom-hours create
/// screen, pre-filled with the organisation's rate for that day.
nonisolated struct OvertimeRateCreateControl: Codable, Hashable, Sendable {
    nonisolated struct Option: Codable, Hashable, Sendable, Identifiable {
        var value: Double
        var label: String
        var organization: Bool
        var id: Double { value }
    }

    var organizationMultiplier: Double
    var prefill: Double
    var options: [Option]
}

/// What `overtimeMultiplierMoveFields` says to do with the stored `otMultiplierOverride` of a booking that is saved
/// again or moved: leave it (`{}`), write this rate, or remove it (`{ otMultiplierOverride: null }`).
nonisolated enum OvertimeMultiplierFieldWrite: Hashable, Sendable {
    case keep
    case set(Double)
    case remove

    /// The booking's `otMultiplierOverride` after this write (`BookingWritePatch` writes the change: a value, or
    /// `FieldValue.delete()` for nil on an edit). A mapping of the script's answer, not a rule.
    func applied(to stored: Double?) -> Double? {
        switch self {
        case .keep: return stored
        case .set(let value): return value
        case .remove: return nil
        }
    }
}

// MARK: - Script calls

extension CanonicalBusinessEngine {
    /// RULEBOOK 1.32.0 §2 `canBookOtherLocationsFor(viewer, personUserIds)`: whether Office, Working from home, Site
    /// survey and the custom schedule items may be offered for every one of `personUserIds` (users ids). Admins anyone;
    /// a manager only themself under any of their ids; operatives never; an empty list or no viewer false. False when
    /// the script did not answer, so a place the rules would refuse is never offered.
    nonisolated static func canBookOtherLocationsFor(_ viewer: JobAccessViewer?, personUserIds: [String]) -> Bool {
        callJSON("canBookOtherLocationsFor", arguments: [RulebookJSON.orNull(viewer?.json), personUserIds]) as? Bool ?? false
    }

    /// RULEBOOK 1.32.0 §25 `overtimeRateCreateControl({ organization, dayKey, timeZone })` for the open organisation
    /// (`OrganizationRulebookContext.payrollPolicyDocument`) on `dayKey`. Nil when the script did not answer.
    nonisolated static func overtimeRateCreateControl(dayKey: String, organization: [String: Any]? = nil) -> OvertimeRateCreateControl? {
        let input: [String: Any] = [
            "organization": organization ?? OrganizationRulebookContext.payrollPolicyDocument ?? [:],
            "dayKey": dayKey,
            "timeZone": overtimeTimeZone,
        ]
        return RulebookJSON.decode(OvertimeRateCreateControl.self, from: callJSON("overtimeRateCreateControl", arguments: [input]))
    }

    /// `overtimeRateCreateControl` for the organisation-zone day of `day`.
    nonisolated static func overtimeRateCreateControl(on day: Date) -> OvertimeRateCreateControl? {
        overtimeRateCreateControl(dayKey: bookingDayKey(day))
    }

    /// RULEBOOK 1.32.0 §25 `overtimeMultiplierCreateFields({ chosen, organizationMultiplier })`: the
    /// `otMultiplierOverride` a new booking stores, or nil to store nothing (left at, or set back to, the
    /// organisation's rate, or a value outside the steps). Nil too when the script did not answer, so a booking never
    /// pins a rate on a missing answer.
    nonisolated static func overtimeMultiplierCreateFields(chosen: Double?, organizationMultiplier: Double) -> Double? {
        let input: [String: Any] = ["chosen": RulebookJSON.orNull(chosen), "organizationMultiplier": organizationMultiplier]
        guard let row = callJSON("overtimeMultiplierCreateFields", arguments: [input]) as? [String: Any] else { return nil }
        return (row["otMultiplierOverride"] as? NSNumber)?.doubleValue
    }

    /// The `otMultiplierOverride` a new booking on `day` stores for the rate `chosen` on a create screen (nil = left at
    /// the organisation's): `overtimeMultiplierCreateFields` against that day's `overtimeRateCreateControl`
    /// (`organizationMultiplier`), so each day of a multi-day request is compared with its own organisation rate.
    nonisolated static func createOtMultiplierOverride(chosen: Double?, on day: Date) -> Double? {
        guard let chosen, let control = overtimeRateCreateControl(on: day) else { return nil }
        return overtimeMultiplierCreateFields(chosen: chosen, organizationMultiplier: control.organizationMultiplier)
    }

    /// RULEBOOK 1.32.0 §25 (review fix r274) `overtimeMultiplierMoveFields({ stored, chosen, organizationMultiplier,
    /// newDocument })`. `rateShown` false is the script's `chosen: undefined` (the rate is not on screen: keep the
    /// stored one); otherwise `chosen` nil is the organisation's rate. Nil when the script did not answer.
    nonisolated static func overtimeMultiplierMoveFields(
        stored: Double?,
        chosen: Double?,
        rateShown: Bool,
        organizationMultiplier: Double,
        newDocument: Bool
    ) -> OvertimeMultiplierFieldWrite? {
        var input: [String: Any] = [
            "stored": RulebookJSON.orNull(stored),
            "organizationMultiplier": organizationMultiplier,
            "newDocument": newDocument,
        ]
        if rateShown { input["chosen"] = RulebookJSON.orNull(chosen) }
        guard let row = callJSON("overtimeMultiplierMoveFields", arguments: [input]) as? [String: Any] else { return nil }
        guard let value = row["otMultiplierOverride"] else { return .keep }
        if let number = value as? NSNumber { return .set(number.doubleValue) }
        return .remove
    }

    /// The `otMultiplierOverride` an existing booking on `day` keeps after a save of the same document (the Daily
    /// Overview booking sheet): `overtimeMultiplierMoveFields(newDocument: false)` against that day's organisation rate.
    /// When the script does not answer, the stored rate is kept (nothing is rewritten on a missing answer).
    nonisolated static func savedOtMultiplierOverride(stored: Double?, chosen: Double?, rateShown: Bool, on day: Date) -> Double? {
        guard let control = overtimeRateCreateControl(on: day),
              let write = overtimeMultiplierMoveFields(
                  stored: stored,
                  chosen: chosen,
                  rateShown: rateShown,
                  organizationMultiplier: control.organizationMultiplier,
                  newDocument: false
              ) else { return stored }
        return write.applied(to: stored)
    }
}
