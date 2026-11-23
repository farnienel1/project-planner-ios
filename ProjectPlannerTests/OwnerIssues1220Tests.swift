import XCTest
@testable import Project_Planner

/// Owner issues 12, 13, 14 and 20 (17 Nov, iPhone): the organisation hub's "Since …" pill reads the stored creation date,
/// the hub header shows the company logo, Warnings' Book labour follows `canScheduleOperatives`, and the Timesheets
/// landing and User Timesheets header count the same rows as web.
@MainActor
final class OwnerIssues1220Tests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Issue 12 — "Since Nov '26"

    func testStoredCreatedAtReadsAFirestoreTimestampMap() throws {
        // 6 Oct 2026 12:00 UTC, as `FirebaseBackend.firestoreJSON` turns a Timestamp.
        let raw: [String: Any] = ["createdAt": ["seconds": 1_791_288_000, "nanoseconds": 0]]
        let date = try XCTUnwrap(Organization.storedCreatedAt(fromJSON: raw))
        XCTAssertEqual(date.timeIntervalSince1970, 1_791_288_000, accuracy: 0.5)
    }

    func testStoredCreatedAtReadsEpochMillisAndIsoText() throws {
        let ms = try XCTUnwrap(Organization.storedCreatedAt(fromJSON: ["createdAt": 1_791_288_000_000.0]))
        XCTAssertEqual(ms.timeIntervalSince1970, 1_791_288_000, accuracy: 0.5)
        let iso = try XCTUnwrap(Organization.storedCreatedAt(fromJSON: ["createdAt": "2026-10-06T12:00:00Z"]))
        XCTAssertEqual(iso.timeIntervalSince1970, 1_791_288_000, accuracy: 0.5)
    }

    func testMissingCreatedAtIsNilNeverNow() {
        XCTAssertNil(Organization.storedCreatedAt(fromJSON: [:]))
        XCTAssertNil(Organization.storedCreatedAt(fromJSON: ["createdAt": NSNull()]))
        XCTAssertNil(Organization.storedCreatedAt(fromJSON: ["createdAt": ""]))
    }

    func testOrganizationMakeKeepsTheStoredCreationDate() {
        let org = Organization.make(
            fromFirestoreId: "org-1",
            data: ["name": "TEST-Org", "createdAt": ["seconds": 1_791_288_000, "nanoseconds": 0]],
            settings: OrganizationSettings()
        )
        XCTAssertEqual(org.storedCreatedAt?.timeIntervalSince1970 ?? 0, 1_791_288_000, accuracy: 0.5)
        XCTAssertEqual(org.createdAt.timeIntervalSince1970, 1_791_288_000, accuracy: 0.5)

        let none = Organization.make(fromFirestoreId: "org-2", data: ["name": "TEST-Org"], settings: OrganizationSettings())
        XCTAssertNil(none.storedCreatedAt)
    }

    func testStoredCreatedAtSurvivesTheLocalCache() throws {
        var org = Organization(firestoreDocumentId: "org-3", name: "TEST-Org")
        org.storedCreatedAt = Date(timeIntervalSince1970: 1_791_288_000)
        let data = try JSONEncoder().encode(org)
        let back = try JSONDecoder().decode(Organization.self, from: data)
        XCTAssertEqual(back.storedCreatedAt?.timeIntervalSince1970 ?? 0, 1_791_288_000, accuracy: 0.5)
    }

    func testHubPillReadsTheStoredDateAndShowsNothingWithoutOne() throws {
        let hub = try source("Project Planner/Views/OrganisationSettingsHubView.swift")
        XCTAssertTrue(hub.contains("guard let c = org?.storedCreatedAt else { return nil }"))
        XCTAssertFalse(hub.contains("org?.createdAt ?? Date()"))
    }

    // MARK: Issue 13 — company logo in the hub header

    func testHubHeaderLoadsTheLogoOnlyThroughSafeExternalUrl() throws {
        let hub = try source("Project Planner/Views/OrganisationSettingsHubView.swift")
        XCTAssertTrue(hub.contains("CanonicalBusinessEngine.safeExternalURL(org?.companyLogoURL)"))
        XCTAssertTrue(hub.contains("organisationSettingsHub.logo"))
    }

    // MARK: Issue 14 — Warnings' Book labour follows canScheduleOperatives

    func testWarningsBookLabourAsksTheRulebook() throws {
        let warnings = try source("Project Planner/Views/WarningsDetailView.swift")
        XCTAssertTrue(warnings.contains("userStore.canOpenJobScheduling()"))
        XCTAssertFalse(warnings.contains("userStore.hasAdminAccess() || userStore.displayUser?.permissions.manager == true"))
    }

    // MARK: Issue 20 — the same three figures as web

    func testUserTimesheetsHeaderShowsAwaitingSignedOffAndExported() throws {
        let invoicing = try source("Project Planner/Views/InvoicingView.swift")
        XCTAssertFalse(invoicing.contains("label: \"People\")"))
        XCTAssertTrue(invoicing.contains("PPStat(value: queueLoadedOnce ? \"\\(signedRows.count)\" : \"–\", label: \"Signed off\")"))
        XCTAssertTrue(invoicing.contains("label: \"Exported\")"))
    }

    func testLandingExportedCountsTheExportedListRows() throws {
        let invoicing = try source("Project Planner/Views/InvoicingView.swift")
        // The landing no longer counts only the current pay run's sheets.
        XCTAssertFalse(invoicing.contains("TimesheetApprovalPolicy.isExported(TimesheetDraftStore.load(userId: $0.id, weekStart: openWeek.start))"))
        XCTAssertTrue(invoicing.contains("landingExportedCount = rows.count"))
        XCTAssertEqual(invoicing.components(separatedBy: "ExportedTimesheetHistoryLoader.load(").count - 1, 2)
    }

    func testUnknownPersonStandInReadsLikeWeb() {
        let stand = PersonTimesheetLookup.unresolvedPerson(storedUserId: "qalpe29v-0000-0000-0000-000000000000", organizationId: "org")
        XCTAssertTrue(stand.fullName.hasPrefix(CanonicalBusinessEngine.unknownBookingPersonLabel))
        XCTAssertTrue(stand.fullName.uppercased().contains("QALPE29V"))
    }
}
