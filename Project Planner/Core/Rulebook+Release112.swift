//
//  Rulebook+Release112.swift
//  Project Planner
//
//  Typed wrappers for the functions rulebook 1.12.0 added (docs/RULEBOOK.md §4.4, §11, §16, §18): the forced app
//  update (`PLATFORM_CONFIG_APP_PATH`, `appUpdateRequired`), the 12-month leave year (`leaveYearEndMonth`,
//  `validateLeaveYearMonths`, `validateAnnualLeaveDefaults`, `LEAVE_YEAR_MONTHS_MESSAGE`) and the operative-only
//  invitation test (`invitationIsOperativeOnly`). Every answer comes from the packed script through
//  `CanonicalBusinessEngine.callJSON`; nothing is decided here.
//

import Foundation

extension CanonicalBusinessEngine {
    // MARK: - Forced app update (§18)

    /// `PLATFORM_CONFIG_APP_PATH` (`platformConfig/app`). Nil when the script did not answer.
    nonisolated static var platformConfigAppPath: String? {
        constant("PLATFORM_CONFIG_APP_PATH", as: String.self)
    }

    /// `appUpdateRequired({ platform: 'ios', runningBuild }, config)`. `config` is the `platformConfig/app` document
    /// as read (nil when missing). False when the script did not answer, so an unanswered check never blocks.
    nonisolated static func appUpdateRequired(runningBuild: Int?, config: [String: Any]?) -> Bool {
        var running: [String: Any] = ["platform": "ios"]
        running["runningBuild"] = runningBuild.map { $0 as Any } ?? NSNull()
        let configJSON: Any = config.map { FirebaseBackend.firestoreJSON($0) } ?? NSNull()
        return callJSON("appUpdateRequired", arguments: [running, configJSON]) as? Bool ?? false
    }

    // MARK: - Leave year (§4.4)

    /// `leaveYearEndMonth(startMonth)`: the month a leave year starting in `startMonth` ends (always 12 months).
    /// Nil when the script did not answer.
    nonisolated static func leaveYearEndMonth(startMonth: Int) -> Int? {
        (callJSON("leaveYearEndMonth", arguments: [startMonth]) as? NSNumber)?.intValue
    }

    /// The start month whose `leaveYearEndMonth` is `endMonth` (picking the end month moves the start, as web does).
    /// Searches the script's answers only; nil when none matches or the script did not answer.
    nonisolated static func leaveYearStartMonth(endingIn endMonth: Int) -> Int? {
        (1...12).first { leaveYearEndMonth(startMonth: $0) == endMonth }
    }

    /// `LEAVE_YEAR_MONTHS_MESSAGE`. Nil when the script did not answer.
    nonisolated static var leaveYearMonthsMessage: String? {
        constant("LEAVE_YEAR_MONTHS_MESSAGE", as: String.self)
    }

    /// `validateLeaveYearMonths(startMonth, endMonth)` for a person's leave year: nil when valid, else the message to
    /// show. When the script did not answer the save is refused with a retry message (the year was not checked).
    nonisolated static func leaveYearMonthsError(startMonth: Int, endMonth: Int) -> String? {
        leaveYearAnswer(callJSON("validateLeaveYearMonths", arguments: [startMonth, endMonth]))
    }

    /// `validateAnnualLeaveDefaults({ startMonth, endMonth })` for the organisation `annualLeaveDefaults` save.
    nonisolated static func annualLeaveDefaultsError(startMonth: Int, endMonth: Int) -> String? {
        leaveYearAnswer(callJSON("validateAnnualLeaveDefaults", arguments: [["startMonth": startMonth, "endMonth": endMonth]]))
    }

    nonisolated private static func leaveYearAnswer(_ answer: Any?) -> String? {
        if answer is NSNull { return nil }
        if let message = answer as? String { return message }
        return "Could not check the leave year. Try again."
    }

    // MARK: - Invitations (§11, §16)

    /// `invitationIsOperativeOnly(invitation)`: the invitation gives an operative and nothing more — the only kind a
    /// manager with operatives access (not an admin) may create. Nil when the script did not answer.
    nonisolated static func invitationIsOperativeOnly(_ invitation: [String: Any]) -> Bool? {
        callJSON("invitationIsOperativeOnly", arguments: [peopleDocumentJSON(invitation)]) as? Bool
    }
}

/// Add User / resend sign-up from a manager with operatives access who is not an admin: the security rules accept
/// only an operative-only invitation (`invitationIsOperativeOnly`), so the app refuses any other before writing.
nonisolated struct InvitationNotOperativeOnlyError: LocalizedError {
    var errorDescription: String? {
        "Managers can only invite operatives. Ask an admin to invite admins or managers."
    }
}

extension InvitationDocument {
    /// Throws `InvitationNotOperativeOnlyError` when the inviter is known not to be an admin and `fields` (the
    /// invitation about to be written) are not operative-only. `inviterIsAdmin` nil (unknown) leaves the decision
    /// to the security rules. An unanswered script check is not a refusal.
    nonisolated static func requireAllowed(_ fields: [String: Any], inviterIsAdmin: Bool?) throws {
        guard inviterIsAdmin == false else { return }
        if CanonicalBusinessEngine.invitationIsOperativeOnly(fields) == false {
            throw InvitationNotOperativeOnlyError()
        }
    }
}

extension InvitationDocument {
    /// The message to show instead of re-inviting `subject` (resend sign-up from Manage Users), or nil to go ahead:
    /// the invitation would carry the subject's admin / manager / operatives / operative-mode flags, and a signed-in
    /// inviter who is not an admin may write only an operative-only one (`invitationIsOperativeOnly`). Checked before
    /// the old links are marked used, so a refused resend leaves the current link working.
    @MainActor
    static func resendRefusal(subject: AppUser, inviter: AppUser?) -> String? {
        let draft: [String: Any] = [
            "email": subject.email,
            "organizationId": subject.organizationId,
            "permissions": [
                "adminAccess": subject.permissions.adminAccess,
                "manager": subject.permissions.manager,
                "operatives": subject.permissions.operatives,
                "operativeMode": subject.permissions.operativeMode,
            ],
        ]
        guard let fields = try? createFields(from: draft) else { return nil }
        do {
            try requireAllowed(fields, inviterIsAdmin: inviter.map { $0.isRosterAdmin })
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
