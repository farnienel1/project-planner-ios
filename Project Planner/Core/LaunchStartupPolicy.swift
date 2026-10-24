//
//  LaunchStartupPolicy.swift
//  Project Planner
//
//  Client startup decisions: which roster row a denied user-document read may keep,
//  which users query shapes to issue, whether a listener is already attached,
//  which push tokens to store, and whether a missing userEmails document is an error.
//  These are not shared booking, warning, or invoicing rules.
//

import Foundation

enum LaunchStartupPolicy {
    enum RosterUserDocumentRead: Equatable {
        case present
        case confirmedMissing
        case permissionDenied
        case unconfirmed
    }

    enum RosterAbsenceDecision: Equatable {
        /// The row stays. A timeout or an offline miss is not proof the person left.
        case keep
        /// The row leaves the roster. Denial is not proof the document still exists.
        case drop
    }

    static func rosterAbsenceDecision(_ read: RosterUserDocumentRead) -> RosterAbsenceDecision {
        switch read {
        case .present, .unconfirmed:
            return .keep
        case .confirmedMissing, .permissionDenied:
            return .drop
        }
    }

    static func isPermissionDenied(domain: String, code: Int, description: String) -> Bool {
        if domain == "FIRFirestoreErrorDomain" && code == 7 { return true }
        let lowered = description.lowercased()
        return lowered.contains("missing or insufficient permissions")
            || lowered.contains("permission denied")
            || lowered.contains("permission-denied")
    }

    static func isNotFound(domain: String, code: Int) -> Bool {
        domain == "FIRFirestoreErrorDomain" && code == 5
    }

    enum OrganizationUserQueryShape: Equatable {
        case organizationId(String)
        case lowercasedOrganizationId(String)
        case organizationsPath(String)
        case documentReference
    }

    /// The organisation id string that just succeeded. Other shapes are not issued.
    static func organizationUserQueryShapes(afterSuccessfulOrganizationId organizationId: String) -> [OrganizationUserQueryShape] {
        let orgId = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orgId.isEmpty else { return [] }
        return [.organizationId(orgId)]
    }

    static func shouldIssueAlternateOrganizationUserShapes(primarySucceeded: Bool) -> Bool {
        !primarySucceeded
    }

    /// A shape that returned permission-denied is not retried through cache or a second get.
    static func shouldRetryOrganizationUserQuery(permissionDenied: Bool) -> Bool {
        !permissionDenied
    }

    /// Member keys, email-claim user ids, and explicit link fields. A catalogue document id
    /// is not a user document and is not point-read.
    static func pointReadUserIds(
        alreadyLoaded: Set<String>,
        memberUserIds: Set<String>,
        claimUserIds: Set<String>,
        explicitLinkUserIds: Set<String>,
        directoryDocumentIds: Set<String>
    ) -> Set<String> {
        let allowed = memberUserIds
            .union(claimUserIds)
            .union(explicitLinkUserIds)
        let catalogueOnly = directoryDocumentIds.subtracting(allowed)
        return allowed.subtracting(alreadyLoaded).subtracting(catalogueOnly)
    }

    /// Same target is already attached. A second start must not remove and reopen it.
    static func shouldAttachListener(activeTarget: String?, requestedTarget: String) -> Bool {
        let requested = requestedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return false }
        let active = activeTarget?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !active.isEmpty else { return true }
        return active != requested
    }

    /// A second `setFirebaseBackend` for the instance already stored does not rewire stores.
    static func shouldRewireStore(isSameInstance: Bool) -> Bool {
        !isSameInstance
    }

    enum UserEmailsPointRead: Equatable {
        case linked(String)
        case notFound
        case failed
    }

    /// A missing `userEmails/{email}` document is not a startup error and is not retried.
    /// A failed read stays failed so a claims miss cannot hide live pending invites.
    static func classifyUserEmailsPointRead(
        exists: Bool?,
        userId: String?,
        errorDomain: String?,
        errorCode: Int?
    ) -> UserEmailsPointRead {
        if let errorDomain, let errorCode, isNotFound(domain: errorDomain, code: errorCode) {
            return .notFound
        }
        if errorDomain != nil {
            return .failed
        }
        if exists == false {
            return .notFound
        }
        let trimmed = userId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return .linked(trimmed) }
        return .notFound
    }

    static func userEmailsReadIsStartupError(_ read: UserEmailsPointRead) -> Bool {
        switch read {
        case .notFound, .linked:
            return false
        case .failed:
            return false
        }
    }

    static func shouldRetryUserEmailsPointRead(_ read: UserEmailsPointRead) -> Bool {
        switch read {
        case .notFound:
            return false
        case .linked, .failed:
            return false
        }
    }

    /// A failed claims read must not be treated as "no claims", which would hide live invites.
    static func failedUserEmailsReadDropsLiveInvites(_ read: UserEmailsPointRead) -> Bool {
        false
    }

    static let pushTokenStoredLimit = 8

    static func isTerminalPushTokenFailure(_ message: String) -> Bool {
        let text = message.lowercased()
        if text.contains("invalid apns credential") { return true }
        if text.contains("registration-token-not-registered") { return true }
        if text.contains("invalid registration token") { return true }
        if text.contains("not a valid fcm registration token") { return true }
        if text.contains("unregistered") { return true }
        if text.contains("invalid token") { return true }
        return false
    }

    /// Keeps the current device token, drops tokens that just failed, and stops the list
    /// growing without a bound. Tokens that have not failed stay until the cap trims the oldest.
    static func nextStoredPushTokens(
        existing: [String],
        currentDeviceToken: String,
        failedTokens: Set<String>
    ) -> [String] {
        let current = currentDeviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let failed = Set(failedTokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        var older: [String] = []
        var seen = Set<String>()
        if !current.isEmpty {
            seen.insert(current)
        }
        for raw in existing {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, token != current, !failed.contains(token), seen.insert(token).inserted else { continue }
            older.append(token)
        }
        let currentCount = current.isEmpty || failed.contains(current) ? 0 : 1
        let room = max(0, pushTokenStoredLimit - currentCount)
        if older.count > room {
            older = Array(older.suffix(room))
        }
        if currentCount == 0 { return older }
        return [current] + older
    }

    static func shouldStartInboxWrite(
        onlyIfMissing: Bool,
        alreadyAcceptedIds: Set<String>,
        notificationId: String
    ) -> Bool {
        let id = notificationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        if onlyIfMissing && alreadyAcceptedIds.contains(id) { return false }
        return true
    }

    /// Earlier of the warning-scan start and the current week start. Bookings before this
    /// are not part of the launch subscription. There is no second date rule here.
    static func launchBookingLowerBound(warningStart: Date, weekStart: Date) -> Date {
        min(warningStart, weekStart)
    }

    static func launchBookingIncludes(date: Date, lowerBound: Date?) -> Bool {
        guard let lowerBound else { return true }
        return date >= lowerBound
    }
}
