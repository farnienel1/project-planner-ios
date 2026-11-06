//
//  Rulebook+WorksLists.swift
//  Project Planner
//
//  RULEBOOK 1.21.0 / 1.21.1 §21 (web `lib/canonical/worksLists.ts`): which jobs appear in which list, under which tab,
//  in which count, for which viewer, and which jobs a person may book onto. Every answer comes from the packed script
//  through `CanonicalBusinessEngine.callJSON` and is memoised by its exact input, so a list body never runs the script
//  per row. Swift only maps `Project` and the stores' rows into the script's plain-data inputs and maps the answer back.
//

import Foundation

/// `WorksListContext`: everything a job list may need besides the jobs and the viewer, as plain rows.
nonisolated struct RulebookWorksListContext {
    /// `organizations/{orgId}/managers` rows `{ id, email }` (`JobAccessContext.managers`).
    var managers: [[String: String]] = []
    /// `organizations/{orgId}/operatives` rows `{ id, email }`.
    var operatives: [[String: String]] = []
    /// Labour bookings `{ projectId, operativeId, status }` in their stored spelling.
    var bookings: [[String: String]] = []
    /// Manager site bookings `{ userId, locationType, locationId }`.
    var managerSiteBookings: [[String: String]] = []
    /// Tasks `{ projectId, assignedOperativeIds, assignedManagerIds }`.
    var tasks: [[String: Any]] = []
    /// Jobs the viewer has a deadline on, by id.
    var deadlineJobIds: [String] = []
    /// `bookableJobs` only: `bookings` (default) or `managerSiteBookings`.
    var bookingCollection: String? = nil

    var json: [String: Any] {
        var out: [String: Any] = [
            "managers": managers,
            "operatives": operatives,
            "bookings": bookings,
            "managerSiteBookings": managerSiteBookings,
            "tasks": tasks,
            "deadlineJobIds": deadlineJobIds,
        ]
        if let bookingCollection { out["bookingCollection"] = bookingCollection }
        return out
    }
}

/// `WorksTabCounts`: `{ all, active, upcoming, completed }`; active + upcoming + completed = all.
nonisolated struct RulebookWorksTabCounts: Equatable, Sendable {
    var all: Int
    var active: Int
    var upcoming: Int
    var completed: Int
}

extension Project {
    /// This job as a `WorksListJob` (§21): its stored id, collection, `isLive`, organisation-zone start and end day,
    /// manager fields and per-job hide lists. `_i` carries the caller's index so the answer maps back to this value.
    func worksListJSON(index: Int) -> [String: Any] {
        var row: [String: Any] = jobAccessFields
        row["id"] = documentId
        row["collection"] = jobType == .smallWorks ? "smallWorks" : "projects"
        row["isLive"] = isLive
        row["startDayKey"] = OrganizationRulebookContext.dayKey(startDate)
        row["endDayKey"] = OrganizationRulebookContext.dayKey(endDate)
        row["hiddenOperativeUserIds"] = hiddenOperativeUserIds.sorted()
        row["_i"] = index
        return row
    }
}

extension CanonicalBusinessEngine {
    nonisolated private struct IndexBox: Sendable { let indices: [Int] }

    nonisolated private static let worksIndexMemo = RulebookAnswerMemo<String, IndexBox>(limit: 256)
    nonisolated private static let worksValueMemo = RulebookAnswerMemo<String, RulebookJSONBox>(limit: 512)

