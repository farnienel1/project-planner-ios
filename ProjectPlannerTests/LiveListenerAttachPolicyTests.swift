import XCTest
@testable import Project_Planner

/// Owner report 13 Nov: the people lists on the phone were a cached copy with no live listener delivering, so booked
/// catalogue operatives read "Unknown person" until a relaunch (RULEBOOK §1: a cache is never the only read).
final class LiveListenerAttachPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: retryDelay

    func testANetworkFailureIsRetriedWithAGrowingBackOffThenStops() {
        XCTAssertNil(LiveListenerAttachPolicy.retryDelay(afterFailures: 0, permissionDenied: false))
        XCTAssertEqual(LiveListenerAttachPolicy.retryDelay(afterFailures: 1, permissionDenied: false), 5)
        XCTAssertEqual(LiveListenerAttachPolicy.retryDelay(afterFailures: 2, permissionDenied: false), 15)
        XCTAssertEqual(LiveListenerAttachPolicy.retryDelay(afterFailures: 5, permissionDenied: false), 300)
        XCTAssertNil(LiveListenerAttachPolicy.retryDelay(afterFailures: 6, permissionDenied: false), "no endless loop")
    }

    func testAPermissionRefusalIsRetriedOnce() {
        XCTAssertEqual(LiveListenerAttachPolicy.retryDelay(afterFailures: 1, permissionDenied: true), 30)
        XCTAssertNil(LiveListenerAttachPolicy.retryDelay(afterFailures: 2, permissionDenied: true))
    }

    func testPermissionDeniedIsReadFromTheFirestoreError() {
        XCTAssertTrue(LiveListenerAttachPolicy.isPermissionDenied(NSError(domain: "FIRFirestoreErrorDomain", code: 7)))
        XCTAssertFalse(LiveListenerAttachPolicy.isPermissionDenied(NSError(domain: "FIRFirestoreErrorDomain", code: 14)))
        XCTAssertFalse(LiveListenerAttachPolicy.isPermissionDenied(NSError(domain: "Other", code: 7)))
    }

    // MARK: needsServerRead

    func testNoListenerAtAllNeedsAServerReadWhenOnline() {
        XCTAssertTrue(LiveListenerAttachPolicy.needsServerRead(attachedAt: nil, lastServerSnapshotAt: nil, online: true, now: t0))
        XCTAssertFalse(LiveListenerAttachPolicy.needsServerRead(attachedAt: nil, lastServerSnapshotAt: nil, online: false, now: t0))
    }

    func testAListenerWithNoServerSnapshotAfterTheGraceNeedsAServerRead() {
        let attached = t0
        XCTAssertFalse(
            LiveListenerAttachPolicy.needsServerRead(attachedAt: attached, lastServerSnapshotAt: nil, online: true, now: t0.addingTimeInterval(10)),
            "still inside the grace"
        )
        XCTAssertTrue(
            LiveListenerAttachPolicy.needsServerRead(attachedAt: attached, lastServerSnapshotAt: nil, online: true, now: t0.addingTimeInterval(21))
        )
        XCTAssertTrue(
            LiveListenerAttachPolicy.needsServerRead(
                attachedAt: attached, lastServerSnapshotAt: t0.addingTimeInterval(-60), online: true, now: t0.addingTimeInterval(21)
            ),
            "a server snapshot from before this attach does not count"
        )
    }

    func testAServerSnapshotSinceTheAttachIsEnough() {
        XCTAssertFalse(
            LiveListenerAttachPolicy.needsServerRead(
                attachedAt: t0, lastServerSnapshotAt: t0.addingTimeInterval(2), online: true, now: t0.addingTimeInterval(300)
            )
        )
    }

    // MARK: unknown person gate

    func testAnUnknownPersonRefreshesOncePerOrganisation() {
        XCTAssertTrue(LiveListenerAttachPolicy.shouldRefreshForUnknownPerson(organizationId: "Org-1", alreadyRefreshed: []))
        XCTAssertFalse(LiveListenerAttachPolicy.shouldRefreshForUnknownPerson(organizationId: "Org-1", alreadyRefreshed: ["org-1"]))
        XCTAssertTrue(LiveListenerAttachPolicy.shouldRefreshForUnknownPerson(organizationId: "org-2", alreadyRefreshed: ["org-1"]))
        XCTAssertFalse(LiveListenerAttachPolicy.shouldRefreshForUnknownPerson(organizationId: " ", alreadyRefreshed: []))
    }

    func testTheUnknownPersonRefreshWaitsForBothPeopleListsToLoadForTheOpenOrganisation() {
        XCTAssertFalse(LiveListenerAttachPolicy.peopleListsLoaded(organizationId: "ORG", operativesLoadedFor: nil, rosterLoadedFor: "org"))
        XCTAssertFalse(LiveListenerAttachPolicy.peopleListsLoaded(organizationId: "ORG", operativesLoadedFor: "org", rosterLoadedFor: "other"))
        XCTAssertTrue(LiveListenerAttachPolicy.peopleListsLoaded(organizationId: "ORG", operativesLoadedFor: "org ", rosterLoadedFor: "Org"))
    }

    // MARK: clock

    func testTheClockRecordsAttachServerSnapshotsAndFailures() {
        let clock = LiveListenerClock()
        clock.markAttached(key: "operatives", organizationId: "ORG", at: t0)
        XCTAssertEqual(clock.attachedAt(key: "operatives", organizationId: "org"), t0, "organisation ids without case")
        XCTAssertEqual(clock.markFailed(key: "operatives", organizationId: "org"), 1)
        XCTAssertNil(clock.attachedAt(key: "operatives", organizationId: "org"), "a failed listener is not attached")
        XCTAssertEqual(clock.markFailed(key: "operatives", organizationId: "org"), 2)
        clock.markServerSnapshot(key: "operatives", organizationId: "org", at: t0)
        XCTAssertEqual(clock.markFailed(key: "operatives", organizationId: "org"), 1, "a server snapshot resets the count")
        clock.resetFailures(organizationId: "ORG")
        XCTAssertEqual(clock.markFailed(key: "operatives", organizationId: "org"), 1, "a foreground return starts afresh")
        XCTAssertEqual(clock.lastServerSnapshotAt(key: "operatives", organizationId: "ORG"), t0)
    }

    // MARK: part 2 — organisation settings, single documents, planned listeners

    func testARetryAttachesOnlyWhileTheSameOrganisationIsOpenAndSignedIn() {
        XCTAssertTrue(LiveListenerAttachPolicy.mayRetryAttach(listenerOrganizationId: "ORG", currentOrganizationId: " org ", isAuthenticated: true))
        XCTAssertFalse(LiveListenerAttachPolicy.mayRetryAttach(listenerOrganizationId: "ORG", currentOrganizationId: "other", isAuthenticated: true), "never another company's listener after a switch")
        XCTAssertFalse(LiveListenerAttachPolicy.mayRetryAttach(listenerOrganizationId: "ORG", currentOrganizationId: "ORG", isAuthenticated: false), "never after sign-out")
        XCTAssertFalse(LiveListenerAttachPolicy.mayRetryAttach(listenerOrganizationId: "ORG", currentOrganizationId: nil, isAuthenticated: true))
        XCTAssertFalse(LiveListenerAttachPolicy.mayRetryAttach(listenerOrganizationId: " ", currentOrganizationId: " ", isAuthenticated: true))
    }

    func testTheSettingsListenerIsReattachedAloneAfterAFailureAndReplacedOnASwitch() {
        typealias A = LiveListenerAttachPolicy.OrganizationDocumentAttach
        XCTAssertEqual(LiveListenerAttachPolicy.organizationDocumentAttach(activeTarget: nil, requestedTarget: "org:a", hasRegistration: false), A.replace, "first attach: as before")
        XCTAssertEqual(LiveListenerAttachPolicy.organizationDocumentAttach(activeTarget: "org:a", requestedTarget: "org:a", hasRegistration: true), A.keep, "never two listeners")
        XCTAssertEqual(LiveListenerAttachPolicy.organizationDocumentAttach(activeTarget: "org:a", requestedTarget: "org:a", hasRegistration: false), A.reattachSameOrganization, "a failed listener comes back without stopping the others")
        XCTAssertEqual(LiveListenerAttachPolicy.organizationDocumentAttach(activeTarget: "org:a", requestedTarget: "org:b", hasRegistration: false), A.replace, "a switch after a failure is still a full switch")
        XCTAssertEqual(LiveListenerAttachPolicy.organizationDocumentAttach(activeTarget: "org:a", requestedTarget: "org:b", hasRegistration: true), A.replace)
        XCTAssertEqual(LiveListenerAttachPolicy.organizationDocumentAttach(activeTarget: "org:a", requestedTarget: "  ", hasRegistration: false), A.keep)
    }

    func testAPlannedListenerIsAttachedOnlyWhenMissingNeverTornDownWhenSlow() {
        XCTAssertFalse(LiveListenerAttachPolicy.plannedListenerNeedsReattach(listenerRecorded: false, online: false), "offline: the cache is all there is")
        XCTAssertTrue(LiveListenerAttachPolicy.plannedListenerNeedsReattach(listenerRecorded: false, online: true), "no listener at all")
        XCTAssertFalse(LiveListenerAttachPolicy.plannedListenerNeedsReattach(listenerRecorded: true, online: true), "a recorded listener, however slow, is left alone")
    }

    func testALateFailureOfAReplacedSettingsListenerIsIgnored() {
        let current = UUID()
        let replaced = UUID()
        XCTAssertTrue(LiveListenerAttachPolicy.acceptsOrganizationDocumentFailure(failedGeneration: current, currentGeneration: current, failedTarget: "org:a", activeTarget: "org:a"))
        XCTAssertFalse(LiveListenerAttachPolicy.acceptsOrganizationDocumentFailure(failedGeneration: replaced, currentGeneration: current, failedTarget: "org:a", activeTarget: "org:a"), "a watchdog re-attach replaced it")
        XCTAssertFalse(LiveListenerAttachPolicy.acceptsOrganizationDocumentFailure(failedGeneration: current, currentGeneration: current, failedTarget: "org:a", activeTarget: "org:b"), "the organisation was switched")
        XCTAssertFalse(LiveListenerAttachPolicy.acceptsOrganizationDocumentFailure(failedGeneration: current, currentGeneration: current, failedTarget: "org:a", activeTarget: nil), "signed out")
    }

    func testAStoppedListenerIsNotReattachedByAPendingRetry() {
        let registry = OrgListenerRegistry()
        let mark = registry.stopMark(key: "timesheet")
        let token = registry.set(key: "timesheet", target: "timesheet:a", remove: {})
        registry.remove(key: "timesheet", token: token)
        XCTAssertEqual(registry.stopMark(key: "timesheet"), mark, "a failed listener dropping itself is not a stop")
        registry.remove(key: "timesheet")
        XCTAssertNotEqual(registry.stopMark(key: "timesheet"), mark, "the screen closed: the retry must not attach it again")
        let other = registry.stopMark(key: "jobTypes")
        registry.removeAll()
        XCTAssertNotEqual(registry.stopMark(key: "jobTypes"), other, "an organisation switch or sign-out stops every key")
    }

    func testADocumentOnlyPlanCountsAsAnsweredOnceEachDocumentAnsweredOrFailed() {
        let ledger = DataParityListenerLedger()
        let generation = ledger.begin(key: "projects", organizationId: "ORG", sourceCount: 2)
        ledger.record(key: "projects", generation: generation, source: 0, ids: ["J1"], fromCache: true, hasPendingWrites: false)
        XCTAssertEqual(ledger.snapshot(key: "projects", organizationId: "org")?.serverSnapshot, false, "cache only")
        // The server confirming the cached copy (a metadata-only snapshot) is recorded, though not delivered.
        ledger.record(key: "projects", generation: generation, source: 0, ids: ["J1"], fromCache: false, hasPendingWrites: false)
        XCTAssertEqual(ledger.snapshot(key: "projects", organizationId: "org")?.serverSnapshot, false, "the other document has not answered")
        // A job the operative may not read: refused, and counted as answered.
        ledger.markFailed(key: "projects", generation: generation, source: 1)
        XCTAssertEqual(ledger.snapshot(key: "projects", organizationId: "org")?.serverSnapshot, true)
        XCTAssertEqual(ledger.snapshot(key: "projects", organizationId: "org")?.ids, ["J1"])
    }

    func testTheDeduperComparesNullAndNumbersByValue() {
        let deduper = DocumentSnapshotDeduper()
        XCTAssertTrue(deduper.shouldDeliver(["a": NSNull(), "n": NSNumber(value: 1)]))
        XCTAssertFalse(deduper.shouldDeliver(["a": NSNull(), "n": 1]), "NSNull equals NSNull; a bridged 1 equals NSNumber 1")
        XCTAssertTrue(deduper.shouldDeliver(["a": 0, "n": 1]), "a value replacing null is a change")
        XCTAssertTrue(deduper.shouldDeliver(["a": 0, "n": 1.5]), "a number change is a change")
        XCTAssertTrue(deduper.shouldDeliver(["a": 0, "n": 1.5, "list": [NSNull(), "x"] as [Any]]), "a new field is a change")
        XCTAssertFalse(deduper.shouldDeliver(["a": 0, "n": 1.5, "list": [NSNull(), "x"] as [Any]]))
    }

    func testTheWatchdogChecksEveryPlannedCollection() {
        XCTAssertEqual(
            Set(LiveListenerAttachPolicy.plannedWatchdogKeys),
            ["projects", "smallWorks", "subcontractorBookings", "bookings", "managerSiteBookings"]
        )
    }

    func testASingleDocumentPassesOnOnlyDataChanges() {
        let deduper = DocumentSnapshotDeduper()
        XCTAssertTrue(deduper.shouldDeliver(["name": "A", "n": 1]), "the first snapshot always")
        XCTAssertFalse(deduper.shouldDeliver(["name": "A", "n": 1]), "the server confirming the cached copy changes nothing")
        XCTAssertTrue(deduper.shouldDeliver(["name": "B", "n": 1]))
        XCTAssertTrue(deduper.shouldDeliver(nil), "the document was deleted")
        XCTAssertFalse(deduper.shouldDeliver(nil))
        XCTAssertTrue(deduper.shouldDeliver(["name": "B", "n": 1]), "and created again")

        let missingFirst = DocumentSnapshotDeduper()
        XCTAssertTrue(missingFirst.shouldDeliver(nil), "a missing document is still the first answer")
    }

    func testTheClockKeepsOrganisationSettingsAndPlannedKeysApart() {
        let clock = LiveListenerClock()
        clock.markAttached(key: "organization", organizationId: "ORG", at: t0)
        clock.markAttached(key: "projects", organizationId: "ORG", at: t0.addingTimeInterval(5))
        XCTAssertEqual(clock.attachedAt(key: "organization", organizationId: "org"), t0)
        XCTAssertEqual(clock.attachedAt(key: "projects", organizationId: "org"), t0.addingTimeInterval(5))
        XCTAssertNil(clock.attachedAt(key: "organization", organizationId: "other"), "never another company's")
    }
}
