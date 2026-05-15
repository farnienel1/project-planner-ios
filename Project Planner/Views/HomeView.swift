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
    @State private var homeWarningCount: Int = 0
    @State private var cachedUpNextSections: [HomeUpNextDaySection] = []
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
    @State private var isCustomisingQuickActions = false
    @State private var showingAddQuickActionPicker = false
    @State private var showingQuickActionCustomizeHint = false
    @State private var persistedQuickActionIds: [String] = []
    @State private var showingGeneralAppSettings = false
    @State private var hasLoadedQuickActionLayout = false
    @State private var showingAdminOverviewCustomize = false
    @State private var draftAdminOverviewMetricIds: [HomeOverviewMetricID] = []
    @State private var persistedAdminOverviewMetricIds: [HomeOverviewMetricID] = []
    @State private var hasLoadedAdminOverviewMetrics = false
    
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
            WarningsDetailView(warningsService: WarningsService.shared)
                .environmentObject(projectStore)
                .environmentObject(userStore)
                .environmentObject(operativeStore)
                .environmentObject(bookingStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(firebaseBackend)
                .environmentObject(appSettings)
                .environmentObject(holidayStore)
        }
        .sheet(isPresented: $showingTasksDetail) {
            TasksDetailView()
                .environmentObject(taskStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(holidayStore)
                .environmentObject(notificationService)
                .environmentObject(firebaseBackend)
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
            await taskStore.loadData()
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
        .sheet(isPresented: $showingAdminOverviewCustomize) {
            AdminHomeOverviewCustomizeSheet(
                draftMetricIds: $draftAdminOverviewMetricIds,
                metricValue: { overviewMetricValueString($0) },
                onSave: {
                    persistedAdminOverviewMetricIds = draftAdminOverviewMetricIds
                    savePersistedAdminOverviewMetrics()
                }
            )
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
                .environmentObject(appSettings)
                .environmentObject(firebaseBackend)
                .environmentObject(taskStore)
                .environmentObject(notificationService)
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
                .environmentObject(appSettings)
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("openOrgSitesMapFromMore"))) { _ in
            showingOrgSitesMap = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("openSiteAuditFromMore"))) { _ in
            showingSiteAudit = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .mainMenuOpenSurface)) { note in
            guard let raw = note.userInfo?["route"] as? String,
                  let route = MainMenuSurfaceRoute(rawValue: raw) else { return }
            switch route {
            case .clients: showingClientsView = true
            case .createProject: showingCreateProject = true
            case .createSmallWorks: showingCreateSmallWorks = true
            case .skills: showingSkillsManagement = true
            case .qualifications: showingQualificationsManagement = true
            case .myQualifications: showingOperativeQualifications = true
            case .jobTypes: showingJobTypesManagement = true
            case .wholesalers: showingWholesalers = true
            case .addUser: showingAddUser = true
            case .manageUsers: showingManageUsers = true
            case .tasksDetail: showingTasksDetail = true
            case .generalAppSettings: showingGeneralAppSettings = true
            case .orgSitesMap: showingOrgSitesMap = true
            case .siteAudit: showingSiteAudit = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mainMenuResetPassword)) { _ in
            if let email = firebaseBackend.currentUser?.email {
                Task { try? await firebaseBackend.resetPassword(email: email) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mainMenuSignOut)) { _ in
            userStore.clearOnSignOut()
            try? firebaseBackend.signOut()
        }
        .sheet(isPresented: $showingQuickMenu) {
            QuickMenuSheet()
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

    /// Incomplete tasks assigned to the current user with due date strictly before today.
    private var tasksOverdueCount: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return taskStore.tasks.filter { task in
            guard !task.isCompleted, let due = task.dueDate else { return false }
            let d0 = cal.startOfDay(for: due)
            guard d0 < today else { return false }
            return task.isAssignedToUser(
                userEmail: userStore.currentUser?.email,
                operatives: operativeStore.allOperatives,
                managers: operativeStore.allManagers,
                isOperativeMode: userStore.isOperativeMode()
            )
        }.count
    }

    private var outstandingTasksAllUsersCount: Int {
        taskStore.tasks.filter { !$0.isCompleted }.count
    }

    private var operativesOnSiteTodayCount: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let ids = Set(
            bookingStore.bookings
                .filter { cal.isDate($0.date, inSameDayAs: today) && ($0.status == .confirmed || $0.status == .tentative) }
                .map { $0.operativeId.uuidString }
        )
        return ids.count
    }

    private var managersOnSiteTodayCount: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return Set(
            managerScheduleStore.managerSiteBookings
                .filter {
                    cal.isDate($0.date, inSameDayAs: today)
                        && ($0.locationType == ManagerLocationType.project
                            || $0.locationType == ManagerLocationType.smallWork)
                }
                .map(\.userId)
        ).count
    }

    private var operativesOnALTodayCount: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let holidays = holidayStore.approvedBookings(covering: today)
        var keys = Set<String>()
        for h in holidays {
            if let oid = h.operativeId {
                keys.insert("op:\(oid.uuidString)")
            }
            if let uid = h.userId?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty,
               let u = userStore.organizationUsers.first(where: { $0.id == uid }),
               u.permissions.operativeMode {
                keys.insert("u:\(uid)")
            }
        }
        return keys.count
    }

    private var managersOnALTodayCount: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let holidays = holidayStore.approvedBookings(covering: today)
        var seen = Set<String>()
        for h in holidays {
            guard let uid = h.userId?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else { continue }
            guard let u = userStore.organizationUsers.first(where: { $0.id == uid }) else { continue }
            guard !u.permissions.operativeMode,
                  !u.isSuperAdmin,
                  !u.permissions.adminAccess,
                  u.permissions.manager,
                  u.isActive else { continue }
            seen.insert(uid)
        }
        return seen.count
    }

    private static let defaultAdminOverviewMetricIds: [HomeOverviewMetricID] = [
        .tasksDueTodayPersonal, .tasksDueWeekPersonal, .warnings
    ]

    private var adminOverviewStorageKey: String {
        let uid = firebaseBackend.currentUser?.uid ?? "anonymous"
        return "homeOverviewMetrics.v1.\(uid)"
    }

    private func loadPersistedAdminOverviewMetricsIfNeeded() {
        guard !hasLoadedAdminOverviewMetrics else { return }
        hasLoadedAdminOverviewMetrics = true
        if let raw = UserDefaults.standard.array(forKey: adminOverviewStorageKey) as? [String] {
            let allowed = Set(HomeOverviewMetricID.allCases.map(\.rawValue))
            let decoded = raw.compactMap { HomeOverviewMetricID(rawValue: $0) }
                .filter { allowed.contains($0.rawValue) }
            var seen = Set<HomeOverviewMetricID>()
            let uniq = decoded.filter { seen.insert($0).inserted }
            persistedAdminOverviewMetricIds = uniq.isEmpty ? Self.defaultAdminOverviewMetricIds : Array(uniq.prefix(3))
        } else {
            persistedAdminOverviewMetricIds = Self.defaultAdminOverviewMetricIds
        }
    }

    private func savePersistedAdminOverviewMetrics() {
        UserDefaults.standard.set(persistedAdminOverviewMetricIds.map(\.rawValue), forKey: adminOverviewStorageKey)
    }

    private var adminResolvedOverviewMetricIds: [HomeOverviewMetricID] {
        let base = persistedAdminOverviewMetricIds.isEmpty ? Self.defaultAdminOverviewMetricIds : persistedAdminOverviewMetricIds
        return Array(base.prefix(3))
    }

    private func overviewMetricValueString(_ mid: HomeOverviewMetricID) -> String {
        switch mid {
        case .tasksDueTodayPersonal: return "\(tasksDueTodayCount)"
        case .tasksDueWeekPersonal: return "\(tasksDueThisWeekCount)"
        case .warnings: return "\(homeWarningCount)"
        case .operativesOnSite: return "\(operativesOnSiteTodayCount)"
        case .managersOnSite: return "\(managersOnSiteTodayCount)"
        case .operativesOnAL: return "\(operativesOnALTodayCount)"
        case .managersOnAL: return "\(managersOnALTodayCount)"
        case .outstandingTasksAllUsers: return "\(outstandingTasksAllUsersCount)"
        }
    }

    private func overviewMetricContributesToHeadsUp(_ mid: HomeOverviewMetricID) -> Bool {
        switch mid {
        case .tasksDueTodayPersonal: return tasksDueTodayCount > 0
        case .tasksDueWeekPersonal: return tasksDueThisWeekCount > 0
        case .warnings: return homeWarningCount > 0
        case .outstandingTasksAllUsers: return outstandingTasksAllUsersCount > 0
        default: return false
        }
    }

    private var todayOverviewIsHeadsUp: Bool {
        if userStore.isOperativeMode() {
            return tasksDueTodayCount > 0 || tasksDueThisWeekCount > 0 || tasksOverdueCount > 0
        }
        if userStore.hasAdminAccess() {
            return adminResolvedOverviewMetricIds.contains { overviewMetricContributesToHeadsUp($0) }
        }
        return tasksDueTodayCount > 0 || tasksDueThisWeekCount > 0 || homeWarningCount > 0
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
            loadPersistedAdminOverviewMetricsIfNeeded()
        }
        .task(id: homeDataRefreshTrigger) {
            await refreshHomeDerivedData()
        }
        .onChange(of: showingAdminOverviewCustomize) { _, isOpen in
            if isOpen {
                let base = persistedAdminOverviewMetricIds.isEmpty
                    ? Self.defaultAdminOverviewMetricIds
                    : persistedAdminOverviewMetricIds
                draftAdminOverviewMetricIds = Array(base.prefix(3))
            }
        }
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
        let headsUp = todayOverviewIsHeadsUp
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
                Spacer(minLength: 8)
                if userStore.hasAdminAccess() {
                    Button {
                        let base = persistedAdminOverviewMetricIds.isEmpty
                            ? Self.defaultAdminOverviewMetricIds
                            : persistedAdminOverviewMetricIds
                        draftAdminOverviewMetricIds = Array(base.prefix(3))
                        showingAdminOverviewCustomize = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.95))
                            .padding(8)
                            .background(.white.opacity(0.14))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Customize dashboard metrics")
                }
                Text(headsUp ? "Heads up" : "On track")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.18))
                    .clipShape(Capsule())
            }
            overviewMetricPillsRow
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

    @ViewBuilder
    private var overviewMetricPillsRow: some View {
        if userStore.isOperativeMode() {
            HStack(spacing: 10) {
                overviewStatPill(value: "\(tasksDueTodayCount)", label: "Tasks Due Today")
                overviewStatPill(value: "\(tasksDueThisWeekCount)", label: "Tasks due this week")
                overviewStatPill(value: "\(tasksOverdueCount)", label: "Tasks Overdue")
            }
        } else if userStore.hasAdminAccess() {
            HStack(spacing: 10) {
                ForEach(adminResolvedOverviewMetricIds, id: \.self) { mid in
                    overviewStatPill(
                        value: overviewMetricValueString(mid),
                        label: mid.compactPillTitle
                    )
                }
            }
        } else {
            HStack(spacing: 10) {
                overviewStatPill(value: "\(tasksDueTodayCount)", label: "Due today")
                overviewStatPill(value: "\(tasksDueThisWeekCount)", label: "This week")
                overviewStatPill(value: "\(assignedTasksCount)", label: "Tasks")
            }
        }
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
                    value: homeWarningCount == 0 ? "All clear" : "\(homeWarningCount) active"
                ) {
                    Task { await openWarningsDetail() }
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

    /// Capitalises the **second word** on each line (e.g. `Create small` → `Create Small`). For classic
    /// two-line tiles where the first line is a single word (`Small` / `works`), capitalises the second line.
    /// Skips forced hyphen wraps like `Qualifi-\ncations` so we do not turn `cations` into `Cations`.
    private func capitalizeSecondWordsInQuickActionTitle(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return raw }

        let firstLineTrimmed = lines[0].trimmingCharacters(in: .whitespaces)
        let firstLineWordCount = firstLineTrimmed.split(separator: " ", omittingEmptySubsequences: true).count
        let firstLineIsHyphenWrap = firstLineTrimmed.hasSuffix("-")

        func capitalizeWord(_ w: String) -> String {
            guard let first = w.first else { return w }
            return String(first).uppercased() + w.dropFirst()
        }

        var result: [String] = []
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

            if parts.count >= 2 {
                if i > 0, firstLineWordCount == 1 {
                    result.append(parts.map { capitalizeWord($0) }.joined(separator: " "))
                } else {
                    var r = parts
                    r[1] = capitalizeWord(r[1])
                    result.append(r.joined(separator: " "))
                }
            } else if parts.count == 1, i > 0, firstLineWordCount == 1, !firstLineIsHyphenWrap {
                result.append(capitalizeWord(parts[0]))
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    private func displayTitleForQuickAction(id: String) -> String {
        let raw: String
        if id == HomeQuickActionID.staffAddUser.rawValue, !userStore.canManageUsers() {
            raw = "Add\noperative"
        } else if id == HomeQuickActionID.staffManageUsersSheet.rawValue, !userStore.canManageUsers() {
            raw = "Manage\noperatives"
        } else {
            raw = HomeQuickActionRegistry.meta(for: id)?.title ?? ""
        }
        return capitalizeSecondWordsInQuickActionTitle(raw)
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
        case HomeQuickActionID.staffTasks.rawValue:
            showingTasksDetail = true
        default:
            break
        }
    }

    @ViewBuilder
    private func quickActionTileContents(meta: HomeQuickActionMeta, title: String) -> some View {
        let tint = meta.color
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.22))
                    .frame(width: 40, height: 40)
                Image(systemName: meta.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(homeInk)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.88)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 5)
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
                        .frame(width: 124, height: 104)
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

            let sections = cachedUpNextSections
            if sections.isEmpty {
                Text("No upcoming bookings on your schedule.")
                    .font(.system(size: 13))
                    .foregroundStyle(homeMuted)
                    .padding(.vertical, 8)
            } else {
                ForEach(sections) { section in
                    Text(section.heading)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(homeInk)
                        .padding(.top, section.id == sections.first?.id ? 0 : 6)
                        .padding(.bottom, 6)

                    ForEach(section.rows) { row in
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
            Spacer(minLength: 0)
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
    
    private var homeDataRefreshTrigger: HomeDataRefreshTrigger {
        HomeDataRefreshTrigger(
            operativeCount: operativeStore.allOperatives.count,
            bookingCount: bookingStore.bookings.count,
            projectCount: projectStore.projects.count,
            smallWorksCount: projectStore.smallWorks.count,
            managerBookingCount: managerScheduleStore.managerSiteBookings.count,
            holidayCount: holidayStore.bookings.count,
            userCount: userStore.organizationUsers.count,
            isHomeProfileLoading: userStore.isHomeProfileLoading,
            currentUserId: userStore.currentUser?.id
        )
    }

    /// Rebuild Up Next + warning count off the main thread; Home does not observe `WarningsService` (avoids full-tree redraws).
    private func refreshHomeDerivedData() async {
        guard !userStore.isHomeProfileLoading, userStore.currentUser != nil else { return }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard !Task.isCancelled else { return }
        guard !userStore.isHomeProfileLoading, userStore.currentUser != nil else { return }

        let policy = firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
        let operatives = operativeStore.allOperatives
        let bookings = bookingStore.bookings
        // Small works are already in `projects` (smallWorks is a filter) — never concatenate both.
        let projects = projectStore.projects
        let users = userStore.organizationUsers
        let managerBookings = managerScheduleStore.managerSiteBookings
        let authUserId = firebaseBackend.currentUser?.uid
        let userEmail = userStore.currentUser?.email
        let blue = homeBlue
        let purple = Color(red: 0.325, green: 0.29, blue: 0.718)

        async let upNextTask: [HomeUpNextDaySection] = Task.detached(priority: .utility) {
            HomeUpNextSupport.upcomingDaySections(
                minDistinctDays: 2,
                mergeRowLimit: 48,
                now: Date(),
                authUserId: authUserId,
                currentUserEmail: userEmail,
                operatives: operatives,
                bookings: bookings,
                managerBookings: managerBookings,
                allProjects: projects,
                organizationUsers: users,
                accentBlue: blue,
                accentPurple: purple,
                payrollTimePolicy: policy
            )
        }.value

        if userStore.hasAdminAccess() {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: today) ?? today)
            let tomorrowProjectIds = Set(
                bookings
                    .filter {
                        cal.isDate($0.date, inSameDayAs: tomorrow) &&
                            ($0.status == .confirmed || $0.status == .tentative)
                    }
                    .map(\.projectId)
            )
            let projectsTomorrow = projects.filter { tomorrowProjectIds.contains($0.id) }
            await WarningsService.shared.updateWarningsAsync(
                operatives: operatives,
                bookings: bookings,
                projects: projects,
                users: users,
                managerSiteBookings: managerBookings,
                holidayBookings: holidayStore.bookings,
                payrollTimePolicy: policy,
                labourCoverageStart: cal.date(byAdding: .day, value: -14, to: today),
                labourCoverageEnd: cal.date(byAdding: .day, value: 28, to: today),
                materialOrderCutOffEnabled: appSettings.settings.notifications.materialOrderCutOff,
                projectsWithTomorrowBookings: projectsTomorrow
            )
            guard !Task.isCancelled else { return }
            homeWarningCount = WarningsService.shared.warningCount
        }

        cachedUpNextSections = await upNextTask
    }

    private func openWarningsDetail() async {
        if userStore.hasAdminAccess() {
            await refreshHomeDerivedData()
        }
        showingWarningsDetail = true
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
    
    private var taskLimitWarningBanner: some View {
        Group {
            // Avoid scanning every project’s task count while `currentUser` is nil — that can freeze the main thread during startup.
            if userStore.hasAdminAccess(), userStore.currentUser != nil {
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


private struct HomeDataRefreshTrigger: Equatable {
    var operativeCount: Int
    var bookingCount: Int
    var projectCount: Int
    var smallWorksCount: Int
    var managerBookingCount: Int
    var holidayCount: Int
    var userCount: Int
    var isHomeProfileLoading: Bool
    var currentUserId: String?
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