    nonisolated private static func memoKey(_ function: String, _ arguments: [Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(arguments),
              let bytes = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else { return nil }
        return function + "|" + (String(data: bytes, encoding: .utf8) ?? "")
    }

    /// Calls a §21 function that returns jobs and maps the answer back to the caller's values by `_i`. Nil when the
    /// script did not answer.
    @MainActor private static func worksJobs(_ function: String, jobs: [Project], extra: [Any]) -> [Project]? {
        let rows = jobs.enumerated().map { $0.element.worksListJSON(index: $0.offset) }
        let arguments: [Any] = [rows] + extra
        let compute: () -> IndexBox? = {
            guard let answer = callJSON(function, arguments: arguments) as? [[String: Any]] else { return nil }
            return IndexBox(indices: answer.compactMap { ($0["_i"] as? NSNumber)?.intValue })
        }
        let box = memoKey(function, arguments).flatMap { worksIndexMemo.value(for: $0, compute: compute) } ?? compute()
        guard let indices = box?.indices else { return nil }
        return indices.compactMap { $0 >= 0 && $0 < jobs.count ? jobs[$0] : nil }
    }

    /// A §21 call returning a plain value, memoised by input. Nil when the script did not answer.
    nonisolated private static func worksValue(_ function: String, _ arguments: [Any]) -> Any? {
        let compute: () -> RulebookJSONBox? = {
            guard let value = callJSON(function, arguments: arguments), !(value is NSNull) else { return nil }
            return RulebookJSONBox(object: ["v": value])
        }
        let box = memoKey(function, arguments).flatMap { worksValueMemo.value(for: $0, compute: compute) } ?? compute()
        return box?.object["v"]
    }

    nonisolated private static func nowArgument(_ now: Date) -> String { isoString(from: now) }

    // MARK: - §21 functions

    /// `worksListMembership(jobs, kind)`: every document of that kind (the collection decides, never `jobType`), once by
    /// id — two jobs with one job number both stay — inactive included. The input order is kept.
    @MainActor static func worksListMembership(_ jobs: [Project], kind: JobKind) -> [Project] {
        worksJobs("worksListMembership", jobs: jobs, extra: [kind.rawValue])
            ?? jobs.filter { $0.jobKind == kind }
    }

    /// `visibleJobs(jobs, viewer, context)`: the jobs this viewer sees (§17, by account id and email, never by name).
    /// Empty with no viewer or no answer.
    @MainActor static func visibleJobs(_ jobs: [Project], viewer: JobAccessViewer?, context: RulebookWorksListContext) -> [Project] {
        guard let viewer else { return [] }
        return worksJobs("visibleJobs", jobs: jobs, extra: [viewer.json, context.json]) ?? []
    }

    /// `bookableJobs(jobs, viewer, context)` (1.21.1): visible, not inactive and `canWriteBooking` for
    /// `context.bookingCollection`. The job's start and end dates are never checked. Empty with no viewer or no answer.
    @MainActor static func bookableJobs(_ jobs: [Project], viewer: JobAccessViewer?, context: RulebookWorksListContext) -> [Project] {
        guard let viewer else { return [] }
        return worksJobs("bookableJobs", jobs: jobs, extra: [viewer.json, context.json]) ?? []
    }

    /// `worksInTab(jobs, tab, now, timeZone)`: the jobs under `active`, `upcoming`, `completed` or `all`, in order.
    @MainActor static func worksInTab(
        _ jobs: [Project],
        tab: String,
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> [Project] {
        worksJobs("worksInTab", jobs: jobs, extra: [tab, nowArgument(now), timeZone]) ?? (tab == "all" ? jobs : [])
    }

    /// `operativeJobIds(viewer, context)`: the jobs of the viewer's own labour bookings, tasks and deadlines.
    nonisolated static func operativeJobIds(viewer: JobAccessViewer?, context: RulebookWorksListContext) -> [String] {
        guard let viewer else { return [] }
        return worksValue("operativeJobIds", [viewer.json, context.json]) as? [String] ?? []
    }

    /// `worksListPersonIds(viewer, context)`: every id a booking, task or list may name the viewer by (account ids, and
    /// the operatives and managers rows on their email). Never by name.
    nonisolated static func worksListPersonIds(viewer: JobAccessViewer?, context: RulebookWorksListContext) -> [String] {
        guard let viewer else { return [] }
        return worksValue("worksListPersonIds", [viewer.json, context.json]) as? [String] ?? []
    }

    /// `jobWorkStatus(job, now, timeZone)`: `active`, `upcoming`, `completed` or `inactive` on `now`'s
    /// organisation-zone day. Nil when the script did not answer.
    @MainActor static func jobWorkStatus(
        _ job: Project,
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> String? {
        worksValue("jobWorkStatus", [job.worksListJSON(index: 0), nowArgument(now), timeZone]) as? String
    }

    /// `worksTab(status)`: the tab a status belongs to (an inactive job is under `completed`).
    nonisolated static func worksTab(_ status: String) -> String {
        worksValue("worksTab", [status]) as? String ?? (status == "inactive" ? "completed" : status)
    }

    /// `worksTabCounts(jobs, now, timeZone)`. Nil when the script did not answer.
    @MainActor static func worksTabCounts(
        _ jobs: [Project],
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookWorksTabCounts? {
        let rows = jobs.enumerated().map { $0.element.worksListJSON(index: $0.offset) }
        guard let map = worksValue("worksTabCounts", [rows, nowArgument(now), timeZone]) as? [String: Any] else { return nil }
        func count(_ key: String) -> Int { (map[key] as? NSNumber)?.intValue ?? 0 }
        return RulebookWorksTabCounts(all: count("all"), active: count("active"), upcoming: count("upcoming"), completed: count("completed"))
    }

    /// `activeJobsCount(jobs, viewer, context, now, timeZone)`: Home "active projects" — the jobs the viewer sees that
    /// are active today. 0 with no viewer or no answer.
    @MainActor static func activeJobsCount(
        _ jobs: [Project],
        viewer: JobAccessViewer?,
        context: RulebookWorksListContext,
        now: Date = Date(),
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> Int {
        guard let viewer else { return 0 }
        let rows = jobs.enumerated().map { $0.element.worksListJSON(index: $0.offset) }
        let value = worksValue("activeJobsCount", [rows, viewer.json, context.json, nowArgument(now), timeZone])
        return (value as? NSNumber)?.intValue ?? 0
    }
}

// MARK: - Building the context from the stores

@MainActor
enum WorksListContextBuilder {
    /// The §21 context from what this device has loaded. `deadlineJobIds` are stored job ids.
    static func context(
        operatives: [Operative],
        bookings: [Booking],
        managerSiteBookings: [ManagerSiteBooking],
        tasks: [ProjectTask],
        deadlineJobIds: [String] = [],
        bookingCollection: String? = nil
    ) -> RulebookWorksListContext {
        RulebookWorksListContext(
            managers: JobAccessContext.managers.compactMap { row in
                guard let id = row["id"] as? String else { return nil }
                return ["id": id, "email": row["email"] as? String ?? ""]
            },
            operatives: operatives.map { ["id": $0.documentId, "email": $0.email] },
            bookings: bookings.map {
                [
                    "projectId": $0.storedProjectId,
                    "operativeId": Booking.storedOperativeId(for: $0.operativeId),
                    "status": $0.status.rawValue,
                ]
            },
            managerSiteBookings: managerSiteBookings.map {
                [
                    "userId": $0.userId,
                    "locationType": $0.locationType.rawValue,
                    "locationId": $0.locationKey ?? $0.locationId.map { WorkDocumentKeys.storedId(for: $0) } ?? "",
                ]
            },
            tasks: tasks.map { task in
                [
                    "projectId": WorkDocumentKeys.storedId(for: task.projectId),
                    "assignedOperativeIds": (task.assignedOperativeIds + [task.assignedOperativeId].compactMap { $0 })
                        .map { Booking.storedOperativeId(for: $0) },
                    "assignedManagerIds": (task.assignedManagerIds + [task.assignedManagerId].compactMap { $0 }).map(\.uuidString),
                ]
            },
            deadlineJobIds: deadlineJobIds,
            bookingCollection: bookingCollection
        )
    }
}

// MARK: - My Projects / My Small works (RULEBOOK 1.33.0 §21)

/// `MyWorksPicks`: the person's own pick list per kind. `nil` means never saved (the list is pre-filled with the jobs
/// they manage, `myWorksDefaultIds`); an empty array is a saved, empty list.
nonisolated struct MyWorksPicks: Equatable, Sendable {
    var projects: [String]?
    var smallWorks: [String]?

    static let neverSaved = MyWorksPicks(projects: nil, smallWorks: nil)

    var json: [String: Any] {
        ["projects": projects.map { $0 as Any } ?? NSNull(), "smallWorks": smallWorks.map { $0 as Any } ?? NSNull()]
    }
}

extension CanonicalBusinessEngine {
    /// `myWorksPicksPath(organizationId, uid)`: `organizations/{orgId}/worksListPicks/{uid}`. Nil when either id is blank
    /// or the script did not answer.
    nonisolated static func myWorksPicksPath(organizationId: String, uid: String) -> String? {
        let org = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !org.isEmpty, !user.isEmpty else { return nil }
        return callJSON("myWorksPicksPath", arguments: [org, user]) as? String
    }

    /// `parseMyWorksPicks(data)`: a missing document or field is never saved (`nil`). Only the two lists are passed (the
    /// stored `updatedAt` is a Firestore timestamp). Never saved when the script did not answer.
    nonisolated static func parseMyWorksPicks(_ data: [String: Any]?) -> MyWorksPicks {
        var row: [String: Any] = [:]
        for key in ["projects", "smallWorks"] {
            if let list = data?[key] as? [Any] { row[key] = list.compactMap { $0 as? String } }
        }
        guard let answer = callJSON("parseMyWorksPicks", arguments: [row]) as? [String: Any] else { return .neverSaved }
        return MyWorksPicks(projects: answer["projects"] as? [String], smallWorks: answer["smallWorks"] as? [String])
    }

    /// `myWorksPicksWriteFields(kind, ids, updatedAt)`: that kind's list (de-duplicated, capped) and `updatedAt`. The
    /// caller replaces `updatedAt` with the server timestamp and merges. Nil when the script did not answer.
    nonisolated static func myWorksPicksWriteFields(kind: JobKind, ids: [String]) -> [String: Any]? {
        callJSON("myWorksPicksWriteFields", arguments: [kind.rawValue, ids, "updatedAt"]) as? [String: Any]
    }

    /// `hasMyWorksList(viewer)`: admins, super admins and managers outside operative mode; never operatives.
    nonisolated static func hasMyWorksList(_ viewer: JobAccessViewer?) -> Bool {
        guard let viewer else { return false }
        return callJSON("hasMyWorksList", arguments: [viewer.json]) as? Bool ?? false
    }

    /// `defaultWorksListTab(viewer)`: `mine` for people with the My list, else `active`.
    nonisolated static func defaultWorksListTab(_ viewer: JobAccessViewer?) -> String {
        callJSON("defaultWorksListTab", arguments: [viewer?.json ?? NSNull()]) as? String ?? "active"
    }

    /// `myWorksTabLabel(kind)`: "My Projects" / "My Small works".
    nonisolated static func myWorksTabLabel(_ kind: JobKind) -> String {
        callJSON("myWorksTabLabel", arguments: [kind.rawValue]) as? String ?? (kind == .smallWorks ? "My Small works" : "My Projects")
    }

    /// `myWorksEmptyTitle(kind)`: "No projects in your list yet" / "No small works in your list yet".
    nonisolated static func myWorksEmptyTitle(_ kind: JobKind) -> String {
        callJSON("myWorksEmptyTitle", arguments: [kind.rawValue]) as? String ?? ""
    }

    /// `myWorksEmptyActionLabel(kind)`: the empty state's button, which opens the ⚙ picker.
    nonisolated static func myWorksEmptyActionLabel(_ kind: JobKind) -> String {
        callJSON("myWorksEmptyActionLabel", arguments: [kind.rawValue]) as? String ?? ""
    }

    /// `myWorksList(jobs, picks, viewer, context, kind)`: the jobs of `kind` the viewer sees whose id is on their list
    /// (saved picks, else the jobs they manage), every status, in list order. Empty with no viewer or no answer.
    @MainActor static func myWorksList(
        _ jobs: [Project],
        picks: MyWorksPicks,
        viewer: JobAccessViewer?,
        context: RulebookWorksListContext,
        kind: JobKind
    ) -> [Project] {
        guard let viewer else { return [] }
        return worksJobs("myWorksList", jobs: jobs, extra: [picks.json, viewer.json, context.json, kind.rawValue]) ?? []
    }

    /// `myWorksPickerRows(jobs, picks, viewer, context, kind)`: every job of `kind` the viewer sees, in list order, with
    /// whether it is on their list. Empty with no viewer or no answer.
    @MainActor static func myWorksPickerRows(
        _ jobs: [Project],
        picks: MyWorksPicks,
        viewer: JobAccessViewer?,
        context: RulebookWorksListContext,
        kind: JobKind
    ) -> [(job: Project, picked: Bool)] {
        guard let viewer else { return [] }
        let rows = jobs.enumerated().map { $0.element.worksListJSON(index: $0.offset) }
        guard let answer = callJSON(
            "myWorksPickerRows",
            arguments: [rows, picks.json, viewer.json, context.json, kind.rawValue]
        ) as? [[String: Any]] else { return [] }
        return answer.compactMap { row in
            guard let job = row["job"] as? [String: Any],
                  let index = (job["_i"] as? NSNumber)?.intValue,
                  index >= 0, index < jobs.count else { return nil }
            return (jobs[index], row["picked"] as? Bool ?? false)
        }
    }

    /// `myWorksPicksAfterToggle(current, jobId, picked)`: the list after ticking or unticking one job. `current` when
    /// the script did not answer.
    nonisolated static func myWorksPicksAfterToggle(_ current: [String], jobId: String, picked: Bool) -> [String] {
        callJSON("myWorksPicksAfterToggle", arguments: [current, jobId, picked]) as? [String] ?? current
    }
}
