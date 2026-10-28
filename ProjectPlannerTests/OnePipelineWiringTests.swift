import XCTest
@testable import Project_Planner

/// The Swift side of the one-pipeline rulebook: each wrapper passes iOS models into the shared
/// function and maps the answer back. The rules themselves are covered by `CanonicalParityFixtureTests`.
@MainActor
final class OnePipelineWiringTests: XCTestCase {
    private func manager(id: String, passwordSet: Bool, updatedAt: Date?) -> AppUser {
        var user = AppUser(
            id: id,
            email: "test-manager@example.com",
            organizationId: "org-test",
            role: .manager,
            firstName: "TEST",
            surname: "Manager",
            isActive: true,
            passwordSet: passwordSet,
            permissions: UserPermissions(manager: true)
        )
        user.documentUpdatedAt = updatedAt
        return user
    }

    func testTheRosterKeepsTheSignedInDocumentAndFoldsTheInvite() {
        let invite = manager(id: "463952DE-0375-435D-8AB3-67570C902C56", passwordSet: false, updatedAt: Date())
        let signedIn = manager(id: "rWoccK8LDZVJjBj3UCbqay8bPyf2", passwordSet: true, updatedAt: Date(timeIntervalSinceNow: -86_400))
        let folded = FirebaseBackend.foldRosterBySameEmail([invite, signedIn])
        XCTAssertEqual(folded.users.map(\.id), [signedIn.id])
        XCTAssertEqual(folded.users.first?.sameEmailUserIds, [invite.id])
        XCTAssertEqual(folded.aliases[invite.id], signedIn.id)
    }

    func testOldManagerClashKeysMoveToTheDayKey() {
        let seconds = CanonicalBusinessEngine.date(fromDayKey: "2026-10-22")!.timeIntervalSince1970
        let old = "mgr-clash-463952DE-0375-435D-8AB3-67570C902C56-\(seconds)-0"
        XCTAssertEqual(
            WarningResolutionStore.migratedResolutionKey(old),
            "mgr-clash-463952DE-0375-435D-8AB3-67570C902C56-2026-10-22-0"
        )
        let current = "mgr-clash-463952DE-0375-435D-8AB3-67570C902C56-2026-10-22-0"
        XCTAssertEqual(WarningResolutionStore.migratedResolutionKey(current), current)
        XCTAssertEqual(WarningResolutionStore.migratedResolutionKey("unbooked-2026-10-21-u1"), "unbooked-2026-10-21-u1")
    }

    func testJobStatusComesFromTheRulebook() {
        let today = CanonicalBusinessEngine.date(fromDayKey: "2026-10-22")!
        let tomorrow = CanonicalBusinessEngine.date(fromDayKey: "2026-10-23")!
        let end = CanonicalBusinessEngine.date(fromDayKey: "2026-11-30")!
        XCTAssertEqual(ProjectStatusRulebook.status(isLive: true, start: tomorrow, end: end, on: today), .upcoming)
        XCTAssertEqual(ProjectStatusRulebook.status(isLive: true, start: today, end: today, on: today), .active)
        XCTAssertEqual(ProjectStatusRulebook.status(isLive: false, start: today, end: end, on: today), .inactive)
    }

    func testBookingDownloadMovesBackForAnEarlierWindow() {
        let start = CanonicalBusinessEngine.bookingLoadStart(loadedFromDayKey: "2026-10-26", neededDayKeys: ["2026-10-16"])
        XCTAssertEqual(start?.startDayKey, "2026-10-16")
        XCTAssertEqual(start?.reload, true)
    }
}
