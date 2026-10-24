//
//  OrganizationMembershipSupport.swift
//  Project Planner
//
//  Multi-organisation membership summaries and trial access policy.
//

import Foundation
import FirebaseFirestore

nonisolated func firestoreAccountActive(from data: [String: Any]?) -> Bool {
    guard let data else { return true }
    if let value = firestoreBool(data["accountActive"]) { return value }
    return true
}

nonisolated func firestoreUserIsActive(from data: [String: Any]?) -> Bool {
    guard let data else { return true }
    if let value = firestoreBool(data["isActive"]) { return value }
    return true
}

struct OrgMembershipSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let roleInOrg: String
    let isTrial: Bool
    let trialAccessBlocked: Bool
    /// `CanonicalBusinessEngine.hasAccess` for this company's nested billing map. Missing billing stays open.
    /// Trial locks stay on `trialAccessBlocked` and do not set this flag.
    let subscriptionHasAccess: Bool
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

/// Companies the phone already knows. Built from `sessionMembershipIds` with an empty members scan.
enum OrganizationSwitcherCatalog {
    static func knownCompaniesBeforeScan(
        previous: [OrgMembershipSummary],
        rememberedOrganizationId: String?,
        documentOrganizationId: String?,
        explicitOrganizationId: String?,
        currentOrganizationId: String?,
        currentOrganizationName: String?,
        cachedNameForRemembered: String?
    ) -> [OrgMembershipSummary] {
        let ids = CanonicalBusinessEngine.sessionMembershipIds(
            discoveredIds: [],
            previousIds: previous.map(\.id),
            rememberedOrganizationId: rememberedOrganizationId,
            documentOrganizationId: documentOrganizationId,
            explicitOrganizationId: explicitOrganizationId,
            discoveryIncomplete: true
        ) ?? previous.map(\.id)
        return ids.map { organizationId in
            if let existing = previous.first(where: { organizationIdsMatch($0.id, organizationId) }) {
                return existing
            }
            let knownName: String? = {
                if organizationIdsMatch(currentOrganizationId, organizationId) { return currentOrganizationName }
                if organizationIdsMatch(rememberedOrganizationId, organizationId) { return cachedNameForRemembered }
                return nil
            }()
            let coalesced = CanonicalBusinessEngine.coalesceOrganizationName([knownName]) ?? ""
            return OrgMembershipSummary(
                id: organizationId,
                name: CanonicalBusinessEngine.displayOrganizationName(coalesced) ?? "Organisation",
                roleInOrg: "member",
                isTrial: false,
                trialAccessBlocked: false,
                subscriptionHasAccess: true,
                createdAt: nil
            )
        }
    }
}

enum OrganizationSwitchError: LocalizedError {
    case notAuthenticated
    case organizationNotFound
    case notAMember
    case trialBlocked(String)
    case subscriptionLapsed

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
        case .subscriptionLapsed:
            return SubscriptionLapsedCopy.headline
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
        let parsed = CanonicalBusinessEngine.parseOrganizationName(Organization.nameParsePayload(from: orgData)) ?? ""
        return OrgMembershipSummary(
            id: organizationId,
            name: CanonicalBusinessEngine.displayOrganizationName(parsed) ?? "Organisation",
            roleInOrg: roleInOrg,
            isTrial: isTrialOrganization(orgData),
            trialAccessBlocked: isAccessBlocked(orgData),
            subscriptionHasAccess: CanonicalBusinessEngine.hasAccess(
                billing: OrganizationBillingMap.payload(from: orgData)
            ) ?? true,
            createdAt: createdAt
        )
    }
}
