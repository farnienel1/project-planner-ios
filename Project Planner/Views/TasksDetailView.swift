//
//  TasksDetailView.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import SwiftUI

private enum MyTasksScreenPalette {
    static let canvas = ProjectWorksRevampColors.canvas
    static let ink = ProjectWorksRevampColors.ink
    static let muted = ProjectWorksRevampColors.muted
    static let border = ProjectWorksRevampColors.border
    static let blue = ProjectWorksRevampColors.blue
    static let blueLight = ProjectWorksRevampColors.blueLight
    static let todoCount = ProjectWorksRevampColors.muted
    static let inProgressCount = ProjectWorksRevampColors.upcomingAmber
    static let overdueCount = ProjectWorksRevampColors.requiredPillFg
    static let doneCount = ProjectWorksRevampColors.activeGreen
    static let stripTodo = Color(red: 197 / 255, green: 201 / 255, blue: 210 / 255)
}

struct TasksDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var bookingStore: BookingStore

    @State private var searchText = ""
    /// RULEBOOK 1.89.0 §34: the tab (Active / Overdue / Completed) and the My tasks / Everyone scope, remembered on
    /// this phone (`taskScopeFor`: staff default to Everyone, operatives always My tasks — bug B9).
    @State private var tab: TaskTab = .active
    @State private var scopeChoice: String? = UserDefaults.standard.string(forKey: TasksDetailView.scopeDefaultsKey)

    static let scopeDefaultsKey = "pp.tasks.scope"

    /// RULEBOOK 1.91.0 §34 (decision B): filters and sort, remembered per organisation for this screen
    /// (`parseTaskFilters` / `parseTaskSort`).
    @State private var filters: TaskFilterSet = .none
    @State private var sortChoice: TaskSortChoice = .overdueFirst
    @State private var showingFilters = false
    @State private var rememberedLoadedFor: String? = nil
    /// Review of #305: the scoped / filtered lists and the filter options, built once per store change.
    @State private var hubMemo = TaskHubMemo()
    private static let filterScope = "main"

    private var organizationId: String { firebaseBackend.currentOrganization?.firestoreDocumentId ?? "" }

    /// RULEBOOK §5 `qualificationExpiryRows` for the signed-in operative's own catalogue rows (every row of their
    /// account, `bookingIdsForAccount`): organisation day, one calendar month ahead, already expired included — the
    /// rows the Home badge counts (`qualificationExpiryCount`). It used to be a 30-day device-calendar window that
    /// dropped expired qualifications and found the operative by email.
    private var qualificationExpiryBannerItems: [(id: String, title: String, subtitle: String)] {
        guard userStore.isOperativeMode(), let me = userStore.currentUser else { return [] }
        let ids = labourBookingIds(for: me, operatives: operativeStore.allOperatives)
        let mine = operativeStore.allOperatives.filter { ids.contains($0.id) }
        guard !mine.isEmpty,
              let rows = CanonicalBusinessEngine.qualificationExpiryRows(operatives: mine.map(\.rulebookQualificationRow))
        else { return [] }
        return rows.sorted { $0.dayKey < $1.dayKey }.map { row in
            let days = row.daysUntilExpiry
            let subtitle: String
            if days < 0 {
                subtitle = "Expired \(-days) day\(days == -1 ? "" : "s") ago. Tell your manager when you have renewed it."
            } else if days == 0 {
                subtitle = "Renew today — tell your manager when complete."
            } else {
                subtitle = "\(days) day\(days == 1 ? "" : "s") remaining. Tell your manager when you have renewed it."
            }
            return (id: row.id, title: "\(row.title): \(row.qualificationName)", subtitle: subtitle)
        }
    }

    private var viewerRole: CanonicalBusinessEngine.CanonicalStaffAccountRole? {
        TaskRulebook.viewerRole(userStore.displayUser)
    }

    /// RULEBOOK 1.89.0 §34 `taskAccess`: staff (admins and managers outside operative mode) see every task.
    private var access: TaskRulebookAccess { TaskRulebook.access(role: viewerRole) }

    private var scope: TaskScope { TaskRulebook.scope(role: viewerRole, remembered: scopeChoice) }

    /// RULEBOOK §23 `tasksAssignedToViewer`: assigned under any id the person goes by (as web My tasks and Home).
    private var userRelevantTasks: [ProjectTask] {
        TaskAssignmentRulebook.assignedTasks(
            taskStore.tasks,
            viewer: userStore.currentUser,
            organizationUsers: userStore.organizationUsers,
            operatives: operativeStore.allOperatives,
            managers: operativeStore.allManagers
        )
    }

    /// RULEBOOK 1.91.0 §34 `visibleTasksForViewer` (decision A): admins every task, managers the tasks on the jobs they
    /// manage plus tasks assigned to or created by them, operatives the tasks assigned to them.
    /// Review of #305: loading until every store has a server answer; failed (with Retry) when a load failed or the
    /// rulebook did not answer — never "No tasks".
    private var visibility: TaskVisibilityState {
        TaskStoreAnswers.visibility(
            taskStore: taskStore, projectStore: projectStore, operativeStore: operativeStore,
            userStore: userStore, organizationId: organizationId
        )
    }

    private var visibleTasks: [ProjectTask] { visibility.tasks }

    private var jobs: [Project] { TaskViewingRulebook.allJobs(projectStore) }

    /// The jobs, the people rows and the roster have loaded (web review of #459: nothing is shown as "No tasks" and no
    /// remembered filter is dropped on a partial load).
    private var visibilityReady: Bool {
        if case .ready = visibility { return true }
        return false
    }

    private var personKeys: [String: String] {
        TaskStoreAnswers.personKeys(operativeStore: operativeStore, userStore: userStore)
    }

    /// The scoped list, the filtered list, the filter options and the assignee choices, built once per store /
    /// scope / filter change (review of #305: several rulebook calls each).
    private var hub: TaskHubModel {
        let key = TaskHubMemo.Key(
            tasks: taskStore.revision, projects: projectStore.revision, operatives: operativeStore.revision,
            users: userStore.revision, viewer: (userStore.displayUser ?? userStore.currentUser)?.hashValue ?? 0,
            ready: visibilityReady, scope: scope, filters: filters, organizationId: organizationId
        )
        if let model = hubMemo.model, hubMemo.key == key { return model }
        let visible = visibleTasks
        let scoped: [ProjectTask]
        if scope == .everyone {
            scoped = visible
        } else {
            let mine = Set(userRelevantTasks.map(\.id))
            scoped = visible.filter { mine.contains($0.id) }
        }
        let keys = personKeys
        let model = TaskHubModel(
            scopeTasks: scoped,
            filtered: TaskViewingRulebook.filter(scoped, filters: filters, jobs: jobs, personKeys: keys),
            options: TaskViewingRulebook.filterOptions(tasks: scoped, jobs: jobs, personKeys: keys, users: userStore.unfoldedOrganizationUsers),
            assignees: buildAssigneeChoices(scoped, keys: keys)
        )
        hubMemo.key = key
        hubMemo.model = model
        return model
    }

    private var hubScopeTasks: [ProjectTask] { hub.scopeTasks }

    /// The scoped list with the filters on (counts and tabs follow the filters, as web).
    private var filteredScopeTasks: [ProjectTask] { hub.filtered }

    private var filterOptions: (projects: [TaskFilterChoice], smallWorks: [TaskFilterChoice], creators: [TaskFilterChoice]) {
        hub.options
    }

    private var assigneeChoices: [TaskFilterChoice] { hub.assignees }

    /// RULEBOOK 1.89.0 §34 `taskTabCounts`: the same definitions as Home and the job tile (an overdue task is also
    /// active).
    private var tabCounts: [TaskTab: Int] { TaskRulebook.tabCounts(filteredScopeTasks) }

    private var displayedTasks: [ProjectTask] {
        var list = filteredScopeTasks.filter { TaskRulebook.tabs(for: $0).contains(tab) }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter { task in
                if task.title.lowercased().contains(q) { return true }
                if (task.details ?? "").lowercased().contains(q) { return true }
                if let project = projectStore.projects.first(where: { $0.id == task.projectId }) {
                    if project.jobNumber.lowercased().contains(q) { return true }
                    if project.siteName.lowercased().contains(q) { return true }
                }
                if let sw = projectStore.smallWorks.first(where: { $0.id == task.projectId }) {
                    if sw.jobNumber.lowercased().contains(q) { return true }
                    if sw.siteName.lowercased().contains(q) { return true }
                }
                return false
            }
        }
        // RULEBOOK 1.91.0 §34 `sortTasks`: overdue first (the 1.89.0 tab order) or by due date.
        return TaskViewingRulebook.sort(list, sort: sortChoice, tab: tab)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    tasksNavyHeader

                    VStack(alignment: .leading, spacing: 14) {
                        if !pendingHolidayApprovals.isEmpty {
                            holidayBannersSection
                        }
                        if !qualificationExpiryBannerItems.isEmpty {
                            qualificationBannersSection
                        }

                        filterBar

                        if case .failed(let message) = visibility {
                            errorState(message)
                        } else if !visibilityReady {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(40)
                        } else if displayedTasks.isEmpty {
                            emptyStateCard
                        } else {
                            VStack(spacing: 10) {
                                ForEach(displayedTasks) { task in
                                    MyTasksRedesignTaskCard(task: task)
                                        .environmentObject(projectStore)
                                        .environmentObject(operativeStore)
                                        .environmentObject(taskStore)
                                        .environmentObject(userStore)
                                        .environmentObject(firebaseBackend)
                                        .environmentObject(notificationService)
                                        .environmentObject(bookingStore)
                                }
                            }
                        }
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                    .ppContentSheet()
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("tasksDetail.done")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
            }
            .task(id: firebaseBackend.currentOrganization?.firestoreDocumentId ?? "") {
                guard !(firebaseBackend.currentOrganization?.firestoreDocumentId ?? "").isEmpty else { return }
                loadRememberedFilters()
                await taskStore.loadData()
                await holidayStore.loadData()
            }
            .sheet(isPresented: $showingFilters) {
                TaskFilterSheet(
                    filters: $filters,
                    options: filterOptions,
                    showsJobFilters: true,
                    assignees: assigneeChoices
                )
            }
            .onChange(of: filters) { _, next in
                TaskViewingRulebook.rememberFilters(next, scope: Self.filterScope, organizationId: organizationId)
            }
            .onChange(of: sortChoice) { _, next in
                TaskViewingRulebook.rememberSort(next, scope: Self.filterScope, organizationId: organizationId)
            }
            .onChange(of: visibilityReady) { _, ready in
                if ready { pruneRememberedFilters() }
            }
            .refreshable {
                await taskStore.loadData()
                await holidayStore.loadData()
            }
        }
    }

    // MARK: Filters and sort (RULEBOOK 1.91.0 §34, decision B)

    private func loadRememberedFilters() {
        guard !organizationId.isEmpty, rememberedLoadedFor != organizationId else { return }
        rememberedLoadedFor = organizationId
        filters = TaskViewingRulebook.rememberedFilters(scope: Self.filterScope, organizationId: organizationId)
        sortChoice = TaskViewingRulebook.rememberedSort(scope: Self.filterScope, organizationId: organizationId)
        if visibilityReady { pruneRememberedFilters() }
    }

    /// Drop remembered values no longer offered — only once everything has loaded.
    private func pruneRememberedFilters() {
        guard visibilityReady else { return }
        let next = TaskViewingRulebook.pruned(filters, options: filterOptions, jobs: jobs, personKeys: personKeys)
        if next != filters { filters = next }
    }

    /// The people a task can be filtered by (one per person, from the assignee names).
    private func buildAssigneeChoices(_ tasks: [ProjectTask], keys: [String: String]) -> [TaskFilterChoice] {
        TaskAssigneeFilterChoices.build(tasks, keys: keys, index: TaskPersonIndex.current(operativeStore: operativeStore, userStore: userStore))
    }

    /// Filters (n), Sort, and the active filter chips with ✕ and Clear all.
    private var filterBar: some View {
        TaskFilterSortBar(
            filters: $filters,
            sort: $sortChoice,
            tab: tab,
            ready: visibilityReady,
            options: filterOptions,
            assignees: assigneeChoices,
            identifierPrefix: "tasksDetail",
            onShowFilters: { showingFilters = true }
        )
        .padding(.horizontal, 16)
    }

    /// Home-style navy header: the tab counts (RULEBOOK 1.89.0 §34 bug B13: one count per tab, no overlapping
    /// To do / In progress / Done cards), search, scope and tab pills.
    private var tasksNavyHeader: some View {
        let counts = tabCounts
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                PPStat(value: "\(counts[.active] ?? 0)", label: TaskTab.active.label)
                PPStatDivider()
                PPStat(value: "\(counts[.overdue] ?? 0)", label: TaskTab.overdue.label, highlight: (counts[.overdue] ?? 0) > 0)
                PPStatDivider()
                PPStat(value: "\(counts[.completed] ?? 0)", label: TaskTab.completed.label)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(PPColor.onNavySecondary)
                TextField("Search tasks…", text: $searchText)
                    .accessibilityIdentifier("tasksDetail.searchTasks")
                    .font(.callout)
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(PPColor.onNavyFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5)
            )
            .padding(.top, 20)

            if access.seesEveryone {
                HStack(spacing: 6) {
                    ForEach(TaskScope.allCases, id: \.self) { option in
                        scopePill(title: option.label, isSelected: scope == option) {
                            scopeChoice = option.rawValue
                            UserDefaults.standard.set(option.rawValue, forKey: Self.scopeDefaultsKey)
                        }
                    }
                }
                .padding(.top, 12)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TaskTab.allCases, id: \.self) { option in
                        scopePill(title: "\(option.label) · \(tabCounts[option] ?? 0)", isSelected: tab == option) {
                            tab = option
                        }
                    }
                }
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private func scopePill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? PPColor.navy : Color.white.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(isSelected ? Color.white : PPColor.onNavyFill))
                .overlay(
                    Capsule()
                        .strokeBorder(PPColor.onNavyStroke, lineWidth: isSelected ? 0 : 0.5)
                )
        }
        .accessibilityIdentifier("tasksDetail.\(AccessibilityID.token(title))")
        .buttonStyle(.plain)
    }

    private var emptyStateCard: some View {
        VStack(spacing: 14) {
            PPIconTile(symbol: "checklist", family: .plan, size: PPMetrics.quickActionIcon, lifted: true)
            Text(emptyTitle)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(emptySubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private var emptyTitle: String {
        switch tab {
        case .active: return scope == .mine ? "Nothing assigned to you" : "No active tasks"
        case .completed: return "No completed tasks"
        case .overdue: return "No overdue tasks"
        }
    }

    private var emptySubtitle: String {
        switch tab {
        case .active:
            return scope == .everyone
                ? "Active tasks from every project and small work appear here."
                : "When someone assigns you on a task, it will show here."
        case .completed:
            return scope == .everyone
                ? "Completed tasks from every project and small work appear here."
                : "Completed tasks assigned to you will appear here."
        case .overdue:
            return "Overdue tasks also stay under Active. This tab shows only tasks past their due date."
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            PPIconTile(symbol: "exclamationmark.triangle.fill", family: .alert, size: 44)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task {
                    await TaskStoreAnswers.retry(
                        taskStore: taskStore, projectStore: projectStore, operativeStore: operativeStore, userStore: userStore
                    )
                }
            }
            .accessibilityIdentifier("tasksDetail.retry")
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(PPColor.brand)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private var holidayBannersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Annual leave approvals")
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            ForEach(pendingHolidayApprovals) { request in
                HolidayApprovalTaskCard(
                    request: request,
                    requesterName: requesterName(for: request),
                    isCancellationRequest: request.cancellationRequestedAt != nil,
                    onApprove: { approveHolidayRequest(request) },
                    onDecline: { declineHolidayRequest(request) }
                )
            }
        }
    }

    private var qualificationBannersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Qualification reminders")
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            ForEach(qualificationExpiryBannerItems, id: \.id) { item in
                HStack(alignment: .top, spacing: 12) {
                    PPIconTile(symbol: "rosette", family: .alert, size: PPMetrics.menuIcon)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(item.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
            }
        }
    }

    /// D6: admins and super admins see every pending request; anyone else only the requests whose
    /// `leaveApproverIds` names them. Nobody sees their own.
    private var pendingHolidayApprovals: [HolidayBooking] {
        guard userStore.currentUser != nil else { return [] }
        let filtered = AnnualLeaveApproval.decidableRequests(
            holidayStore.pendingRequests,
            viewer: holidayApprovalViewer,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )

        // Newest request first (the order the hub used by default).
        return filtered.sorted { $0.createdAt > $1.createdAt }
    }

    private var holidayApprovalViewer: AppUser? {
        guard let me = userStore.currentUser else { return nil }
        return userStore.organizationUsers.first(where: { $0.id == me.id }) ?? me
    }

    private func canDecideHoliday(_ request: HolidayBooking) -> Bool {
        AnnualLeaveApproval.canDecide(
            request,
            viewer: holidayApprovalViewer,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )
    }

    private func requesterName(for request: HolidayBooking) -> String {
        if let uid = request.userId,
           let u = userStore.organizationUsers.first(where: { $0.id == uid }) {
            return u.fullName
        }
        if let oid = request.operativeId,
           let op = operativeStore.allOperatives.first(where: { $0.id == oid }) {
            return "\(op.firstName) \(op.lastName)"
        }
        return "Operative"
    }

    private func approveHolidayRequest(_ request: HolidayBooking) {
        guard let uid = userStore.currentUser?.id, canDecideHoliday(request) else { return }
        Task {
            let name = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Manager"
            if request.cancellationRequestedAt != nil {
                let removed = await holidayStore.deleteBooking(request)
                // Owner decision 5: accepting a cancellation removes the leave ("removed").
                Feedback.play(removed, success: .leaveRemoved)
                if let ownerId = request.userId {
                    await notificationService.notifyAnnualLeaveCancelledByManager(
                        userId: ownerId,
                        booking: request,
                        managerName: name
                    )
                }
                await notificationService.loadNotifications()
                return
            }
            let result = await holidayStore.approveBooking(request, approvedByUserId: uid)
            Feedback.play(result, success: .leaveApproved)
            await notifyDecision(to: request, approved: true, decidedByName: name)
            await notificationService.loadNotifications()
        }
    }

    private func declineHolidayRequest(_ request: HolidayBooking) {
        guard let uid = userStore.currentUser?.id, canDecideHoliday(request) else { return }
        Task {
            if request.cancellationRequestedAt != nil {
                // Refuse the cancellation: the leave stays approved (`holidayDecisionRecipients` is told).
                guard await holidayStore.refuseCancellation(request) else {
                    Feedback.play(.actionRefused)
                    return
                }
                Feedback.play(FeedbackDecision.leaveEvent(pendingSync: holidayStore.isPendingSync(request), success: .leaveDeclined))
                if let ownerId = request.userId {
                    let name = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Manager"
                    await notificationService.notifyAnnualLeaveCancellationRefused(
                        userId: ownerId,
                        booking: request,
                        decidedByName: name
                    )
                }
                await notificationService.loadNotifications()
                return
            }
            let result = await holidayStore.rejectBooking(request, rejectedByUserId: uid)
            Feedback.play(result, success: .leaveDeclined)
            let name = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Manager"
            await notifyDecision(to: request, approved: false, decidedByName: name)
            await notificationService.loadNotifications()
        }
    }

    private func notifyDecision(to request: HolidayBooking, approved: Bool, decidedByName: String) async {
        if let requesterUserId = request.userId {
            await notificationService.notifyHolidayRequestDecisionToUser(
                userId: requesterUserId,
                bookingId: request.id,
                approved: approved,
                decidedByName: decidedByName
            )
            // RULEBOOK §13: a decision notifies the requester only (`holidayDecisionRecipients`); no admin copy.
            return
        }
        if let oid = request.operativeId,
           let op = operativeStore.allOperatives.first(where: { $0.id == oid }),
           let operativeUser = userStore.organizationUsers.first(where: {
               ($0.permissions.operativeMode || $0.role == .operative) &&
               $0.email.lowercased() == op.email.lowercased()
           }) {
            await notificationService.notifyHolidayRequestDecisionToUser(
                userId: operativeUser.id,
                bookingId: request.id,
                approved: approved,
                decidedByName: decidedByName
            )
        }
    }
}

// MARK: - Redesigned task row (matches my-tasks HTML)

private struct MyTasksRedesignTaskCard: View {
    let task: ProjectTask
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var bookingStore: BookingStore

    @State private var showingTaskDetail = false
    @State private var showingCarryOut = false

    private var resolvedTask: ProjectTask {
        taskStore.tasks.first(where: { $0.id == task.id }) ?? task
    }

    @State private var actionError: String?
    @State private var actionBusy = false

    /// RULEBOOK 1.89.0 §34 `taskAccess`: staff and the task's assignees start, complete and reopen it.
    private var canAct: Bool {
        let isAssignee = TaskAssignmentRulebook.isAssigned(
            resolvedTask,
            viewer: userStore.currentUser,
            organizationUsers: userStore.organizationUsers,
            operatives: operativeStore.allOperatives,
            managers: operativeStore.allManagers
        )
        return TaskRulebook.access(role: TaskRulebook.viewerRole(userStore.displayUser), isAssignee: isAssignee).canAct
    }

    /// RULEBOOK 1.89.0 §34 `taskActions`: Start (To do), Complete (In progress), Reopen (Completed). "Carry out" is gone.
    /// Nil when the rules did not answer (no action is offered).
    private var primaryAction: TaskActionKind? { TaskRulebook.actions(resolvedTask.status)?.primary }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accentStripColor)
                .frame(width: 4)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 8) {
                Button { showingTaskDetail = true } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Text(resolvedTask.title)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            statusPill
                        }

                        HStack(spacing: 5) {
                            Image(systemName: projectLineIcon)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(red: 197 / 255, green: 201 / 255, blue: 210 / 255))
                            Text(projectLineText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Spacer()
                            HStack(spacing: 5) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 12))
                                    .foregroundStyle(dueColor)
                                Text(dueText)
                                    .font(.footnote.weight(dueWeight))
                                    .foregroundStyle(dueColor)
                            }
                        }
                    }
                    // RULEBOOK 1.91.0 (owner 25 Nov): the whole area is the target, blank space included.
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("myTasksRedesignTaskCard.calendar")
                .buttonStyle(.plain)

                checklistRow

                if checklistProgress > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(MyTasksScreenPalette.border)
                                .frame(height: 4)
                            Capsule()
                                .fill(progressBarFill)
                                .frame(width: geo.size.width * checklistProgress, height: 4)
                        }
                    }
                    .frame(height: 4)
                }

                HStack {
                    assigneeInitialsRow
                    Spacer()
                    priorityPill
                }
            }
        }
        .padding(14)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        // RULEBOOK 1.91.0 (owner 25 Nov: a card took several taps to open): one tap anywhere on the card opens it. The
        // Start / Complete button inside keeps its own action (a Button wins over the card's tap gesture).
        .contentShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        .onTapGesture { showingTaskDetail = true }
        .accessibilityAddTraits(.isButton)
        .sheet(isPresented: $showingTaskDetail) {
            CompletedTaskDetailView(task: resolvedTask)
                .environmentObject(taskStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(projectStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
                .environmentObject(bookingStore)
        }
        .sheet(isPresented: $showingCarryOut) {
            TaskCompletionPopupView(
                task: resolvedTask,
                isPresented: $showingCarryOut,
                onComplete: { completedBy, images, files, notes in
                    Task { await applyTaskCompletion(completedBy: completedBy, images: images, files: files, notes: notes) }
                }
            )
            .environmentObject(firebaseBackend)
            .environmentObject(userStore)
            .environmentObject(taskStore)
            .environmentObject(projectStore)
        }
    }

    private func applyTaskCompletion(completedBy: String, images: [String], files: [String], notes: String?) async {
        // RULEBOOK 1.89.0 §34: who and when come from `taskStatusChangeFields`; ticks are the task's real items only
        // (F25), older ticks kept.
        guard var updatedTask = TaskRulebook.applyingStatus(.completed, to: resolvedTask, by: completedBy) else {
            actionError = "Couldn't save. The app's rules did not load — close and reopen the app, then try again."
            return
        }
        var ticks = updatedTask.completedItemIds
        for item in updatedTask.items where !ticks.contains(item.id) { ticks.append(item.id) }
        updatedTask.completedItemIds = ticks
        updatedTask.completionImages = images
        updatedTask.completionFiles = files
        updatedTask.completionNotes = notes
        updatedTask.updatedAt = Date()
        guard await taskStore.updateTaskReportingError(updatedTask) else {
            actionError = taskStore.lastWriteError
            return
        }
        await notificationService.notifyTaskCompleted(task: updatedTask, completedBy: completedBy)
    }

    @ViewBuilder
    private var checklistRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 12))
                    .foregroundStyle(MyTasksScreenPalette.muted)
                Text(checklistSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(MyTasksScreenPalette.muted)
                Spacer()
                if canAct, let primaryAction {
                    Button { runPrimaryAction() } label: {
                        HStack(spacing: 4) {
                            Text(actionBusy ? "Saving…" : TaskRulebook.actionLabel(primaryAction))
                                .font(.footnote.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(MyTasksScreenPalette.blue)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .disabled(actionBusy)
                    .accessibilityIdentifier("myTasksRedesignTaskCard.button")
                    .buttonStyle(.plain)
                }
            }
            if let actionError {
                Text(actionError)
                    .font(.footnote)
                    .foregroundStyle(MyTasksScreenPalette.overdueCount)
            }
        }
    }

    /// Start and Reopen change the status at once (`taskActionStatus`: Reopen → In progress, completion cleared);
    /// Complete opens the complete step.
    private func runPrimaryAction() {
        guard let action = primaryAction else { return }
        switch action {
        case .complete:
            showingCarryOut = true
        case .start, .reopen:
            let name = userStore.currentUser?.fullName ?? ""
            guard let status = TaskRulebook.actionStatus(action),
                  let updated = TaskRulebook.applyingStatus(status, to: resolvedTask, by: name) else {
                actionError = "Couldn't save. The app's rules did not load — close and reopen the app, then try again."
                return
            }
            actionBusy = true
            actionError = nil
            Task {
                let ok = await taskStore.updateTaskReportingError(updated)
                actionBusy = false
                if !ok { actionError = taskStore.lastWriteError ?? "Couldn't save. Check the connection and try again." }
            }
        }
    }

    private var projectLineIcon: String {
        if projectStore.smallWorks.contains(where: { $0.id == task.projectId }) {
            return "hammer.fill"
        }
        return "folder.fill"
    }

    private var projectLineText: String {
        if let p = projectStore.projects.first(where: { $0.id == task.projectId }) {
            return "\(p.jobNumber) \(p.siteName)"
        }
        if let sw = projectStore.smallWorks.first(where: { $0.id == task.projectId }) {
            return "\(sw.jobNumber) \(sw.siteName)"
        }
        return "Unknown job"
    }

    /// RULEBOOK 1.89.0 §34 `taskCompleteStep`: the task's real items only (F25).
    private var checklistStep: TaskCompleteStepInfo {
        TaskRulebook.completeStep(items: resolvedTask.items, completedItemIds: resolvedTask.completedItemIds)
    }

    private var checklistSummary: String {
        let step = checklistStep
        if !step.showChecklist { return "No checklist" }
        return "\(step.done) of \(step.total) items"
    }

    private var checklistProgress: CGFloat {
        let step = checklistStep
        guard step.total > 0 else { return 0 }
        return CGFloat(step.done) / CGFloat(step.total)
    }

    private var progressBarFill: Color {
        if isOverdue { return MyTasksScreenPalette.overdueCount }
        if resolvedTask.status == .inProgress { return MyTasksScreenPalette.blue }
        return MyTasksScreenPalette.blue
    }

    /// RULEBOOK 1.23.0 §23 `CanonicalBusinessEngine.isTaskOverdue`: not completed and due before today, organisation day.
    private var isOverdue: Bool {
        CanonicalBusinessEngine.isTaskOverdue(status: resolvedTask.status.rawValue, dueDate: resolvedTask.dueDate)
    }

    /// RULEBOOK 1.89.0 §34 `taskDueLabel`: "3 days overdue", "Due today", "Due Thu", "No due date" (bug B10), on the
    /// organisation day.
    private var dueInfo: TaskDueText { TaskRulebook.dueText(resolvedTask) }

    private var dueText: String { dueInfo.label }

    private var dueColor: Color {
        switch dueInfo.tone {
        case "red": return MyTasksScreenPalette.overdueCount
        case "amber": return MyTasksScreenPalette.inProgressCount
        default: return MyTasksScreenPalette.muted
        }
    }

    private var dueWeight: Font.Weight {
        (dueColor == MyTasksScreenPalette.overdueCount) ? .medium : .regular
    }

    private var accentStripColor: Color {
        if isOverdue { return MyTasksScreenPalette.overdueCount }
        switch resolvedTask.status {
        case .inProgress: return MyTasksScreenPalette.inProgressCount
        case .completed: return MyTasksScreenPalette.doneCount
        case .todo: return MyTasksScreenPalette.stripTodo
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch resolvedTask.status {
        case .todo:
            statusCapsule(text: TaskRulebook.statusLabel(.todo), fg: MyTasksScreenPalette.muted, bg: ProjectWorksRevampColors.grayTint, icon: "circle.dashed")
        case .inProgress:
            statusCapsule(text: TaskRulebook.statusLabel(.inProgress), fg: MyTasksScreenPalette.inProgressCount, bg: ProjectWorksRevampColors.amberTint, icon: "chart.line.uptrend.xyaxis")
        case .completed:
            statusCapsule(text: TaskRulebook.statusLabel(.completed), fg: MyTasksScreenPalette.doneCount, bg: ProjectWorksRevampColors.greenTint, icon: "checkmark.circle.fill")
        }
    }

    private func statusCapsule(text: String, fg: Color, bg: Color, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(bg)
        .clipShape(Capsule())
    }

    private var priorityPill: some View {
        let (fg, bg, dot) = priorityColors
        return HStack(spacing: 3) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
            Text(TaskRulebook.priorityLabel(resolvedTask.priority))
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(bg)
        .clipShape(Capsule())
    }

    private var priorityColors: (Color, Color, Color) {
        switch resolvedTask.priority {
        case .low:
            return (MyTasksScreenPalette.muted, ProjectWorksRevampColors.grayTint, MyTasksScreenPalette.muted)
        case .normal:
            return (MyTasksScreenPalette.inProgressCount, ProjectWorksRevampColors.amberTint, MyTasksScreenPalette.inProgressCount)
        case .high:
            return (MyTasksScreenPalette.overdueCount, ProjectWorksRevampColors.requiredPillBg, MyTasksScreenPalette.overdueCount)
        case .urgent:
            return (MyTasksScreenPalette.overdueCount, ProjectWorksRevampColors.requiredPillBg, MyTasksScreenPalette.overdueCount)
        }
    }

    private var assigneeInitialsRow: some View {
        let initials = assigneeInitialsList
        return HStack(spacing: -6) {
            ForEach(Array(initials.enumerated()), id: \.offset) { _, ini in
                Text(ini)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        LinearGradient(
                            colors: [MyTasksScreenPalette.blue, MyTasksScreenPalette.blueLight],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            }
        }
    }

    /// One per person (owner decision 17 Nov, web #364): two stored ids of one person show one avatar.
    private var assigneeInitialsList: [String] {
        let index = TaskPersonIndex.current(operativeStore: operativeStore, userStore: userStore)
        // RULEBOOK 1.89.0 §34 bug B11: a removed person still shows (as "Removed user", initials "?").
        let names = TaskPeopleRulebook.assigneeEntries(
            managerIds: resolvedTask.allAssignedManagerIds,
            operativeIds: resolvedTask.allAssignedOperativeIds,
            index: index,
            allManagerRows: operativeStore.managers,
            loaded: operativeStore.rosterLoaded
        )
        return Array(names.map { $0.removed ? "?" : Self.initials(from: $0.name) }.prefix(3))
    }

    private static func initials(from fullName: String) -> String {
        let parts = fullName.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            let a = parts[0].prefix(1)
            let b = parts[1].prefix(1)
            return String(a + b).uppercased()
        }
        if let p = parts.first { return String(p.prefix(2)).uppercased() }
        return "?"
    }
}

private struct HolidayApprovalTaskCard: View {
    let request: HolidayBooking
    let requesterName: String
    let isCancellationRequest: Bool
    let onApprove: () -> Void
    let onDecline: () -> Void
    @EnvironmentObject private var smartCache: SmartCacheService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isCancellationRequest ? "xmark.circle.fill" : "sun.max.fill")
                    .foregroundColor(isCancellationRequest ? .red : .orange)
                Text(isCancellationRequest ? "Annual leave cancellation request" : "Annual leave request")
                    .font(.headline)
                Spacer()
                Text("Pending")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .foregroundColor(.orange)
                    .cornerRadius(8)
            }

            Text(requesterName)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("\(request.startDate.formatted(date: .abbreviated, time: .omitted)) – \(request.endDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button(isCancellationRequest ? "Keep Booking" : "Decline", action: onDecline)
                    .accessibilityIdentifier("holidayApprovalTaskCard.keepBooking")
                    .buttonStyle(.bordered)
                    .tint(.red)
                Button(isCancellationRequest ? "Approve Cancellation" : "Approve", action: onApprove)
                    .accessibilityIdentifier("holidayApprovalTaskCard.approveCancellation")
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
            // RULEBOOK §2: annual leave approval is online only.
            .onlineOnly(isOnline: smartCache.isOnline)
        }
        .padding(14)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
    }
}

