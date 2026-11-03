//
//  Rulebook+Subscription.swift
//  Project Planner
//
//  Rulebook 1.13.0 §19 (owner decision Q3): a lapsed subscription blocks the organisation on every platform.
//  `subscriptionAccess({ billing, now, viewerIsAdmin, viewerIsPlatformOwner })` decides `open`, `adminBillingOnly` or
//  `blocked`; the screen shows `SUBSCRIPTION_LAPSED_MESSAGE` (and `SUBSCRIPTION_LAPSED_ADMIN_NOTE` for admins).
//  iOS has no billing screen, so `adminBillingOnly` is the same full-screen block with the admin note — never a link or
//  a price. Nothing is decided here.
//

import Foundation

/// `SubscriptionAccess`.
nonisolated enum RulebookSubscriptionAccess: String, Sendable {
    case open
    case adminBillingOnly
    case blocked
}

extension CanonicalBusinessEngine {
    /// `subscriptionAccess(...)`. Open when the script did not answer (as `hasAccess` failing open).
    nonisolated static func subscriptionAccess(
        billing: [String: Any]?,
        viewerIsAdmin: Bool,
        viewerIsPlatformOwner: Bool,
        now: Date = Date()
    ) -> RulebookSubscriptionAccess {
        let input: [String: Any] = [
            "billing": billing ?? NSNull(),
            "now": (now.timeIntervalSince1970 * 1000).rounded(),
            "viewerIsAdmin": viewerIsAdmin,
            "viewerIsPlatformOwner": viewerIsPlatformOwner,
        ]
        return (callJSON("subscriptionAccess", arguments: [input]) as? String).flatMap(RulebookSubscriptionAccess.init(rawValue:)) ?? .open
    }

    /// `SUBSCRIPTION_LAPSED_MESSAGE`.
    nonisolated static var subscriptionLapsedMessage: String {
        constant("SUBSCRIPTION_LAPSED_MESSAGE", as: String.self)
            ?? "The organisation's Project Planner subscription has lapsed. Please contact your system administrator and ask them to renew."
    }

    /// `SUBSCRIPTION_LAPSED_ADMIN_NOTE`.
    nonisolated static var subscriptionLapsedAdminNote: String {
        constant("SUBSCRIPTION_LAPSED_ADMIN_NOTE", as: String.self)
            ?? "You are an admin: renew the subscription in Settings → Billing."
    }
}

extension Organization {
    /// `subscriptionAccess` for the signed-in viewer of this organisation.
    func subscriptionAccess(viewer: AppUser?) -> RulebookSubscriptionAccess {
        CanonicalBusinessEngine.subscriptionAccess(
            billing: OrganizationBillingMap.dictionary(json: billingJSON),
            viewerIsAdmin: viewer?.isRosterAdmin == true,
            viewerIsPlatformOwner: CanonicalBusinessEngine.isPlatformOwnerEmail(viewer?.email)
        )
    }
}
