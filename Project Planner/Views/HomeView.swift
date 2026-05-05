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
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                logoAndTitleSection
                navigationMenuBar
                taskLimitWarningBanner
                warningsAndTasksSection
                navigationTilesGrid
                
                if userStore.canViewProjects() {
                    maintenanceSection
                }
            }
        }
        .navigationBarHidden(true)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(.systemGroupedBackground),
                    Color(.systemGroupedBackground).opacity(0.8)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
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
        .onAppear {
            // Load notifications when view appears
            Task {
                await notificationService.loadNotifications()
            }
        }
        .sheet(isPresented: $showingCreateClient) {
            CreateClientView()
                .environmentObject(projectStore)
        }
        .sheet(isPresented: $showingCreateProject) {
            CreateProjectView()
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
        }
        .sheet(isPresented: $showingCreateSmallWorks) {
            CreateSmallWorksView()
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
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
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("dismissManageUsersAndSelectTab"))) { notification in
            showingManageUsers = false
        }
        .fullScreenCover(isPresented: $showingClientsView) {
            ClientsView()
                .environmentObject(projectStore)
        }
    }
    
    // MARK: - Logo and Title Section
    private var logoAndTitleSection: some View {
        VStack(spacing: 8) {
            Text("Project Planner")
                .font(.system(size: 34, weight: .bold, design: .default))
                .foregroundColor(Color.theme.primary(for: appSettings.settings.colorScheme))
                .environment(\.appColorScheme, appSettings.settings.colorScheme)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Rectangle()
                .fill(Color.theme.primary.opacity(0.2))
                .frame(height: 2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }
    
    // MARK: - Navigation Menu Bar
    private var navigationMenuBar: some View {
        VStack(spacing: 16) {
            // User Name and Menu Button Row
            HStack {
                // User Name
                if let appUser = userStore.currentUser {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .foregroundColor(Color.theme.primary)
                        Text("Welcome, \(appUser.firstName.isEmpty ? (appUser.email.components(separatedBy: "@").first?.capitalized ?? "User") : appUser.firstName)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    }
                } else if let currentUser = firebaseBackend.currentUser?.email {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .foregroundColor(Color.theme.primary)
                        Text("Welcome, \(extractNameFromEmail(currentUser))")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    }
                }
                
                Spacer()
                
                // Notification Badge Button — tap opens list and marks all as read so badge clears; only new notifications will show after that
                Button(action: {
                    let service = notificationService
                    Task {
                        await service.markAllAsRead()
                        showingNotifications = true
                    }
                }) {
                    ZStack {
                        Image(systemName: "bell.fill")
                            .font(.title3)
                            .foregroundColor(.primary)
                        
                        if notificationService.unreadCount > 0 {
                            Text("\(notificationService.unreadCount > 99 ? "99+" : "\(notificationService.unreadCount)")")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Color.red)
                                .clipShape(Circle())
                                .offset(x: 12, y: -12)
                        } else {
                            // Show "0" when no notifications
                            Text("0")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Color.red)
                                .clipShape(Circle())
                                .offset(x: 12, y: -12)
                        }
                    }
                }
                .padding(.trailing, 8)
                
                // Scrollable menu sheet
                Button {
                    showingQuickMenu = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.title2)
                        .foregroundColor(Color.theme.primary(for: appSettings.settings.colorScheme))
                        .padding(12)
                        .background(Color.white)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                }
                .environment(\.appColorScheme, appSettings.settings.colorScheme)
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 20)
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
                showingManageUsers: $showingManageUsers
            )
            .environmentObject(userStore)
            .environmentObject(firebaseBackend)
        }
    }
    
    // MARK: - Helper Functions
    private func extractNameFromEmail(_ email: String) -> String {
        // Extract the part before @ and capitalize it
        let name = email.components(separatedBy: "@").first ?? email
        return name.capitalized
    }
    
    // MARK: - Warnings and Tasks Section
    private var warningsAndTasksSection: some View {
        HStack(spacing: 16) {
            if userStore.hasAdminAccess() {
                // Warnings Tile (Super Admin / Admin only)
                Button(action: {
                    DispatchQueue.main.async {
                        showingWarningsDetail = true
                    }
                }) {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.red)
                            Text("Warnings")
                                .font(.headline)
                                .foregroundColor(.red)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.1))
                        
                        HStack {
                            Spacer()
                            if warningsService.warningCount == 0 {
                                Text("No warnings")
                                    .font(.subheadline)
                                    .foregroundColor(.red.opacity(0.8))
                            } else {
                                HStack(spacing: 4) {
                                    Text("\(warningsService.warningCount) Warning\(warningsService.warningCount == 1 ? "" : "s")")
                                        .font(.subheadline)
                                        .foregroundColor(.red.opacity(0.8))
                                        .fontWeight(.semibold)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.red.opacity(0.6))
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.05))
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity)
            }
            
            // Tasks Tile
            Button(action: {
                DispatchQueue.main.async {
                    showingTasksDetail = true
                }
            }) {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Image(systemName: "checklist")
                            .foregroundColor(.blue)
                        Text("Tasks")
                            .font(.headline)
                            .foregroundColor(.blue)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(Color.blue.opacity(0.1))
                    
                    HStack {
                        Spacer()
                        let taskCount = assignedTasksCount
                        Text("\(taskCount) Task\(taskCount == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundColor(.blue.opacity(0.8))
                            .fontWeight(.semibold)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.blue.opacity(0.6))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(Color.blue.opacity(0.05))
                }
            }
            .buttonStyle(PlainButtonStyle())
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .onAppear {
            if userStore.hasAdminAccess() {
                updateWarnings()
            }
            Task {
                await taskStore.loadData()
            }
        }
        .onChange(of: operativeStore.allOperatives) { _, _ in
            if userStore.hasAdminAccess() {
                updateWarnings()
            }
        }
        .onChange(of: bookingStore.bookings) { _, _ in
            if userStore.hasAdminAccess() {
                updateWarnings()
            }
        }
        .onChange(of: projectStore.projects) { _, _ in
            if userStore.hasAdminAccess() {
                updateWarnings()
            }
        }
        .onChange(of: projectStore.smallWorks) { _, _ in
            if userStore.hasAdminAccess() {
                updateWarnings()
            }
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
            // For regular users, count all active tasks
            return taskStore.tasks.filter { !$0.isCompleted }.count + pendingHolidayApprovalsCount
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
    
    // MARK: - Navigation Tiles Grid
    private var navigationTilesGrid: some View {
        VStack(spacing: 16) {
            if userStore.isOperativeMode() {
                // Operative Mode – Projects, Small Works, Annual Leave, My Schedule (view-only), Settings
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 12) {
                    navigationTile(
                        icon: "folder.fill",
                        title: "Projects",
                        action: {
                            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 1])
                        }
                    )
                    navigationTile(
                        icon: "hammer.fill",
                        title: "Small Works",
                        action: {
                            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 2])
                        }
                    )
                    navigationTile(
                        icon: "sun.max.fill",
                        title: "Annual Leave",
                        action: {
                            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 8])
                        }
                    )
                    navigationTile(
                        icon: "doc.text.viewfinder",
                        title: "Site Audit",
                        action: { showingSiteAudit = true }
                    )
                    navigationTile(
                        icon: "calendar",
                        title: "My Schedule",
                        action: { showingMySchedule = true }
                    )
                    navigationTile(
                        icon: "gearshape.fill",
                        title: "Settings",
                        action: {
                            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 5])
                        }
                    )
                }
            } else {
                // Full Mode - All tiles
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 12) {
                    // Row 1: Weekly Report, Daily Overview
                    if userStore.hasAdminAccess() {
                        navigationTile(
                            icon: "chart.bar.doc.horizontal",
                            title: "Weekly Report",
                            action: { }
                        )
                        navigationTile(
                            icon: "calendar.badge.clock",
                            title: "Daily Overview",
                            action: { showingDailyOverview = true }
                        )
                    }
                    // Row 2: Projects (left), Small Works (right)
                    if userStore.canViewProjects() {
                        navigationTile(
                            icon: "folder.fill",
                            title: "Projects",
                            action: {
                                NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 1])
                            }
                        )
                        navigationTile(
                            icon: "hammer.fill",
                            title: "Small Works",
                            action: {
                                NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 2])
                            }
                        )
                    }
                    // Row 3: Annual Leave + My Schedule
                    if userStore.hasAdminAccess() || userStore.displayUser?.permissions.manager == true {
                        navigationTile(
                            icon: "sun.max.fill",
                            title: "Annual Leave",
                            action: {
                                NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 8])
                            }
                        )
                    }
                    if userStore.canViewProjects() || userStore.isOperativeMode() {
                        navigationTile(
                            icon: "calendar",
                            title: "My Schedule",
                            action: { showingMySchedule = true }
                        )
                    }
                    navigationTile(
                        icon: "doc.text.viewfinder",
                        title: "Site Audit",
                        action: { showingSiteAudit = true }
                    )

                    // Row 4: Managers + Operatives
                    if userStore.hasAdminAccess() {
                        navigationTile(
                            icon: "person.badge.key.fill",
                            title: "Managers",
                            action: {
                                NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 4])
                            }
                        )
                    }
                    if userStore.canViewOperatives() {
                        navigationTile(
                            icon: "person.3.fill",
                            title: "Operatives",
                            action: {
                                NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 3])
                            }
                        )
                    }

                    if userStore.hasAdminAccess() {
                        navigationTile(
                            icon: "map.fill",
                            title: "Site Map",
                            action: { showingOrgSitesMap = true }
                        )
                    }

                    navigationTile(
                        icon: "gearshape.fill",
                        title: "Settings",
                        action: {
                            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 5])
                        }
                    )
                    .gridCellColumns(2)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .sheet(isPresented: $showingDailyOverview) {
            DailyOverviewView()
                .environmentObject(bookingStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(holidayStore)
                .environmentObject(managerScheduleStore)
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
        }
        .sheet(isPresented: $showingSiteAudit) {
            SiteAuditHubView()
                .environmentObject(projectStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
    }
    
    // MARK: - Navigation Tile
    private func navigationTile(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundColor(Color.theme.primary(for: appSettings.settings.colorScheme))
                
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .padding(.vertical, 16)
            .background(Color.white)
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Maintenance Section
    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !userStore.isOperativeMode() {
                Text("Maintenance")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 20)
            }
            
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Maintenance Coming Soon!")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                        
                        Text("Maintenance features will be available in a future update.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 30)
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

// MARK: - Operative qualifications (read-only)

struct OperativeQualificationsReadOnlyView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
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
        NavigationStack {
            Group {
                if let op = operative {
                    if op.qualifications.isEmpty {
                        ContentUnavailableView(
                            "No qualifications",
                            systemImage: "graduationcap",
                            description: Text("Your manager can add qualifications to your profile.")
                        )
                    } else {
                        List {
                            ForEach(Array(op.qualifications).sorted(by: { $0.name < $1.name })) { q in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(q.name).font(.headline)
                                    if let exp = op.qualificationExpiryDates[q.id] {
                                        Text("Expires: \(exp.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("No expiry on file")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                } else {
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
                }
            }
            .navigationTitle("My Qualifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await repairOperativeLinkIfNeeded()
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
            dayRate: u.dayRate
        )
        await operativeStore.addOperative(newOperative)
        repairMessage = "Created and linked operative profile."
    }
}

struct QuickMenuSheet: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
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

    var body: some View {
        NavigationStack {
            List {
                Section("Navigate") {
                    if !userStore.isOperativeMode() {
                        actionRow("Clients", "person.2.fill") { showingClientsView = true }
                    }
                    actionRow("Projects", "folder.fill") { selectTab(1) }
                    actionRow("Small Works", "hammer.fill") { selectTab(2) }
                    if userStore.canViewOperatives() { actionRow("Operatives", "person.3.fill") { selectTab(3) } }
                    if userStore.canViewManagers() { actionRow("Managers", "person.badge.key.fill") { selectTab(4) } }
                }

                Section("Tools") {
                    if userStore.canManageSkills() {
                        actionRow("Skills", "wrench.and.screwdriver.fill") { showingSkillsManagement = true }
                    }
                    if userStore.canManageQualifications() {
                        actionRow("Qualifications", "graduationcap.fill") { showingQualificationsManagement = true }
                    }
                    if userStore.isOperativeMode() {
                        actionRow("My Qualifications", "graduationcap.fill") { showingOperativeQualifications = true }
                    }
                    if userStore.hasAdminAccess() {
                        actionRow("Job Types", "folder.fill") { showingJobTypesManagement = true }
                        actionRow("Wholesalers", "building.2.fill") { showingWholesalers = true }
                    }
                }

                if userStore.hasAdminAccess() || userStore.displayUser?.permissions.manager == true {
                    Section("Create") {
                        actionRow("Create Project", "plus.square.fill") { showingCreateProject = true }
                        actionRow("Create Small Works", "hammer.fill") { showingCreateSmallWorks = true }
                    }
                }

                if userStore.canManageUsers() ||
                    (!userStore.hasAdminAccess() &&
                     userStore.displayUser?.permissions.manager == true &&
                     userStore.displayUser?.permissions.operatives == true) {
                    Section("User Management") {
                        actionRow(userStore.canManageUsers() ? "Add User" : "Add Operative", "person.badge.plus.fill") {
                            showingAddUser = true
                        }
                        actionRow(userStore.canManageUsers() ? "Manage Users" : "Manage Operatives", "person.2.fill") {
                            showingManageUsers = true
                        }
                    }
                }

                Section("Account") {
                    actionRow("Reset Password", "key.fill") {
                        if let email = firebaseBackend.currentUser?.email {
                            Task { try? await firebaseBackend.resetPassword(email: email) }
                        }
                    }
                    actionRow("Sign Out", "rectangle.portrait.and.arrow.right") {
                        userStore.clearOnSignOut()
                        try? firebaseBackend.signOut()
                    }
                }
            }
            .navigationTitle("Menu")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func actionRow(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                action()
            }
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private func selectTab(_ tab: Int) {
        NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": tab])
    }
}

#Preview {
    HomeView()
        .environmentObject(SimpleAuthManager())
        .environmentObject(FirebaseBackend())
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(BookingStore())
}
