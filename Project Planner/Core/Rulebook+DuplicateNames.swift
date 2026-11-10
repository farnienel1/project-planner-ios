//
//  Rulebook+DuplicateNames.swift
//  Project Planner
//
//  Rulebook 1.36.0 (docs/RULEBOOK.md §11 "Duplicate names", owner decision 10 Nov): before Add user saves (the Ghost
//  account path too), warn when the first and last name match a person already in the organisation. Web
//  `lib/canonical/duplicateUserNames.ts`, called through `CanonicalBusinessEngine`:
//    - `usersWithSameName(roster, { firstName, lastName }, { claimedEmails })` — the matching people, one per person;
//    - `DUPLICATE_NAME_WARNING_TITLE` / `_MESSAGE`, `DUPLICATE_NAME_CONFIRM_LABEL`, `DUPLICATE_NAME_CANCEL_LABEL`.
//  A warning only. Nothing is compared here. When the script does not answer, Add user refuses to create the user —
//  invite and ghost alike — with `DuplicateNameRulebook.unavailableMessage` and saves nothing (owner decision 10 Nov,
//  consistent with 7 Nov: a ghost is never created when the rules cannot load).
//

import Foundation

/// One `usersWithSameName` row.
nonisolated struct RulebookSameNamePerson: Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    /// '' for a ghost or anyone without an email.
    var email: String
    /// `admin` | `manager` | `operative` (`permissionLevelOf`).
    var level: String
    var active: Bool
    /// `active` | `inactive` | `pending` (`rosterSegment`).
    var segment: String
    var ghost: Bool
}

extension CanonicalBusinessEngine {
    nonisolated static var duplicateNameWarningTitle: String {
        constant("DUPLICATE_NAME_WARNING_TITLE", as: String.self) ?? "Name already in use"
    }

    nonisolated static var duplicateNameWarningMessage: String {
        constant("DUPLICATE_NAME_WARNING_MESSAGE", as: String.self)
            ?? "A user with this name already exists. Are you sure you want to add this user?"
    }

    nonisolated static var duplicateNameConfirmLabel: String {
        constant("DUPLICATE_NAME_CONFIRM_LABEL", as: String.self) ?? "Add anyway"
    }

    nonisolated static var duplicateNameCancelLabel: String {
        constant("DUPLICATE_NAME_CANCEL_LABEL", as: String.self) ?? "Cancel"
    }

    /// `usersWithSameName(roster, { firstName, lastName }, { claimedEmails })`. `roster` is every users document of the
    /// organisation (`DuplicateNameRulebook.roster`); `claimedEmails` nil = the `userEmails` claims did not load. Nil
    /// when the script did not answer.
    nonisolated static func usersWithSameName(
        roster: [[String: Any]],
        firstName: String,
        lastName: String,
        claimedEmails: [String]?
    ) -> [RulebookSameNamePerson]? {
        let draft: [String: Any] = ["firstName": firstName, "lastName": lastName]
        let options: [String: Any] = ["claimedEmails": claimedEmails.map { $0 as Any } ?? NSNull()]
        guard let rows = callJSON("usersWithSameName", arguments: [roster, draft, options]) as? [[String: Any]] else {
            return nil
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return RulebookSameNamePerson(
                id: id,
                displayName: row["displayName"] as? String ?? "",
                email: row["email"] as? String ?? "",
                level: row["level"] as? String ?? "manager",
                active: row["active"] as? Bool ?? false,
                segment: row["segment"] as? String ?? "pending",
                ghost: row["ghost"] as? Bool ?? false
            )
        }
    }
}

/// The roster rows `usersWithSameName` reads: the people payload (`RulebookPeople.person`: ids, email, level flags,
/// `passwordSet`, `isActive`, `ghost`) plus the stored names and phone (`rosterSegment` reads them).
enum DuplicateNameRulebook {
    /// Shown when the rules cannot run on this phone; nothing is saved (owner decision 10 Nov, judgement call 4).
    static let unavailableMessage = "Couldn't check this user — try again."

    /// What Add user does with a `usersWithSameName` answer.
    enum Decision: Equatable {
        /// No one shares the name (or the person already chose Add anyway): save.
        case save
        /// Show the duplicate-name warning with these people.
        case warn([RulebookSameNamePerson])
        /// The script did not answer: refuse with this message, save nothing.
        case refuse(String)
    }

    /// `answer` is `CanonicalBusinessEngine.usersWithSameName(...)` (nil = the script did not answer). `nameConfirmed`
    /// is true after Add anyway. The rules must answer even then, so a save is never made without them.
    static func decision(answer: [RulebookSameNamePerson]?, nameConfirmed: Bool) -> Decision {
        guard let answer else { return .refuse(unavailableMessage) }
        if nameConfirmed || answer.isEmpty { return .save }
        return .warn(answer)
    }


    static func row(_ user: AppUser) -> [String: Any] {
        var row = RulebookPeople.person(user)
        row["firstName"] = user.firstName
        row["surname"] = user.surname
        if let mobile = user.mobileNumber { row["mobileNumber"] = mobile }
        return row
    }

    static func roster(_ users: [AppUser]) -> [[String: Any]] {
        users.map { row($0) }
    }
}
