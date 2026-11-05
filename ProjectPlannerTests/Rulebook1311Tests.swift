import XCTest
@testable import Project_Planner

/// RULEBOOK 1.31.1 iOS follow-on (web hand-off v1.31.1): the `invitations` queries the restructured security rules
/// accept. Every list names `organizationId` + `email`; an operatives manager's also names `invitedBy` (users id or
/// sign-in email, compared without case). New invitations keep `invitedBy` = the sender's email, never a made-up one.
/// The writes stay `invitationCreateFields` / `invitationUsedWriteFields` / `userDeleteWrites` (`CanonicalBusinessEngine`).
@MainActor
final class Rulebook1311Tests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// These queries follow the 1.31.1 rules, so the packed rulebook must be 1.31.1 or later. The exact version is
    /// `RulebookParityTests`' job (script stamp == `docs/RULEBOOK.md`), so later syncs do not have to edit this test.
    func testRulebookVersionIsAtLeast1311() throws {
        let version = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp()?.version)
        XCTAssertNotEqual(version.compare("1.31.1", options: .numeric), .orderedAscending, "rulebook \(version) is older than 1.31.1")
    }

    // MARK: invitedBy on a new invitation

    /// The rules compare `invitedBy` with the Auth token email or uid, so the write names the sign-in email first —
    /// never the profile email, which may differ.
    func testSenderFieldNamesTheSignInEmailNotTheProfileEmail() throws {
        XCTAssertEqual(try InvitationDocument.senderField(authEmail: " Auth@Example.test ", authUid: "TEST-UID"), "Auth@Example.test")
    }

    func testSenderFieldFallsBackToUid() throws {
        XCTAssertEqual(try InvitationDocument.senderField(authEmail: "  ", authUid: "TEST-UID"), "TEST-UID")
        XCTAssertEqual(try InvitationDocument.senderField(authEmail: nil, authUid: " TEST-UID "), "TEST-UID")
    }

    func testSenderFieldNeverReturnsBlank() {
        XCTAssertThrowsError(try InvitationDocument.senderField(authEmail: nil, authUid: nil)) { error in
            XCTAssertEqual(error as? InvitationSenderMissingError, InvitationSenderMissingError())
        }
        XCTAssertThrowsError(try InvitationDocument.senderField(authEmail: " ", authUid: ""))
    }

    // MARK: sender forms

    func testSenderValuesCoverUidEmailAndLowerCaseWithoutDuplicates() {
        XCTAssertEqual(
            InvitationDocument.senderValues(authUid: "TEST-UID", authEmail: "Ops@Example.test", profileEmail: "Ops@Example.test"),
            ["TEST-UID", "Ops@Example.test", "ops@example.test"]
        )
        XCTAssertEqual(
            InvitationDocument.senderValues(authUid: nil, authEmail: "", profileEmail: "ops@example.test"),
            ["ops@example.test"]
        )
    }

    // MARK: query plans

    func testAdminQueryNamesOrganisationAndEmailOnly() {
        let lookups = InvitationDocument.lookups(
            organizationId: "TEST-ORG",
            email: "invitee@example.test",
            callerIsAdmin: true,
            senders: ["TEST-ADMIN"]
        )
        XCTAssertEqual(lookups, [InvitationLookup(organizationId: "TEST-ORG", email: "invitee@example.test", invitedBy: nil)])
    }

    func testAdminQueryAsksStoredLowerCaseThenTypedEmail() {
        let lookups = InvitationDocument.lookups(
            organizationId: "TEST-ORG",
            email: " Invitee@Example.test ",
            callerIsAdmin: true,
            senders: []
        )
        XCTAssertEqual(lookups.map(\.email), ["invitee@example.test", "Invitee@Example.test"])
        XCTAssertTrue(lookups.allSatisfy { $0.organizationId == "TEST-ORG" && $0.invitedBy == nil })
    }

    func testOperativesManagerQueryAlsoNamesEverySenderForm() {
        let senders = InvitationDocument.senderValues(authUid: "TEST-OPS", authEmail: "Ops@Example.test", profileEmail: nil)
        let lookups = InvitationDocument.lookups(
            organizationId: "TEST-ORG",
            email: "invitee@example.test",
            callerIsAdmin: false,
            senders: senders
        )
        XCTAssertEqual(lookups.map(\.invitedBy), ["TEST-OPS", "Ops@Example.test", "ops@example.test"])
        XCTAssertTrue(lookups.allSatisfy { $0.organizationId == "TEST-ORG" && $0.email == "invitee@example.test" })
    }

    func testNoQueryWithoutOrganisationEmailOrSender() {
        XCTAssertTrue(InvitationDocument.lookups(organizationId: " ", email: "a@example.test", callerIsAdmin: true, senders: []).isEmpty)
        XCTAssertTrue(InvitationDocument.lookups(organizationId: "TEST-ORG", email: "", callerIsAdmin: true, senders: []).isEmpty)
        // An operatives manager with no sender id would be refused by the rules: ask nothing.
        XCTAssertTrue(InvitationDocument.lookups(organizationId: "TEST-ORG", email: "a@example.test", callerIsAdmin: false, senders: []).isEmpty)
    }

    // MARK: resend order

    private struct CreateRefused: Error {}

    func testResendCreatesFirstThenClosesEarlierLinksWithTheNewId() async throws {
        var steps: [String] = []
        let result = try await InvitationDocument.resend(create: {
            steps.append("create")
            return "TEST-NEW"
        }, closeEarlier: { newId in
            steps.append("close:\(newId)")
            return InvitationCloseResult(closed: 2)
        })
        XCTAssertEqual(steps, ["create", "close:TEST-NEW"])
        XCTAssertEqual(result.invitationId, "TEST-NEW")
        XCTAssertEqual(result.closed.closed, 2)
    }

    func testRefusedCreateClosesNothing() async {
        var closeCalled = false
        do {
            _ = try await InvitationDocument.resend(create: {
                throw CreateRefused()
            }, closeEarlier: { _ in
                closeCalled = true
                return InvitationCloseResult()
            })
            XCTFail("a refused create must throw")
        } catch {
            XCTAssertTrue(error is CreateRefused)
        }
        XCTAssertFalse(closeCalled, "the earlier links must keep working when the new invitation was not created")
    }

    func testClosableIdsSkipTheNewInvitationAndUsedOnes() {
        let rows: [(id: String, isUsed: Bool)] = [
            (id: "TEST-OLD-1", isUsed: false),
            (id: "test-new", isUsed: false),
            (id: "TEST-OLD-2", isUsed: true),
            (id: "TEST-OLD-3", isUsed: false),
        ]
        XCTAssertEqual(InvitationDocument.closableInvitationIds(rows, excluding: "TEST-NEW"), ["TEST-OLD-1", "TEST-OLD-3"])
    }

    // MARK: refusals

    func testOnlyPermissionDeniedIsSkipped() {
        XCTAssertTrue(InvitationDocument.isPermissionDenied(NSError(domain: "FIRFirestoreErrorDomain", code: 7)))
        XCTAssertFalse(InvitationDocument.isPermissionDenied(NSError(domain: "FIRFirestoreErrorDomain", code: 14)), "unavailable is rethrown")
        XCTAssertFalse(InvitationDocument.isPermissionDenied(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
    }

    // MARK: what the person is told

    func testSummaryCountsClosedLinksForAnAdmin() {
        XCTAssertEqual(InvitationDocument.closeSummary(InvitationCloseResult(closed: 2)), "Closed 2 earlier links.")
        XCTAssertEqual(InvitationDocument.closeSummary(InvitationCloseResult(closed: 1)), "Closed 1 earlier link.")
        XCTAssertEqual(InvitationDocument.closeSummary(InvitationCloseResult()), "No earlier links to close.")
    }

    func testSummaryCountsRefusedAndFailedMarks() {
        XCTAssertEqual(
            InvitationDocument.closeSummary(InvitationCloseResult(closed: 1, refused: 1, failed: 2)),
            "Closed 1 earlier link. 1 earlier link could not be closed (not yours to close). 2 earlier links could not be closed; try again."
        )
        XCTAssertEqual(
            InvitationDocument.closeSummary(InvitationCloseResult(lookupFailed: true)),
            "Couldn't check for earlier links; they may still work."
        )
    }

    func testOperativesManagerIsToldOthersLinksMayStillWork() {
        XCTAssertEqual(
            InvitationDocument.closeSummary(InvitationCloseResult(closed: 1, ownLinksOnly: true)),
            "Closed 1 earlier link. Links sent by others (for example an admin) may still work."
        )
    }

    // MARK: call sites

    /// The rules refuse an `invitations` list without `organizationId` (everyone) or without `invitedBy` (an operatives
    /// manager). Every app query goes through `InvitationDocument.fetch`, which always names both.
    func testNoAppSourceQueriesInvitationsOutsideTheLookup() throws {
        let appRoot = repoRoot.appendingPathComponent("Project Planner")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        let pattern = try NSRegularExpression(pattern: #"collection\("invitations"\)\s*\.whereField"#)
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard url.lastPathComponent != "InvitationLookup.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [], "query invitations through InvitationDocument.fetch / lookupsForSignedInUser")
    }

    func testManageUsersNeverWritesAMadeUpSender() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Project Planner/Views/ManageUsersView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains(#"?? "System""#), "invitedBy must name the sender (rules: invitationSentByCaller)")
        XCTAssertFalse(source.contains("currentUser?.email ?? "), "invitedBy is the sign-in email or uid, never the profile email")
        // All three resend paths create first and close after (`InvitationDocument.resend`).
        XCTAssertEqual(source.components(separatedBy: "InvitationDocument.resend(create:").count - 1, 3)
        XCTAssertEqual(source.components(separatedBy: "InvitationDocument.signedInSenderField()").count - 1, 3)
        XCTAssertEqual(source.components(separatedBy: "InvitationDocument.closeSummary(").count - 1, 3)
    }
}
