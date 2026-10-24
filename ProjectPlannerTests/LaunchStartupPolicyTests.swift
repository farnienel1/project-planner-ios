import XCTest
@testable import Project_Planner

final class LaunchStartupPolicyTests: XCTestCase {
    func testDeniedUserDocumentReadDropsThatRow() {
        XCTAssertEqual(
            LaunchStartupPolicy.rosterAbsenceDecision(.permissionDenied),
            .drop
        )
        XCTAssertEqual(
            LaunchStartupPolicy.rosterAbsenceDecision(.confirmedMissing),
            .drop
        )
        XCTAssertEqual(LaunchStartupPolicy.rosterAbsenceDecision(.present), .keep)
        XCTAssertEqual(LaunchStartupPolicy.rosterAbsenceDecision(.unconfirmed), .keep)
        XCTAssertTrue(
            LaunchStartupPolicy.isPermissionDenied(
                domain: "FIRFirestoreErrorDomain",
                code: 7,
                description: "Missing or insufficient permissions."
            )
        )
        XCTAssertFalse(
            LaunchStartupPolicy.isPermissionDenied(
                domain: "FIRFirestoreErrorDomain",
                code: 14,
                description: "The operation couldn’t be completed."
            )
        )
    }

    func testSuccessfulOrganizationIdQueryDoesNotIssueOtherShapes() {
        let orgId = "2C67391E-D1FE-4F9F-8055-7149ACDE1F96"
        let shapes = LaunchStartupPolicy.organizationUserQueryShapes(afterSuccessfulOrganizationId: orgId)
        XCTAssertEqual(shapes, [.organizationId(orgId)])
        XCTAssertFalse(shapes.contains { shape in
            if case .lowercasedOrganizationId = shape { return true }
            if case .organizationsPath = shape { return true }
            if case .documentReference = shape { return true }
            return false
        })
        XCTAssertFalse(LaunchStartupPolicy.shouldIssueAlternateOrganizationUserShapes(primarySucceeded: true))
        XCTAssertFalse(LaunchStartupPolicy.shouldRetryOrganizationUserQuery(permissionDenied: true))
        XCTAssertTrue(LaunchStartupPolicy.shouldRetryOrganizationUserQuery(permissionDenied: false))

        let directoryIds: Set<String> = [
            "F532E7A0-E01A-4B47-8740-79E979185B28",
            "C24730B1-1D6D-4AB4-BB24-946917F3918D",
            "3FDF499D-92A7-44B8-B7C5-49DB128C18FC",
            "DE1D3201-7929-4843-B5C8-883ED49FFC43",
            "F05FE02E-0F7C-4F44-A3A8-FCF6F43D2995",
            "BEA63B7A-A5BD-4DEC-A9AE-E1C070177AA2",
            "42AC3D29-8EA2-4F95-88E9-5B355F3357C6",
            "89C27C2A-7ADB-4ACA-B134-93CDFE55B91D"
        ]
        let pointReads = LaunchStartupPolicy.pointReadUserIds(
            alreadyLoaded: ["dul1tDjfQfMX6ruXPHb8kJX5P7g2"],
            memberUserIds: ["member-auth"],
            claimUserIds: [],
            explicitLinkUserIds: [],
            directoryDocumentIds: directoryIds
        )
        XCTAssertEqual(pointReads, ["member-auth"])
        XCTAssertTrue(pointReads.isDisjoint(with: directoryIds))
    }

    func testDuplicateListenerStartDoesNotAttachAgain() {
        XCTAssertFalse(
            LaunchStartupPolicy.shouldAttachListener(activeTarget: "org:2C67391E", requestedTarget: "org:2C67391E")
        )
        XCTAssertFalse(
            LaunchStartupPolicy.shouldAttachListener(
                activeTarget: "bookings:2C67391E|1",
                requestedTarget: "bookings:2C67391E|1"
            )
        )
        XCTAssertFalse(
            LaunchStartupPolicy.shouldAttachListener(activeTarget: "user:dul1", requestedTarget: "user:dul1")
        )
        XCTAssertTrue(
            LaunchStartupPolicy.shouldAttachListener(activeTarget: nil, requestedTarget: "user:dul1")
        )
        XCTAssertTrue(
            LaunchStartupPolicy.shouldAttachListener(activeTarget: "org:A", requestedTarget: "org:B")
        )
        XCTAssertFalse(LaunchStartupPolicy.shouldRewireStore(isSameInstance: true))
        XCTAssertTrue(LaunchStartupPolicy.shouldRewireStore(isSameInstance: false))
    }

    func testSameInboxNotificationIsNotWrittenTwice() {
        let id = "BA5C6815-73E6-40C1-ACC8-D42D981FB164"
        XCTAssertTrue(
            LaunchStartupPolicy.shouldStartInboxWrite(
                onlyIfMissing: true,
                alreadyAcceptedIds: [],
                notificationId: id
            )
        )
        XCTAssertFalse(
            LaunchStartupPolicy.shouldStartInboxWrite(
                onlyIfMissing: true,
                alreadyAcceptedIds: [id],
                notificationId: id
            )
        )
    }

