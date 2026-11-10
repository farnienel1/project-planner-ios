import XCTest
@testable import Project_Planner

/// RULEBOOK 1.36.0 §11 (owner decision 10 Nov): the duplicate-name warning on Add user. Every answer comes from the
/// packed script through `CanonicalBusinessEngine.usersWithSameName`; these tests lock the Swift inputs
/// (`DuplicateNameRulebook.roster` carries names, ids, email, level, `passwordSet`, `ghost`) and how the answer is read.
/// TEST data only.
@MainActor
final class Rulebook1360DuplicateNameTests: XCTestCase {
    private func person(
        _ id: String,
        email: String,
        first: String = "TEST-Sam",
        last: String = "Smith",
        active: Bool = true,
        passwordSet: Bool = true
    ) -> AppUser {
        AppUser(
            id: id,
            email: email,
            organizationId: "TEST-ORG-1360",
            role: .operative,
            firstName: first,
            surname: last,
            isActive: active,
            passwordSet: passwordSet,
            permissions: UserPermissions(operativeMode: true)
        )
    }

    private func matches(_ users: [AppUser], first: String, last: String, claims: [String]? = nil) -> [RulebookSameNamePerson] {
        guard let rows = CanonicalBusinessEngine.usersWithSameName(
            roster: DuplicateNameRulebook.roster(users),
            firstName: first,
            lastName: last,
            claimedEmails: claims
        ) else {
            XCTFail("usersWithSameName did not answer")
            return []
        }
        return rows
    }

