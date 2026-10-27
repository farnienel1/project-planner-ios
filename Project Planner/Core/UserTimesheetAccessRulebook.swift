//
//  UserTimesheetAccessRulebook.swift
//  Project Planner
//
//  Whose timesheets a viewer sees on User Timesheets comes from the rulebook's
//  `userTimesheetSubjects` (web `lib/canonical`): admins see every active
//  timesheet user, managers see the active people they line-manage under any
//  of their ids. Until the packed script exports that function, `isAvailable`
//  is false and UserStore keeps the screen's previous behaviour.
//

import Foundation

enum UserTimesheetAccessRulebook {
    static let functionName = "userTimesheetSubjects"

    /// True once the packed `canonical-business.js` exports `userTimesheetSubjects`.
    static var isAvailable: Bool {
        CanonicalBusinessEngine.exportKind(functionName) == "function"
    }

    static func rolePayload(_ user: AppUser) -> [String: Any] {
        let role = UserStore.staffAccountRole(for: user)
        return [
            "isSuperAdmin": role.isSuperAdmin,
            "isAdmin": role.isAdmin,
            "isManager": role.isManager,
            "isOperativeMode": role.isOperativeMode
        ]
    }

    static func payload(viewer: AppUser, members: [AppUser]) -> [String: Any] {
        [
            "viewer": [
                "id": viewer.id,
                "formerIds": viewer.formerUserIds,
                "aliasIds": viewer.sameEmailUserIds,
                "role": rolePayload(viewer)
            ] as [String: Any],
            "members": members.map { member -> [String: Any] in
                [
                    "id": member.id,
                    "email": member.email,
                    "isActive": member.isActive,
                    "role": rolePayload(member),
                    "assignedManagerUserIds": member.assignedManagerUserIds,
                    "assignedManagerUserId": member.assignedManagerUserId ?? NSNull(),
                    "hasNoLineManager": member.hasNoLineManager
                ]
            }
        ]
    }

    /// Member ids the viewer may open, in roster order. Nil when the script did not answer.
    static func subjectUserIds(viewer: AppUser, members: [AppUser]) -> [String]? {
        guard isAvailable,
              let rows = CanonicalBusinessEngine.objectRows(
                function: functionName,
                payload: payload(viewer: viewer, members: members)
              ) else {
            return nil
        }
        return rows.compactMap { $0["userId"] as? String }
    }
}