    func testInvalidApnsTokenIsRemovedAndUnfailedTokensStay() {
        XCTAssertTrue(LaunchStartupPolicy.isTerminalPushTokenFailure("Invalid APNs credential"))
        XCTAssertTrue(LaunchStartupPolicy.isTerminalPushTokenFailure("registration-token-not-registered"))
        XCTAssertFalse(LaunchStartupPolicy.isTerminalPushTokenFailure("The network connection was lost."))

        let failed = "dead-token-suffix"
        var existing = (0..<12).map { "older-token-\($0)" }
        existing.append(failed)
        existing.append("keep-me")
        let next = LaunchStartupPolicy.nextStoredPushTokens(
            existing: existing,
            currentDeviceToken: "current-device",
            failedTokens: [failed]
        )
        XCTAssertEqual(next.first, "current-device")
        XCTAssertFalse(next.contains(failed))
        XCTAssertTrue(next.contains("keep-me"))
        XCTAssertFalse(next.contains("older-token-0"))
        XCTAssertEqual(LaunchStartupPolicy.pushTokenStoredLimit, 8)
        XCTAssertEqual(next.count, 8)
        XCTAssertFalse(next.joined(separator: " ").contains("07876643693"))
        XCTAssertFalse(next.joined(separator: " ").contains("172465743"))
    }

    func testTerminalFailureRemovesOnlyThatTokenAndNonTerminalKeepsTheArray() {
        let existing = ["live-a", "dead-token", "live-b"]
        let removed = LaunchStartupPolicy.nextStoredPushTokens(
            existing: existing,
            currentDeviceToken: "current-device",
            failedTokens: ["dead-token"]
        )
        XCTAssertEqual(removed, ["current-device", "live-a", "live-b"])

        XCTAssertFalse(LaunchStartupPolicy.isTerminalPushTokenFailure("The network connection was lost."))
        let kept = LaunchStartupPolicy.nextStoredPushTokens(
            existing: existing,
            currentDeviceToken: "current-device",
            failedTokens: []
        )
        XCTAssertEqual(kept, ["current-device", "live-a", "dead-token", "live-b"])
    }

    func testMissingUserEmailsLookupIsNotAStartupError() {
        let missing = LaunchStartupPolicy.classifyUserEmailsPointRead(
            exists: false,
            userId: nil,
            errorDomain: nil,
            errorCode: nil
        )
        XCTAssertEqual(missing, .notFound)
        XCTAssertFalse(LaunchStartupPolicy.userEmailsReadIsStartupError(missing))
        XCTAssertFalse(LaunchStartupPolicy.shouldRetryUserEmailsPointRead(missing))

        let notFoundError = LaunchStartupPolicy.classifyUserEmailsPointRead(
            exists: nil,
            userId: nil,
            errorDomain: "FIRFirestoreErrorDomain",
            errorCode: 5
        )
        XCTAssertEqual(notFoundError, .notFound)
        XCTAssertFalse(LaunchStartupPolicy.shouldRetryUserEmailsPointRead(notFoundError))

        let denied = LaunchStartupPolicy.classifyUserEmailsPointRead(
            exists: nil,
            userId: nil,
            errorDomain: "FIRFirestoreErrorDomain",
            errorCode: 7
        )
        XCTAssertEqual(denied, .failed)
        XCTAssertFalse(LaunchStartupPolicy.failedUserEmailsReadDropsLiveInvites(denied))
        XCTAssertFalse(LaunchStartupPolicy.shouldRetryUserEmailsPointRead(denied))
    }

    func testLaunchBookingWindowDropsHistoryBeforeTheWarningOrWeekStart() {
        let warningStart = Date(timeIntervalSince1970: 1_760_572_800)
        let weekStart = warningStart.addingTimeInterval(86_400 * 3)
        let bound = LaunchStartupPolicy.launchBookingLowerBound(warningStart: warningStart, weekStart: weekStart)
        XCTAssertEqual(bound, warningStart)
        XCTAssertFalse(
            LaunchStartupPolicy.launchBookingIncludes(
                date: warningStart.addingTimeInterval(-86_400),
                lowerBound: bound
            )
        )
        XCTAssertTrue(LaunchStartupPolicy.launchBookingIncludes(date: weekStart, lowerBound: bound))
        XCTAssertTrue(
            LaunchStartupPolicy.launchBookingIncludes(
                date: weekStart.addingTimeInterval(86_400 * 40),
                lowerBound: bound
            )
        )

        let laterWarning = weekStart.addingTimeInterval(86_400)
        let weekBound = LaunchStartupPolicy.launchBookingLowerBound(
            warningStart: laterWarning,
            weekStart: weekStart
        )
        XCTAssertEqual(weekBound, weekStart)
        XCTAssertTrue(LaunchStartupPolicy.launchBookingIncludes(date: weekStart, lowerBound: weekBound))
    }
}
