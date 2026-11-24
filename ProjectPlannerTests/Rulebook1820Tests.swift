import XCTest
import CoreLocation
@testable import Project_Planner

/// RULEBOOK 1.82.0 (web hand-off v1.82.0): site map leave for the whole company, names written per organisation, the
/// job of an older toolbox notice, and the site map's coordinate order. TEST data only.
@MainActor
final class Rulebook1820Tests: XCTestCase {
    func testSiteMapLeaveIsTheWholeCompanyOncePerPerson() {
        let day = "2026-11-25"
        let records: [[String: Any]] = [
            ["id": "h1", "userId": "U1", "startDayKey": day, "endDayKey": day, "timeSlot": "AM", "status": "approved"],
            ["id": "h2", "userId": "u1", "startDayKey": day, "endDayKey": day, "timeSlot": "PM", "status": "approved"],
            ["id": "h3", "userId": "u2", "startDayKey": day, "endDayKey": day, "status": "pending"],
            ["id": "h4", "operativeId": "op9", "startDayKey": day, "endDayKey": day, "status": "approved"],
        ]
        let summary = CanonicalBusinessEngine.siteMapLeaveSummary(
            records: records, dayKey: day, timeZone: "Europe/London", nonWorkingDayKeys: [],
            roster: [["id": "u1", "name": "Ann"]], operatives: [["id": "op9", "email": "", "name": "Bob"]]
        )
        XCTAssertEqual(summary?.onAnnualLeave, 2)
        XCTAssertEqual(summary?.people.first?.recordIds, ["h1", "h2"])
    }

    func testEveryNameEditWritesTheOrganisationEntry() {
        let home = CanonicalBusinessEngine.memberNameEditPlan(organizationId: "TEST-A", homeOrganizationId: "TEST-A")
        XCTAssertEqual(home?.writeEntry, true)
        XCTAssertEqual(home?.writeAccount, true)
        let other = CanonicalBusinessEngine.memberNameEditPlan(organizationId: "TEST-B", homeOrganizationId: "TEST-A")
        XCTAssertEqual(other?.writeEntry, true)
        XCTAssertEqual(other?.writeAccount, false)
        XCTAssertTrue(CanonicalBusinessEngine.canWriteMemberName(writerUserId: "mgr", subjectUserId: "op", writerIsAdmin: false, writerManagesOperative: true))
        XCTAssertFalse(CanonicalBusinessEngine.canWriteMemberName(writerUserId: "mgr", subjectUserId: "op", writerIsAdmin: false))
        XCTAssertTrue(CanonicalBusinessEngine.memberNameEntryMissing(userId: "u9", aliases: [], names: [:], serverRead: true))
        XCTAssertFalse(CanonicalBusinessEngine.memberNameEntryMissing(userId: "u9", aliases: [], names: [:], serverRead: false))
        XCTAssertEqual(CanonicalBusinessEngine.memberNameJoinEntry([("", ""), ("Ann", "Lee")])?.firstName, "Ann")
    }

    func testOlderToolboxNoticeFindsItsJob() {
        let found = CanonicalBusinessEngine.healthSafetyIssueJob(issueId: "issue-9", candidates: [
            (jobId: "p1", collection: "projects", documents: [nil, ["issues": [["id": "other"]]]]),
            (jobId: "sw2", collection: "smallWorks", documents: [["issues": [["id": "ISSUE-9", "title": "Ladders"]]]]),
        ])
        XCTAssertEqual(found?.jobId, "sw2")
        XCTAssertEqual(found?.collection, "smallWorks")
        XCTAssertNil(CanonicalBusinessEngine.healthSafetyIssueJob(issueId: "none", candidates: []))
    }

    func testSiteMapSavedPinWinsThenLatLngTextThenGeocoding() async {
        var geocoded: [String] = []
        let geocode: (String) async -> CLLocationCoordinate2D? = { address in
            geocoded.append(address)
            return CLLocationCoordinate2D(latitude: 1, longitude: 1)
        }
        let pin = await SiteMapCoordinate.resolve(latitude: 51.5, longitude: -0.12, address: "1 High St, AB1 2CD", geocode: geocode)
        XCTAssertEqual(pin?.latitude, 51.5)
        let typed = await SiteMapCoordinate.resolve(latitude: nil, longitude: nil, address: "52.10000, -1.20000", geocode: geocode)
        XCTAssertEqual(typed?.latitude, 52.1)
        XCTAssertTrue(geocoded.isEmpty)
        let looked = await SiteMapCoordinate.resolve(latitude: 0, longitude: 0, address: "1 High St, AB1 2CD", geocode: geocode)
        XCTAssertEqual(looked?.latitude, 1)
        XCTAssertEqual(geocoded, ["1 High St, AB1 2CD"])
        let none = await SiteMapCoordinate.resolve(latitude: nil, longitude: nil, address: "  ", geocode: geocode)
        XCTAssertNil(none)
    }
}
