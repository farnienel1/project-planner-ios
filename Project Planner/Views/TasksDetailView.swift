//
//  TasksDetailView.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import SwiftUI

private enum MyTasksScreenPalette {
    static let canvas = Color(red: 247 / 255, green: 248 / 255, blue: 250 / 255)
    static let ink = Color(red: 11 / 255, green: 16 / 255, blue: 32 / 255)
    static let muted = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)
    static let border = Color(red: 238 / 255, green: 240 / 255, blue: 243 / 255)
    static let blue = Color(red: 24 / 255, green: 95 / 255, blue: 165 / 255)
    static let blueLight = Color(red: 55 / 255, green: 138 / 255, blue: 221 / 255)
    static let todoCount = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)
    static let inProgressCount = Color(red: 133 / 255, green: 79 / 255, blue: 11 / 255)
    static let overdueCount = Color(red: 163 / 255, green: 45 / 255, blue: 45 / 255)
    static let doneCount = Color(red: 15 / 255, green: 110 / 255, blue: 86 / 255)
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

    @State private var searchText = ""
    @State private var listSegment: GlobalMyTasksSegment = .assignedToMe
    @State private var sortNewestFirst = true

    private enum GlobalMyTasksSegment: Hashable {
        case assignedToMe
        case active
        case overdue
        case completed

        static let ordered: [GlobalMyTasksSegment] = [.assignedToMe, .active, .overdue, .completed]

        func pillTitle(activeCount: Int, completedCount: Int, overdueCount: Int) -> String {
            switch self {
            case .assignedToMe: return "Assigned to me"
            case .active: return "Active · \(activeCount)"
            case .overdue: return overdueCount > 0 ? "Overdue · \(overdueCount)" : "Overdue"
            case .completed: return completedCount > 0 ? "Completed · \(completedCount)" : "Completed"
            }
        }
    }

    private var qualificationExpiryBannerItems: [(id: String, title: String, subtitle: String)] {
        guard userStore.isOperativeMode(),
              let email = userStore.currentUser?.email else { return [] }
        let em = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let op = operativeStore.allOperatives.first(where: {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == em
        }) else { return [] }
        let today = Calendar.current.startOfDay(for: Date())
        guard let horizon = Calendar.current.date(byAdding: .day, value: 30, to: today) else { return [] }
        var rows: [(String, String, String)] = []
        for (qid, exp) in op.qualificationExpiryDates {
            guard exp >= today && exp <= horizon,
                  let q = op.qualifications.first(where: { $0.id == qid }) else { continue }
            let days = Calendar.current.dateComponents([.day], from: today, to: exp).day ?? 0
            rows.append((
                id: qid.uuidString,
                title: "Qualification expiring: \(q.name)",
                subtitle: days <= 0 ? "Renew today — tell your manager when complete." : "\(days) day(s) remaining. Tell your manager when you have renewed it."
            ))
        }
        return rows.sorted(by: { $0.1 < $1.1 })
    }

    /// Home “Tasks” hub: job tasks only when assigned to the current user (all roles). Holiday items use separate banners.
    private func taskBelongsInMyList(_ task: ProjectTask) -> Bool {
        task.isAssignedToUser(
            userEmail: userStore.currentUser?.email,
            operatives: operativeStore.allOperatives,
            managers: operativeStore.allManagers,
            isOperativeMode: userStore.isOperativeMode()
        )
    }

    private var userRelevantTasks: [ProjectTask] {
        taskStore.tasks.filter { taskBelongsInMyList($0) }
    }

    private var myTasksStats: (todo: Int, inProgress: Int, overdue: Int, done: Int) {
        let base = userRelevantTasks
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let incomplete = base.filter { !$0.isCompleted }
        let todo = incomplete.filter { $0.status == .todo }.count
        let inProgress = incomplete.filter { $0.status == .inProgress }.count
        let overdue = incomplete.filter { task in
            guard let due = task.dueDate else { return false }
            return cal.startOfDay(for: due) < startOfToday
        }.count
        let done = base.filter { $0.isCompleted }.count
        return (todo, inProgress, overdue, done)
    }

    private var activeRelevantCount: Int {
        userRelevantTasks.filter { !$0.isCompleted }.count
    }

    private var completedRelevantCount: Int {
        userRelevantTasks.filter { $0.isCompleted }.count
    }

    private var overdueRelevantCount: Int {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        return userRelevantTasks.filter { task in
            guard !task.isCompleted, let due = task.dueDate else { return false }
            return cal.startOfDay(for: due) < startOfToday
        }.count
    }

    private var displayedTasks: [ProjectTask] {
        var list = userRelevantTasks
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        switch listSegment {
        case .active:
            list = list.filter { !$0.isCompleted }
        case .completed:
            list = list.filter { $0.isCompleted }
        case .assignedToMe:
            list = list.filter { !$0.isCompleted }
            list = list.filter {
                $0.isAssignedToUser(
                    userEmail: userStore.currentUser?.email,
                    operatives: operativeStore.allOperatives,
                    managers: operativeStore.allManagers,
                    isOperativeMode: userStore.isOperativeMode()
                )
            }
        case .overdue:
            list = list.filter { !$0.isCompleted }
            list = list.filter { task in
                guard let due = task.dueDate else { return false }
                return cal.startOfDay(for: due) < startOfToday
            }
        }
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
        if sortNewestFirst {
            return list.sorted { $0.createdAt > $1.createdAt }
        }
        return list.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !pendingHolidayApprovals.isEmpty {
                        holidayBannersSection
                    }
                    if !qualificationExpiryBannerItems.isEmpty {
                        qualificationBannersSection
                    }

                    let stats = myTasksStats
                    HStack(spacing: 8) {
                        statChip(value: stats.todo, label: "To do", valueColor: MyTasksScreenPalette.todoCount)
                        statChip(value: stats.inProgress, label: "In progress", valueColor: MyTasksScreenPalette.inProgressCount)
                        statChip(value: stats.overdue, label: "Overdue", valueColor: MyTasksScreenPalette.overdueCount)
                        statChip(value: stats.done, label: "Done", valueColor: MyTasksScreenPalette.doneCount)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(MyTasksScreenPalette.muted)
                        TextField("Search tasks…", text: $searchText)
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                        Menu {
                            Button(sortNewestFirst ? "Sort: Oldest first" : "Sort: Newest first") {
                                sortNewestFirst.toggle()
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(MyTasksScreenPalette.blue)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(red: 229 / 255, green: 231 / 255, blue: 235 / 255), lineWidth: 0.5)
                    )

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(GlobalMyTasksSegment.ordered, id: \.self) { seg in
                                scopePill(
                                    title: seg.pillTitle(
                                        activeCount: activeRelevantCount,
                                        completedCount: completedRelevantCount,
                                        overdueCount: overdueRelevantCount
                                    ),
                                    isSelected: listSegment == seg
                                ) {
                                    listSegment = seg
                                }
                            }
                        }
                    }

                    if taskStore.isLoading && userRelevantTasks.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(40)
                    } else if let err = taskStore.errorMessage, userRelevantTasks.isEmpty {
                        errorState(err)
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
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .background(MyTasksScreenPalette.canvas.ignoresSafeArea())
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MyTasksScreenPalette.ink)
                }
            }
            .task {
                await taskStore.loadData()
                await holidayStore.loadData()
            }
            .refreshable {
                await taskStore.loadData()
                await holidayStore.loadData()
            }
        }
    }

    private func statChip(value: Int, label: String, valueColor: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(valueColor)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(MyTasksScreenPalette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MyTasksScreenPalette.border, lineWidth: 0.5))
    }

    private func scopePill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : MyTasksScreenPalette.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isSelected ? MyTasksScreenPalette.blue : Color.white)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color(red: 229 / 255, green: 231 / 255, blue: 235 / 255), lineWidth: isSelected ? 0 : 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var emptyStateCard: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 230 / 255, green: 241 / 255, blue: 251 / 255))
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "checklist")
                        .font(.system(size: 26))
                        .foregroundStyle(MyTasksScreenPalette.blue)
                )
            Text(emptyTitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MyTasksScreenPalette.ink)
            Text(emptySubtitle)
                .font(.system(size: 12))
                .foregroundStyle(MyTasksScreenPalette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(MyTasksScreenPalette.border, lineWidth: 0.5))
    }

    private var emptyTitle: String {
        switch listSegment {
        case .active: return "No active tasks"
        case .completed: return "No completed tasks"
        case .assignedToMe: return "Nothing assigned to you"
        case .overdue: return "No overdue tasks"
        }
    }

    private var emptySubtitle: String {
        switch listSegment {
        case .active:
            return "When you are assigned to tasks on a job, they will appear here."
        case .completed:
            return "Completed tasks will appear here."
        case .assignedToMe:
            return "When someone assigns you on a task, it will show here."
        case .overdue:
            return "Overdue tasks still appear under Active. This filter shows only tasks past their due date."
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(MyTasksScreenPalette.muted)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await taskStore.loadData() }
            }
            .buttonStyle(.borderedProminent)
            .tint(MyTasksScreenPalette.blue)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var holidayBannersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Holiday approvals")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MyTasksScreenPalette.ink)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MyTasksScreenPalette.overdueCount)
            ForEach(qualificationExpiryBannerItems, id: \.id) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(MyTasksScreenPalette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(red: 252 / 255, green: 235 / 255, blue: 235 / 255).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var pendingHolidayApprovals: [HolidayBooking] {
        guard let me = userStore.currentUser, !me.permissions.operativeMode else { return [] }
        let pending = holidayStore.pendingRequests

        let filtered: [HolidayBooking]
        if me.permissions.manager && !me.isSuperAdmin && !me.permissions.adminAccess && me.role != .admin {
            filtered = pending.filter { assignedApproverUserId(for: $0) == me.id }
        } else if userStore.hasAdminAccess() {
            filtered = pending.filter {
                let assigned = assignedApproverUserId(for: $0)
                return assigned == nil || assigned == me.id
            }
        } else {
            filtered = []
        }

        if sortNewestFirst {
            return filtered.sorted { $0.createdAt > $1.createdAt }
        }
        return filtered.sorted { $0.createdAt < $1.createdAt }
    }

    private func assignedApproverUserId(for request: HolidayBooking) -> String? {
        if let uid = request.userId,
           let requester = userStore.organizationUsers.first(where: { $0.id == uid }) {
            if requester.permissions.manager &&
                !requester.permissions.annualLeaveSelfBook &&
                !requester.permissions.operativeMode &&
                !requester.isSuperAdmin &&
                !requester.permissions.adminAccess &&
                requester.role != .admin {
                return nil
            }
            let managerId = requester.assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (managerId?.isEmpty == false) ? managerId : nil
        }
        if let oid = request.operativeId,
           let op = operativeStore.allOperatives.first(where: { $0.id == oid }),
           let requester = userStore.organizationUsers.first(where: {
               ($0.permissions.operativeMode || $0.role == .operative) &&
               $0.email.lowercased() == op.email.lowercased()
           }) {
            let managerId = requester.assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (managerId?.isEmpty == false) ? managerId : nil
        }
        return nil
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
        guard let uid = userStore.currentUser?.id else { return }
        Task {
            let name = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Manager"
            if request.cancellationRequestedAt != nil {
                await holidayStore.deleteBooking(request)
                await notifyDecision(
                    to: request,
                    approved: true,
                    decidedByName: "\(name) approved your annual leave cancellation"
                )
                await notificationService.loadNotifications()
                return
            }
            await holidayStore.approveBooking(request, approvedByUserId: uid)
            await notifyDecision(to: request, approved: true, decidedByName: name)
            await notificationService.loadNotifications()
        }
    }

    private func declineHolidayRequest(_ request: HolidayBooking) {
        guard let uid = userStore.currentUser?.id else { return }
        Task {
            if request.cancellationRequestedAt != nil {
                var updated = request
                updated.cancellationRequestedAt = nil
                updated.cancellationRequestedByUserId = nil
                updated.updatedAt = Date()
                do {
                    try await holidayStore.saveBooking(updated)
                } catch {
                    return
                }
                await notificationService.loadNotifications()
                return
            }
            await holidayStore.rejectBooking(request, rejectedByUserId: uid)
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
            if approved,
               let requester = userStore.organizationUsers.first(where: { $0.id == requesterUserId }),
               requester.permissions.manager,
               !requester.permissions.annualLeaveSelfBook,
               !requester.permissions.operativeMode,
               !requester.isSuperAdmin,
               !requester.permissions.adminAccess,
               requester.role != .admin {
                await notificationService.notifyAdminAnnualLeaveApproval(
                    managerName: requester.fullName,
                    approvedByName: decidedByName,
                    excludingUserId: userStore.currentUser?.id
                )
            }
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

    @State private var showingTaskDetail = false

    private var resolvedTask: ProjectTask {
        taskStore.tasks.first(where: { $0.id == task.id }) ?? task
    }

    var body: some View {
        Button {
            showingTaskDetail = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accentStripColor)
                    .frame(width: 4)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(resolvedTask.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(MyTasksScreenPalette.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        statusPill
                    }

                    HStack(spacing: 5) {
                        Image(systemName: projectLineIcon)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 197 / 255, green: 201 / 255, blue: 210 / 255))
                        Text(projectLineText)
                            .font(.system(size: 11))
                            .foregroundStyle(MyTasksScreenPalette.muted)
                    }

                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: "checklist")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(red: 197 / 255, green: 201 / 255, blue: 210 / 255))
                            Text(checklistSummary)
                                .font(.system(size: 11))
                                .foregroundStyle(MyTasksScreenPalette.muted)
                        }
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: "calendar")
                                .font(.system(size: 12))
                                .foregroundStyle(dueColor)
                            Text(dueText)
                                .font(.system(size: 11, weight: dueWeight))
                                .foregroundStyle(dueColor)
                        }
                    }

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
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(MyTasksScreenPalette.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingTaskDetail) {
            CompletedTaskDetailView(task: resolvedTask)
                .environmentObject(taskStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(projectStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
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

    private var checklistSummary: String {
        let items = resolvedTask.effectiveItems
        if items.count <= 1 { return "No checklist" }
        let ids = Set(items.map(\.id))
        let done = Set(resolvedTask.completedItemIds).intersection(ids).count
        return "\(done) of \(items.count) items"
    }

    private var checklistProgress: CGFloat {
        let items = resolvedTask.effectiveItems
        guard items.count > 1 else { return 0 }
        let ids = Set(items.map(\.id))
        let done = Set(resolvedTask.completedItemIds).intersection(ids).count
        return CGFloat(done) / CGFloat(items.count)
    }

    private var progressBarFill: Color {
        if isOverdue { return MyTasksScreenPalette.overdueCount }
        if resolvedTask.status == .inProgress { return MyTasksScreenPalette.blue }
        return MyTasksScreenPalette.blue
    }

    private var isOverdue: Bool {
        guard !resolvedTask.isCompleted, let due = resolvedTask.dueDate else { return false }
        return Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: Date())
    }

    private var dueText: String {
        guard let due = resolvedTask.dueDate else { return "No date" }
        let cal = Calendar.current
        let d0 = cal.startOfDay(for: due)
        let t0 = cal.startOfDay(for: Date())
        if resolvedTask.isCompleted || d0 >= t0 {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE d MMM"
            return fmt.string(from: due)
        }
        let days = cal.dateComponents([.day], from: d0, to: t0).day ?? 0
        if days == 1 { return "Yesterday" }
        if days > 1 { return "\(days) days ago" }
        return due.formatted(date: .abbreviated, time: .omitted)
    }

    private var dueColor: Color {
        guard let due = resolvedTask.dueDate, !resolvedTask.isCompleted else { return MyTasksScreenPalette.muted }
        if Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: Date()) {
            return MyTasksScreenPalette.overdueCount
        }
        return MyTasksScreenPalette.muted
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
            statusCapsule(text: "To do", fg: MyTasksScreenPalette.muted, bg: Color(red: 242 / 255, green: 243 / 255, blue: 245 / 255), icon: "circle.dashed")
        case .inProgress:
            statusCapsule(text: "In progress", fg: MyTasksScreenPalette.inProgressCount, bg: Color(red: 250 / 255, green: 238 / 255, blue: 218 / 255), icon: "chart.line.uptrend.xyaxis")
        case .completed:
            statusCapsule(text: "Done", fg: MyTasksScreenPalette.doneCount, bg: Color(red: 225 / 255, green: 245 / 255, blue: 238 / 255), icon: "checkmark.circle.fill")
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
            Text(resolvedTask.priority.rawValue)
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
            return (MyTasksScreenPalette.muted, Color(red: 242 / 255, green: 243 / 255, blue: 245 / 255), MyTasksScreenPalette.muted)
        case .normal:
            return (MyTasksScreenPalette.inProgressCount, Color(red: 250 / 255, green: 238 / 255, blue: 218 / 255), MyTasksScreenPalette.inProgressCount)
        case .high:
            return (MyTasksScreenPalette.overdueCount, Color(red: 252 / 255, green: 235 / 255, blue: 235 / 255), MyTasksScreenPalette.overdueCount)
        case .urgent:
            return (MyTasksScreenPalette.overdueCount, Color(red: 252 / 255, green: 235 / 255, blue: 235 / 255), MyTasksScreenPalette.overdueCount)
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

    private var assigneeInitialsList: [String] {
        var out: [String] = []
        for id in resolvedTask.allAssignedManagerIds {
            if let m = operativeStore.allManagers.first(where: { $0.id == id }) {
                out.append(Self.initials(from: m.fullName))
            }
        }
        for id in resolvedTask.allAssignedOperativeIds {
            if let o = operativeStore.allOperatives.first(where: { $0.id == id }) {
                out.append(Self.initials(from: o.name))
            }
        }
        return Array(out.prefix(3))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isCancellationRequest ? "xmark.circle.fill" : "sun.max.fill")
                    .foregroundColor(isCancellationRequest ? .red : .orange)
                Text(isCancellationRequest ? "Holiday cancellation request" : "Holiday request")
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
                    .buttonStyle(.bordered)
                    .tint(.red)
                Button(isCancellationRequest ? "Approve Cancellation" : "Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
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
        .environmentObject(ProjectTaskStore())
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(UserStore())
        .environmentObject(HolidayStore())
        .environmentObject(NotificationService())
        .environmentObject(FirebaseBackend())
}
