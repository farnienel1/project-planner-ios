//
//  Rulebook+TaskViewing.swift
//  Project Planner
//
//  RULEBOOK 1.91.0 §34 (owner decisions 25 Nov; web `lib/canonical/taskViewing.ts`): who sees which task
//  (`visibleTasksForViewer` — admins every task; managers the tasks on jobs they manage plus tasks assigned to or
//  created by them; operatives the tasks assigned to them), the Tasks filters and sorts (`taskFilterOptions`,
//  `filterTasks`, `sortTasks`, `TASK_SORTS`, `taskSortLabel`), and who the assignee pickers offer
//  (`taskAssigneeCandidates` — never a deleted or inactive person). Swift only maps its models into the script's rows
//  and maps the answers back (AGENTS.md Rule 0).
//

import Foundation

/// `TaskSortKey`.
nonisolated enum TaskSortChoice: String, CaseIterable, Hashable, Sendable {
    case overdueFirst = "overdue_first"
    case dueEarliest = "due_earliest"
    case dueLatest = "due_latest"
}

/// `TaskDueFilter` (without the empty "any").
nonisolated enum TaskDueFilterChoice: String, CaseIterable, Hashable, Sendable {
    case overdue, today, week, none
}

/// `TaskFilters`: '' / nil = any.
nonisolated struct TaskFilterSet: Codable, Hashable, Sendable {
    var projectId: String = ""
    var smallWorksId: String = ""
    var creatorKey: String = ""
    var assigneeKey: String = ""
    var priority: String = ""
    var due: String = ""

    static let none = TaskFilterSet()

    var json: [String: Any] {
        [
            "projectId": projectId, "smallWorksId": smallWorksId, "creatorKey": creatorKey,
            "assigneeKey": assigneeKey, "priority": priority, "due": due,
        ]
    }

    init() {}

    init(json: Any?) {
        let row = json as? [String: Any] ?? [:]
        projectId = row["projectId"] as? String ?? ""
        smallWorksId = row["smallWorksId"] as? String ?? ""
        creatorKey = row["creatorKey"] as? String ?? ""
        assigneeKey = row["assigneeKey"] as? String ?? ""
        priority = row["priority"] as? String ?? ""
        due = row["due"] as? String ?? ""
    }
}

/// `TaskFilterOption`.
nonisolated struct TaskFilterChoice: Hashable, Sendable, Identifiable {
    var value: String
    var label: String
    var count: Int
    var id: String { value }
}

/// `taskAssigneeCandidates` → the row ids offered and the rows whose person is gone (all lower case).
nonisolated struct TaskAssigneeCandidateIds: Sendable {
    var managerIds: Set<String>
    var operativeIds: Set<String>
    var goneIds: Set<String>
}

@MainActor
enum TaskViewingRulebook {
    // MARK: Rows

    /// A `managers` row as the task rules read it (ids in the app's UUID space, as tasks store them).
    static func managerRow(_ manager: Manager) -> [String: Any] {
        [
            "id": manager.id.uuidString,
            "email": manager.email,
            "linkedUserId": manager.linkedUserId.map { $0 as Any } ?? NSNull(),
            "isActive": manager.isActive,
            "firstName": manager.firstName,
            "lastName": manager.lastName,
        ]
    }

    /// An `operatives` row as the task rules read it.
    static func operativeRow(_ operative: Operative) -> [String: Any] {
        [
            "id": Booking.operativeMatchKey(for: operative.id),
            "email": operative.email,
            "linkedUserId": operative.linkedUserId.map { $0 as Any } ?? NSNull(),
            "isActive": operative.isActive,
            "firstName": operative.firstName,
            "lastName": operative.lastName,
        ]
    }

    /// A task as the visibility and filter rules read it (the §34 row plus job, creator and assignees).
    static func taskRow(_ task: ProjectTask) -> [String: Any] {
        var row = TaskRulebook.row(task)
        row["projectId"] = task.projectKey ?? task.projectId.uuidString
        row["createdByUserId"] = task.createdByUserId.map { $0 as Any } ?? NSNull()
        row["createdBy"] = task.createdBy
        row["assignedOperativeIds"] = task.assignedOperativeIds.map { Booking.operativeMatchKey(for: $0) }
        row["assignedOperativeId"] = task.assignedOperativeId.map { Booking.operativeMatchKey(for: $0) as Any } ?? NSNull()
        row["assignedManagerIds"] = task.assignedManagerIds.map(\.uuidString)
        row["assignedManagerId"] = task.assignedManagerId.map { $0.uuidString as Any } ?? NSNull()
        return row
    }

