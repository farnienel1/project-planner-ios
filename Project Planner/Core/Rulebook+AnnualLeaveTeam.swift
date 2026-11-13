//
//  Rulebook+AnnualLeaveTeam.swift
//  Project Planner
//
//  RULEBOOK 1.40.0 (§4.4, §9; owner decisions 11 Nov; web `lib/canonical/annualLeaveTeam.ts` and
//  `annualLeaveAdjustments.ts`). Annual leave → Team (who a viewer's list holds and whether the tab shows) and manual
//  annual-leave adjustments. Every answer comes from the packed script through `CanonicalBusinessEngine.callJSON`;
//  Swift only maps the stores into the script's plain rows and reads the answer back. Nothing is decided here.
//

import Foundation

/// One `annualLeaveAdjustments/{id}` document as `parseAnnualLeaveAdjustmentDocument` reads it.
nonisolated struct AnnualLeaveAdjustmentRecord: Identifiable, Hashable, Sendable {
    let id: String
    let userId: String
    /// Days added (above 0) or taken off (below 0), half-day steps.
    let days: Double
    let reason: String
    /// The leave year it belongs to (the year's first day, `annualLeaveBalance(...).yearKey`).
    let yearKey: String
    /// The writer's users id; screens show their roster name (`annualLeaveAdjustmentAuthorName`), never a stored name.
    let createdBy: String
    let createdAtMs: Double?

    /// The `{ days, yearKey }` row `annualLeaveBalance` reads.
    var balanceRow: [String: Any] { ["days": days, "yearKey": yearKey] }
}

extension CanonicalBusinessEngine {
    nonisolated private static let annualLeaveTeamMemo = RulebookAnswerMemo<String, [String]>(limit: 64)

    // MARK: - Team (§9)

    /// `annualLeaveTeamPeople({ viewer, people, roster })`: the ids (`people[].id`) on the viewer's Team list, in input
    /// order. Nil when the script did not answer.
    nonisolated static func annualLeaveTeamPeopleIds(
        viewer: [String: Any],
        people: [[String: Any]],
        roster: [[String: Any]]
    ) -> [String]? {
        let input: [String: Any] = ["viewer": viewer, "people": people, "roster": roster]
        guard let key = rulebookMemoKey(input) else { return nil }
        return annualLeaveTeamMemo.value(for: key) {
            guard let rows = callJSON("annualLeaveTeamPeople", arguments: [input]) as? [[String: Any]] else { return nil }
            return rows.compactMap { $0["id"] as? String }
        }
    }

    /// `annualLeaveTeamTabVisible({ viewer, people, roster })`. Nil when the script did not answer.
    nonisolated static func annualLeaveTeamTabVisible(
        viewer: [String: Any],
        people: [[String: Any]],
        roster: [[String: Any]]
    ) -> Bool? {
        callJSON("annualLeaveTeamTabVisible", arguments: [["viewer": viewer, "people": people, "roster": roster]]) as? Bool
    }

    /// `annualLeaveTeamPersonIsCurrent(person)`: not deleted, inactive or a pending invite. False when the script did not
    /// answer.
    nonisolated static func annualLeaveTeamPersonIsCurrent(_ person: [String: Any]) -> Bool {
        callJSON("annualLeaveTeamPersonIsCurrent", arguments: [person]) as? Bool ?? false
    }

    /// `annualLeaveTeamEmptyMessage(viewer)`. Nil when the script did not answer.
    nonisolated static func annualLeaveTeamEmptyMessage(viewer: [String: Any]) -> String? {
        callJSON("annualLeaveTeamEmptyMessage", arguments: [viewer]) as? String
    }

    // MARK: - Adjustments (§4.4)

    /// `ANNUAL_LEAVE_ADJUSTMENTS_COLLECTION`.
    nonisolated static var annualLeaveAdjustmentsCollection: String {
        constant("ANNUAL_LEAVE_ADJUSTMENTS_COLLECTION", as: String.self) ?? "annualLeaveAdjustments"
    }