/// Legacy tile layout (kept for any future reuse); My Tasks uses `MyTasksRedesignTaskCard`.
struct TaskTileView: View {
    let task: ProjectTask
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService

    var body: some View {
        MyTasksRedesignTaskCard(task: task)
            .environmentObject(projectStore)
            .environmentObject(operativeStore)
            .environmentObject(taskStore)
            .environmentObject(userStore)
            .environmentObject(firebaseBackend)
            .environmentObject(notificationService)
    }
}

#Preview {
    TasksDetailView()
        .environmentObject(SmartCacheService())
        .environmentObject(ProjectTaskStore())
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(UserStore())
        .environmentObject(HolidayStore())
        .environmentObject(NotificationService())
        .environmentObject(FirebaseBackend())
}

/// Review of #305: what the Tasks hub builds from the stores, memoised per store / scope / filter change.
struct TaskHubModel {
    var scopeTasks: [ProjectTask]
    var filtered: [ProjectTask]
    var options: (projects: [TaskFilterChoice], smallWorks: [TaskFilterChoice], creators: [TaskFilterChoice])
    var assignees: [TaskFilterChoice]
}

/// Held in `@State`; written while the body is read (no publishing), so a redraw with the same stores reuses it.
final class TaskHubMemo {
    struct Key: Equatable {
        let tasks: Int
        let projects: Int
        let operatives: Int
        let users: Int
        let viewer: Int
        let ready: Bool
        let scope: TaskScope
        let filters: TaskFilterSet
        let organizationId: String
    }

    var key: Key?
    var model: TaskHubModel?
}