    /// Every project and small works job once (a small works document whose id a project also holds is its own job).
    static func allJobs(_ store: ProjectStore) -> [Project] {
        var seen = Set<String>()
        var out: [Project] = []
        for job in store.projects + store.smallWorks {
            let key = "\(job.jobKind.rawValue)|\(job.documentId.lowercased())"
            if seen.insert(key).inserted { out.append(job) }
        }
        return out
    }

    /// A job with its stored manager fields (`TaskVisibilityJob`).
    static func jobRow(_ job: Project) -> [String: Any] {
        var row = job.jobAccessFields
        row["id"] = job.documentId
        return row
    }

    // MARK: Visibility (decision A)

    /// `visibleTasksForViewer`: the tasks the viewer may see, in the given order. Nil when the script did not answer
    /// (a screen then shows nothing rather than every task).
    static func visibleTasks(
        _ tasks: [ProjectTask],
        viewer: AppUser?,
        jobs: [Project],
        users: [AppUser],
        operatives: [Operative],
        managers: [Manager]
    ) -> [ProjectTask]? {
        guard let viewer else { return [] }
        guard !tasks.isEmpty else { return [] }
        let input: [String: Any] = [
            "viewer": RulebookRosterLists.levelRow(viewer),
            "tasks": tasks.map(taskRow),
            "jobs": jobs.map(jobRow),
            "roster": users.map(RulebookRosterLists.levelRow),
            "operatives": operatives.map(operativeRow),
            "managers": managers.map(managerRow),
        ]
        guard let rows = CanonicalBusinessEngine.callJSON("visibleTasksForViewer", arguments: [input]) as? [[String: Any]] else {
            return nil
        }
        let ids = Set(rows.compactMap { ($0["id"] as? String)?.lowercased() })
        return tasks.filter { ids.contains($0.id.uuidString.lowercased()) }
    }

    // MARK: Filters and sorts (decision B)

    /// `TASK_SORTS` in order, with `taskSortLabel` for the tab.
    static func sortChoices(tab: TaskTab) -> [(choice: TaskSortChoice, label: String)] {
        TaskSortChoice.allCases.map { ($0, sortLabel($0, tab: tab)) }
    }

    /// `taskSortLabel(key, tab)`.
    static func sortLabel(_ sort: TaskSortChoice, tab: TaskTab) -> String {
        CanonicalBusinessEngine.callJSON("taskSortLabel", arguments: [sort.rawValue, tab.rawValue]) as? String ?? sort.rawValue
    }

    /// `parseTaskSort`.
    static func parseSort(_ raw: String?) -> TaskSortChoice {
        let answer = CanonicalBusinessEngine.callJSON("parseTaskSort", arguments: [raw.map { $0 as Any } ?? NSNull()]) as? String
        return TaskSortChoice(rawValue: answer ?? "") ?? .overdueFirst
    }

    /// `parseTaskFilters`.
    static func parseFilters(_ raw: [String: Any]?) -> TaskFilterSet {
        TaskFilterSet(json: CanonicalBusinessEngine.callJSON("parseTaskFilters", arguments: [raw.map { $0 as Any } ?? NSNull()]))
    }

    /// `taskActiveFilterCount`.
    static func activeFilterCount(_ filters: TaskFilterSet) -> Int {
        (CanonicalBusinessEngine.callJSON("taskActiveFilterCount", arguments: [filters.json]) as? NSNumber)?.intValue ?? 0
    }

    /// The locations the filters read (`TaskFilterLocation`): every project and small works job.
    static func locations(_ jobs: [Project]) -> [[String: Any]] {
        jobs.map { job in
            [
                "id": job.documentId,
                "kind": job.jobKind == .smallWorks ? "smallWorks" : "project",
                "code": job.jobNumber,
                "name": job.siteName,
            ]
        }
    }

