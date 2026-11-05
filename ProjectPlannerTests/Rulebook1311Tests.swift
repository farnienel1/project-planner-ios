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

    func testRulebookVersionIs1311() {
        XCTAssertEqual(CanonicalBusinessEngine.rulebookStamp()?.version, "1.31.1")
    }

    // MARK: invitedBy on a new invitation

    func testSenderFieldKeepsTheProfileEmail() {
        XCTAssertEqual(
            InvitationDocument.senderField(profileEmail: " Manager@Example.test ", authEmail: "manager@example.test", authUid: "TEST-UID"),
            "Manager@Example.test"
        )
    }

    func testSenderFieldFallsBackToSignInEmailThenUid() {
        XCTAssertEqual(InvitationDocument.senderField(profileEmail: "  ", authEmail: "auth@example.test", authUid: "TEST-UID"), "auth@example.test")
        XCTAssertEqual(InvitationDocument.senderField(profileEmail: nil, authEmail: nil, authUid: "TEST-UID"), "TEST-UID")
        XCTAssertEqual(InvitationDocument.senderField(profileEmail: nil, authEmail: nil, authUid: nil), "")
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
        XCTAssertEqual(source.components(separatedBy: "InvitationDocument.markEarlierInvitationsUsed(").count - 1, 3)
    }
}