    func testExactMatchIsReadWithLevelAndEmail() {
        let rows = matches([person("TEST-U-1", email: "test-sam@example.com")], first: "TEST-Sam", last: "Smith")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "TEST-U-1")
        XCTAssertEqual(rows.first?.email, "test-sam@example.com")
        XCTAssertEqual(rows.first?.level, "operative")
        XCTAssertEqual(rows.first?.segment, "active")
        XCTAssertEqual(rows.first?.active, true)
        XCTAssertEqual(rows.first?.ghost, false)
    }

    func testLetterCaseAndSpacesAreIgnored() {
        let users = [person("TEST-U-1", email: "test-sam@example.com")]
        XCTAssertEqual(matches(users, first: "  test-sam ", last: " SMITH").count, 1)
    }

    func testDifferentSurnameAndEmptyNamesGiveNoMatch() {
        let users = [person("TEST-U-1", email: "test-sam@example.com")]
        XCTAssertTrue(matches(users, first: "TEST-Sam", last: "Smyth").isEmpty)
        XCTAssertTrue(matches(users, first: "", last: "Smith").isEmpty)
        XCTAssertTrue(matches(users, first: "TEST-Sam", last: "  ").isEmpty)
    }

    func testTwoRowsOnOneEmailAreOnePerson() {
        let users = [
            person("TEST-PLACEHOLDER-1", email: "TEST-SAM@example.com", passwordSet: false),
            person("TEST-U-1", email: "test-sam@example.com"),
        ]
        let rows = matches(users, first: "TEST-Sam", last: "Smith")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "TEST-U-1", "the active row speaks for the person")
    }

    func testInactiveAndGhostCountDeletedProfileDoesNot() {
        var ghost = person("TEST-GHOST-1", email: "", passwordSet: false)
        ghost.isGhost = true
        let inactive = person("TEST-U-2", email: "test-sam2@example.com", active: false)
        let rows = matches([ghost, inactive], first: "TEST-Sam", last: "Smith")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.id == "TEST-GHOST-1" })?.ghost, true)
        XCTAssertEqual(rows.first(where: { $0.id == "TEST-U-2" })?.segment, "inactive")
        let deleted = person("TEST-DEL-1", email: "", first: "Deleted", last: "user")
        XCTAssertTrue(matches([deleted], first: "Deleted", last: "user").isEmpty)
    }

    func testLeftoverInviteWithoutClaimIsLeftOut() {
        let leftover = person("TEST-P-1", email: "test-sam@example.com", passwordSet: false)
        XCTAssertTrue(matches([leftover], first: "TEST-Sam", last: "Smith", claims: []).isEmpty)
        XCTAssertEqual(matches([leftover], first: "TEST-Sam", last: "Smith", claims: ["test-sam@example.com"]).count, 1)
    }

    func testCopyComesFromTheRulebook() {
        XCTAssertEqual(
            CanonicalBusinessEngine.duplicateNameWarningMessage,
            "A user with this name already exists. Are you sure you want to add this user?"
        )
        XCTAssertEqual(CanonicalBusinessEngine.duplicateNameConfirmLabel, "Add anyway")
        XCTAssertEqual(CanonicalBusinessEngine.duplicateNameCancelLabel, "Cancel")
    }

    // MARK: Owner decision 10 Nov (judgement call 4): no rules, no new user

    func testScriptNotAnsweringRefusesTheSave() {
        XCTAssertEqual(
            DuplicateNameRulebook.decision(answer: nil, nameConfirmed: false),
            .refuse("Couldn't check this user — try again.")
        )
        // Add anyway never bypasses the rules: still refused when they do not answer.
        XCTAssertEqual(
            DuplicateNameRulebook.decision(answer: nil, nameConfirmed: true),
            .refuse(DuplicateNameRulebook.unavailableMessage)
        )
    }

    func testAnswerDecidesWarnOrSave() {
        let match = RulebookSameNamePerson(
            id: "TEST-U-1", displayName: "TEST-Sam Smith", email: "test-sam@example.com",
            level: "operative", active: true, segment: "active", ghost: false
        )
        XCTAssertEqual(DuplicateNameRulebook.decision(answer: [], nameConfirmed: false), .save)
        XCTAssertEqual(DuplicateNameRulebook.decision(answer: [match], nameConfirmed: false), .warn([match]))
        XCTAssertEqual(DuplicateNameRulebook.decision(answer: [match], nameConfirmed: true), .save)
    }

    /// Both Add user paths (invite and ghost) ask before they start saving, so a refusal saves nothing.
    func testBothAddUserPathsCheckBeforeSaving() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appendingPathComponent("Project Planner/Views/AddUserView.swift"),
            encoding: .utf8
        )
        for marker in ["private func createUser() {", "private func createGhostAccount() {"] {
            let body = try XCTUnwrap(AddUserSavedDataGuardTests.declaration(startingAt: marker, in: view), marker)
            let check = try XCTUnwrap(body.range(of: "if stopForDuplicateName() { return }"), "\(marker) does not check")
            let creating = try XCTUnwrap(body.range(of: "isCreating = true"), "\(marker) never saves")
            XCTAssertLessThan(check.lowerBound, creating.lowerBound, "\(marker) must check before it starts saving")
        }
        XCTAssertTrue(view.contains("case .refuse(let message):"), "the refusal must stop the save with its message")
    }

    // MARK: Review 10 Nov

    func testContactLabelNoAppLoginOnlyForGhosts() {
        XCTAssertEqual(CanonicalBusinessEngine.sameNamePersonContactLabel(email: "test-sam@example.com", ghost: false), "test-sam@example.com")
        XCTAssertEqual(CanonicalBusinessEngine.sameNamePersonContactLabel(email: "", ghost: true), "No app login")
        XCTAssertEqual(CanonicalBusinessEngine.sameNamePersonContactLabel(email: "", ghost: false), "No email")
    }

    /// Add anyway's confirmation never outlives the alert: set only around its one synchronous `createUser()` call,
    /// cleared right after it, on Cancel and when a name field changes; the check consumes it.
    func testNameConfirmationNeverOutlivesTheAlert() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = AddUserSavedDataGuardTests.normalized(try String(
            contentsOf: root.appendingPathComponent("Project Planner/Views/AddUserView.swift"),
            encoding: .utf8
        ))
        for snippet in [
            "role: .cancel) { duplicateNameConfirmed = false }",
            "duplicateNameConfirmed = true createUser() duplicateNameConfirmed = false }",
            ".onChange(of: firstName) { _, _ in duplicateNameConfirmed = false }",
            ".onChange(of: surname) { _, _ in duplicateNameConfirmed = false }",
            "let nameConfirmed = duplicateNameConfirmed duplicateNameConfirmed = false",
        ] {
            XCTAssertTrue(view.contains(AddUserSavedDataGuardTests.normalized(snippet)), snippet)
        }
        // Set in exactly one place.
        XCTAssertEqual(view.components(separatedBy: "duplicateNameConfirmed = true").count - 1, 1)
        // `createUser()` starts no Task before the check, so the flag is read synchronously within that call.
        let full = try String(contentsOf: root.appendingPathComponent("Project Planner/Views/AddUserView.swift"), encoding: .utf8)
        let body = try XCTUnwrap(AddUserSavedDataGuardTests.declaration(startingAt: "private func createUser() {", in: full))
        let check = try XCTUnwrap(body.range(of: "if stopForDuplicateName() { return }"))
        XCTAssertNil(body[..<check.lowerBound].range(of: "Task {"))
    }
}