    /// `taskPersonKeys(...).keys`: lower-case id → person key.
    static func personKeys(managers: [Manager], operatives: [Operative], users: [AppUser]) -> [String: String] {
        let input: [String: Any] = [
            "managers": managers.map(managerRow),
            "operatives": operatives.map(operativeRow),
            "roster": users.map(RulebookRosterLists.levelRow),
        ]
        guard let answer = CanonicalBusinessEngine.callJSON("taskPersonKeys", arguments: [input]) as? [String: Any] else { return [:] }
        return answer["keys"] as? [String: String] ?? [:]
    }

    /// `taskFilterOptions`: the projects, small works and creators the filters offer, with counts over `tasks`.
    static func filterOptions(
        tasks: [ProjectTask],
        jobs: [Project],
        personKeys: [String: String],
        users: [AppUser]
    ) -> (projects: [TaskFilterChoice], smallWorks: [TaskFilterChoice], creators: [TaskFilterChoice]) {
        let input: [String: Any] = [
            "tasks": tasks.map(taskRow),
            "locations": locations(jobs),
            "personKeys": personKeys,
            "roster": users.map(RulebookRosterLists.levelRow),
        ]
        guard let answer = CanonicalBusinessEngine.callJSON("taskFilterOptions", arguments: [input]) as? [String: Any] else {
            return ([], [], [])
        }
        func choices(_ key: String) -> [TaskFilterChoice] {
            (answer[key] as? [[String: Any]] ?? []).compactMap { row in
                guard let value = row["value"] as? String, !value.isEmpty else { return nil }
                return TaskFilterChoice(
                    value: value,
                    label: row["label"] as? String ?? value,
                    count: (row["count"] as? NSNumber)?.intValue ?? 0
                )
            }
        }
        return (choices("projects"), choices("smallWorks"), choices("creators"))
    }

    /// `filterTasks(tasks, filters, { locations, personKeys, nowMs, timeZone })`. The given tasks unchanged when the
    /// script did not answer and no filter is on; none when a filter is on (never a wrong list).
    static func filter(
        _ tasks: [ProjectTask],
        filters: TaskFilterSet,
        jobs: [Project],
        personKeys: [String: String],
        now: Date = Date()
    ) -> [ProjectTask] {
        guard activeFilterCount(filters) > 0, !tasks.isEmpty else { return tasks }
        let context: [String: Any] = [
            "locations": locations(jobs),
            "personKeys": personKeys,
            "nowMs": (now.timeIntervalSince1970 * 1000).rounded(),
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
        ]
        guard let rows = CanonicalBusinessEngine.callJSON("filterTasks", arguments: [tasks.map(taskRow), filters.json, context]) as? [[String: Any]] else {
            return []
        }
        let ids = Set(rows.compactMap { ($0["id"] as? String)?.lowercased() })
        return tasks.filter { ids.contains($0.id.uuidString.lowercased()) }
    }

    /// `sortTasks(tasks, sort, tab, nowMs, timeZone)`. Overdue first is the 1.89.0 tab order (`TaskRulebook.sorted`).
    static func sort(_ tasks: [ProjectTask], sort: TaskSortChoice, tab: TaskTab, now: Date = Date()) -> [ProjectTask] {
        guard tasks.count > 1 else { return tasks }
        if sort == .overdueFirst { return TaskRulebook.sorted(tasks, tab: tab, now: now) }
        let arguments: [Any] = [
            tasks.map(taskRow), sort.rawValue, tab.rawValue,
            (now.timeIntervalSince1970 * 1000).rounded(), OrganizationRulebookContext.timeZoneIdentifier,
        ]
        guard let rows = CanonicalBusinessEngine.callJSON("sortTasks", arguments: arguments) as? [[String: Any]] else { return tasks }
        var byId: [String: ProjectTask] = [:]
        for task in tasks where byId[task.id.uuidString.lowercased()] == nil { byId[task.id.uuidString.lowercased()] = task }
        let ordered = rows.compactMap { ($0["id"] as? String).flatMap { byId[$0.lowercased()] } }
        return ordered.count == tasks.count ? ordered : tasks
    }

    /// `TASK_DUE_FILTERS` labels.
    static func dueFilterChoices() -> [(choice: TaskDueFilterChoice, label: String)] {
        let rows = CanonicalBusinessEngine.constant("TASK_DUE_FILTERS", as: [[String: String]].self) ?? []
        return TaskDueFilterChoice.allCases.map { choice in
            (choice, rows.first { $0["key"] == choice.rawValue }?["label"] ?? choice.rawValue)
        }
    }