    /// `ANNUAL_LEAVE_ADJUSTMENT_NOTE`: what an adjustment does, shown above the form.
    nonisolated static var annualLeaveAdjustmentNote: String {
        constant("ANNUAL_LEAVE_ADJUSTMENT_NOTE", as: String.self)
            ?? "Adds or takes off days for this leave year only. It does not carry over, and it counts only while the person is PAYE."
    }

    /// `annualLeaveAdjustmentValidationError({ days, reason })`: nil when it may be saved, else the message. When the
    /// script did not answer, a generic refusal (nothing is saved).
    nonisolated static func annualLeaveAdjustmentValidationError(days: Double, reason: String) -> String? {
        let answer = callJSON("annualLeaveAdjustmentValidationError", arguments: [["days": days, "reason": reason]])
        if answer is NSNull { return nil }
        if let message = answer as? String { return message }
        return "The adjustment could not be checked. Try again."
    }

    /// `annualLeaveAdjustmentCreateFields(input)`: the stored fields of a new adjustment (the app adds `createdAt` and
    /// write metadata). Nil when the input is refused or the script did not answer.
    nonisolated static func annualLeaveAdjustmentCreateFields(
        userId: String,
        days: Double,
        reason: String,
        yearKey: String,
        createdBy: String,
        allowedYearKeys: [String]
    ) -> [String: Any]? {
        let input: [String: Any] = [
            "userId": userId,
            "days": days,
            "reason": reason,
            "yearKey": yearKey,
            "createdBy": createdBy,
            "allowedYearKeys": allowedYearKeys,
        ]
        return callJSON("annualLeaveAdjustmentCreateFields", arguments: [input]) as? [String: Any]
    }

    /// `parseAnnualLeaveAdjustmentDocument(docId, data)`. Nil when the reader refuses it or the script did not answer.
    nonisolated static func parseAnnualLeaveAdjustmentDocument(docId: String, data: [String: Any]) -> AnnualLeaveAdjustmentRecord? {
        guard let row = callJSON("parseAnnualLeaveAdjustmentDocument", arguments: [docId, data]) as? [String: Any],
              let id = row["id"] as? String,
              let userId = row["userId"] as? String,
              let days = (row["days"] as? NSNumber)?.doubleValue,
              let yearKey = row["yearKey"] as? String else { return nil }
        return AnnualLeaveAdjustmentRecord(
            id: id,
            userId: userId,
            days: days,
            reason: row["reason"] as? String ?? "",
            yearKey: yearKey,
            createdBy: row["createdBy"] as? String ?? "",
            createdAtMs: (row["createdAtMs"] as? NSNumber)?.doubleValue
        )
    }

    /// `annualLeaveAdjustmentLabel(days)`: "+2 days", "−0.5 day".
    nonisolated static func annualLeaveAdjustmentLabel(_ days: Double) -> String {
        callJSON("annualLeaveAdjustmentLabel", arguments: [days]) as? String ?? String(days)
    }

    /// `canAdjustAnnualLeave(viewer, subject, roster)`: an admin, or one of the subject's line managers; never the
    /// subject. False when the script did not answer.
    nonisolated static func canAdjustAnnualLeave(viewer: [String: Any], subject: [String: Any], roster: [[String: Any]]) -> Bool {
        callJSON("canAdjustAnnualLeave", arguments: [viewer, subject, roster]) as? Bool ?? false
    }

    /// `canViewAnnualLeaveAdjustments(viewer, subject, roster)`: the subject and everyone who may adjust them. False
    /// when the script did not answer.
    nonisolated static func canViewAnnualLeaveAdjustments(viewer: [String: Any], subject: [String: Any], roster: [[String: Any]]) -> Bool {
        callJSON("canViewAnnualLeaveAdjustments", arguments: [viewer, subject, roster]) as? Bool ?? false
    }

