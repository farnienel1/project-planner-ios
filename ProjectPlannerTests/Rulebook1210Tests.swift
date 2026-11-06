import XCTest
@testable import Project_Planner

/// RULEBOOK 1.21.0 / 1.21.1 §21 (job lists) on iOS through `CanonicalBusinessEngine`. The cases are the 1.21.0
/// parity-fixture cases, fed through the Swift wrappers with jobs read by the rulebook reader (`parseJobDocument`).
/// Every expected value was checked in node against the packed `canonical-business.js` (sha256 4230d8e4…6306f666) with
/// the JSON these wrappers send (`Project.worksListJSON`).
@MainActor
final class Rulebook1210Tests: XCTestCase {
    private let london = "Europe/London"

    private func job(_ id: String, smallWorks: Bool = false, _ data: [String: Any]) throws -> Project {
        try XCTUnwrap(FirebaseBackend.jobs(fromDocuments: [(id: id, data: data)], smallWorks: smallWorks).first)
    }

    private func instant(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    private func role(admin: Bool = false, manager: Bool = false, operative: Bool = false) -> CanonicalBusinessEngine.CanonicalStaffAccountRole {
        CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: admin, isManager: manager, isOperativeMode: operative)
    }

    private var operativeViewer: JobAccessViewer {
        JobAccessViewer(role: role(operative: true), projectsToggle: false, smallWorksToggle: false, uid: "U-OP", ids: ["U-OP"], email: "op@x.com")
    }

    private func managerViewer(projectsToggle: Bool) -> JobAccessViewer {
        JobAccessViewer(role: role(manager: true), projectsToggle: projectsToggle, smallWorksToggle: false, uid: "U-M", ids: ["U-M"], email: "m@x.com")
    }

    private var operativeContext: RulebookWorksListContext {
        RulebookWorksListContext(
            operatives: [["id": "OPROW-1", "email": "OP@x.com"]],
            bookings: [
                ["projectId": "J-BOOKED", "operativeId": "oprow-1", "status": "Confirmed"],
                ["projectId": "J-OTHER", "operativeId": "OPROW-1", "status": "Cancelled"],
                ["projectId": "J-HIDDEN", "operativeId": "U-OP", "status": "Confirmed"],
            ],
            tasks: [["projectId": "J-TASK", "assignedOperativeIds": ["OPROW-1"]]],
            deadlineJobIds: ["J-DEADLINE"]
        )
    }

    func testThePackedScriptIsRulebook1211OrLater() throws {
        let stamp = try XCTUnwrap(CanonicalBusinessEngine.rulebookStamp())
        let parts = stamp.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertFalse(parts.lexicographicallyPrecedes([1, 21, 1]), "rulebook \(stamp.version) predates 1.21.1")
        let names = Set(CanonicalBusinessEngine.exportNames())
        for name in [
            "worksListMembership", "visibleJobs", "operativeJobIds", "worksListPersonIds", "jobWorkStatus", "worksTab",
            "worksInTab", "worksTabCounts", "bookableJobs", "activeJobsCount",
        ] {
            XCTAssertTrue(names.contains(name), name)
        }
    }

    // MARK: Tabs and counts

    func testAnInactiveSmallWorksJobIsUnderCompletedAndAllCountsEveryRow() throws {
        let off = try job("SW-1", smallWorks: true, ["jobNumber": "S1", "isLive": false, "startDate": "2026-11-01", "endDate": "2026-11-30"])
        let live = try job("SW-2", smallWorks: true, ["jobNumber": "S2", "startDate": "2026-11-01", "endDate": "2026-11-30"])
        let later = try job("SW-3", smallWorks: true, ["jobNumber": "S3", "startDate": "2026-12-01", "endDate": "2026-12-05"])
        let now = try instant("2026-11-03T12:00:00Z")
        let counts = try XCTUnwrap(CanonicalBusinessEngine.worksTabCounts([off, live, later], now: now, timeZone: london))
        XCTAssertEqual(counts, RulebookWorksTabCounts(all: 3, active: 1, upcoming: 1, completed: 1))
        XCTAssertEqual(counts.active + counts.upcoming + counts.completed, counts.all, "the tiles add up to All")
        XCTAssertEqual(CanonicalBusinessEngine.worksInTab([off, live, later], tab: "completed", now: now, timeZone: london).map(\.documentId), ["SW-1"])
        XCTAssertEqual(
            CanonicalBusinessEngine.worksInTab([off, live, later], tab: "all", now: now, timeZone: london).map(\.documentId),
            ["SW-1", "SW-2", "SW-3"],
            "All = the list's length"
        )
        XCTAssertEqual(CanonicalBusinessEngine.worksTab("inactive"), "completed")
    }

