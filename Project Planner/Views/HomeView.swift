//
//  HomeView.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import SwiftUI
import FirebaseAuth

struct HomeView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var notificationService: NotificationService
    @StateObject private var warningsService = WarningsService()
    
    @State private var showingCreateClient = false
    @State private var showingNotifications = false
    @State private var showingCreateProject = false
    @State private var showingCreateSmallWorks = false
    @State private var showingCreateOperative = false
    @State private var showingCreateManager = false
    @State private var showingSkillsManagement = false
    @State private var showingQualificationsManagement = false
    @State private var showingJobTypesManagement = false
    @State private var showingAddUser = false
    @State private var showingManageUsers = false
    @State private var showingDailyOverview = false
    @State private var showingWeeklyReport = false
    @State private var showingOrgSitesMap = false
    @State private var showingMySchedule = false
    @State private var showingWarningsDetail = false
    @State private var showingTasksDetail = false
    @State private var showingWholesalers = false
    @State private var showingOperativeQualifications = false
    @State private var showingSiteAudit = false
    
    // Navigation states for menu items
    @State private var showingClientsView = false
    @State private var showingQuickMenu = false
    @State private var warningsRefreshTask: Task<Void, Never>?
    @State private var isCustomisingQuickActions = false
    @State private var showingAddQuickActionPicker = false
    @State private var showingQuickActionCustomizeHint = false
    @State private var persistedQuickActionIds: [String] = []
    @State private var showingGeneralAppSettings = false
    @State private var hasLoadedQuickActionLayout = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                taskLimitWarningBanner
                homeDashboardRoot
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar(.hidden, for: .navigationBar)
        .background(homeCanvasBackground.ignoresSafeArea(edges: .top))
        .sheet(isPresented: $showingWarningsDetail) {
            WarningsDetailView(warningsService: warningsService)
                .environmentObject(projectStore)
                .environmentObject(userStore)
                .environmentObject(operativeStore)
        }
        .sheet(isPresented: $showingTasksDetail) {
            TasksDetailView()
                .environmentObject(taskStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(holidayStore)
                .environmentObject(notificationService)
        }
        .sheet(isPresented: $showingNotifications) {
            NotificationsView()
                .environmentObject(notificationService)
                .environmentObject(userStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(bookingStore)
                .environmentObject(taskStore)
        }
        .task {
            // Defer slightly so Home can render before notification work; ContentView also refreshes periodically.
            try? await Task.sleep(nanoseconds: 800_000_000)
            await notificationService.loadNotifications()
        }
        .sheet(isPresented: $showingCreateClient) {
            CreateClientView()
                .environmentObject(projectStore)
        }
        .sheet(isPresented: $showingCreateProject) {
            CreateProjectView()
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(notificationService)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .sheet(isPresented: $showingCreateSmallWorks) {
            CreateSmallWorksView()
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(notificationService)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .sheet(isPresented: $showingCreateOperative) {
            CreateOperativeView()
                .environmentObject(operativeStore)
        }
        .sheet(isPresented: $showingCreateManager) {
            CreateManagerView()
                .environmentObject(operativeStore)
        }
        .sheet(isPresented: $showingSkillsManagement) {
            SkillsManagementView()
                .environmentObject(operativeStore)
        }
        .sheet(isPresented: $showingQualificationsManagement) {
            QualificationsManagementView()
                .environmentObject(operativeStore)
        }
        .sheet(isPresented: $showingOperativeQualifications) {
            OperativeQualificationsReadOnlyView()
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .sheet(isPresented: $showingJobTypesManagement) {
            JobTypesManagementView()
                .environmentObject(projectStore)
        }
        .sheet(isPresented: $showingAddUser) {
            AddUserView(mode: (!userStore.hasAdminAccess() &&
                               userStore.displayUser?.permissions.manager == true &&
                               userStore.displayUser?.permissions.operatives == true)
                        ? .managerAddingOperative
                        : .admin)
                .environmentObject(userStore)
        }
        .sheet(isPresented: $showingManageUsers) {
            ManageUsersView()
                .environmentObject(userStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(holidayStore)
                .environmentObject(firebaseBackend)
        }
        .sheet(isPresented: $showingWholesalers) {
            WholesalersView()
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("dismissManageUsersAndSelectTab"))) { notification in
            showingManageUsers = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("openTasksDetail"))) { _ in
            showingTasksDetail = true
        }
        .fullScreenCover(isPresented: $showingClientsView) {
            ClientsView()
                .environmentObject(projectStore)
        }
        .sheet(isPresented: $showingDailyOverview) {
            DailyOverviewView()
                .environmentObject(bookingStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(holidayStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(subcontractorStore)
        }
        .sheet(isPresented: $showingWeeklyReport) {
            WeeklyReportView()
                .environmentObject(bookingStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(holidayStore)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
                .environmentObject(subcontractorStore)
        }
        .sheet(isPresented: $showingOrgSitesMap) {
            OrgSitesMapView()
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
                .environmentObject(projectStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
        }
        .sheet(isPresented: $showingMySchedule) {
            MyScheduleView()
                .environmentObject(firebaseBackend)
                .environmentObject(bookingStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(holidayStore)
                .environmentObject(appSettings)
        }
        .sheet(isPresented: $showingSiteAudit) {
            SiteAuditHubView()
                .environmentObject(projectStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .sheet(isPresented: $showingQuickMenu) {
            QuickMenuSheet(
                showingClientsView: $showingClientsView,
                showingCreateProject: $showingCreateProject,
                showingCreateSmallWorks: $showingCreateSmallWorks,
                showingSkillsManagement: $showingSkillsManagement,
                showingQualificationsManagement: $showingQualificationsManagement,
                showingJobTypesManagement: $showingJobTypesManagement,
                showingWholesalers: $showingWholesalers,
                showingOperativeQualifications: $showingOperativeQualifications,
                showingAddUser: $showingAddUser,
                showingManageUsers: $showingManageUsers,
                showingTasksDetail: $showingTasksDetail
            )
            .environmentObject(userStore)
            .environmentObject(firebaseBackend)
            .environmentObject(appSettings)
            .environmentObject(projectStore)
            .environmentObject(operativeStore)
        }
        .onAppear {
            managerScheduleStore.loadData()
            loadPersistedQuickActionsIfNeeded()
        }
        .onChange(of: userStore.currentUser?.id) { _, _ in
            hasLoadedQuickActionLayout = false
            loadPersistedQuickActionsIfNeeded()
        }
        .sheet(isPresented: $showingAddQuickActionPicker) {
            HomeQuickActionAddSheet(
                ids: addableQuickActionIds,
                displayTitle: { id in displayTitleForQuickAction(id: id) }
            ) { id in
                appendQuickAction(id: id)
                showingAddQuickActionPicker = false
            }
        }
        .sheet(isPresented: $showingGeneralAppSettings) {
            NavigationStack {
                GeneralAppSettingsView()
                    .environmentObject(appSettings)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingGeneralAppSettings = false }
                        }
                    }
            }
        }
        .alert("Quick actions", isPresented: $showingQuickActionCustomizeHint) {
            Button("OK") {
                UserDefaults.standard.set(true, forKey: quickActionCustomizeHintKey)
            }
        } message: {
            Text("Drag the icons to your desired layout.")
        }
    }

    // MARK: - Home dashboard (HTML / design reference)

    private var homeCanvasBackground: Color {
        Color(red: 0.97, green: 0.973, blue: 0.98)
    }

    private var homeInk: Color { Color(red: 0.043, green: 0.063, blue: 0.125) }
    private var homeMuted: Color { Color(red: 0.42, green: 0.45, blue: 0.49) }
    private var homeBlue: Color { Color(red: 0.094, green: 0.373, blue: 0.647) }
    private var homeBlueLight: Color { Color(red: 0.216, green: 0.541, blue: 0.867) }

    private var greetingFirstName: String {
        if let appUser = userStore.currentUser {
            if !appUser.firstName.isEmpty { return appUser.firstName }
            return appUser.email.components(separatedBy: "@").first?.capitalized ?? "there"
        }
        if let email = firebaseBackend.currentUser?.email {
            return extractNameFromEmail(email)
        }
        return "there"
    }

    private var profileInitials: String {
        guard let u = userStore.currentUser else {
            let e = firebaseBackend.currentUser?.email ?? "?"
            return String(e.prefix(2)).uppercased()
        }
        let f = u.firstName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)
        let s = u.surname.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)
        if f.isEmpty && s.isEmpty {
            return String(u.email.prefix(2)).uppercased()
        }
        return "\(f)\(s)".uppercased()
    }

    private var todayWeekdayLine: String {
        Date().formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private var liveProjectCount: Int {
        projectStore.liveProjects.count + projectStore.smallWorks.count
    }

    private var tasksDueTodayCount: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return taskStore.tasks.filter { task in
            guard !task.isCompleted, let due = task.dueDate, cal.isDate(due, inSameDayAs: today) else { return false }
            return task.isAssignedToUser(
                userEmail: userStore.currentUser?.email,
                operatives: operativeStore.allOperatives,
                managers: operativeStore.allManagers,
                isOperativeMode: userStore.isOperativeMode()
            )
        }.count
    }

    private var tasksDueThisWeekCount: Int {
        let cal = Calendar.current
        let now = Date()
        guard let weekEnd = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: now)) else { return 0 }
        return taskStore.tasks.filter { task in
            guard !task.isCompleted, let due = task.dueDate else { return false }
            let d0 = cal.startOfDay(for: due)
            guard d0 >= cal.startOfDay(for: now), d0 < weekEnd else { return false }
            return task.isAssignedToUser(
                userEmail: userStore.currentUser?.email,
                operatives: operativeStore.allOperatives,
                managers: operativeStore.allManagers,
                isOperativeMode: userStore.isOperativeMode()
            )
        }.count
    }

    private var homeDashboardRoot: some View {
        VStack(alignment: .leading, spacing: 0) {
            homeGreetingHeader
            todayOverviewCard
            homeSecondaryStatusRow
            quickActionsHeaderRow
            quickActionsIconGrid
            upNextSection
            if userStore.canViewProjects() && !userStore.isOperativeMode() {
                maintenanceTeaserCompact
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .onAppear {
            scheduleWarningsRefresh()
        }
        .onChange(of: operativeStore.allOperatives) { _, _ in scheduleWarningsRefresh() }
        .onChange(of: bookingStore.bookings) { _, _ in scheduleWarningsRefresh() }
        .onChange(of: projectStore.projects) { _, _ in scheduleWarningsRefresh() }
        .onChange(of: projectStore.smallWorks) { _, _ in scheduleWarningsRefresh() }
    }

    private var homeGreetingHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(todayWeekdayLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(homeMuted)
                Text("Hi, \(greetingFirstName)")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(homeInk)
                    .tracking(-0.3)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    Task {
                        await notificationService.markAllAsRead()
                        showingNotifications = true
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(homeInk)
                            .frame(width: 38, height: 38)
                            .background(Color.white)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color(red: 0.9, green: 0.91, blue: 0.93), lineWidth: 0.5))
                        if notificationService.unreadCount > 0 {
                            Circle()
                                .fill(Color(red: 0.89, green: 0.29, blue: 0.29))
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                                .offset(x: 2, y: -2)
                        }
                    }
                }
                .buttonStyle(.plain)
                Text(profileInitials)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(homeBlue)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(red: 0.9, green: 0.91, blue: 0.93), lineWidth: 0.5))
            }
        }
        .padding(.bottom, 18)
    }

    private var todayOverviewCard: some View {
        let onTrack = warningsService.warningCount == 0 && tasksDueTodayCount == 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today's overview")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .textCase(.uppercase)
                        .tracking(0.3)
                    Text("\(liveProjectCount) active project\(liveProjectCount == 1 ? "" : "s")")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(onTrack ? "On track" : "Heads up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.18))
                    .clipShape(Capsule())
            }
            HStack(spacing: 10) {
                overviewStatPill(value: "\(tasksDueTodayCount)", label: "Tasks today")
                overviewStatPill(value: "\(tasksDueThisWeekCount)", label: "Due this week")
                overviewStatPill(value: "\(warningsService.warningCount)", label: "Warnings")
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .background(
            LinearGradient(
                colors: [homeBlue, homeBlueLight],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.bottom, 14)
    }

    private func overviewStatPill(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var homeSecondaryStatusRow: some View {
        HStack(spacing: 10) {
            if userStore.hasAdminAccess() || userStore.isHomeProfileLoading {
                secondaryPill(
                    icon: "exclamationmark.triangle.fill",
                    iconTint: Color(red: 0.64, green: 0.18, blue: 0.18),
                    iconBackground: Color(red: 0.99, green: 0.92, blue: 0.92),
                    title: "Warnings",
                    value: warningsService.warningCount == 0 ? "All clear" : "\(warningsService.warningCount) active"
                ) {
                    DispatchQueue.main.async { showingWarningsDetail = true }
                }
                .frame(maxWidth: .infinity)
            }
            secondaryPill(
                icon: "checklist",
                iconTint: homeBlue,
                iconBackground: Color(red: 0.9, green: 0.945, blue: 0.984),
                title: "Tasks",
                value: "\(assignedTasksCount) pending"
            ) {
                DispatchQueue.main.async { showingTasksDetail = true }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 18)
    }

    private func secondaryPill(
        icon: String,
        iconTint: Color,
        iconBackground: Color,
        title: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconBackground)
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(iconTint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(homeMuted)
                    Text(value)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(homeInk)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(red: 0.933, green: 0.941, blue: 0.953), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var quickActionStorageKey: String {
        let uid = firebaseBackend.currentUser?.uid ?? "anonymous"
        return "homeQuickActionOrder.\(uid)"
    }

    private var quickActionCustomizeHintKey: String {
        let uid = firebaseBackend.currentUser?.uid ?? "anonymous"
        return "homeQuickActionCustomizeHint.\(uid)"
    }

    private func loadPersistedQuickActionsIfNeeded() {
        guard !hasLoadedQuickActionLayout else { return }
        hasLoadedQuickActionLayout = true
        if let saved = UserDefaults.standard.array(forKey: quickActionStorageKey) as? [String], !saved.isEmpty {
            let allowed = Set(HomeQuickActionRegistry.allEligibleIds(userStore: userStore))
            var seen = Set<String>()
            let filtered = saved.filter { allowed.contains($0) }.filter { seen.insert($0).inserted }
            persistedQuickActionIds = filtered.isEmpty
                ? HomeQuickActionRegistry.defaultOrderedIds(userStore: userStore)
                : filtered
        } else {
            persistedQuickActionIds = HomeQuickActionRegistry.defaultOrderedIds(userStore: userStore)
        }
    }

    private func savePersistedQuickActions() {
        UserDefaults.standard.set(persistedQuickActionIds, forKey: quickActionStorageKey)
    }

    private func sanitizePersistedQuickActionsIfNeeded() {
        let allowed = Set(HomeQuickActionRegistry.allEligibleIds(userStore: userStore))
        let next = persistedQuickActionIds.filter { allowed.contains($0) }
        if next.count != persistedQuickActionIds.count {
            persistedQuickActionIds = next.isEmpty
                ? HomeQuickActionRegistry.defaultOrderedIds(userStore: userStore)
                : next
            savePersistedQuickActions()
        }
    }

    private var addableQuickActionIds: [String] {
        let onHome = Set(persistedQuickActionIds)
        return HomeQuickActionRegistry.allEligibleIds(userStore: userStore)
            .filter { !onHome.contains($0) }
            .sorted()
    }

    private func displayTitleForQuickAction(id: String) -> String {
        if id == HomeQuickActionID.staffAddUser.rawValue, !userStore.canManageUsers() {
            return "Add\noperative"
        }
        if id == HomeQuickActionID.staffManageUsersSheet.rawValue, !userStore.canManageUsers() {
            return "Manage\noperatives"
        }
        return HomeQuickActionRegistry.meta(for: id)?.title ?? ""
    }

    private func appendQuickAction(id: String) {
        guard HomeQuickActionRegistry.isEligible(id: id, userStore: userStore) else { return }
        guard !persistedQuickActionIds.contains(id) else { return }
        persistedQuickActionIds.append(id)
        savePersistedQuickActions()
    }

    private func removeQuickAction(id: String) {
        persistedQuickActionIds.removeAll { $0 == id }
        savePersistedQuickActions()
    }

    private func reorderQuickAction(fromId: String, toId: String) {
        guard let from = persistedQuickActionIds.firstIndex(of: fromId),
              let to = persistedQuickActionIds.firstIndex(of: toId),
              from != to else { return }
        var ids = persistedQuickActionIds
        let item = ids.remove(at: from)
        let insertIndex = from < to ? to - 1 : to
        ids.insert(item, at: insertIndex)
        persistedQuickActionIds = ids
        savePersistedQuickActions()
    }

    private func performQuickAction(id: String) {
        guard HomeQuickActionRegistry.isEligible(id: id, userStore: userStore) else { return }
        switch id {
        case HomeQuickActionID.opProjects.rawValue, HomeQuickActionID.staffProjects.rawValue:
            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 1])
        case HomeQuickActionID.opSmallWorks.rawValue, HomeQuickActionID.staffSmallWorks.rawValue:
            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 2])
        case HomeQuickActionID.opAnnualLeave.rawValue, HomeQuickActionID.staffAnnualLeave.rawValue:
            presentAnnualLeaveFromHome()
        case HomeQuickActionID.opSiteAudit.rawValue, HomeQuickActionID.staffSiteAudit.rawValue:
            showingSiteAudit = true
        case HomeQuickActionID.opSchedule.rawValue, HomeQuickActionID.staffSchedule.rawValue:
            showingMySchedule = true
        case HomeQuickActionID.opSettings.rawValue, HomeQuickActionID.staffSettings.rawValue:
            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 5])
        case HomeQuickActionID.staffWeeklyReport.rawValue:
            showingWeeklyReport = true
        case HomeQuickActionID.staffDailyOverview.rawValue:
            showingDailyOverview = true
        case HomeQuickActionID.staffManagers.rawValue:
            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 4])
        case HomeQuickActionID.staffOperatives.rawValue:
            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 3])
        case HomeQuickActionID.staffSubcontractors.rawValue:
            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 9])
        case HomeQuickActionID.staffSiteMap.rawValue:
            showingOrgSitesMap = true
        case HomeQuickActionID.staffClients.rawValue:
            showingClientsView = true
        case HomeQuickActionID.staffCreateProject.rawValue:
            showingCreateProject = true
        case HomeQuickActionID.staffCreateSmallWorks.rawValue:
            showingCreateSmallWorks = true
        case HomeQuickActionID.staffSkills.rawValue:
            showingSkillsManagement = true
        case HomeQuickActionID.staffQualifications.rawValue:
            showingQualificationsManagement = true
        case HomeQuickActionID.staffMyQualifications.rawValue:
            showingOperativeQualifications = true
        case HomeQuickActionID.staffJobTypes.rawValue:
            showingJobTypesManagement = true
        case HomeQuickActionID.staffWholesalers.rawValue:
            showingWholesalers = true
        case HomeQuickActionID.staffAddUser.rawValue:
            showingAddUser = true
        case HomeQuickActionID.staffManageUsersSheet.rawValue:
            showingManageUsers = true
        case HomeQuickActionID.staffHelp.rawValue:
            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 6])
        case HomeQuickActionID.staffHoliday.rawValue:
            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 8])
        case HomeQuickActionID.staffGeneralAppSettings.rawValue:
            showingGeneralAppSettings = true
        default:
            break
        }
    }

    @ViewBuilder
    private func quickActionTileContents(meta: HomeQuickActionMeta, title: String) -> some View {
        let tint = meta.color
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.22))
                    .frame(width: 36, height: 36)
                Image(systemName: meta.symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(homeInk)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(red: 0.933, green: 0.941, blue: 0.953), lineWidth: 0.5)
        )
    }

    private var quickActionsHeaderRow: some View {
        HStack {
            Text("Quick actions")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(homeInk)
            Spacer()
            if isCustomisingQuickActions, !addableQuickActionIds.isEmpty {
                Button {
                    showingAddQuickActionPicker = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(homeBlue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add quick action")
            }
            Button {
                showingQuickMenu = true
            } label: {
                Label("Main Menu", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(homeBlue)
            }
            .buttonStyle(.plain)
            Button {
                if isCustomisingQuickActions {
                    isCustomisingQuickActions = false
                    sanitizePersistedQuickActionsIfNeeded()
                    savePersistedQuickActions()
                } else {
                    isCustomisingQuickActions = true
                    if !UserDefaults.standard.bool(forKey: quickActionCustomizeHintKey) {
                        showingQuickActionCustomizeHint = true
                    }
                }
            } label: {
                Text(isCustomisingQuickActions ? "Done" : "Customise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(homeMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 10)
    }

    private let quickGrid = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var quickActionsIconGrid: some View {
        LazyVGrid(columns: quickGrid, spacing: 10) {
            ForEach(persistedQuickActionIds, id: \.self) { id in
                if let meta = HomeQuickActionRegistry.meta(for: id),
                   HomeQuickActionRegistry.isEligible(id: id, userStore: userStore) {
                    if isCustomisingQuickActions {
                        quickActionCustomizeTile(id: id, meta: meta)
                    } else {
                        Button {
                            performQuickAction(id: id)
                        } label: {
                            quickActionTileContents(meta: meta, title: displayTitleForQuickAction(id: id))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.bottom, 18)
        .onAppear { sanitizePersistedQuickActionsIfNeeded() }
    }

    @ViewBuilder
    private func quickActionCustomizeTile(id: String, meta: HomeQuickActionMeta) -> some View {
        let title = displayTitleForQuickAction(id: id)
        ZStack(alignment: .topTrailing) {
            quickActionTileContents(meta: meta, title: title)
                .draggable(id) {
                    quickActionTileContents(meta: meta, title: title)
                        .frame(width: 118, height: 100)
                        .opacity(0.9)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first, dragged != id else { return false }
                    reorderQuickAction(fromId: dragged, toId: id)
                    return true
                }

            Button {
                removeQuickAction(id: id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.black.opacity(0.42)))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .accessibilityLabel("Remove \(title) from quick actions")
        }
    }

    private var upNextRows: [HomeUpNextRow] {
        HomeUpNextSupport.upcomingRows(
            limit: 2,
            now: Date(),
            authUserId: firebaseBackend.currentUser?.uid,
            currentUserEmail: userStore.currentUser?.email,
            operatives: operativeStore.allOperatives,
            bookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings,
            allProjects: projectStore.projects,
            organizationUsers: userStore.organizationUsers,
            accentBlue: homeBlue,
            accentPurple: Color(red: 0.325, green: 0.29, blue: 0.718)
        )
    }

    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up next")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(homeInk)
                Spacer()
                Button("See all") { showingMySchedule = true }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(homeBlue)
            }
            .padding(.bottom, 10)

            let rows = upNextRows
            if rows.isEmpty {
                Text("No upcoming bookings on your schedule.")
                    .font(.system(size: 13))
                    .foregroundStyle(homeMuted)
                    .padding(.vertical, 8)
            } else {
                ForEach(rows) { row in
                    Button {
                        showingMySchedule = true
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(row.accentColor)
                                .frame(width: 4, height: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(homeInk)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(row.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(homeMuted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color(red: 0.77, green: 0.79, blue: 0.82))
                        }
                        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color(red: 0.933, green: 0.941, blue: 0.953), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var maintenanceTeaserCompact: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.98, green: 0.933, blue: 0.855))
                    .frame(width: 36, height: 36)
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(red: 0.522, green: 0.31, blue: 0.043))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Maintenance")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(homeInk)
                    Text("Soon")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(red: 0.522, green: 0.31, blue: 0.043))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.98, green: 0.933, blue: 0.855))
                        .clipShape(Capsule())
                }
                Text("Coming in a future update")
                    .font(.system(size: 11))
                    .foregroundStyle(homeMuted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14))
                .foregroundStyle(Color(red: 0.77, green: 0.79, blue: 0.82))
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(red: 0.933, green: 0.941, blue: 0.953), lineWidth: 0.5)
        )
    }

    // MARK: - Helper Functions
    private func extractNameFromEmail(_ email: String) -> String {
        // Extract the part before @ and capitalize it
        let name = email.components(separatedBy: "@").first ?? email
        return name.capitalized
    }
    
    /// Debounce: bulk store updates during startup were calling `updateWarnings` repeatedly and freezing the main thread.
    private func scheduleWarningsRefresh() {
        guard userStore.hasAdminAccess() || userStore.isHomeProfileLoading else { return }
        warningsRefreshTask?.cancel()
        warningsRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard userStore.hasAdminAccess() else { return }
            updateWarnings()
        }
    }
    
    private var assignedTasksCount: Int {
        if userStore.isOperativeMode() {
            let em = userStore.currentUser.map {
                $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            guard !em.isEmpty,
                  let operative = operativeStore.allOperatives.first(where: {
                      $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == em
                  }) else {
                return operativeQualificationExpiryReminderCount
            }
            let taskCount = taskStore.tasks.filter { task in
                !task.isCompleted && task.allAssignedOperativeIds.contains(operative.id)
            }.count
            return taskCount + operativeQualificationExpiryReminderCount
        } else {
            let email = userStore.currentUser?.email
            let taskCount = taskStore.tasks.filter { task in
                !task.isCompleted
                    && task.isAssignedToUser(
                        userEmail: email,
                        operatives: operativeStore.allOperatives,
                        managers: operativeStore.allManagers,
                        isOperativeMode: false
                    )
            }.count
            return taskCount + pendingHolidayApprovalsCount
        }
    }

    private var pendingHolidayApprovalsCount: Int {
        guard let me = userStore.currentUser, !me.permissions.operativeMode else { return 0 }
        let pending = holidayStore.pendingRequests
        if me.permissions.manager && !me.isSuperAdmin && !me.permissions.adminAccess && me.role != .admin {
            return pending.filter { request in
                assignedApproverUserId(for: request) == me.id
            }.count
        }
        if userStore.hasAdminAccess() {
            return pending.filter { request in
                let approver = assignedApproverUserId(for: request)
                return approver == nil || approver == me.id
            }.count
        }
        return 0
    }

    private func assignedApproverUserId(for request: HolidayBooking) -> String? {
        if let uid = request.userId,
           let requester = userStore.organizationUsers.first(where: { $0.id == uid }) {
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
    
    /// Upcoming qualification expiries (next 30 days) — surfaced to operatives under Tasks.
    private var operativeQualificationExpiryReminderCount: Int {
        guard userStore.isOperativeMode(),
              let email = userStore.currentUser?.email else { return 0 }
        let em = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let op = operativeStore.allOperatives.first(where: {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == em
        }) else { return 0 }
        let today = Calendar.current.startOfDay(for: Date())
        guard let horizon = Calendar.current.date(byAdding: .day, value: 30, to: today) else { return 0 }
        var n = 0
        for (_, exp) in op.qualificationExpiryDates {
            if exp >= today && exp <= horizon { n += 1 }
        }
        return n
    }
    
    private func updateWarnings() {
        warningsService.updateWarnings(
            operatives: operativeStore.allOperatives,
            bookings: bookingStore.bookings,
            projects: projectStore.projects + projectStore.smallWorks,
            managers: operativeStore.allManagers,
            users: userStore.organizationUsers
        )
    }
    
    private var taskLimitWarningBanner: some View {
        Group {
            // Avoid scanning every project’s task count while `currentUser` is nil — that can freeze the main thread during startup.
            if userStore.hasAdminAccess() {
                let projectsAtLimit = projectStore.projects.filter { project in
                    taskStore.taskCount(for: project.id) >= 500
                }
                
                if !projectsAtLimit.isEmpty {
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Warning: Task limit reached")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.orange.opacity(0.1))
                        
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(projectsAtLimit.prefix(3)) { project in
                                Text("\(project.jobNumber): Delete first 50 completed tasks to clear some space")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            if projectsAtLimit.count > 3 {
                                Text("And \(projectsAtLimit.count - 3) more project(s)...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.05))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
            }
        }
    }
    
    /// Presents annual leave in a sheet (same path as notification deep links). Avoids swapping `mainTabContent` to tab 8’s nested `NavigationStack`, which has been crashing on some iOS builds.
    private func presentAnnualLeaveFromHome(showPendingRequests: Bool = false) {
        NotificationCenter.default.post(
            name: NSNotification.Name("openHoliday"),
            object: nil,
            userInfo: ["showRequests": showPendingRequests]
        )
    }

    // MARK: - Sample Data
    private var sampleProjects: [SampleProject] {
        [
            SampleProject(
                jobNumber: "C646",
                siteName: "Lancelot Place",
                address: "8 Lancelot Place, SW7 1DR, London",
                jobType: "CAT A",
                operative: "Billey",
                company: "RED Construction",
                date: "31 October 2025"
            ),
            SampleProject(
                jobNumber: "C709",
                siteName: "Tower Hotel",
                address: "Tower Hotel, St Katherine's Way, E1W 1LD",
                jobType: "CAT A",
                operative: "Morgan",
                company: "RED Construction",
                date: "3 March 2026"
            )
        ]
    }
    
    private var sampleSmallWorks: [SampleProject] {
        [
            SampleProject(
                jobNumber: "C842",
                siteName: "Ferrari Garage Temps",
                address: "133-135 Old Brompton Road, SW7 3RP",
                jobType: "Small Works",
                operative: "Farnie",
                company: "Pryer Construction",
                date: "2 October 2025"
            )
        ]
    }
}

// MARK: - Supporting Views and Models

struct SampleProject: Identifiable {
    let id = UUID()
    let jobNumber: String
    let siteName: String
    let address: String
    let jobType: String
    let operative: String
    let company: String
    let date: String
}

struct ProjectCard: View {
    let project: SampleProject
    @EnvironmentObject var appSettings: AppSettingsStore
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(project.jobNumber) - \(project.siteName)")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    
                    Text(project.address)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text(project.date)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Image(systemName: project.jobType == "Small Works" ? "hammer" : "wrench")
                        .font(.caption)
                        .foregroundColor(Color.theme.primary(for: appSettings.settings.colorScheme))
                    Text(project.jobType)
                        .font(.caption)
                        .foregroundColor(Color.theme.primary(for: appSettings.settings.colorScheme))
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "person")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text(project.operative)
                        .font(.caption)
                        .foregroundColor(.green)
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "building")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(project.company)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                Spacer()
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

struct ProjectCardFromStore: View {
    let project: Project
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var appSettings: AppSettingsStore
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(project.jobNumber) - \(project.siteName)")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    
                    Text(project.siteAddress)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text(formatDate(project.startDate))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Image(systemName: project.jobType == .smallWorks ? "hammer" : "wrench")
                        .font(.caption)
                        .foregroundColor(Color.theme.primary(for: appSettings.settings.colorScheme))
                    Text(jobTypeDisplayText)
                        .font(.caption)
                        .foregroundColor(Color.theme.primary(for: appSettings.settings.colorScheme))
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "person")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text(project.manager.rawValue)
                        .font(.caption)
                        .foregroundColor(.green)
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "building")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(project.client.name)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                Spacer()
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
    
    private var jobTypeDisplayText: String {
        return project.customJobType ?? "N/A"
    }
    
}

// MARK: - Operative qualifications

struct OperativeQualificationsReadOnlyView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @State private var isRepairingLink = false
    @State private var repairMessage: String?
    
    private var operative: Operative? {
        guard let email = userStore.currentUser?.email else { return nil }
        let e = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return operativeStore.allOperatives.first {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == e
        }
    }
    
    var body: some View {
        Group {
            if let op = operative {
                OperativeQualificationsEditorView(
                    operative: op,
                    title: "My Qualifications",
                    canEditAssignments: true,
                    presentation: .myQualifications
                )
                .environmentObject(operativeStore)
                .environmentObject(firebaseBackend)
            } else {
                NavigationStack {
                    ContentUnavailableView(
                        "Profile not linked",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("No operative record matches your email. Ask an admin to check your account email matches your operative profile.")
                    )
                    if let repairMessage {
                        Text(repairMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    Button(isRepairingLink ? "Repairing..." : "Repair link now") {
                        Task { await repairOperativeLinkIfNeeded() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRepairingLink)
                    .navigationTitle("My Qualifications")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
                .task {
                    await repairOperativeLinkIfNeeded()
                }
            }
        }
    }
    
    /// Auto-repairs broken operative ↔ user linkage for operative accounts:
    /// 1) direct email match (already linked)
    /// 2) name match then update operative email
    /// 3) create missing operative profile from current user details
    @MainActor
    private func repairOperativeLinkIfNeeded() async {
        guard userStore.isOperativeMode() else { return }
        guard !isRepairingLink else { return }
        guard let u = userStore.currentUser else { return }
        
        let email = u.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return }
        
        // Already linked
        if operativeStore.allOperatives.contains(where: {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == email
        }) {
            repairMessage = nil
            return
        }
        
        isRepairingLink = true
        defer { isRepairingLink = false }
        
        let normalizedFirst = u.firstName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedLast = u.surname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        // Try name-based relink first (legacy rows where email drifted)
        if let idx = operativeStore.allOperatives.firstIndex(where: { op in
            op.firstName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedFirst &&
            op.lastName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedLast
        }) {
            var op = operativeStore.allOperatives[idx]
            op.email = email
            op.updatedAt = Date()
            await operativeStore.updateOperative(op)
            repairMessage = "Linked to existing operative profile."
            return
        }
        
        // No match found: create missing operative profile so operative-mode features can work.
        let first = u.firstName.isEmpty ? u.email.components(separatedBy: "@").first ?? "Operative" : u.firstName
        let last = u.surname.isEmpty ? "User" : u.surname
        let newOperative = Operative(
            firstName: first,
            lastName: last,
            email: email,
            startDate: Date(),
            skills: [],
            qualifications: [],
            qualificationExpiryDates: [:],
            isActive: u.isActive,
            dayRate: u.dayRate,
            tradeTypePreset: u.tradeTypePreset,
            tradeTypeCustom: u.tradeTypeCustom
        )
        await operativeStore.addOperative(newOperative)
        repairMessage = "Created and linked operative profile."
    }
}

struct HomeQuickActionAddSheet: View {
    let ids: [String]
    let displayTitle: (String) -> String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if ids.isEmpty {
                    ContentUnavailableView(
                        "No more actions",
                        systemImage: "checkmark.circle",
                        description: Text("All available quick actions are already on your home screen.")
                    )
                } else {
                    List(ids, id: \.self) { id in
                        Button {
                            onPick(id)
                        } label: {
                            if let meta = HomeQuickActionRegistry.meta(for: id) {
                                Label {
                                    Text(displayTitle(id).replacingOccurrences(of: "\n", with: " "))
                                } icon: {
                                    Image(systemName: meta.symbol)
                                        .foregroundStyle(meta.color)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add quick action")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct QuickMenuSheet: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss

    @Binding var showingClientsView: Bool
    @Binding var showingCreateProject: Bool
    @Binding var showingCreateSmallWorks: Bool
    @Binding var showingSkillsManagement: Bool
    @Binding var showingQualificationsManagement: Bool
    @Binding var showingJobTypesManagement: Bool
    @Binding var showingWholesalers: Bool
    @Binding var showingOperativeQualifications: Bool
    @Binding var showingAddUser: Bool
    @Binding var showingManageUsers: Bool
    @Binding var showingTasksDetail: Bool

    private var quickCreateGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.theme.primary(for: appSettings.settings.colorScheme),
                ProjectWorksRevampColors.blueLight
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center) {
                        Text("Main Menu")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .tracking(-0.3)
                        Spacer(minLength: 12)
                        Button("Done") { dismiss() }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 7)
                            .background(ProjectWorksRevampColors.blue)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 4)

                    if showQuickCreateSection {
                        quickCreateCard
                    }

                    if hasNavigateRows {
                        menuSectionTitle("Navigate")
                        menuGroupedCard {
                            if !userStore.isOperativeMode() {
                                polishedNavigateRow(
                                    icon: "briefcase.fill",
                                    iconBackground: Color(red: 0.902, green: 0.945, blue: 0.984),
                                    iconTint: ProjectWorksRevampColors.blue,
                                    title: "Clients",
                                    subtitle: "\(projectStore.clients.count) on file"
                                ) {
                                    showingClientsView = true
                                }
                            }
                            if userStore.canViewProjects() {
                                polishedNavigateRow(
                                    icon: "folder.fill",
                                    iconBackground: Color(red: 0.882, green: 0.961, blue: 0.933),
                                    iconTint: ProjectWorksRevampColors.activeGreen,
                                    title: "Projects",
                                    subtitle: "\(regularProjectsInProgress) in progress"
                                ) {
                                    selectTab(1)
                                }
                                polishedNavigateRow(
                                    icon: "hammer.fill",
                                    iconBackground: Color(red: 0.98, green: 0.933, blue: 0.855),
                                    iconTint: ProjectWorksRevampColors.upcomingAmber,
                                    title: "Small works",
                                    subtitle: "\(smallWorksOpenCount) open"
                                ) {
                                    selectTab(2)
                                }
                            }
                            if userStore.canViewOperatives() {
                                polishedNavigateRow(
                                    icon: "person.3.fill",
                                    iconBackground: ProjectWorksRevampColors.jobTypePillBg,
                                    iconTint: Color(red: 0.325, green: 0.29, blue: 0.718),
                                    title: "Operatives",
                                    subtitle: "\(activeOperativesCount) team members"
                                ) {
                                    selectTab(3)
                                }
                            }
                            if userStore.canViewManagers() {
                                polishedNavigateRow(
                                    icon: "person.badge.shield.checkmark.fill",
                                    iconBackground: Color(red: 0.984, green: 0.918, blue: 0.941),
                                    iconTint: Color(red: 0.6, green: 0.208, blue: 0.337),
                                    title: "Managers",
                                    subtitle: "\(operativeStore.allManagers.count) active"
                                ) {
                                    selectTab(4)
                                }
                            }
                        }
                    }

                    if hasToolsRows {
                        menuSectionTitle("Tools")
                        menuGroupedCard {
                            if userStore.canManageSkills() {
                                polishedToolRow(
                                    icon: "wrench.and.screwdriver.fill",
                                    iconBackground: Color(red: 0.98, green: 0.925, blue: 0.906),
                                    iconTint: Color(red: 0.6, green: 0.235, blue: 0.114),
                                    title: "Skills",
                                    badge: nil
                                ) {
                                    showingSkillsManagement = true
                                }
                            }
                            if userStore.canManageQualifications() {
                                polishedToolRow(
                                    icon: "graduationcap.fill",
                                    iconBackground: Color(red: 0.902, green: 0.945, blue: 0.984),
                                    iconTint: ProjectWorksRevampColors.blue,
                                    title: "Qualifications",
                                    badge: qualificationsExpiringSoonCount > 0
                                        ? "\(qualificationsExpiringSoonCount) expiring"
                                        : nil
                                ) {
                                    showingQualificationsManagement = true
                                }
                            }
                            if userStore.isOperativeMode() {
                                polishedToolRow(
                                    icon: "graduationcap.fill",
                                    iconBackground: Color(red: 0.902, green: 0.945, blue: 0.984),
                                    iconTint: ProjectWorksRevampColors.blue,
                                    title: "My qualifications",
                                    badge: nil
                                ) {
                                    showingOperativeQualifications = true
                                }
                            }
                            if userStore.hasAdminAccess() {
                                polishedToolRow(
                                    icon: "square.grid.2x2.fill",
                                    iconBackground: Color(red: 0.882, green: 0.961, blue: 0.933),
                                    iconTint: ProjectWorksRevampColors.activeGreen,
                                    title: "Job types",
                                    badge: nil
                                ) {
                                    showingJobTypesManagement = true
                                }
                                polishedToolRow(
                                    icon: "building.2.fill",
                                    iconBackground: Color(red: 0.98, green: 0.933, blue: 0.855),
                                    iconTint: ProjectWorksRevampColors.upcomingAmber,
                                    title: "Wholesalers",
                                    badge: nil
                                ) {
                                    showingWholesalers = true
                                }
                            }
                            if userStore.canManageSubcontractors() {
                                polishedToolRow(
                                    icon: "person.2.badge.gearshape.fill",
                                    iconBackground: ProjectWorksRevampColors.jobTypePillBg,
                                    iconTint: Color(red: 0.325, green: 0.29, blue: 0.718),
                                    title: "Sub contractors",
                                    badge: nil
                                ) {
                                    selectTab(9)
                                }
                            }
                        }
                    }

                    if showTeamSection {
                        menuSectionTitle("Team")
                        menuGroupedCard {
                            polishedToolRow(
                                icon: "person.badge.plus.fill",
                                iconBackground: ProjectWorksRevampColors.jobTypePillBg,
                                iconTint: Color(red: 0.325, green: 0.29, blue: 0.718),
                                title: userStore.canManageUsers() ? "Add user" : "Add operative",
                                badge: nil
                            ) {
                                showingAddUser = true
                            }
                            polishedToolRow(
                                icon: "person.2.fill",
                                iconBackground: Color(red: 0.902, green: 0.945, blue: 0.984),
                                iconTint: ProjectWorksRevampColors.blue,
                                title: userStore.canManageUsers() ? "Manage users" : "Manage operatives",
                                badge: nil
                            ) {
                                showingManageUsers = true
                            }
                        }
                    }

                    menuSectionTitle("App & account")
                    menuGroupedCard {
                        polishedToolRow(
                            icon: "gearshape.fill",
                            iconBackground: Color(red: 0.949, green: 0.953, blue: 0.961),
                            iconTint: ProjectWorksRevampColors.muted,
                            title: "Settings",
                            badge: nil
                        ) {
                            selectTab(5)
                        }
                        if userStore.hasAdminAccess() {
                            NavigationLink {
                                GeneralAppSettingsView()
                                    .environmentObject(appSettings)
                            } label: {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color(red: 0.902, green: 0.945, blue: 0.984))
                                        .frame(width: 32, height: 32)
                                        .overlay(
                                            Image(systemName: "slider.horizontal.3")
                                                .font(.system(size: 16, weight: .medium))
                                                .foregroundStyle(ProjectWorksRevampColors.blue)
                                        )
                                    Text("General")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(ProjectWorksRevampColors.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
                                }
                                .padding(.vertical, 11)
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(ProjectWorksRevampColors.border)
                        }
                        if !userStore.isOperativeMode() {
                            polishedToolRow(
                                icon: "questionmark.circle.fill",
                                iconBackground: Color(red: 0.882, green: 0.961, blue: 0.933),
                                iconTint: ProjectWorksRevampColors.activeGreen,
                                title: "Help & support",
                                badge: nil
                            ) {
                                selectTab(6)
                            }
                        }
                        polishedToolRow(
                            icon: "key.fill",
                            iconBackground: ProjectWorksRevampColors.jobTypePillBg,
                            iconTint: Color(red: 0.325, green: 0.29, blue: 0.718),
                            title: "Reset password",
                            badge: nil,
                            showsDivider: false
                        ) {
                            if let email = firebaseBackend.currentUser?.email {
                                Task { try? await firebaseBackend.resetPassword(email: email) }
                            }
                        }
                    }

                    signOutButton

                    Text(appVersionLine)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var appVersionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "Project Planner · v\(v)"
    }

    private var showQuickCreateSection: Bool {
        quickCreateVisibleButtonCount > 0
    }

    private var quickCreateVisibleButtonCount: Int {
        (canCreateProject ? 1 : 0) + (canCreateSmallWorks ? 1 : 0) + (canAddUserQuick ? 1 : 0) + 1
    }

    private var canAddUserQuick: Bool {
        userStore.canManageUsers()
            || (!userStore.hasAdminAccess()
                && userStore.displayUser?.permissions.manager == true
                && userStore.displayUser?.permissions.operatives == true)
    }

    private var hasNavigateRows: Bool {
        !userStore.isOperativeMode()
            || userStore.canViewProjects()
            || userStore.canViewOperatives()
            || userStore.canViewManagers()
    }

    private var hasToolsRows: Bool {
        userStore.canManageSkills()
            || userStore.canManageQualifications()
            || userStore.isOperativeMode()
            || userStore.hasAdminAccess()
            || userStore.canManageSubcontractors()
    }

    private var showTeamSection: Bool {
        userStore.canManageUsers()
            || (!userStore.hasAdminAccess()
                && userStore.displayUser?.permissions.manager == true
                && userStore.displayUser?.permissions.operatives == true)
    }

    private var regularProjectsInProgress: Int {
        projectStore.projects.filter { $0.jobType != .smallWorks && $0.status == .active }.count
    }

    private var smallWorksOpenCount: Int {
        projectStore.smallWorks.filter { $0.status == .active || $0.status == .upcoming }.count
    }

    private var activeOperativesCount: Int {
        operativeStore.allOperatives.filter(\.isActive).count
    }

    private var qualificationsExpiringSoonCount: Int {
        let today = Calendar.current.startOfDay(for: Date())
        guard let horizon = Calendar.current.date(byAdding: .day, value: 30, to: today) else { return 0 }
        var n = 0
        for op in operativeStore.allOperatives {
            for (_, exp) in op.qualificationExpiryDates {
                if exp >= today && exp <= horizon { n += 1 }
            }
        }
        return n
    }

    private var quickCreateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick create")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .tracking(0.3)
                    Text("Start something new")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 8)
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Circle())
            }
            HStack(spacing: 8) {
                if canCreateProject {
                    quickCreatePillButton(icon: "folder.badge.plus", title: "Project") {
                        showingCreateProject = true
                    }
                }
                if canCreateSmallWorks {
                    quickCreatePillButton(icon: "hammer.fill", title: "Small work") {
                        showingCreateSmallWorks = true
                    }
                }
                if canAddUserQuick {
                    quickCreatePillButton(icon: "person.badge.plus", title: "User") {
                        showingAddUser = true
                    }
                }
                quickCreatePillButton(icon: "plus.rectangle.on.rectangle", title: "Task") {
                    showingTasksDetail = true
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(quickCreateGradient)
        )
    }

    private func quickCreatePillButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button {
            dismissAfter(action)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
    }

    private func menuSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .tracking(0.4)
            .padding(.leading, 4)
    }

    private func menuGroupedCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func polishedNavigateRow(
        icon: String,
        iconBackground: Color,
        iconTint: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                dismissAfter(action)
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(iconBackground)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: icon)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(iconTint)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
                }
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            Divider().overlay(ProjectWorksRevampColors.border)
        }
    }

    private func polishedToolRow(
        icon: String,
        iconBackground: Color,
        iconTint: Color,
        title: String,
        badge: String?,
        showsDivider: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                dismissAfter(action)
            } label: {
                polishedToolRowLabel(icon: icon, iconBackground: iconBackground, iconTint: iconTint, title: title, badge: badge)
            }
            .buttonStyle(.plain)
            if showsDivider {
                Divider().overlay(ProjectWorksRevampColors.border)
            }
        }
    }

    private func polishedToolRowLabel(
        icon: String,
        iconBackground: Color,
        iconTint: Color,
        title: String,
        badge: String?
    ) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(iconBackground)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconTint)
                )
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(red: 0.639, green: 0.176, blue: 0.176))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.988, green: 0.922, blue: 0.922))
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
        }
        .padding(.vertical, 11)
    }

    private var signOutButton: some View {
        Button {
            dismissAfter {
                userStore.clearOnSignOut()
                try? firebaseBackend.signOut()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .medium))
                Text("Sign out")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color(red: 0.639, green: 0.176, blue: 0.176))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(red: 0.988, green: 0.922, blue: 0.922), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func dismissAfter(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            action()
        }
    }

    private func selectTab(_ tab: Int) {
        NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": tab])
    }

    private var canCreateProject: Bool {
        guard let user = userStore.currentUser else { return false }
        if user.permissions.operativeMode { return false }
        if user.isSuperAdmin || user.permissions.adminAccess { return true }
        return user.permissions.manager && user.permissions.projects
    }

    private var canCreateSmallWorks: Bool {
        guard let user = userStore.currentUser else { return false }
        if user.permissions.operativeMode { return false }
        if user.isSuperAdmin || user.permissions.adminAccess { return true }
        return user.permissions.manager && user.permissions.smallWorks
    }
}

#Preview {
    HomeView()
        .environmentObject(SimpleAuthManager())
        .environmentObject(FirebaseBackend())
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(BookingStore())
        .environmentObject(SubcontractorStore())
}
