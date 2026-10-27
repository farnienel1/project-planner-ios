//
//  MaterialOrderRecipientsRulebook.swift
//  Project Planner
//
//  Who gets the "New material order" inbox row comes from the rulebook's
//  `materialOrderRecipients` (web `lib/canonical`): the active managers assigned
//  to that project or small works, never the person who added the line. Until
//  the packed script exports that function, `recipientUserIds` is nil and
//  NotificationService keeps its previous recipients.
//

import Foundation

enum MaterialOrderRecipientsRulebook {
    static let functionName = "materialOrderRecipients"

    /// True once the packed `canonical-business.js` exports `materialOrderRecipients`.
    static var isAvailable: Bool {
        CanonicalBusinessEngine.exportKind(functionName) == "function"
    }

    static func payload(
        jobManagerIds: [String],
        managers: [Manager],
        accounts: [AppUser],
        adder: AppUser?,
        adderUserId: String?
    ) -> [String: Any] {
        var adderIds: [String] = []
        if let adderUserId, !adderUserId.isEmpty { adderIds.append(adderUserId) }
        if let adder { adderIds += [adder.id] + adder.formerUserIds + adder.sameEmailUserIds }
        return [
            "jobManagerIds": jobManagerIds,
            "managers": managers.map { ["id": $0.id.uuidString, "email": $0.email] },
            "accounts": accounts.map { account -> [String: Any] in
                [
                    "id": account.id,
                    "email": account.email,
                    "isActive": account.isActive,
                    "formerIds": account.formerUserIds,
                    "aliasIds": account.sameEmailUserIds,
                    "role": UserTimesheetAccessRulebook.rolePayload(account)
                ]
            },
            "adderIds": Array(Set(adderIds)).sorted()
        ]
    }

    /// Account ids to notify. Nil when the script did not answer.
    static func recipientUserIds(
        jobManagerIds: [String],
        managers: [Manager],
        accounts: [AppUser],
        adder: AppUser?,
        adderUserId: String?
    ) -> [String]? {
        guard isAvailable,
              let rows = CanonicalBusinessEngine.objectRows(
                function: functionName,
                payload: payload(jobManagerIds: jobManagerIds, managers: managers, accounts: accounts, adder: adder, adderUserId: adderUserId)
              ) else {
            return nil
        }
        return rows.compactMap { $0["userId"] as? String }
    }
}