    // MARK: List membership

    func testMembershipKeepsEveryDocumentAndTheSameJobNumberTwice() throws {
        let p1 = try job("P-1", ["jobNumber": "C646", "jobType": "Small Works", "isLive": false])
        let p2 = try job("P-2", ["jobNumber": "C646"])
        let sw = try job("SW-9", smallWorks: true, ["jobNumber": "C646", "jobType": "CAT A", "isLive": false])
        XCTAssertEqual(CanonicalBusinessEngine.worksListMembership([p1, p2, sw], kind: .projects).map(\.documentId), ["P-1", "P-2"])
        XCTAssertEqual(
            CanonicalBusinessEngine.worksListMembership([p1, p2, sw], kind: .smallWorks).map(\.documentId),
            ["SW-9"],
            "an inactive small works job typed CAT A stays a small works job"
        )
    }

    // MARK: Visibility (by account id and email, never by name)

    func testAnOperativeSeesAJobThroughATaskOnly() throws {
        let jobs = [
            try job("J-TASK", [:]),
            try job("J-BOOKED", [:]),
            try job("J-OTHER", [:]),
            try job("J-HIDDEN", smallWorks: true, ["hiddenOperativeUserIds": ["u-op"]]),
        ]
        XCTAssertEqual(
            CanonicalBusinessEngine.visibleJobs(jobs, viewer: operativeViewer, context: operativeContext).map(\.documentId),
            ["J-TASK", "J-BOOKED"],
            "a task's job and the booked job; not the cancelled booking's job, not the hidden job"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.operativeJobIds(viewer: operativeViewer, context: operativeContext),
            ["J-BOOKED", "J-HIDDEN", "J-TASK", "J-DEADLINE"]
        )
        XCTAssertTrue(CanonicalBusinessEngine.bookableJobs(jobs, viewer: operativeViewer, context: operativeContext).isEmpty, "operatives book onto no job")
    }

    /// RULEBOOK 1.33.0 §17, §21 (owner decisions 6 Nov): every manager sees every job, toggle or not, and the managers'
    /// hide list (`hiddenManagerUserIds`) is no longer read — a stored value is ignored.
    func testAManagerWithAndWithoutTheProjectsToggle() throws {
        let jobs = [
            try job("MINE", ["managerUserIds": ["U-M"]]),
            try job("NOT-MINE", ["managerUserIds": ["U-X"]]),
            try job("HIDDEN", ["managerUserIds": ["U-M"], "hiddenManagerUserIds": ["U-M"]]),
            try job("SW-OTHER", smallWorks: true, ["managerUserIds": ["U-X"]]),
        ]
        let context = RulebookWorksListContext()
        XCTAssertEqual(
            CanonicalBusinessEngine.visibleJobs(jobs, viewer: managerViewer(projectsToggle: false), context: context).map(\.documentId),
            ["MINE", "NOT-MINE", "HIDDEN", "SW-OTHER"],
            "without the toggle: every job, the stored managers' hide list ignored"
        )
        XCTAssertEqual(
            CanonicalBusinessEngine.visibleJobs(jobs, viewer: managerViewer(projectsToggle: true), context: context).map(\.documentId),
            ["MINE", "NOT-MINE", "HIDDEN", "SW-OTHER"],
            "with the Projects toggle: the same list"
        )
    }

    // MARK: Bookable jobs (1.21.1: dates never checked)