    // MARK: Remembered filters (per organisation, the main Tasks screen and a job's tab apart)

    private static func defaultsKey(_ scope: String, organizationId: String, _ what: String) -> String {
        "pp.tasks.\(what).\(scope).\(organizationId)"
    }

    static func rememberedFilters(scope: String, organizationId: String) -> TaskFilterSet {
        let raw = UserDefaults.standard.dictionary(forKey: defaultsKey(scope, organizationId: organizationId, "filters"))
        return parseFilters(raw)
    }

    static func rememberFilters(_ filters: TaskFilterSet, scope: String, organizationId: String) {
        UserDefaults.standard.set(filters.json, forKey: defaultsKey(scope, organizationId: organizationId, "filters"))
    }

    static func rememberedSort(scope: String, organizationId: String) -> TaskSortChoice {
        parseSort(UserDefaults.standard.string(forKey: defaultsKey(scope, organizationId: organizationId, "sort")))
    }

    static func rememberSort(_ sort: TaskSortChoice, scope: String, organizationId: String) {
        UserDefaults.standard.set(sort.rawValue, forKey: defaultsKey(scope, organizationId: organizationId, "sort"))
    }

    /// A remembered filter set with the values no longer offered dropped (job deleted, person key changed). Call only
    /// once tasks, jobs, rows and the roster have all loaded (web review of #459: never prune on a partial load).
    static func pruned(
        _ filters: TaskFilterSet,
        options: (projects: [TaskFilterChoice], smallWorks: [TaskFilterChoice], creators: [TaskFilterChoice]),
        jobs: [Project],
        personKeys: [String: String]
    ) -> TaskFilterSet {
        var next = filters
        let projectIds = Set(jobs.filter { $0.jobKind == .projects }.map { $0.documentId.lowercased() })
        let smallWorksIds = Set(jobs.filter { $0.jobKind == .smallWorks }.map { $0.documentId.lowercased() })
        if !next.projectId.isEmpty, !projectIds.contains(next.projectId.lowercased()) { next.projectId = "" }
        if !next.smallWorksId.isEmpty, !smallWorksIds.contains(next.smallWorksId.lowercased()) { next.smallWorksId = "" }
        // Who assigned: a creator the visible tasks no longer have is dropped (the options cover every tab).
        if !next.creatorKey.isEmpty, !options.creators.contains(where: { $0.value == next.creatorKey }) { next.creatorKey = "" }
        let keys = Set(personKeys.values)
        if !next.assigneeKey.isEmpty, !keys.contains(next.assigneeKey), !next.assigneeKey.hasPrefix("id:") { next.assigneeKey = "" }
        return next
    }

    // MARK: Assignee candidates (owner report 25 Nov)

    /// `taskAssigneeCandidates({ managers, operatives, roster })`. Nil when the script did not answer (a picker then
    /// offers nobody new rather than a deleted person).
    static func assigneeCandidates(managers: [Manager], operatives: [Operative], users: [AppUser]) -> TaskAssigneeCandidateIds? {
        let input: [String: Any] = [
            "managers": managers.map(managerRow),
            "operatives": operatives.map(operativeRow),
            "roster": users.map(RulebookRosterLists.levelRow),
        ]
        guard let answer = CanonicalBusinessEngine.callJSON("taskAssigneeCandidates", arguments: [input]) as? [String: Any] else {
            return nil
        }
        func ids(_ key: String) -> Set<String> {
            Set((answer[key] as? [String] ?? []).map { $0.lowercased() })
        }
        return TaskAssigneeCandidateIds(managerIds: ids("managerIds"), operativeIds: ids("operativeIds"), goneIds: ids("goneIds"))
    }
}

// MARK: - Store answers, memoised (review of #305)

/// What a Tasks screen shows for its inputs: loading (some store has no server answer yet for the open
/// organisation), failed (a load failed, or the rulebook did not answer), or the visible tasks.
enum TaskVisibilityState: Equatable {
    case loading
    case failed(String)
    case ready([ProjectTask])

    var tasks: [ProjectTask] {
        if case .ready(let tasks) = self { return tasks }
        return []
    }
}

