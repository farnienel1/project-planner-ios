//
//  Rulebook+OrganizationDeletion.swift
//  Project Planner
//
//  Rulebook 1.15.0 (docs/RULEBOOK.md §11, §20): a deleted organisation (`organizationDeletionState`,
//  `organizationDeletedMessage`) and "Delete my account" (`accountDeletionPath`,
//  `organizationDeleteConfirmationError`). iOS never shows deletion or billing controls or prices: a scheduled or
//  erased organisation is a full-screen message with Sign out (and Switch organisation when the person belongs to
//  another). Answers come from the packed script; nothing is decided here.
//

import Foundation

/// `organizationDeletionState(org, now)`.
nonisolated enum RulebookOrganizationDeletionState: Equatable, Sendable {
    case active
    case scheduled(eraseAfterMs: Double?, due: Bool, restoreBy: String)
    case erased

    var isLocked: Bool { self != .active }
}

/// `accountDeletionPath(viewer, roster, org)`.
nonisolated enum RulebookAccountDeletionPath: String, Sendable {
    case delete
    case handoverRequired = "handover_required"
    case deleteWithCompany = "delete_with_company"
}

extension CanonicalBusinessEngine {
    /// `organizationDeletionState(org, now)` for the organisation document's `deletion` map. Active when the script
    /// did not answer (the security rules still lock a scheduled organisation).
    nonisolated static func organizationDeletionState(deletion: [String: Any]?, now: Date = Date()) -> RulebookOrganizationDeletionState {
        guard let deletion else { return .active }
        let org: [String: Any] = ["deletion": deletion]
        guard let row = callJSON("organizationDeletionState", arguments: [org, (now.timeIntervalSince1970 * 1000).rounded()]) as? [String: Any] else {
            return .active
        }
        switch row["state"] as? String {
        case "scheduled":
            return .scheduled(
                eraseAfterMs: (row["eraseAfterMs"] as? NSNumber)?.doubleValue,
                due: row["due"] as? Bool ?? false,
                restoreBy: row["restoreBy"] as? String ?? "super_admin"
            )
        case "erased":
            return .erased
        default:
            return .active
        }
    }

    /// `organizationDeletedMessage(eraseAfterMs, timeZone)`.
    nonisolated static func organizationDeletedMessage(eraseAfterMs: Double?, timeZone: String) -> String {
        let erase: Any = eraseAfterMs.map { $0 as Any } ?? NSNull()
        return callJSON("organizationDeletedMessage", arguments: [erase, timeZone]) as? String
            ?? "This organisation has been deleted and will be erased."
    }

    /// `accountDeletionPath(viewer, roster, org)`. `delete` when the script did not answer (the server decides again).
    nonisolated static func accountDeletionPath(
        viewer: [String: Any],
        roster: [[String: Any]],
        org: [String: Any]
    ) -> RulebookAccountDeletionPath? {
        (callJSON("accountDeletionPath", arguments: [viewer, roster, org]) as? String).flatMap(RulebookAccountDeletionPath.init(rawValue:))
    }

    /// `organizationDeleteConfirmationError({ organizationName, typedName, typedConfirmation })`: nil when both match.
    nonisolated static func organizationDeleteConfirmationError(
        organizationName: String,
        typedName: String,
        typedConfirmation: String
    ) -> String? {
        let input: [String: Any] = [
            "organizationName": organizationName,
            "typedName": typedName,
            "typedConfirmation": typedConfirmation,
        ]
        let answer = callJSON("organizationDeleteConfirmationError", arguments: [input])
        if answer is NSNull { return nil }
        return answer as? String ?? "Type the company name exactly as it is shown."
    }

    /// `ACCOUNT_HANDOVER_REQUIRED_MESSAGE`.
    nonisolated static var accountHandoverRequiredMessage: String {
        constant("ACCOUNT_HANDOVER_REQUIRED_MESSAGE", as: String.self)
            ?? "You are the super admin. Make another admin the super admin before you delete your account."
    }

    /// `ACCOUNT_DELETE_WITH_COMPANY_MESSAGE`.
    nonisolated static var accountDeleteWithCompanyMessage: String {
        constant("ACCOUNT_DELETE_WITH_COMPANY_MESSAGE", as: String.self)
            ?? "You are the only member of this organisation. Deleting your account also deletes the organisation. Type the company name and DELETE to confirm."
    }
}

extension Organization {
    /// `organizationDeletionState` for this organisation's live `deletion` map.
    var deletionState: RulebookOrganizationDeletionState {
        CanonicalBusinessEngine.organizationDeletionState(deletion: OrganizationBillingMap.dictionary(json: deletionJSON))
    }

    /// `organizationDeletedMessage` in the organisation's business time zone.
    var deletedMessage: String {
        let eraseAfter: Double? = {
            if case .scheduled(let ms, _, _) = deletionState { return ms }
            return nil
        }()
        let zone = CanonicalBusinessEngine.callJSON("organizationTimeZone", arguments: [countryCode]) as? String ?? "Europe/London"
        return CanonicalBusinessEngine.organizationDeletedMessage(eraseAfterMs: eraseAfter, timeZone: zone)
    }
}