    func testAJobPastItsEndDateAndOneWithNoEndDateAreBookable() throws {
        let jobs = [
            try job("LIVE", ["managerUserIds": ["U-M"], "startDate": "2026-11-01", "endDate": "2026-11-30"]),
            try job("INACTIVE", ["managerUserIds": ["U-M"], "isLive": false, "startDate": "2026-11-01", "endDate": "2026-11-30"]),
            try job("NOT-MINE", ["managerUserIds": ["U-X"], "startDate": "2026-11-01", "endDate": "2026-11-30"]),
            try job("ENDED", ["managerUserIds": ["U-M"], "startDate": "2026-10-01", "endDate": "2026-11-02"]),
            try job("NO-END", smallWorks: true, ["managerUserIds": ["U-M"], "startDate": "2026-01-05"]),
        ]
        XCTAssertEqual(
            CanonicalBusinessEngine.bookableJobs(jobs, viewer: managerViewer(projectsToggle: false), context: RulebookWorksListContext()).map(\.documentId),
            ["LIVE", "ENDED", "NO-END"]
        )
    }

    /// RULEBOOK 1.33.0 §17, §21 (owner decisions 6 Nov): every manager sees every job, so a job they do not manage
    /// (NOT-MINE) is on their lists and counts when active today. LIVE, NOT-MINE and SW-A are active on 3 Nov; INACTIVE
    /// and ENDED are not. Before 1.33.0 the count was 2 (a manager without the toggle saw only their own jobs).
    func testHomeActiveCountIsTheActiveTabOfTheViewersLists() throws {
        let jobs = [
            try job("LIVE", ["managerUserIds": ["U-M"], "startDate": "2026-11-01", "endDate": "2026-11-30"]),
            try job("INACTIVE", ["managerUserIds": ["U-M"], "isLive": false, "startDate": "2026-11-01", "endDate": "2026-11-30"]),
            try job("NOT-MINE", ["managerUserIds": ["U-X"], "startDate": "2026-11-01", "endDate": "2026-11-30"]),
            try job("ENDED", ["managerUserIds": ["U-M"], "startDate": "2026-10-01", "endDate": "2026-11-02"]),
            try job("SW-A", smallWorks: true, ["managerUserIds": ["U-M"], "startDate": "2026-11-03", "endDate": "2026-11-03"]),
        ]
        let now = try instant("2026-11-03T12:00:00Z")
        XCTAssertEqual(
            CanonicalBusinessEngine.activeJobsCount(
                jobs, viewer: managerViewer(projectsToggle: false), context: RulebookWorksListContext(), now: now, timeZone: london
            ),
            3
        )
    }

    // MARK: Day boundary and the job number

    func testTheStatusDayIsTheOrganisationZone() throws {
        let j = try job("J", ["startDate": "2026-11-01", "endDate": "2026-11-03"])
        let lateUTC = try instant("2026-11-03T23:30:00Z")
        XCTAssertEqual(CanonicalBusinessEngine.jobWorkStatus(j, now: lateUTC, timeZone: london), "active", "still 3 Nov in London")
        XCTAssertEqual(CanonicalBusinessEngine.jobWorkStatus(j, now: lateUTC, timeZone: "Pacific/Auckland"), "completed", "already 4 Nov in Auckland")
    }

    func testANumericJobNumberIsReadAsText() throws {
        XCTAssertEqual(try job("JOB-N", ["jobNumber": 4521, "siteName": "Yard", "startDate": "2026-11-03T09:00:00Z"]).jobNumber, "4521")
    }

    func testTheListChipsComeFromTheScript() throws {
        let off = try job("SW-OFF", smallWorks: true, ["isLive": false])
        XCTAssertEqual(WorksListStatusCounts.tab(for: .inactive), "completed")
        XCTAssertTrue(WorksListStatusCounts.matches(off, chip: .completed))
        XCTAssertFalse(WorksListStatusCounts.matches(off, chip: .active))
        XCTAssertEqual(WorksListStatusCounts.from([off]).all, 1)
    }
}