    /// `annualLeaveAdjustedNoticeText({ personName, actorName, days, reason })`: the inbox title and message (pushed),
    /// and the reason as the row's inbox-only `detail` (never pushed, review r306 #10).
    nonisolated static func annualLeaveAdjustedNoticeText(
        personName: String,
        actorName: String,
        days: Double,
        reason: String
    ) -> (title: String, message: String, detail: String?) {
        let input: [String: Any] = ["personName": personName, "actorName": actorName, "days": days, "reason": reason]
        guard let row = callJSON("annualLeaveAdjustedNoticeText", arguments: [input]) as? [String: Any],
              let title = row["title"] as? String,
              let message = row["message"] as? String else {
            return ("Annual leave adjusted", "\(actorName) adjusted \(personName)'s annual leave.", nil)
        }
        return (title, message, row["detail"] as? String)
    }

    /// `leaveDecisionRequester({ userId, operativeId }, roster)` (RULEBOOK 1.40.0, owner decision 13 Nov, item 17): the
    /// roster person a leave decision is judged against — the users row whose id is the record's userId (else
    /// operativeId), else `{ id }` with no line manager (admins only). Nil without either id or when the script did
    /// not answer.
    nonisolated static func leaveDecisionRequester(userId: String?, operativeId: String?, roster: [[String: Any]]) -> [String: Any]? {
        var request: [String: Any] = [:]
        if let userId, !userId.isEmpty { request["userId"] = userId }
        if let operativeId, !operativeId.isEmpty { request["operativeId"] = operativeId }
        guard !request.isEmpty else { return nil }
        return callJSON("leaveDecisionRequester", arguments: [request, roster]) as? [String: Any]
    }

    /// `annualLeaveAdjustmentAuthorName(adjustment, roster)`: who made it, by `createdBy` on the roster ("Someone" when
    /// not found or the script did not answer).
    nonisolated static func annualLeaveAdjustmentAuthorName(createdBy: String, roster: [[String: Any]]) -> String {
        callJSON("annualLeaveAdjustmentAuthorName", arguments: [["createdBy": createdBy], roster]) as? String ?? "Someone"
    }

