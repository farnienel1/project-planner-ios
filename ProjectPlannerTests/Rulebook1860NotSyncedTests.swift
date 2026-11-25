import XCTest
@testable import Project_Planner

/// RULEBOOK 1.86.0 §2 (owner decision 24 Nov): the "Not synced" page on iOS through `CanonicalBusinessEngine` —
/// `offlineSyncResultRows`, `offlineSyncResultNotificationText`, `offlineReplaceOrganizationReadDecision` — and the phone's
/// own store (`OfflineSyncResultStore`: rows per account, "Got it"). Expected text follows the web tests in
/// `lib/canonical/canonical.test.ts` ("1.86.0 offlineSyncResultRows").
@MainActor
final class Rulebook1860NotSyncedTests: XCTestCase {
    private let old = OfflineSyncSummaryBooking(dayKey: "2026-11-24", place: "J-1042 · Station Road", startTime: "07:00", endTime: "16:00")

    func testRowsSayWhatWasTriedAndWhatChanged() {
        var live = old
        live.startTime = "08:00"
        live.endTime = "17:00"
        let replace = OfflineSyncResultRecord(
            id: "r1", organizationId: "TEST-ORG", userId: "u1", kind: "replace", reason: "changed",
            attempted: OfflineSyncSummaryBooking(dayKey: "2026-11-24", place: "Office", timeSlot: "FULL_DAY"),
            replaced: [old], live: live, liveRead: true, atMs: 1_795_529_100_000
        )
        let gone = OfflineSyncResultRecord(
            id: "d1", organizationId: "TEST-ORG", userId: "u1", kind: "delete", reason: "changed",
            attempted: old, live: nil, liveRead: true, atMs: 1_795_529_000_000
        )
        let rows = CanonicalBusinessEngine.offlineSyncResultRows([replace.ruleInput, gone.ruleInput], timeZone: "Europe/London")
        XCTAssertEqual(rows.map(\.id), ["r1", "d1"])
        XCTAssertEqual(rows[0].title, "You tried to replace Tue 24 Nov · J-1042 · Station Road · 07:00–16:00 with Tue 24 Nov · Office · Full day")
        XCTAssertEqual(rows[0].detail, "Now 08:00–17:00")
        XCTAssertEqual(rows[0].dayKey, "2026-11-24")
        XCTAssertEqual(rows[1].detail, "Deleted on another device", "read as gone")
        XCTAssertEqual(rows[0].dismissLabel, "Got it")
        XCTAssertEqual(CanonicalBusinessEngine.offlineSyncResultTitle, "Not synced")
        XCTAssertEqual(
            CanonicalBusinessEngine.offlineSyncResultNotificationText(count: 2).body,
            "2 changes from this phone were not saved. Tap to see what happened."
        )
    }

    /// Owner 24 Nov (choice 12 tightened): wait only on a network failure.
    func testAnotherCompanysSettingsReadWaitsOnlyOnANetworkFailure() {
        XCTAssertEqual(CanonicalBusinessEngine.offlineReplaceOrganizationReadDecision(code: 14, exists: nil), "wait")
        XCTAssertEqual(CanonicalBusinessEngine.offlineReplaceOrganizationReadDecision(code: 4, exists: nil), "wait")
        XCTAssertEqual(CanonicalBusinessEngine.offlineReplaceOrganizationReadDecision(code: 7, exists: nil), "refusePermission")
        XCTAssertEqual(CanonicalBusinessEngine.offlineReplaceOrganizationReadDecision(code: 5, exists: nil), "refusePermission")
        XCTAssertEqual(CanonicalBusinessEngine.offlineReplaceOrganizationReadDecision(code: nil, exists: false), "refusePermission")
        XCTAssertEqual(FirebaseBackend.offlineReplaceOrganizationRefused.decision, "refusePermission")
    }

    func testTheStoreKeepsRowsPerAccountUntilGotIt() {
        let store = OfflineSyncResultStore(isolatedStorageKey: "TEST-offline-sync-results")
        store.record(OfflineSyncResultRecord(id: "e1", organizationId: "TEST-ORG", userId: "u1", kind: "edit", reason: "permission", attempted: old, atMs: 1))
        store.record(OfflineSyncResultRecord(id: "e2", organizationId: "TEST-ORG", userId: "u2", kind: "edit", reason: "missing", attempted: old, atMs: 2))
        XCTAssertEqual(store.rows(userId: "u1").map(\.id), ["e1"], "another account's rows never show")
        XCTAssertEqual(store.rows(userId: "u1").first?.detail, "You no longer have permission")
        store.dismiss(id: "e1")
        XCTAssertTrue(store.rows(userId: "u1").isEmpty)
        XCTAssertEqual(store.rows(userId: "u2").map(\.id), ["e2"])
    }

    func testPlaceLabels() {
        XCTAssertEqual(OfflineSyncSummary.placeLabel(locationType: "office", locationId: nil, customName: nil), "Office")
        XCTAssertEqual(OfflineSyncSummary.placeLabel(locationType: "custom", locationId: nil, customName: " Yard "), "Yard")
        XCTAssertEqual(OfflineSyncSummary.jobLabel("unknown-job"), "Deleted job")
    }
}
