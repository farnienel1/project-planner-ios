//
//  Rulebook+CompanyActivity.swift
//  Project Planner
//
//  Rulebook 1.4.0 (docs/RULEBOOK.md §13): company activity notices (`operative_created`, `manager_created`,
//  `client_created`, `project_created`, `small_works_created`, `warning_removed`) go to the active admins outside
//  operative mode, never the actor, one row each (`companyActivityRecipients`); the Settings test notification is
//  `push_test` to its sender (`pushTestRecipients`). Every answer comes from the packed script through
//  `CanonicalBusinessEngine.callJSON` / `constant`; nothing is decided here.
//

import Foundation

extension CanonicalBusinessEngine {
    /// `companyActivityRecipients(actor, roster)`: every active admin and super admin outside operative mode,
    /// without the actor under any of their ids. Nil when the script did not answer (nothing is written then).
    nonisolated static func companyActivityRecipients(actor: Any, roster: [[String: Any]]) -> [String]? {
        callJSON("companyActivityRecipients", arguments: [actor, roster]) as? [String]
    }

    /// `pushTestRecipients(actor)`: the signed-in user only. Nil when the script did not answer.
    nonisolated static func pushTestRecipients(actor: Any) -> [String]? {
        callJSON("pushTestRecipients", arguments: [actor]) as? [String]
    }

    /// `notificationPushesToActor(type)`: only `push_test` reaches the person who wrote the row.
    nonisolated static func notificationPushesToActor(_ type: String) -> Bool? {
        callJSON("notificationPushesToActor", arguments: [type]) as? Bool
    }

    /// `COMPANY_ACTIVITY_NOTICE_TYPES`. Empty when the script did not answer.
    nonisolated static var companyActivityNoticeTypes: [String] {
        constant("COMPANY_ACTIVITY_NOTICE_TYPES", as: [String].self) ?? []
    }

    /// `PUSH_TEST_NOTICE_TYPE` ("push_test"). Nil when the script did not answer.
    nonisolated static var pushTestNoticeType: String? {
        constant("PUSH_TEST_NOTICE_TYPE", as: String.self)
    }
}