    /// `annualLeaveEmploymentInput({ person, payProfile, privatePay, payProfileRead })`: the employment-type fields of
    /// the balance from the person's pay record. `.some(nil)` means unreadable (count the whole year); nil when the
    /// script did not answer.
    nonisolated static func annualLeaveEmploymentInput(
        person: [String: Any],
        payProfileFields: [String: Any]?,
        privatePay: Bool,
        payProfileRead: Bool
    ) -> AnnualLeaveEmployment?? {
        var input: [String: Any] = ["person": person, "privatePay": privatePay, "payProfileRead": payProfileRead]
        input["payProfile"] = payProfileFields.map { ["fields": $0] as Any } ?? NSNull()
        let answer = callJSON("annualLeaveEmploymentInput", arguments: [input])
        if answer is NSNull { return .some(nil) }
        guard let row = answer as? [String: Any] else { return nil }
        let effective = (row["employmentTypeEffectiveAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            ?? (row["employmentTypeEffectiveAt"] as? String).flatMap(Self.leaveEmploymentInstant)
        return .some(AnnualLeaveEmployment(
            employmentType: row["employmentType"] as? String ?? "",
            transitionFrom: row["employmentTypeTransitionFrom"] as? String,
            effectiveAt: effective
        ))
    }

    /// An ISO instant the script returned (with or without fractional seconds).
    nonisolated private static func leaveEmploymentInstant(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// `annualLeaveBalanceNotes(balance, { showsEmploymentType })`: the notes under a balance. They name the employment
    /// type only when the viewer may see the person's pay (`canViewPersonPay`).
    nonisolated static func annualLeaveBalanceNotes(
        hasAllowance: Bool,
        proRata: Bool,
        notCountedTaken: Double,
        showsEmploymentType: Bool
    ) -> (proRata: String?, notCounted: String?, noAllowance: String?) {
        let balance: [String: Any] = ["hasAllowance": hasAllowance, "proRata": proRata, "notCountedTaken": notCountedTaken]
        guard let row = callJSON("annualLeaveBalanceNotes", arguments: [balance, ["showsEmploymentType": showsEmploymentType]]) as? [String: Any] else {
            return (nil, nil, nil)
        }
        return (row["proRata"] as? String, row["notCounted"] as? String, row["noAllowance"] as? String)
    }
}

// MARK: - Team rows

extension AnnualLeavePersonBuilder {
    /// A users document as the Team rule reads it: the rulebook person plus the names, sign-up and ghost flags.
    static func teamCandidate(_ user: AppUser) -> [String: Any] {
        var row = RulebookPeople.person(user)
        row["firstName"] = user.firstName
        row["surname"] = user.surname
        return row
    }

    /// A catalogue `operatives` row with no account (`catalogueOperative`).
    static func teamCandidate(_ operative: Operative) -> [String: Any] {
        [
            "id": operative.documentId,
            "email": operative.email,
            "firstName": operative.firstName,
            "surname": operative.lastName,
            "isActive": operative.isActive,
            "catalogueOperative": true,
        ]
    }
}

// MARK: - Balance with employment type and adjustments (§4.4)

/// The employment-type fields `annualLeaveBalance` reads (RULEBOOK 1.40.0): the allowance applies only on PAYE days
/// (`employmentTypeOnDay`, effective-dated).
nonisolated struct AnnualLeaveEmployment: Hashable, Sendable {
    var employmentType: String
    var transitionFrom: String?
    var effectiveAt: Date?

    var json: [String: Any] {
        var row: [String: Any] = ["employmentType": employmentType]
        if let transitionFrom { row["employmentTypeTransitionFrom"] = transitionFrom }
        if let effectiveAt { row["employmentTypeEffectiveAt"] = (effectiveAt.timeIntervalSince1970 * 1000).rounded() }
        return row
    }
}

@MainActor
extension AnnualLeaveEmployment {
    /// The person's stored type and any scheduled change.
    init(_ user: AppUser) {
        self.init(
            employmentType: user.employmentType.rawValue,
            transitionFrom: user.employmentTypeTransitionFrom?.rawValue,
            effectiveAt: user.employmentTypeEffectiveAt
        )
    }
}

/// `annualLeaveBalance` as the 1.40.0 screens read it.
nonisolated struct RulebookAnnualLeaveBalance: Hashable, Sendable {
    var hasAllowance: Bool
    var startDayKey: String
    var endDayKey: String
    var yearKey: String
    /// Every approved / pending day this leave year (the Holiday report figure).
    var taken: Double
    var pending: Double
    var usedThisYear: Double
    var yearEntitlement: Double
    var proRata: Bool
    var carriedForward: Double
    var yearAllowance: Double?
    /// Leave on PAYE days only (what comes out of the allowance).
    var allowanceTaken: Double
    var allowancePending: Double
    var adjustmentDays: Double
    var allowanceBeforeAdjustments: Double
    /// May be below zero.
    var remaining: Double?
    /// The figures screens show (review r306 #11): the rulebook's sums, never a subtraction in Swift.
    var shownTaken: Double
    var shownPending: Double
    var notCountedTaken: Double
    var notCountedPending: Double
}

extension CanonicalBusinessEngine {
    nonisolated private static let leaveBalanceMemo = RulebookAnswerMemo<String, RulebookAnnualLeaveBalance>(limit: 256)

    /// RULEBOOK 1.40.0 `annualLeaveBalance(input)` with `employment` and `adjustments`. Nil when the script did not
    /// answer.
    nonisolated static func annualLeaveBalanceFull(
        annualLeaveEnabled: Bool?,
        daysPerYear: Double?,
        startMonth: Int?,
        endMonth: Int?,
        orgDaysPerYear: Double?,
        orgStartMonth: Int?,
        orgEndMonth: Int?,
        carriesOver: Bool?,
        yearAllowance: Double?,
        yearAllowanceKey: String?,
        bookings: [CanonicalLeaveBooking],
        onDayKey: String,
        nonWorkingDayKeys: [String],
        employmentStartDayKey: String?,
        maxCarryOverDays: Double?,
        employment: AnnualLeaveEmployment?,
        adjustments: [AnnualLeaveAdjustmentRecord],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookAnnualLeaveBalance? {
        var input: [String: Any] = [
            "onDayKey": onDayKey,
            "timeZone": timeZone,
            "nonWorkingDayKeys": nonWorkingDayKeys,
            "bookings": bookings.map { booking -> [String: Any] in
                var row: [String: Any] = ["startDayKey": booking.startDayKey, "endDayKey": booking.endDayKey]
                if let slot = booking.timeSlot { row["timeSlot"] = slot }
                if let status = booking.status { row["status"] = status }
                return row
            },
            "adjustments": adjustments.map(\.balanceRow),
        ]
        if let annualLeaveEnabled { input["annualLeaveEnabled"] = annualLeaveEnabled }
        if let daysPerYear, daysPerYear.isFinite { input["daysPerYear"] = daysPerYear }
        if let startMonth { input["startMonth"] = startMonth }
        if let endMonth { input["endMonth"] = endMonth }
        if let orgDaysPerYear, orgDaysPerYear.isFinite { input["orgDaysPerYear"] = orgDaysPerYear }
        if let orgStartMonth { input["orgStartMonth"] = orgStartMonth }
        if let orgEndMonth { input["orgEndMonth"] = orgEndMonth }
        if let carriesOver { input["carriesOver"] = carriesOver }
        if let yearAllowance, yearAllowance.isFinite { input["yearAllowance"] = yearAllowance }
        if let yearAllowanceKey { input["yearAllowanceKey"] = yearAllowanceKey }
        if let employmentStartDayKey, !employmentStartDayKey.isEmpty { input["employmentStartDayKey"] = employmentStartDayKey }
        if let maxCarryOverDays, maxCarryOverDays.isFinite { input["maxCarryOverDays"] = maxCarryOverDays }
        if let employment { input["employment"] = employment.json }
        guard let key = rulebookMemoKey(input) else { return nil }
        return leaveBalanceMemo.value(for: key) {
            guard let row = callJSON("annualLeaveBalance", arguments: [input]) as? [String: Any] else { return nil }
            func number(_ name: String) -> Double { (row[name] as? NSNumber)?.doubleValue ?? 0 }
            func optional(_ name: String) -> Double? { row[name] is NSNull ? nil : (row[name] as? NSNumber)?.doubleValue }
            return RulebookAnnualLeaveBalance(
                hasAllowance: row["hasAllowance"] as? Bool ?? false,
                startDayKey: row["startDayKey"] as? String ?? "",
                endDayKey: row["endDayKey"] as? String ?? "",
                yearKey: row["yearKey"] as? String ?? "",
                taken: number("taken"),
                pending: number("pending"),
                usedThisYear: number("usedThisYear"),
                yearEntitlement: number("yearEntitlement"),
                proRata: row["proRata"] as? Bool ?? false,
                carriedForward: number("carriedForward"),
                yearAllowance: optional("yearAllowance"),
                allowanceTaken: number("allowanceTaken"),
                allowancePending: number("allowancePending"),
                adjustmentDays: number("adjustmentDays"),
                allowanceBeforeAdjustments: number("allowanceBeforeAdjustments"),
                remaining: optional("remaining"),
                shownTaken: number("shownTaken"),
                shownPending: number("shownPending"),
                notCountedTaken: number("notCountedTaken"),
                notCountedPending: number("notCountedPending")
            )
        }
    }
}

/// A notification that opens one person's annual leave page (`annualLeavePerson`): the person's users id, taken once
/// by Annual leave → Team when it appears.
enum AnnualLeaveDeepLinkContext {
    static var pendingPersonUserId: String?

    static func takePendingPersonUserId() -> String? {
        defer { pendingPersonUserId = nil }
        return pendingPersonUserId
    }
}
