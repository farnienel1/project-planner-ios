//
//  OrganizationMembershipSupport.swift
//  Project Planner
//
//  Multi-organisation membership summaries and trial access policy.
//

import Foundation
import FirebaseFirestore

struct OrgMembershipSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let roleInOrg: String
    let isTrial: Bool
    let trialAccessBlocked: Bool
    let createdAt: Date?

    var isActive: Bool { !trialAccessBlocked }

    var roleDisplayName: String {
        switch roleInOrg.lowercased() {
        case "admin": return "Admin"
        case "manager": return "Manager"
        case "member": return "Member"
        default:
            return roleInOrg.prefix(1).uppercased() + roleInOrg.dropFirst()
        }
    }
}

enum OrganizationSwitchError: LocalizedError {
    case notAuthenticated
    case organizationNotFound
    case notAMember
    case trialBlocked(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You must be signed in to switch organisation."
        case .organizationNotFound:
            return "That organisation could not be found."
        case .notAMember:
            return "You are not a member of that organisation."
        case .trialBlocked(let message):
            return message
        }
    }
}

enum OrganizationTrialPolicy {
    static let blockedLoginMessage = "Email info@projectplanner.us to unlock this organisation."

    static func isTrialOrganization(_ data: [String: Any]) -> Bool {
        if data["isTrial"] as? Bool == true { return true }
        if (data["subscriptionStatus"] as? String)?.lowercased() == "trial" { return true }
        if (data["billingStatus"] as? String)?.lowercased() == "trial" { return true }
        return false
    }

    static func isAccessBlocked(_ data: [String: Any]) -> Bool {
        if data["trialAccessBlocked"] as? Bool == true { return true }
        if data["accessBlocked"] as? Bool == true { return true }
        return false
    }

    static func blockedMessage(from data: [String: Any]) -> String {
        if let custom = (data["trialAccessBlockedMessage"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let custom = (data["accessBlockedMessage"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return blockedLoginMessage
    }

    /// Blocks access when the org is explicitly locked, or when this trial org is not the user's first trial membership.
    static func loginBlockMessage(
        organizationId: String,
        orgData: [String: Any],
        memberships: [OrgMembershipSummary]
    ) -> String? {
        if isAccessBlocked(orgData) {
            return blockedMessage(from: orgData)
        }

        let trialMemberships = memberships.filter(\.isTrial)
        guard trialMemberships.count > 1, isTrialOrganization(orgData) else { return nil }

        let sorted = trialMemberships.sorted { lhs, rhs in
            let l = lhs.createdAt ?? .distantFuture
            let r = rhs.createdAt ?? .distantFuture
            if l != r { return l < r }
            return lhs.id < rhs.id
        }
        guard let firstTrial = sorted.first, firstTrial.id != organizationId else { return nil }
        return blockedLoginMessage
    }

    static func membershipSummary(
        organizationId: String,
        orgData: [String: Any],
        roleInOrg: String
    ) -> OrgMembershipSummary {
        let createdAt: Date? = {
            if let ts = orgData["createdAt"] as? Timestamp {
                return ts.dateValue()
            }
            return nil
        }()
        return OrgMembershipSummary(
            id: organizationId,
            name: (orgData["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Organisation",
            roleInOrg: roleInOrg,
            isTrial: isTrialOrganization(orgData),
            trialAccessBlocked: isAccessBlocked(orgData),
            createdAt: createdAt
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