/// RULEBOOK 1.91.0 §34 (review of #305): `visibleTasksForViewer` and `taskPersonKeys` for the open stores, worked out
/// once per store change (keyed by the stores' revisions) instead of several bridge calls on every redraw. Shared by
/// the Tasks hub, a job's Tasks tab and badge, and Home.
@MainActor
enum TaskStoreAnswers {
    static let failedMessage = "Tasks did not finish loading. Check the connection and try again."

    /// Every store `visibleTasksForViewer` reads has a server answer for this organisation (tasks, jobs, the
    /// `operatives` / `managers` rows, the roster) and the viewer's profile has loaded.
    static func inputsLoaded(
        taskStore: ProjectTaskStore,
        projectStore: ProjectStore,
        operativeStore: OperativeStore,
        userStore: UserStore,
        organizationId: String
    ) -> Bool {
        func done(_ finished: String?) -> Bool { organizationIdsMatch(finished, organizationId) }
        return !organizationId.isEmpty
            && done(taskStore.finishedLoadOrganizationId)
            && !projectStore.isLoading && done(projectStore.finishedLoadOrganizationId)
            && !operativeStore.isLoading && done(operativeStore.finishedLoadOrganizationId)
            && done(userStore.organizationUsersFinishedLoadOrganizationId)
            && !JobAccessContext.viewerPending
    }

    private struct Key: Equatable {
        let tasks: Int
        let projects: Int
        let operatives: Int
        let users: Int
        let viewer: Int
        let organizationId: String
        let loaded: Bool
        let taskError: String?
        let taskLoading: Bool
    }

    private static var visibilityMemo: (key: Key, state: TaskVisibilityState)?
    private static var personKeysMemo: (operatives: Int, users: Int, keys: [String: String])?

    static func visibility(
        taskStore: ProjectTaskStore,
        projectStore: ProjectStore,
        operativeStore: OperativeStore,
        userStore: UserStore,
        organizationId: String
    ) -> TaskVisibilityState {
        let viewer = userStore.displayUser ?? userStore.currentUser
        let loaded = inputsLoaded(
            taskStore: taskStore, projectStore: projectStore, operativeStore: operativeStore,
            userStore: userStore, organizationId: organizationId
        )
        let key = Key(
            tasks: taskStore.revision, projects: projectStore.revision, operatives: operativeStore.revision,
            users: userStore.revision, viewer: viewer?.hashValue ?? 0, organizationId: organizationId, loaded: loaded,
            taskError: taskStore.errorMessage, taskLoading: taskStore.isLoading
        )
        if let memo = visibilityMemo, memo.key == key { return memo.state }
        let state: TaskVisibilityState
        if !loaded {
            // A load that failed with nothing to show is failed, not loading forever.
            if let error = taskStore.errorMessage, !taskStore.isLoading, taskStore.tasks.isEmpty {
                state = .failed(error)
            } else {
                state = .loading
            }
        } else if let visible = TaskViewingRulebook.visibleTasks(
            taskStore.tasks,
            viewer: viewer,
            jobs: TaskViewingRulebook.allJobs(projectStore),
            users: userStore.unfoldedOrganizationUsers,
            operatives: operativeStore.allOperatives,
            managers: operativeStore.allManagers
        ) {
            state = .ready(visible)
        } else {
            state = .failed(failedMessage)
        }
        visibilityMemo = (key, state)
        return state
    }

    static func personKeys(operativeStore: OperativeStore, userStore: UserStore) -> [String: String] {
        if let memo = personKeysMemo, memo.operatives == operativeStore.revision, memo.users == userStore.revision {
            return memo.keys
        }
        let keys = TaskViewingRulebook.personKeys(
            managers: operativeStore.allManagers,
            operatives: operativeStore.allOperatives,
            users: userStore.unfoldedOrganizationUsers
        )
        personKeysMemo = (operativeStore.revision, userStore.revision, keys)
        return keys
    }

    /// Retry after a failed load: the stores read again.
    static func retry(taskStore: ProjectTaskStore, projectStore: ProjectStore, operativeStore: OperativeStore, userStore: UserStore) async {
        visibilityMemo = nil
        projectStore.loadData()
        operativeStore.loadData()
        await taskStore.loadData()
        await userStore.loadOrganizationUsers(forceRefresh: true)
    }
}
