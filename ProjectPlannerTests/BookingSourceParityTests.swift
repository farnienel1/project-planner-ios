import XCTest
@testable import Project_Planner

/// iOS lost bookings web shows (Raccord MEP, 28 Oct 2026): a manager's bookings under their sign-in uid,
/// a second job with the same job number, and a 07:30–19:15 day labelled "Full standard day".
@MainActor
final class BookingSourceParityTests: XCTestCase {
    private let invitedId = "463952DE-0375-435D-8AB3-67570C902C56"
    private let signInUid = "rWoccK8LDZVJjBj3UCbqay8bPyf2"

    private func manager(id: String) -> AppUser {
        AppUser(
            id: id,
            email: "test-manager@example.com",
            organizationId: "org-test",
            role: .manager,
            firstName: "TEST",
            surname: "Manager",
            isActive: true,
            passwordSet: true,
            permissions: UserPermissions(manager: true)
        )
    }

    // MARK: - Same email, two users documents

    func testABookingUnderTheFoldedIdBelongsToTheKeptPerson() {
        var kept = manager(id: invitedId)
        kept.sameEmailUserIds = [signInUid]
        XCTAssertEqual(StaffEmailIdentity.account(forUserId: signInUid, in: [kept])?.id, invitedId)
    }

    func testAFormerInviteIdAlsoResolvesWithoutCase() {
        var kept = manager(id: signInUid)
        kept.formerUserIds = [invitedId]
        XCTAssertEqual(StaffEmailIdentity.account(forUserId: invitedId.lowercased(), in: [kept])?.id, signInUid)
    }

    func testTheRosterKeepsFoldedIdsWhenAPersonIsReplaced() {
        let store = UserStore()
        store.currentUser = manager(id: "admin-viewer")
        store.organizationUsers = [manager(id: invitedId)]
        store.applyRosterAliasesForTesting([signInUid: invitedId])
        XCTAssertEqual(store.organizationUsers.first?.sameEmailUserIds, [signInUid])

        // A later update that rebuilds the person without the alias (profile edit, cache restore).
        store.organizationUsers = [manager(id: invitedId)]
        XCTAssertEqual(store.organizationUsers.first?.sameEmailUserIds, [signInUid])
    }

    func testCollapsedRosterReportsTheFoldedId() {
        let chosen = FirebaseBackend.collapsedRosterUser(manager(id: invitedId), manager(id: signInUid))
        XCTAssertEqual(chosen.sameEmailUserIds.count, 1)
        XCTAssertNotEqual(chosen.sameEmailUserIds.first, chosen.id)
    }

    // MARK: - Two jobs, one job number

    private func job(id: UUID, jobNumber: String) -> Project {
        Project(
            id: id,
            jobNumber: jobNumber,
            siteName: "TEST-1 Carnaby Street",
            addressLine1: "1 Test Street",
            townCity: "London",
            postcode: "W1 1AA",
            client: Client(id: UUID(), name: "TEST-Client", contactPerson: nil, email: "", phone: "", address: ""),
            startDate: Date(),
            endDate: Date(),
            jobType: .catA,
            manager: .na
        )
    }

    func testTwoJobsWithTheSameNumberAreBothKept() {
        let first = job(id: UUID(), jobNumber: "C646")
        let second = job(id: UUID(), jobNumber: "C646")
        let kept = ProjectWorksMerge.uniqueWorks([first, second, first])
        XCTAssertEqual(Set(kept.map(\.id)), [first.id, second.id], "Bookings point at either document")
    }

    // MARK: - Custom hours past the standard day

    func testADayRunningIntoOvertimeShowsItsClockTimes() {
        let day = LogicFixtures.day(2026, 10, 21, hour: 8)
        let booking = LogicFixtures.booking(on: day, slot: .customHours, start: "07:30", end: "19:15")
        let subtitle = booking.scheduleCoverageSubtitle(policy: LogicFixtures.policy)
        XCTAssertFalse(subtitle.text.hasPrefix("Full standard day"), subtitle.text)
        XCTAssertTrue(subtitle.text.contains("07:30–19:15"), subtitle.text)
    }

    func testAPlainFullDayStillSaysFullStandardDay() {
        let day = LogicFixtures.day(2026, 10, 21, hour: 8)
        let booking = LogicFixtures.booking(on: day)
        XCTAssertTrue(booking.scheduleCoverageSubtitle(policy: LogicFixtures.policy).text.hasPrefix("Full standard day"))
    }
}
