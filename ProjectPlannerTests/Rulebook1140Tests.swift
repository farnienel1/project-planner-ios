import XCTest
@testable import Project_Planner

/// RULEBOOK 1.14.0 behaviour on iOS through `CanonicalBusinessEngine`. Every expected value was checked in node against
/// the packed `canonical-business.js` (sha256 da6f1afc…dedd).
@MainActor
final class Rulebook1140Tests: XCTestCase {
    // MARK: Line manager selection (1.14.0 §11 `lineManagerSelectedIds`)

    /// Mia has two users documents on one email: an invite leftover (`MGR-OLD`, never signed up) and her live account.
    private func mia(_ id: String, passwordSet: Bool) -> AppUser {
        AppUser(
            id: id,
            email: "mia@example.test",
            organizationId: "TEST-org",
            role: .manager,
            firstName: "Mia",
            surname: "Lane",
            passwordSet: passwordSet,
            permissions: UserPermissions(manager: true)
        )
    }

    private func operative(lineManagers: [String], hasNoLineManager: Bool = false) -> AppUser {
        var user = AppUser(
            id: "OP-1",
            email: "op1@example.test",
            organizationId: "TEST-org",
            role: .operative,
            firstName: "Olly",
            surname: "Op",
            passwordSet: true,
            permissions: UserPermissions(operativeMode: true)
        )
        user.setLineManagerUserIds(lineManagers)
        user.hasNoLineManager = hasNoLineManager
        return user
    }

    private var duplicateManagerRoster: [AppUser] {
        [mia("MGR-OLD", passwordSet: false), mia("mgr-live", passwordSet: true), operative(lineManagers: [])]
    }

    func testCandidatesListAPersonOnceUnderTheLiveDocument() {
        let candidates = LineManagerRulebook.candidates(for: operative(lineManagers: []), roster: duplicateManagerRoster)
        XCTAssertEqual(candidates.map(\.id), ["mgr-live"])
    }

    func testStoredIdOnTheOtherDocumentSelectsThePersonsOneOption() {
        let roster = duplicateManagerRoster
        XCTAssertEqual(LineManagerRulebook.selectedIds(for: operative(lineManagers: ["MGR-OLD"]), roster: roster), ["mgr-live"])
        XCTAssertEqual(
            LineManagerRulebook.selectedIds(for: operative(lineManagers: ["MGR-OLD", "mgr-live"]), roster: roster),
            ["mgr-live"],
            "one entry per person"
        )
        XCTAssertEqual(
            LineManagerRulebook.selectedIds(for: operative(lineManagers: ["ghost"]), roster: roster),
            ["ghost"],
            "an id no candidate matches is kept as stored"
        )
        XCTAssertEqual(
            LineManagerRulebook.selectedIds(for: operative(lineManagers: ["mgr-live"], hasNoLineManager: true), roster: roster),
            []
        )
        let raw = CanonicalBusinessEngine.lineManagerSelectedIds(
            person: LineManagerRulebook.row(operative(lineManagers: ["MGR-OLD"])),
            roster: LineManagerRulebook.roster(roster)
        )
        XCTAssertEqual(raw, ["mgr-live"])
    }

    func testAnUntouchedPickerIsNoChange() {
        let roster = duplicateManagerRoster
        let stored = operative(lineManagers: ["MGR-OLD"])
        XCTAssertFalse(LineManagerRulebook.selectionChanged(["mgr-live"], from: stored, roster: roster))
        XCTAssertFalse(LineManagerRulebook.selectionChanged(["MGR-OLD"], from: stored, roster: roster))
        XCTAssertTrue(LineManagerRulebook.selectionChanged([], from: stored, roster: roster))
    }

    // MARK: Self-employed pay rate (1.14.0 §8, §11)

