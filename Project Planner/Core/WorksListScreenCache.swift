//
//  WorksListScreenCache.swift
//  Project Planner
//
//  1.33.1 (owner reports 10 Nov: Projects with "My Projects" took about 20 s to show, and the ⚙ picker nearly froze
//  the app on Save). The Projects and Small works screens asked the rulebook for the same answers many times on every
//  SwiftUI render — `worksListMembership`, `visibleJobs`, `worksTabCounts`, `myWorksList`, `hasMyWorksList`,
//  `defaultWorksListTab` — once for each tile, menu row, chip and empty-state check. Each call turns every job (and,
//  for `visibleJobs` / `myWorksList`, every booking, task and operative in the context) into JSON and runs the script on
//  the main thread, and the screens re-render every time any store's listener delivers. This cache keeps the answers
//  for one screen and asks the rulebook again only when an input really changed (same functions, same inputs: no second
//  calculator). Unchanged store arrays compare in O(1) (Swift arrays compare their storage first).
//

import Foundation

/// Everything a Projects / Small works list's §21 answers depend on.
struct WorksListScreenInputs: Equatable {
    struct OperativeKey: Equatable {
        let id: String
        let email: String
    }

    var kind: JobKind
    var projects: [Project]
    var smallWorks: [Project]
    var viewer: JobAccessViewer?
    /// `{ id, email }` only: `Operative ==` compares ids alone, and the context also reads the email.
    var operatives: [OperativeKey]
    var managers: [[String: String]]
    var bookings: [Booking]
    var managerSiteBookings: [ManagerSiteBooking]
    var tasks: [ProjectTask]
    var deadlineJobIds: [String]
    /// The organisation day and zone: tab counts move at midnight in the organisation zone.
    var dayKey: String
    var timeZone: String

    init(
        kind: JobKind,
        projects: [Project],
        smallWorks: [Project],
        viewer: JobAccessViewer?,
        operatives: [Operative],
        bookings: [Booking],
        managerSiteBookings: [ManagerSiteBooking],
        tasks: [ProjectTask],
        deadlineJobIds: [String],
        now: Date = Date()
    ) {
        self.kind = kind
        self.projects = projects
        self.smallWorks = smallWorks
        self.viewer = viewer
        self.operatives = operatives.map { OperativeKey(id: $0.documentId, email: $0.email) }
        self.managers = JobAccessContext.managers.map { row in
            row.reduce(into: [String: String]()) { $0[$1.key] = "\($1.value)" }
        }
        self.bookings = bookings
        self.managerSiteBookings = managerSiteBookings
        self.tasks = tasks
        self.deadlineJobIds = deadlineJobIds
        self.dayKey = OrganizationRulebookContext.dayKey(now)
        self.timeZone = OrganizationRulebookContext.timeZoneIdentifier
    }
}

/// The rulebook's answers for one list screen, recomputed only when `WorksListScreenInputs` (or the picks) change.
@MainActor
final class WorksListScreenCache {
    struct Answers {
        let context: RulebookWorksListContext
        /// `visibleJobs(worksListMembership(jobs, kind), viewer, context)`: the list before any status chip.
        let visible: [Project]
        /// `worksTabCounts(visible)`.
        let counts: WorksListStatusCounts
        /// `hasMyWorksList(viewer)`.
        let hasMyList: Bool
        /// `defaultWorksListTab(viewer) == "mine"`.
        let myListIsDefault: Bool
    }

    /// How many times the base answers were asked of the rulebook (tests: not once per render).
    private(set) var baseComputations = 0
    /// How many times `myWorksList` was asked of the rulebook.
    private(set) var myListComputations = 0

    private var baseInputs: WorksListScreenInputs?
    private var base: Answers?
    private var tabJobs: [String: [Project]] = [:]
    private var myListKey: (picks: MyWorksPicks, loaded: Bool)?
    private var myList: [Project] = []

    /// The base answers for `inputs`, from the cache when nothing changed.
    func answers(_ inputs: WorksListScreenInputs) -> Answers {
        if let base, baseInputs == inputs { return base }
        baseComputations += 1
        let context = WorksListContextBuilder.context(
            operatives: [],
            bookings: inputs.bookings,
            managerSiteBookings: inputs.managerSiteBookings,
            tasks: inputs.tasks,
            deadlineJobIds: inputs.deadlineJobIds
        )
        var full = context
        full.operatives = inputs.operatives.map { ["id": $0.id, "email": $0.email] }
        let all = inputs.projects + inputs.smallWorks
        let members = CanonicalBusinessEngine.worksListMembership(all, kind: inputs.kind)
        let visible = CanonicalBusinessEngine.visibleJobs(members, viewer: inputs.viewer, context: full)
        let answers = Answers(
            context: full,
            visible: visible,
            counts: WorksListStatusCounts.from(visible),
            hasMyList: CanonicalBusinessEngine.hasMyWorksList(inputs.viewer),
            myListIsDefault: CanonicalBusinessEngine.defaultWorksListTab(inputs.viewer) == "mine"
        )
        baseInputs = inputs
        base = answers
        tabJobs = [:]
        myListKey = nil
        return answers
    }

    /// `worksInTab(visible, tab)` for a status chip (nil is All), kept until the inputs change.
    func jobs(_ inputs: WorksListScreenInputs, chip: ProjectStatus?) -> [Project] {
        let answers = answers(inputs)
        let tab = WorksListStatusCounts.tab(for: chip)
        if tab == "all" { return answers.visible }
        if let hit = tabJobs[tab] { return hit }
        let jobs = WorksListStatusCounts.jobs(answers.visible, chip: chip)
        tabJobs[tab] = jobs
        return jobs
    }

    /// `myWorksList(jobs, picks, viewer, context, kind)`; empty until the picks are known or without the My list.
    func myList(_ inputs: WorksListScreenInputs, picks: MyWorksPicks, loaded: Bool) -> [Project] {
        let answers = answers(inputs)
        guard answers.hasMyList, loaded else { return [] }
        if let key = myListKey, key.picks == picks, key.loaded == loaded { return myList }
        myListComputations += 1
        myList = CanonicalBusinessEngine.myWorksList(
            inputs.projects + inputs.smallWorks,
            picks: picks,
            viewer: inputs.viewer,
            context: answers.context,
            kind: inputs.kind
        )
        myListKey = (picks, loaded)
        return myList
    }

    /// `myWorksPickerRows`: asked once when the ⚙ opens; the sheet keeps the snapshot (never recomputed per render).
    func pickerRows(_ inputs: WorksListScreenInputs, picks: MyWorksPicks) -> [MyWorksPickerRow] {
        let answers = answers(inputs)
        return CanonicalBusinessEngine.myWorksPickerRows(
            inputs.projects + inputs.smallWorks,
            picks: picks,
            viewer: inputs.viewer,
            context: answers.context,
            kind: inputs.kind
        ).map { MyWorksPickerRow(job: $0.job, picked: $0.picked) }
    }
}

/// One row of the ⚙ picker (`myWorksPickerRows`).
struct MyWorksPickerRow: Equatable {
    let job: Project
    let picked: Bool
}
