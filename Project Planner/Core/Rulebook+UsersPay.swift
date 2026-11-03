//
//  Rulebook+UsersPay.swift
//  Project Planner
//
//  Typed wrappers for users, profile and pay (docs/RULEBOOK.md §8, §11, §12, §14, §16).
//  Every answer comes from the packed script (web lib/canonical/payRate.ts, payAccess.ts,
//  passwordPolicy.ts, leaveRequests.ts). Nothing is decided in Swift.
//

import Foundation

extension CanonicalBusinessEngine {
    /// Stored pay on a profile: `payBasis` (`day` | `hourly`) and exactly one amount.
    nonisolated struct CanonicalStoredPay: Equatable, Sendable {
        var payBasis: String?
        var dayRate: Double?
        var hourlyRate: Double?
    }

    /// `payRateHistoryWriteFields` result: one new `operativeDayRateHistory` row.
    nonisolated struct CanonicalPayRateHistoryWrite: Sendable {
        var userId: String
        var operativeId: String
        /// Nil on a "rate cleared" row (written as null).
        var dayRate: Double?
        /// Nil on a "rate cleared" row (written as null).
        var payBasis: String?
        /// Organisation-zone midnight of the effective day.
        var effectiveAt: Date
        var effectiveDayKey: String
    }

    /// `payRateHistoryWriteFields({ userId, operativeId, rate, payBasis, effective, timeZone })`. A nil `rate`
    /// records "rate cleared". Nil when there is no person id or the script did not answer.
    nonisolated static func payRateHistoryWriteFields(
        userId: String?,
        operativeId: String?,
        rate: Double?,
        payBasis: String?,
        effective: Date,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> CanonicalPayRateHistoryWrite? {
        let input: [String: Any] = [
            "userId": userId ?? "",
            "operativeId": operativeId ?? "",
            "rate": rate.map { $0 as Any } ?? NSNull(),
            "payBasis": payBasis ?? NSNull(),
            "effective": effective.timeIntervalSince1970 * 1000,
            "timeZone": timeZone,
        ]
        guard let row = callJSON("payRateHistoryWriteFields", arguments: [input]) as? [String: Any],
              let effectiveAtMs = jsonNumber(row["effectiveAtMs"]),
              let dayKey = row["effectiveDayKey"] as? String else { return nil }
        return CanonicalPayRateHistoryWrite(
            userId: row["userId"] as? String ?? "",
            operativeId: row["operativeId"] as? String ?? "",
            dayRate: jsonNumber(row["dayRate"]),
            payBasis: row["payBasis"] as? String,
            effectiveAt: Date(timeIntervalSince1970: effectiveAtMs / 1000),
            effectiveDayKey: dayKey
        )
    }

    /// RULEBOOK 1.10.0 §8 `payRateChangeWrites`: the history rows a pay change writes in the profile's batch, or the
    /// refusal message (`PAY_HISTORY_NOT_LOADED_MESSAGE` when `history` is nil — never treated as empty). Previous and
    /// next are `{ rate, payBasis }` (`day` / `hourly`). Nil when the script did not answer.
    nonisolated static func payRateChangeWrites(
        userId: String?,
        operativeId: String?,
        previous: (rate: Double?, payBasis: String?),
        next: (rate: Double?, payBasis: String?),
        historyRowIds: [String]?,
        effective: Date,
        seedEffective: Date?,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> (rows: [CanonicalPayRateHistoryWrite], refusal: String?)? {
        let input: [String: Any] = [
            "userId": userId ?? NSNull(),
            "operativeId": operativeId ?? NSNull(),
            "previousProfile": ["rate": previous.rate ?? NSNull(), "payBasis": previous.payBasis ?? NSNull()],
            "nextProfile": ["rate": next.rate ?? NSNull(), "payBasis": next.payBasis ?? NSNull()],
            "history": historyRowIds.map { ids in ids.map { ["id": $0] } } ?? NSNull(),
            "effectiveDayKey": effective.timeIntervalSince1970 * 1000,
            "seedEffective": seedEffective.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull(),
            "timeZone": timeZone,
        ]
        guard let result = callJSON("payRateChangeWrites", arguments: [input]) as? [String: Any] else { return nil }
        guard result["ok"] as? Bool == true else {
            return ([], result["message"] as? String ?? "Pay history could not be loaded. Check your connection and save again.")
        }
        let rows = (result["rows"] as? [[String: Any]] ?? []).compactMap { row -> CanonicalPayRateHistoryWrite? in
            guard let effectiveAtMs = jsonNumber(row["effectiveAtMs"]), let dayKey = row["effectiveDayKey"] as? String else { return nil }
            return CanonicalPayRateHistoryWrite(
                userId: row["userId"] as? String ?? "",
                operativeId: row["operativeId"] as? String ?? "",
                dayRate: jsonNumber(row["dayRate"]),
                payBasis: row["payBasis"] as? String,
                effectiveAt: Date(timeIntervalSince1970: effectiveAtMs / 1000),
                effectiveDayKey: dayKey
            )
        }
        return (rows, nil)
    }

    /// `payRateOnDay` result.
    nonisolated struct CanonicalPayRateOnDay: Equatable, Sendable {
        /// `day` or `hourly`.
        var payBasis: String
        /// Per day or per hour by `payBasis`. 0 for PAYE. Nil when no rate is set.
        var rate: Double?
        var isPaye: Bool
        var hasRate: Bool
        /// `paye`, `history`, `profile` or `none`.
        var source: String
    }

    /// One `operativeDayRateHistory` row as `payRateOnDay` reads it.
    nonisolated struct CanonicalPayHistoryRow: Sendable {
        var id: String
        var userId: String?
        var operativeId: String?
        /// Amount per day or per hour (the field keeps its old name for both bases). Nil on a "rate cleared" row.
        var dayRate: Double?
        /// Nil on old rows, which count as `day`, and on a "rate cleared" row.
        var payBasis: String?
        var effectiveAt: Date
        var createdAt: Date
    }

    private nonisolated static func jsonNumber(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        return value as? Double
    }

    private nonisolated static func storedPay(from row: Any?) -> CanonicalStoredPay? {
        guard let row = row as? [String: Any] else { return nil }
        return CanonicalStoredPay(
            payBasis: row["payBasis"] as? String,
            dayRate: jsonNumber(row["dayRate"]),
            hourlyRate: jsonNumber(row["hourlyRate"])
        )
    }

    private nonisolated static func payProfileJSON(
        id: String?,
        payBasis: String?,
        dayRate: Double?,
        hourlyRate: Double?
    ) -> [String: Any] {
        [
            "id": id ?? NSNull(),
            "payBasis": payBasis ?? NSNull(),
            "dayRate": dayRate.map { $0.isFinite ? $0 : 0 } ?? NSNull(),
            "hourlyRate": hourlyRate.map { $0.isFinite ? $0 : 0 } ?? NSNull()
        ]
    }

    /// `readStoredRates`: the stored pay read the canonical way (no basis and no amount above 0 is unset).
    nonisolated static func readStoredRates(payBasis: String?, dayRate: Double?, hourlyRate: Double?) -> CanonicalStoredPay? {
        storedPay(from: callJSON(
            "readStoredRates",
            arguments: [payProfileJSON(id: nil, payBasis: payBasis, dayRate: dayRate, hourlyRate: hourlyRate)]
        ))
    }

    /// `exclusiveRates`: the one basis and one amount a rate save writes (the other amount is removed).
    nonisolated static func exclusiveRates(payBasis: String?, dayRate: Double?, hourlyRate: Double?) -> CanonicalStoredPay? {
        let input: [String: Any] = [
            "payBasis": payBasis ?? NSNull(),
            "dayRate": dayRate ?? NSNull(),
            "hourlyRate": hourlyRate ?? NSNull()
        ]
        return storedPay(from: callJSON("exclusiveRates", arguments: [input]))
    }

    /// `payRateOnDay` for one person on one organisation-zone day key.
    /// `user` nil means no `users` document (operative catalogue row only).
    nonisolated static func payRateOnDay(
        userId: String?,
        userPay: CanonicalStoredPay?,
        employment: (type: String?, transitionFrom: String?, effectiveAt: Date?)?,
        operativeId: String?,
        operativePay: CanonicalStoredPay?,
        history: [CanonicalPayHistoryRow],
        userIds: [String] = [],
        operativeIds: [String] = [],
        dayKey: String,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        person: [String: Any]? = nil,
        roster: [[String: Any]]? = nil
    ) -> CanonicalPayRateOnDay? {
        var input: [String: Any] = [
            "dayKey": dayKey,
            "timeZone": timeZone,
            "userIds": userIds,
            "operativeIds": operativeIds
        ]
        // RULEBOOK 1.10.0 §8: `person` + `roster` — history under every id of the person (`personIdSet`) counts.
        if let person { input["person"] = person }
        if let roster { input["roster"] = roster }
        if let userPay {
            var user = payProfileJSON(
                id: userId,
                payBasis: userPay.payBasis,
                dayRate: userPay.dayRate,
                hourlyRate: userPay.hourlyRate
            )
            if let employment {
                user["employmentType"] = employment.type ?? NSNull()
                user["employmentTypeTransitionFrom"] = employment.transitionFrom ?? NSNull()
                user["employmentTypeEffectiveAt"] = employment.effectiveAt.map { isoString(from: $0) } ?? NSNull()
            }
            input["user"] = user
        }
        if let operativePay {
            input["operative"] = payProfileJSON(
                id: operativeId,
                payBasis: operativePay.payBasis,
                dayRate: operativePay.dayRate,
                hourlyRate: operativePay.hourlyRate
            )
        }
        input["history"] = history.map { row -> [String: Any] in
            [
                "id": row.id,
                "userId": row.userId ?? NSNull(),
                "operativeId": row.operativeId ?? NSNull(),
                "dayRate": row.dayRate.map { ($0.isFinite ? $0 : 0) as Any } ?? NSNull(),
                "payBasis": row.payBasis ?? NSNull(),
                "effectiveAt": isoString(from: row.effectiveAt),
                "createdAt": isoString(from: row.createdAt)
            ]
        }
        guard let result = callJSON("payRateOnDay", arguments: [input]) as? [String: Any],
              let basis = result["payBasis"] as? String else { return nil }
        return CanonicalPayRateOnDay(
            payBasis: basis,
            rate: jsonNumber(result["rate"]),
            isPaye: (result["isPaye"] as? Bool) ?? false,
            hasRate: (result["hasRate"] as? Bool) ?? false,
            source: (result["source"] as? String) ?? "none"
        )
    }

    /// `canChangePersonPay(writer, subject)` (§8 "Who may change pay").
    nonisolated static func canChangePersonPay(
        writerUserId: String?,
        writerIsPlatformOwner: Bool,
        writerIsAdmin: Bool,
        writerIsManager: Bool,
        writerHasOperativesAccess: Bool,
        writerIsOperativeMode: Bool,
        subjectUserId: String?,
        subjectIsOperative: Bool
    ) -> Bool {
        let writer: [String: Any] = [
            "userId": writerUserId ?? NSNull(),
            "isPlatformOwner": writerIsPlatformOwner,
            "isAdmin": writerIsAdmin,
            "isManager": writerIsManager,
            "hasOperativesAccess": writerHasOperativesAccess,
            "isOperativeMode": writerIsOperativeMode
        ]
        let subject: [String: Any] = [
            "userId": subjectUserId ?? NSNull(),
            "isOperative": subjectIsOperative
        ]
        return (callJSON("canChangePersonPay", arguments: [writer, subject]) as? Bool) ?? false
    }

    /// `lineManagerIds(user)`: `assignedManagerUserIds`, else the legacy single id; empty when `hasNoLineManager`.
    nonisolated static func lineManagerIds(
        assignedManagerUserIds: [String],
        assignedManagerUserId: String?,
        hasNoLineManager: Bool
    ) -> [String]? {
        let user: [String: Any] = [
            "assignedManagerUserIds": assignedManagerUserIds,
            "assignedManagerUserId": assignedManagerUserId ?? NSNull(),
            "hasNoLineManager": hasNoLineManager
        ]
        return callJSON("lineManagerIds", arguments: [user]) as? [String]
    }

    /// `passwordMinLength({ developerAccount })`: 8, or 10 for the platform owner's developer account.
    nonisolated static func passwordMinLength(developerAccount: Bool) -> Int? {
        (callJSON("passwordMinLength", arguments: [["developerAccount": developerAccount]]) as? NSNumber)?.intValue
    }

    /// `passwordMinLength({ email })`: the platform owner's email (`isPlatformOwnerEmail`) needs the developer minimum.
    nonisolated static func passwordMinLength(email: String?) -> Int? {
        (callJSON("passwordMinLength", arguments: [["email": email ?? ""]]) as? NSNumber)?.intValue
    }

    /// `passwordPolicyError(password, { email })`: the account's email decides the minimum.
    nonisolated static func passwordPolicyError(_ password: String, email: String?) -> PasswordPolicyCheck {
        let options: [String: Any] = ["email": email ?? ""]
        guard let result = callJSON("passwordPolicyError", arguments: [password, options]) else {
            return .unavailable
        }
        if let message = result as? String { return .rejected(message) }
        return .accepted
    }

    /// `isPlatformOwnerEmail(email)`: the platform owner's developer account, ignoring case and spaces.
    nonisolated static func isPlatformOwnerEmail(_ email: String?) -> Bool {
        callJSON("isPlatformOwnerEmail", arguments: [email ?? ""]) as? Bool ?? false
    }

    /// `passwordPolicyError(password, { developerAccount })`: nil when long enough, else the message to show.
    /// Returns nil only when the script answered null; if the script did not answer at all, the caller gets
    /// `.unavailable` so it does not let a password through unchecked.
    nonisolated static func passwordPolicyError(_ password: String, developerAccount: Bool) -> PasswordPolicyCheck {
        let options: [String: Any] = ["developerAccount": developerAccount]
        guard let result = callJSON("passwordPolicyError", arguments: [password, options]) else {
            return .unavailable
        }
        if let message = result as? String { return .rejected(message) }
        return .accepted
    }

    nonisolated enum PasswordPolicyCheck: Equatable, Sendable {
        case accepted
        case rejected(String)
        /// The packed script did not answer.
        case unavailable
    }
}

/// Inputs the pay and password rules need from an account. Swift only maps fields; the rules are above.
extension AppUser {
    /// The platform owner's developer account: `isPlatformOwnerEmail` from the packed script.
    static func isPlatformOwnerEmail(_ email: String?) -> Bool {
        CanonicalBusinessEngine.isPlatformOwnerEmail(email)
    }

    /// Stored pay as `readStoredRates` / `payRateOnDay` read it.
    var canonicalStoredPay: CanonicalBusinessEngine.CanonicalStoredPay {
        CanonicalBusinessEngine.CanonicalStoredPay(payBasis: payBasis, dayRate: dayRate, hourlyRate: hourlyRate)
    }

    /// Subject side of `canChangePersonPay`: operative mode or the operative role.
    var isPaySubjectOperative: Bool {
        permissions.operativeMode || role == .operative
    }
}