    func testPayRateRequiredError() {
        let message = "Set a day rate or hourly rate — self-employed people are paid from it."
        XCTAssertEqual(CanonicalBusinessEngine.payRateRequiredMessage, message)
        XCTAssertEqual(PayRateRequiredRulebook.error(employmentType: .selfEmployed, payBasis: "day", amount: nil), message)
        XCTAssertEqual(PayRateRequiredRulebook.error(employmentType: .selfEmployed, payBasis: "day", amount: 0), message)
        XCTAssertNil(PayRateRequiredRulebook.error(employmentType: .selfEmployed, payBasis: "day", amount: 250))
        XCTAssertNil(PayRateRequiredRulebook.error(employmentType: .selfEmployed, payBasis: "hourly", amount: 18.5))
        XCTAssertNil(PayRateRequiredRulebook.error(employmentType: .paye, payBasis: "day", amount: nil), "PAYE never needs a rate")
        // The basis decides which amount counts.
        XCTAssertEqual(
            CanonicalBusinessEngine.payRateRequiredError(employmentType: "self_employed", payBasis: "hourly", dayRate: 250, hourlyRate: nil),
            message
        )
        // No basis: either amount counts. A missing employment type is self-employed.
        XCTAssertNil(CanonicalBusinessEngine.payRateRequiredError(employmentType: "self_employed", payBasis: nil, dayRate: nil, hourlyRate: 12))
        XCTAssertEqual(CanonicalBusinessEngine.payRateRequiredError(employmentType: nil, payBasis: "day", dayRate: 0, hourlyRate: nil), message)
    }

    private func person(
        _ id: String,
        email: String,
        type: EmploymentType,
        payBasis: String? = nil,
        dayRate: Double? = nil,
        hourlyRate: Double? = nil,
        isActive: Bool = true,
        firstName: String? = nil,
        surname: String = "T"
    ) -> AppUser {
        var user = AppUser(
            id: id,
            email: email,
            organizationId: "TEST-org",
            role: .operative,
            firstName: firstName ?? id,
            surname: surname,
            isActive: isActive,
            passwordSet: true,
            permissions: UserPermissions(operativeMode: true),
            dayRate: dayRate,
            hourlyRate: hourlyRate,
            employmentType: type
        )
        user.payBasis = payBasis
        return user
    }

    func testUsersMissingPayRateListsActiveSelfEmployedPeopleWithoutARate() {
        let roster = [
            person("SE-NORATE", email: "a@x.test", type: .selfEmployed),
            person("SE-RATE", email: "b@x.test", type: .selfEmployed, payBasis: "day", dayRate: 200),
            person("PAYE-1", email: "c@x.test", type: .paye),
            person("SE-INACTIVE", email: "d@x.test", type: .selfEmployed, isActive: false),
            // One person on two documents passes when either active row has a rate.
            person("DUP-A", email: "e@x.test", type: .selfEmployed),
            person("dup-b", email: "E@x.test", type: .selfEmployed, payBasis: "hourly", hourlyRate: 15),
            person("DEL-1", email: "", type: .selfEmployed, firstName: "Deleted", surname: "user"),
            person("SE-ZERO", email: "f@x.test", type: .selfEmployed, payBasis: "day", dayRate: 0),
        ]
        XCTAssertEqual(PayRateRequiredRulebook.usersMissingPayRate(roster).map(\.id), ["SE-NORATE", "SE-ZERO"])
    }

    // MARK: New-user permission defaults (1.14.0 §11)

    func testAddUserStartsEveryChangeableToggleOff() throws {
        for level in [RulebookPermissionLevel.operative, .manager, .admin] {
            let defaults = try XCTUnwrap(CanonicalBusinessEngine.addUserPermissionDefaults(level))
            let draft = UserPermissions().applying(defaults)
            let rows = CanonicalBusinessEngine.permissionToggleRows(
                level: level,
                user: CanonicalBusinessEngine.permissionSubject(permissions: draft, role: level.rawValue, isSuperAdmin: false),
                mode: .add
            ).filter(\.visible)
            XCTAssertFalse(rows.isEmpty, "\(level)")
            for row in rows where row.editable {
                XCTAssertFalse(row.value, "\(level) \(row.field) starts off")
            }
            for row in rows where !row.editable {
                XCTAssertTrue(row.value, "\(level) locked \(row.field) keeps its on value")
            }
        }
    }

    // MARK: Lapsed subscription on iOS (1.14.0 §19)

    func testLapsedScreenShowsOnlyTheLapsedMessageForAdminsToo() {
        XCTAssertNil(SubscriptionLapsedCopy.detail(isAdmin: true))
        XCTAssertEqual(SubscriptionLapsedCopy.visibleText(isAdmin: true), CanonicalBusinessEngine.subscriptionLapsedMessage)
        XCTAssertEqual(SubscriptionLapsedCopy.visibleText(isAdmin: false), CanonicalBusinessEngine.subscriptionLapsedMessage)
    }
}
