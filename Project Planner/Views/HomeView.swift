//
//  HomeView.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import SwiftUI
import UIKit
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
    @EnvironmentObject var smartCache: SmartCacheService
    @State private var homeWarningCount: Int = 0
    /// False until a warnings scan of loaded inputs has published (`WarningsService.hasCompletedLiveDetection`).
    /// Until then the pill reads "Checking…", never "All clear".
    @State private var homeWarningsReady = false
    @State private var cachedUpNextSections: [HomeUpNextDaySection] = []
    @State private var cachedOverviewMetrics = HomeOverviewMetrics()
    @State private var showingCreateClient = false
    @State private var showingNotifications = false
    @State private var showingCreateProject = false
    @State private var showingCreateSmallWorks = false
    @State private var showingCreateOperative = false
    @State private var showingCreateManager = false
    @State private var showingQualificationsManagement = false
    @State private var showingJobTypesManagement = false
    @State private var showingAddUser = false
    @State private var showingManageUsers = false
    @State private var showingDailyOverview = false
    @State private var weeklyReportLaunch: WeeklyReportLaunchToken?
    @State private var showingOrgSitesMap = false
    @State private var showingMySchedule = false
    @State private var showingWarningsDetail = false
    @State private var showingTasksDetail = false
    @State private var showingWholesalers = false
    @State private var showingMaterialCatalogue = false
    @State private var showingOperativeQualifications = false
    @State private var showingSiteAudit = false
    @State private var showingInvoicing = false
    @State private var timesheetReviewDeepLinkUserId: String?
    @State private var timesheetDeepLinkSurface: String?
    @State private var dailyOverviewDay: Date?
    @State private var timesheetReviewDeepLinkWeekStart: Date?
    
    // Navigation states for menu items
    @State private var showingClientsView = false
    @State private var showingQuickMenu = false
    @State private var isCustomisingQuickActions = false
    @State private var showingAddQuickActionPicker = false
    @State private var showingQuickActionCustomizeHint = false
    @State private var persistedQuickActionIds: [String] = []
    @State private var showingGeneralAppSettings = false
    @State private var hasLoadedQuickActionLayoutForUserKey: String?
    @State private var showingAdminOverviewCustomize = false
    @State private var draftAdminOverviewMetricIds: [HomeOverviewMetricID] = []
    @State private var persistedAdminOverviewMetricIds: [HomeOverviewMetricID] = []
    @State private var hasLoadedAdminOverviewMetrics = false
    @State private var showingHomeProfileCard = false
    @State private var isRefreshingHomeConnection = false
    @State private var homeTopInset: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    taskLimitWarningBanner
                    homeDashboardRoot
                }
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .refreshable {
                await refreshHomeConnection()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PPColor.page.ignoresSafeArea())
        // TODO(UI): status bar style — Home is not inside a NavigationStack, so toolbarColorScheme cannot turn the status bar white without changing navigation.
        .sheet(isPresented: $showingWarningsDetail, onDismiss: {
            WarningsRefreshHelper.isWarningsSheetVisible = false
            // REBUILD: no auto warm on dismiss.

        }) {
            WarningsDetailView(
                warningsService: WarningsService.shared,
                projectStore: projectStore,
                userStore: userStore,
                operativeStore: operativeStore,
                bookingStore: bookingStore,
                managerScheduleStore: managerScheduleStore,
                firebaseBackend: firebaseBackend,
                appSettings: appSettings,
                holidayStore: holidayStore,
                notificationService: notificationService,
                subcontractorStore: subcontractorStore,
                taskStore: taskStore
            )
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
                .environmentObject(bookingStore)
        }
        .sheet(isPresented: $showingNotifications) {
            NotificationsView()
                .environmentObject(notificationService)
                .environmentObject(userStore)
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
            // RULEBOOK 1.34.0 §11: a new operative with no login is a ghost (a users document), never an `operatives`
            // row — Add user opens with the Ghost account toggle on (shown only when `ghostToggleVisible` allows it: `canCreateGhost` and the `ghostAccounts` switch, owner decision 7 Nov "1b").
            AddUserView(
                mode: userStore.currentUser?.isRosterAdmin == true ? .admin : .managerAddingOperative,
                startAsGhost: true
            )
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
                .environmentObject(smartCache)
        }
        .sheet(isPresented: $showingCreateManager) {
            CreateManagerView()
                .environmentObject(operativeStore)
        }
        .sheet(isPresented: $showingQualificationsManagement) {
            QualificationsManagementView()
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
        }
        .sheet(isPresented: $showingOperativeQualifications) {
            OperativeQualificationsReadOnlyView()
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
        }
        .sheet(isPresented: $showingJobTypesManagement) {
            JobTypesManagementView()
                .environmentObject(projectStore)
        }
        .sheet(isPresented: $showingAddUser) {
            AddUserView(mode: .admin)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        // Manage Users is a pushed page with the system back button; back returns to Home (D2).
        .fullScreenCover(isPresented: $showingManageUsers) {
            ManageUsersPushedFromHome(isPresented: $showingManageUsers)
                .environmentObject(userStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(holidayStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
        }
        .sheet(isPresented: $showingMaterialCatalogue) {
            MaterialCatalogueRootView()
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .sheet(isPresented: $showingWholesalers) {
            WholesalersView(presentedAsSheet: true)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("openTasksDetail"))) { _ in
            presentTasksDetail()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("navigateToWarnings"))) { _ in
            print("🔥🔥🔥 DEBUG: WARNINGS_NAVIGATE_SYNC")
            presentWarningsDetail()
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
        .sheet(isPresented: $showingDailyOverview, onDismiss: {
            dailyOverviewDay = nil
        }) {
            DailyOverviewView(displayDate: dailyOverviewDay)
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
        .sheet(item: $weeklyReportLaunch, onDismiss: {
            WarningsRefreshHelper.isWeeklyReportVisible = false
            // REBUILD: no auto warm on dismiss.

        }) { token in
            WeeklyReportOpenShell(token: token)
        }
        .sheet(isPresented: $showingOrgSitesMap) {
            OrgSitesMapView()
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
                .environmentObject(projectStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(managerScheduleStore)
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
        // Timesheets opens as a full page (owner, 6 Nov): a sheet left Home showing behind it. Closed with its Done button.
        .fullScreenCover(isPresented: $showingInvoicing, onDismiss: {
            timesheetReviewDeepLinkUserId = nil
            timesheetReviewDeepLinkWeekStart = nil
            timesheetDeepLinkSurface = nil
        }) {
            InvoicingView(
                initialReviewUserId: $timesheetReviewDeepLinkUserId,
                initialReviewWeekStart: $timesheetReviewDeepLinkWeekStart,
                initialSurface: $timesheetDeepLinkSurface
            )
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(projectStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(notificationService)
                .environmentObject(holidayStore)
        }
        .sheet(isPresented: $showingHomeProfileCard) {
            HomeProfileCardSheet()
                .environmentObject(smartCache)
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
                .environmentObject(operativeStore)
                .environmentObject(projectStore)
                .environmentObject(bookingStore)
                .environmentObject(taskStore)
                .environmentObject(holidayStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(appSettings)
                .environmentObject(notificationService)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWorkCatalogueDetail)) { _ in
            showingDailyOverview = false
            showingWarningsDetail = false
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
            case .qualifications: showingQualificationsManagement = true
            case .myQualifications: showingOperativeQualifications = true
            case .jobTypes: showingJobTypesManagement = true
            case .wholesalers: showingWholesalers = true
            case .materialCatalogue:
                if userStore.canManageMaterialCatalogue() {
                    showingMaterialCatalogue = true
                }
            case .addUser: showingAddUser = true
            case .manageUsers:
                if let editUserId = note.userInfo?["editUserId"] as? String, !editUserId.isEmpty {
                    WorkCatalogueDeepLink.pendingEditUserId = editUserId
                }
                presentManageUsers()
            case .tasksDetail: presentTasksDetail()
            case .generalAppSettings:
                break
            case .orgSitesMap: showingOrgSitesMap = true
            case .siteAudit: showingSiteAudit = true
            case .invoicing:
                timesheetReviewDeepLinkUserId = note.userInfo?["targetUserId"] as? String
                timesheetDeepLinkSurface = note.userInfo?["timesheetSurface"] as? String
                if let date = note.userInfo?["weekStart"] as? Date {
                    timesheetReviewDeepLinkWeekStart = date
                } else if let interval = note.userInfo?["weekStart"] as? TimeInterval {
                    timesheetReviewDeepLinkWeekStart = Date(timeIntervalSince1970: interval)
                } else if let number = note.userInfo?["weekStart"] as? NSNumber {
                    timesheetReviewDeepLinkWeekStart = Date(timeIntervalSince1970: number.doubleValue)
                } else if let dayKey = note.userInfo?["dayKey"] as? String,
                          let date = CanonicalBusinessEngine.date(fromDayKey: dayKey) {
                    timesheetReviewDeepLinkWeekStart = date
                } else {
                    timesheetReviewDeepLinkWeekStart = nil
                }
                showingInvoicing = true
            case .mySchedule:
                showingMySchedule = true
            case .dailyOverview:
                if let dayKey = note.userInfo?["dayKey"] as? String,
                   let date = CanonicalBusinessEngine.date(fromDayKey: dayKey) {
                    dailyOverviewDay = date
                } else {
                    dailyOverviewDay = nil
                }
                showingDailyOverview = true
            case .warnings:
                presentWarningsDetail()
            case .notifications:
                showingNotifications = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mainMenuResetPassword)) { _ in
            if let email = firebaseBackend.currentUser?.email {
                Task { try? await firebaseBackend.resetPassword(email: email) }
            }
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
            // Bootstrap already loads manager schedule once — only top up after bootstrap if still empty.
            if firebaseBackend.hasBootstrappedOrgDataLoad,
               managerScheduleStore.managerSiteBookings.isEmpty {
                managerScheduleStore.loadData()
            }
            loadPersistedQuickActionsIfNeeded()
        }
        .onChange(of: userStore.currentUser?.id) { _, _ in
            hasLoadedQuickActionLayoutForUserKey = nil
            loadPersistedQuickActionsIfNeeded()
        }
        .onChange(of: userStore.isHomeProfileLoading) { _, isLoading in
            if !isLoading {
                loadPersistedQuickActionsIfNeeded()
            }
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
                                .accessibilityIdentifier("home.done")
                        }
                    }
            }
        }
        .alert("Quick actions", isPresented: $showingQuickActionCustomizeHint) {
            Button("OK") {
                UserDefaults.standard.set(true, forKey: quickActionCustomizeHintKey)
            }
                .accessibilityIdentifier("home.ok")
        } message: {
            Text("Drag the icons to your desired layout.")
        }
    }

    // MARK: - Home dashboard (HTML / design reference)

    private var homeMuted: Color { ProjectWorksRevampColors.muted }
    private var homeBlue: Color { ProjectWorksRevampColors.blue }

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
        cachedOverviewMetrics.liveProjectCount
    }

    private var tasksDueTodayCount: Int {
        cachedOverviewMetrics.tasksDueToday
    }

    private var tasksDueThisWeekCount: Int {
        cachedOverviewMetrics.tasksDueThisWeek
    }

    /// Incomplete tasks assigned to the current user with due date strictly before today.
    private var tasksOverdueCount: Int {
        cachedOverviewMetrics.tasksOverdue
    }

    private var outstandingTasksAllUsersCount: Int {
        cachedOverviewMetrics.outstandingTasksAllUsers
    }

    private var operativesOnSiteTodayCount: Int {
        cachedOverviewMetrics.operativesOnSiteToday
    }

    private var managersOnSiteTodayCount: Int {
        cachedOverviewMetrics.managersOnSiteToday
    }

    /// Combined daily on-site headcount across operative bookings and manager site bookings.
    private var peopleOnSiteTodayCount: Int {
        cachedOverviewMetrics.peopleOnSiteToday
    }

    private var operativesOnALTodayCount: Int {
        cachedOverviewMetrics.operativesOnALToday
    }

    private var managersOnALTodayCount: Int {
        cachedOverviewMetrics.managersOnALToday
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
        case .warnings:
            return WarningsDisplayPhase.homeMetricValue(hasCompletedLiveDetection: homeWarningsReady, activeCount: homeWarningCount)
        case .operativesOnSite: return "\(peopleOnSiteTodayCount)"
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
        VStack(spacing: 0) {
            homeNavyHeader
            homeLightSheet
        }
        .onAppear {
            loadPersistedAdminOverviewMetricsIfNeeded()
            let inset = Self.topSafeInset()
            if inset > 1 {
                homeTopInset = inset
            }
            print("🔥🔥🔥 DEBUG: HOME_APPEARED inset=\(Int(inset))")
            NotificationCenter.default.post(name: .plannerHomeDidDraw, object: nil)
            // Do not touch WarningsService.shared here. This onAppear runs inside the
            // first layout commit. Creating the shared service then publishes warning
            // counts and the window stays white. The next turn is after that commit.
            DispatchQueue.main.async {
                syncHomeWarningBadgeFromCache()
            }
            // Saved Light/Dark is applied after Home is on screen. The launch shell does not touch it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                appSettings.settings.theme.applyToKeyWindows()
            }
        }
        .task(id: homeDataRefreshTrigger) {
            // Coalesce rapid store updates while Firebase batches load.
            // Longer debounce during bootstrap / while core stores are still loading.
            let bootstrapping = firebaseBackend.isBootstrappingOrgDataLoad
            let inQuiet = firebaseBackend.launchQuietUntil.map { Date() < $0 } ?? false
            let storesBusy = bookingStore.isLoading || operativeStore.isLoading || projectStore.isLoading
            let delayNs: UInt64 = (bootstrapping || inQuiet || storesBusy) ? 2_500_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            // Skip heavy derived work until home-critical bootstrap releases the lock.
            if firebaseBackend.isBootstrappingOrgDataLoad {
                return
            }
            print("🔥🔥🔥 DEBUG: Home derived refresh starting…")
            await refreshHomeDerivedData()
            print("🔥🔥🔥 DEBUG: Home derived refresh finished")
        }
        // REBUILD: Home never auto-scans warnings (that jetsamed Simulator for days).
        // Pill reads disk/shared cache only. User refreshes from the Warnings sheet.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("managerScheduleDidChange"))) { _ in
            // Do not recompute warnings here — that raced launch quiet / deferred loads
            // and jetsamed Simulator. Badge updates when Home warms warnings or
            // when `.warningsDidRecompute` is posted.
            guard userStore.canViewStaffWarnings() else { return }
            syncHomeWarningBadgeFromCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: .warningsDidRecompute)) { notification in
            if let count = notification.userInfo?["count"] as? Int {
                homeWarningCount = count
                homeWarningsReady = WarningsService.shared.hasCompletedLiveDetection
            } else {
                syncHomeWarningBadgeFromCache()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .warningsNeedsHomeRefresh)) { _ in
            // REBUILD: no auto Home warm — only sync badge from shared/disk cache.
            syncHomeWarningBadgeFromCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookingStoreDidChange)) { _ in
            // ContentView owns the debounced warning scan so it still runs on other tabs.
        }
        .onChange(of: showingWarningsDetail) { _, isOpen in
            WarningsRefreshHelper.isWarningsSheetVisible = isOpen
            if isOpen {
                WarningsRefreshHelper.cancelInFlightRefresh()
            }
        }
        .onChange(of: weeklyReportLaunch != nil) { _, isOpen in
            WarningsRefreshHelper.isWeeklyReportVisible = isOpen
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

    // REBUILD stubs — auto warm removed. Badge reads shared/disk cache only.
    @MainActor
    private func syncHomeWarningBadgeFromCache() {
        homeWarningCount = WarningsService.shared.warningCount
        homeWarningsReady = WarningsService.shared.hasCompletedLiveDetection
    }


    /// Status-bar / Dynamic Island height. The root fills the whole window, so Home adds this itself.
    private static func topSafeInset() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var best: CGFloat = 0
        for scene in scenes {
            for window in scene.windows where window.bounds.width > 1 && window.bounds.height > 1 {
                best = max(best, window.safeAreaInsets.top)
            }
        }
        return best
    }

    private var homeNavyHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            homeGreetingHeader
            todayOverviewCard
            homeSecondaryStatusRow
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 8 + homeTopInset)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .ppNavyHeader()
    }

    private var homeLightSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            quickActionsHeaderRow
            quickActionsIconGrid
            upNextSection
            if userStore.canViewProjects() && !userStore.isOperativeMode() {
                maintenanceTeaserCompact
            }
        }
        .padding(.bottom, 28)
        .ppContentSheet()
    }

    private var homeGreetingHeader: some View {
        HStack(alignment: .top) {
            PPGreetingLabel(dateText: todayWeekdayLine, greeting: "Hi, \(greetingFirstName)")
            Spacer()
            HStack(spacing: 8) {
                Button {
                    Task { await refreshHomeConnection() }
                } label: {
                    Group {
                        if isRefreshingHomeConnection {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .accessibilityIdentifier("home.refresh")
                .buttonStyle(PPOnNavyCircleButtonStyle())
                .disabled(isRefreshingHomeConnection)
                .accessibilityLabel("Refresh")
                .accessibilityHint("Checks your connection and syncs changes waiting on this device")
                Button {
                    showingNotifications = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell.fill")
                        if notificationService.unreadCount > 0 {
                            PPBellDot()
                        }
                    }
                }
                .accessibilityIdentifier("home.notifications")
                .buttonStyle(PPOnNavyCircleButtonStyle())
                .accessibilityLabel("Notifications")
                .accessibilityHint("Opens your notification list")
                Button {
                    showingHomeProfileCard = true
                } label: {
                    // RULEBOOK §12: the signed-in profile's photo (live `users/{uid}` listener), initials until it loads.
                    ProfilePhotoAvatar(
                        urlString: userStore.currentUser?.profilePhotoURL,
                        updatedAt: userStore.currentUser?.profilePhotoUpdatedAt
                    ) {
                        Text(profileInitials)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(homeBlue)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
                }
                .accessibilityIdentifier("home.\(AccessibilityID.token(profileInitials))")
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 18)
    }

    @MainActor
    private func refreshHomeConnection() async {
        isRefreshingHomeConnection = true
        defer { isRefreshingHomeConnection = false }
        await smartCache.refreshConnectionAndSync()
        await refreshHomeDerivedData()
    }

    private var todayOverviewCard: some View {
        let headsUp = todayOverviewIsHeadsUp
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                PPOverviewTitle(
                    eyebrow: "Today's overview",
                    count: "\(liveProjectCount)",
                    countLabel: liveProjectCount == 1 ? "active project" : "active projects"
                )
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
                    }
                    .accessibilityIdentifier("home.customize")
                    .buttonStyle(PPOnNavyCircleButtonStyle(size: PPMetrics.smallHeaderButton))
                    .accessibilityLabel("Customize dashboard metrics")
                }
                // TODO(UI): Heads up is a status label, not a button, so PPHeadsUpButtonStyle is not applied.
                headsUpStatusLabel(isHeadsUp: headsUp)
            }
            overviewMetricPillsRow
        }
        .padding(.top, 16)
    }

    private func headsUpStatusLabel(isHeadsUp: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(PPColor.hiVisInk).frame(width: 6, height: 6)
            Text(isHeadsUp ? "Heads up" : "On track")
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(PPColor.hiVisInk)
        .padding(.horizontal, 12)
        .frame(height: PPMetrics.smallHeaderButton)
        .background(PPColor.hiVis, in: Capsule())
    }

    @ViewBuilder
    private var overviewMetricPillsRow: some View {
        if userStore.isOperativeMode() {
            overviewStatRow {
                overviewStatPill(value: "\(tasksDueTodayCount)", label: "Tasks Due Today")
                PPStatDivider()
                overviewStatPill(value: "\(tasksDueThisWeekCount)", label: "Tasks Due This Week")
                PPStatDivider()
                overviewStatPill(value: "\(tasksOverdueCount)", label: "My Tasks Overdue")
            }
        } else if userStore.hasAdminAccess() {
            overviewStatRow {
                ForEach(Array(adminResolvedOverviewMetricIds.enumerated()), id: \.element) { index, mid in
                    if index > 0 {
                        PPStatDivider()
                    }
                    overviewStatPill(
                        value: overviewMetricValueString(mid),
                        label: mid.compactPillTitle,
                        highlight: mid == .warnings
                    )
                }
            }
        } else {
            overviewStatRow {
                overviewStatPill(value: "\(tasksDueTodayCount)", label: "Tasks Due Today")
                PPStatDivider()
                overviewStatPill(value: "\(tasksDueThisWeekCount)", label: "Tasks Due This Week")
                PPStatDivider()
                overviewStatPill(value: "\(assignedTasksCount)", label: "Open Tasks (My Tasks)")
            }
        }
    }

    private func overviewStatRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 16)
    }

    private func overviewStatPill(value: String, label: String, highlight: Bool = false) -> some View {
        PPStat(value: value, label: label, highlight: highlight || label == "Warnings")
    }

    private var homeSecondaryStatusRow: some View {
        HStack(spacing: 8) {
            if userStore.canViewStaffWarnings() {
                secondaryPill(
                    icon: "exclamationmark.triangle.fill",
                    iconTint: ProjectWorksRevampColors.requiredPillFg,
                    iconBackground: ProjectWorksRevampColors.requiredPillBg,
                    title: "Warnings",
                    value: WarningsDisplayPhase.homePillValue(hasCompletedLiveDetection: homeWarningsReady, activeCount: homeWarningCount)
                ) {
                    print("🔥🔥🔥 DEBUG: WARNINGS_BUTTON_SYNC")
                    presentWarningsDetail()
                }
                .frame(maxWidth: .infinity)
            }
            secondaryPill(
                icon: "checklist",
                iconTint: homeBlue,
                iconBackground: ProjectWorksRevampColors.blueTint,
                title: "Tasks",
                value: "\(assignedTasksCount) pending"
            ) {
                presentTasksDetail()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 18)
    }

    private func secondaryPill(
        icon: String,
        iconTint: Color,
        iconBackground: Color,
        title: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        _ = (iconTint, iconBackground)
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let chipValue: String
        let chipUnit: String
        if parts.count == 2, Int(parts[0]) != nil {
            chipValue = String(parts[0])
            chipUnit = String(parts[1])
        } else {
            chipValue = value
            chipUnit = ""
        }
        return Button(action: action) {
            PPStatusChipLabel(
                symbol: icon,
                family: title == "Warnings" ? .alert : .plan,
                title: title,
                value: chipValue,
                unit: chipUnit
            )
        }
        .accessibilityIdentifier("home.warnings")
        .buttonStyle(PPOnNavyChipButtonStyle())
    }

    private var quickActionStorageKeyUserId: String? {
        userStore.currentUser?.id ?? firebaseBackend.currentUser?.uid ?? LocalLayoutPreferences.signedInUserId
    }

    private var quickActionCustomizeHintKey: String {
        let uid = quickActionStorageKeyUserId ?? "anonymous"
        return "homeQuickActionCustomizeHint.\(uid)"
    }

    private func loadPersistedQuickActionsIfNeeded() {
        guard let uid = quickActionStorageKeyUserId else { return }
        guard userStore.currentUser != nil || !userStore.isHomeProfileLoading else { return }
        guard hasLoadedQuickActionLayoutForUserKey != uid else { return }
        hasLoadedQuickActionLayoutForUserKey = uid
        if let saved = LocalLayoutPreferences.loadQuickActionOrder(userId: uid) {
            var seen = Set<String>()
            let cleaned = saved.filter { id in
                HomeQuickActionID.barredFromHome.contains(id) == false
                    && HomeQuickActionRegistry.meta(for: id) != nil
                    && seen.insert(id).inserted
            }
            persistedQuickActionIds = cleaned.isEmpty
                ? HomeQuickActionRegistry.defaultOrderedIds(userStore: userStore)
                : cleaned
        } else {
            persistedQuickActionIds = HomeQuickActionRegistry.defaultOrderedIds(userStore: userStore)
        }
        mergeOperativeHomeDefaultsIfNeeded()
    }

    /// Operative permissions already decide what they may open. A saved layout must not hide those actions.
    private func mergeOperativeHomeDefaultsIfNeeded() {
        guard userStore.isOperativeMode() else { return }
        let defaults = HomeQuickActionRegistry.defaultOrderedIds(userStore: userStore)
        var merged = persistedQuickActionIds
        for id in defaults where !merged.contains(id) {
            merged.append(id)
        }
        guard merged != persistedQuickActionIds else { return }
        persistedQuickActionIds = merged
        savePersistedQuickActions()
    }

    private func savePersistedQuickActions() {
        guard let uid = quickActionStorageKeyUserId else { return }
        LocalLayoutPreferences.saveQuickActionOrder(persistedQuickActionIds, userId: uid)
    }

    private func sanitizePersistedQuickActionsIfNeeded() {
        guard userStore.currentUser != nil || !userStore.isHomeProfileLoading else { return }
        var seen = Set<String>()
        let cleaned = persistedQuickActionIds.filter { id in
            HomeQuickActionID.barredFromHome.contains(id) == false
                && HomeQuickActionRegistry.meta(for: id) != nil
                && seen.insert(id).inserted
        }
        // Keep currently ineligible tiles in storage so permission blips at launch
        // cannot rewrite the user's layout. Display already filters by eligibility.
        if cleaned != persistedQuickActionIds {
            persistedQuickActionIds = cleaned.isEmpty
                ? HomeQuickActionRegistry.defaultOrderedIds(userStore: userStore)
                : cleaned
            savePersistedQuickActions()
        }
        mergeOperativeHomeDefaultsIfNeeded()
    }

    private func isGeneralAppQuickActionTitle(_ title: String) -> Bool {
        let normalized = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "general" || normalized == "general app"
    }

    private var addableQuickActionIds: [String] {
        let onHome = Set(persistedQuickActionIds)
        return HomeQuickActionRegistry.allEligibleIds(userStore: userStore)
            .filter { id in
                !onHome.contains(id) && !isGeneralAppQuickActionTitle(displayTitleForQuickAction(id: id))
            }
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
            raw = HomeQuickActionRegistry.meta(for: id, userStore: userStore)?.title ?? ""
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
            // RULEBOOK 1.32.0 §7, §11: `canOpenWeeklyReport` (admins only) — a tile shown while the profile loaded
            // never opens the report for anyone else.
            guard userStore.canOpenWeeklyReport() else { return }
            weeklyReportLaunch = WeeklyReportLaunchToken(
                bookingStore: bookingStore,
                managerScheduleStore: managerScheduleStore,
                projectStore: projectStore,
                operativeStore: operativeStore,
                holidayStore: holidayStore,
                userStore: userStore,
                firebaseBackend: firebaseBackend,
                subcontractorStore: subcontractorStore,
                appSettings: appSettings,
                notificationService: notificationService,
                taskStore: taskStore
            )
        case HomeQuickActionID.staffDailyOverview.rawValue:
            dailyOverviewDay = nil
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
            break
        case HomeQuickActionID.staffQualifications.rawValue:
            showingQualificationsManagement = true
        case HomeQuickActionID.staffMyQualifications.rawValue:
            showingOperativeQualifications = true
        case HomeQuickActionID.staffJobTypes.rawValue:
            showingJobTypesManagement = true
        case HomeQuickActionID.staffWholesalers.rawValue:
            showingWholesalers = true
        case HomeQuickActionID.staffMaterialCatalogue.rawValue:
            showingMaterialCatalogue = true
        case HomeQuickActionID.staffAddUser.rawValue:
            showingAddUser = true
        case HomeQuickActionID.staffManageUsersSheet.rawValue:
            presentManageUsers()
        case HomeQuickActionID.staffHelp.rawValue:
            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 6])
        case HomeQuickActionID.staffHoliday.rawValue:
            NotificationCenter.default.post(name: NSNotification.Name("selectTab"), object: nil, userInfo: ["tab": 8])
        case HomeQuickActionID.staffGeneralAppSettings.rawValue:
            break
        case HomeQuickActionID.staffTasks.rawValue:
            presentTasksDetail()
        case HomeQuickActionID.staffInvoicing.rawValue:
            showingInvoicing = true
        default:
            break
        }
    }

    @ViewBuilder
    private func quickActionTileContents(meta: HomeQuickActionMeta, title: String) -> some View {
        PPQuickActionLabel(
            title: title,
            symbol: PPMidnightAppearance.quickActionSymbol(id: meta.id, fallback: meta.symbol),
            family: PPMidnightAppearance.quickActionFamily(id: meta.id)
        )
    }

    private var quickActionsHeaderRow: some View {
        PPSectionHeader("Quick actions") {
            if isCustomisingQuickActions, !addableQuickActionIds.isEmpty {
                Button {
                    showingAddQuickActionPicker = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .accessibilityIdentifier("home.addQuickAction")
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.brand)
                .accessibilityLabel("Add quick action")
            }
            Button {
                showingQuickMenu = true
            } label: {
                Label("Main Menu", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityIdentifier("home.mainMenu")
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.brand)
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
                    .fontWeight(.medium)
            }
            .accessibilityIdentifier("home.done2")
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var displayedQuickActionIds: [String] {
        var ids = persistedQuickActionIds.filter { id in
            HomeQuickActionRegistry.isEligible(id: id, userStore: userStore)
                && !isGeneralAppQuickActionTitle(displayTitleForQuickAction(id: id))
        }
        if userStore.isOperativeMode() {
            for id in HomeQuickActionRegistry.defaultOrderedIds(userStore: userStore) where !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }

    private var quickActionsIconGrid: some View {
        LazyVGrid(columns: PPQuickActionGrid.columns, spacing: PPQuickActionGrid.rowSpacing) {
            ForEach(displayedQuickActionIds, id: \.self) { id in
                if let meta = HomeQuickActionRegistry.meta(for: id, userStore: userStore) {
                    if isCustomisingQuickActions {
                        quickActionCustomizeTile(id: id, meta: meta)
                    } else {
                        Button {
                            performQuickAction(id: id)
                        } label: {
                            quickActionTileContents(meta: meta, title: displayTitleForQuickAction(id: id))
                        }
                        .accessibilityIdentifier("home.row.\(id)")
                        .buttonStyle(PPPressableButtonStyle())
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
        // TODO(UI): Customise mode has no jiggle animation today; none was added.
        ZStack(alignment: .topLeading) {
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
                PPRemoveBadgeLabel()
            }
            .accessibilityIdentifier("home.removeFromQuickActions")
            .buttonStyle(.plain)
            .offset(x: -4, y: -4)
            .accessibilityLabel("Remove \(title) from quick actions")
        }
    }

    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPSectionHeader("Up next") {
                Button("See all") { showingMySchedule = true }
                    .accessibilityIdentifier("home.seeAll")
                    .foregroundStyle(PPColor.brand)
            }

            let sections = cachedUpNextSections
            if sections.isEmpty {
                Text("No upcoming bookings on your schedule.")
                    .font(.system(size: 15))
                    .foregroundStyle(homeMuted)
                    .padding(.vertical, 10)
            } else {
                ForEach(sections) { section in
                    PPDayHeading(text: section.heading)
                        .padding(.top, section.id == sections.first?.id ? 0 : 8)

                    ForEach(section.rows) { row in
                        Button {
                            showingMySchedule = true
                        } label: {
                            PPUpNextRowLabel(
                                weekday: row.sortDate.formatted(.dateTime.weekday(.abbreviated)),
                                day: row.sortDate.formatted(.dateTime.day()),
                                title: row.title,
                                time: row.subtitle
                            )
                        }
                        .accessibilityIdentifier("home.row.\(row.id)")
                        .buttonStyle(PPPressableButtonStyle())
                        .padding(.bottom, 12)
                    }
                }
            }
        }
        .padding(.bottom, 10)
    }

    private var maintenanceTeaserCompact: some View {
        PPComingSoonCard(
            title: "Maintenance",
            subtitle: "Coming in a future update",
            badge: "Soon"
        )
        .padding(.top, 8)
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
            taskIncompleteCount: taskStore.tasks.filter { !$0.isCompleted }.count,
            isHomeProfileLoading: userStore.isHomeProfileLoading,
            currentUserId: userStore.currentUser?.id,
            worksRevision: worksRevision,
            orgDataReady: firebaseBackend.hasBootstrappedOrgDataLoad && !firebaseBackend.isBootstrappingOrgDataLoad
        )
    }

    /// Changes when a project or small work date, live flag, or type changes, so Home recounts active jobs.
    private var worksRevision: Int {
        var hash = 0
        for project in projectStore.projects {
            hash = hash &+ project.startDate.hashValue
            hash = hash &+ project.endDate.hashValue
            hash = hash &+ project.updatedAt.hashValue
            hash = hash &+ (project.isLive ? 1 : 0)
            hash = hash &+ project.jobType.hashValue
        }
        return hash
    }

    /// Shows Manage Users already pushed (no slide-up), so it reads as a page with a back button.
    private func presentManageUsers() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            showingManageUsers = true
        }
    }

    private func presentTasksDetail() {
        showingWarningsDetail = false
        showingTasksDetail = true
    }

    private func presentWarningsDetail() {
        showingTasksDetail = false
        WarningsRefreshHelper.isWarningsSheetVisible = true
        WarningsRefreshHelper.cancelInFlightRefresh()
        showingWarningsDetail = true
    }

    /// Rebuild Up Next + overview metrics; warnings refresh stays off the main thread via `WarningsRefreshHelper`.
    @MainActor
    private func refreshHomeDerivedData() async {
        guard !userStore.isHomeProfileLoading, userStore.currentUser != nil else { return }
        guard !Task.isCancelled else { return }
        guard !firebaseBackend.isBootstrappingOrgDataLoad else { return }
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
        let accentBlue = Color(red: 0.094, green: 0.373, blue: 0.647)
        let accentPurple = Color(red: 0.325, green: 0.29, blue: 0.718)
        let tasks = taskStore.tasks
        let managers = operativeStore.allManagers
        let holidays = holidayStore.bookings
        let signedIn = userStore.displayUser ?? userStore.currentUser
        // RULEBOOK 1.21.0 §21 `activeJobsCount`: the same jobs Projects and Small works show under Active.
        let activeProjectCount = WorkAccess.homeActiveProjectCount(
            projects: projects + projectStore.smallWorks,
            viewer: signedIn.map { userStore.jobAccessViewer(for: $0) },
            operatives: operatives,
            bookings: bookings,
            managerBookings: managerBookings,
            tasks: tasks
        )

        async let upNextTask = HomeUpNextSupport.upcomingDaySections(
            minDistinctDays: 2,
            mergeRowLimit: 48,
            now: Date(),
            authUserId: authUserId,
            currentUserEmail: userEmail,
            currentUserFirstName: signedIn?.firstName,
            currentUserSurname: signedIn?.surname,
            operatives: operatives,
            bookings: bookings,
            managerBookings: managerBookings,
            allProjects: projects,
            organizationUsers: users,
            accentBlue: accentBlue,
            accentPurple: accentPurple,
            payrollTimePolicy: policy
        )

        // RULEBOOK 1.33.0 §6, §23: the on-site and on-leave figures count the viewer's Daily Overview team
        // (`dailyOverviewScopeFor`): a manager's own team, everyone for admins.
        let overviewScopeJSON = DailyOverviewScopeSupport.scopeJSON(users: users, operatives: operatives)

        async let metricsTask = HomeOverviewMetrics.compute(
            tasks: tasks,
            viewerId: signedIn?.id ?? authUserId,
            userEmail: userEmail,
            operatives: operatives,
            managers: managers,
            bookings: bookings,
            managerBookings: managerBookings,
            holidays: holidays,
            organizationUsers: users,
            liveProjectCount: activeProjectCount,
            scopeJSON: overviewScopeJSON
        )

        // Paint Home first. Warnings are heavy (main-actor snapshot + scan) — never block first frame on them.
        cachedOverviewMetrics = await metricsTask
        cachedUpNextSections = await upNextTask
        guard !Task.isCancelled else { return }

        if userStore.canViewStaffWarnings() {
            // Do not auto-run warnings on Home after every store refresh — that used to
            // freeze/crash Simulator. Badge stays at last known count; opening Warnings
            // refreshes off the main actor (and never during bootstrap/quiet).
            syncHomeWarningBadgeFromCache()
            if !WarningsService.shared.hasCompletedLiveDetection {
                // No scan has published yet (a listener may not deliver again): queue the booking scheduler's
                // readiness-gated scan. It waits for every input to load and never cancels a running scan.
                WarningsRefreshHelper.requestFirstScanWhenInputsReady(
                    operativeStore: operativeStore,
                    bookingStore: bookingStore,
                    projectStore: projectStore,
                    userStore: userStore,
                    managerScheduleStore: managerScheduleStore,
                    holidayStore: holidayStore,
                    firebaseBackend: firebaseBackend,
                    appSettings: appSettings
                )
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

    /// `leaveDecisionQueue` for the signed-in account (RULEBOOK §9): the same requests its approval queue lists.
    private var pendingHolidayApprovalsCount: Int {
        guard let me = userStore.currentUser else { return 0 }
        let viewer = userStore.organizationUsers.first(where: { $0.id == me.id }) ?? me
        return AnnualLeaveApproval.decidableRequests(
            holidayStore.pendingRequests,
            viewer: viewer,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        ).count
    }
    
    /// RULEBOOK 1.23.0 §5 `CanonicalBusinessEngine.qualificationExpiryCount`: the signed-in operative's own rows from
    /// `qualificationExpiryRows` (organisation day, one calendar month, already expired included) — surfaced under Tasks.
    private var operativeQualificationExpiryReminderCount: Int {
        guard userStore.isOperativeMode(), let me = userStore.currentUser else { return 0 }
        // Every catalogue row of this account (`bookingIdsForAccount`), never an email match here.
        let ids = labourBookingIds(for: me, operatives: operativeStore.allOperatives)
        let mine = operativeStore.allOperatives.filter { ids.contains($0.id) }
        guard !mine.isEmpty else { return 0 }
        return CanonicalBusinessEngine.qualificationExpiryCount(
            operatives: operativeStore.allOperatives.map(\.rulebookQualificationRow),
            operativeIds: mine.map(\.documentId)
        )?.total ?? 0
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
        .background(ProjectWorksRevampColors.surface)
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
                    Image(systemName: project.isSmallWorksDocument ? "hammer" : "wrench")
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
        .background(ProjectWorksRevampColors.surface)
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
    @EnvironmentObject var notificationService: NotificationService
    @State private var isRepairingLink = false
    @State private var repairMessage: String?
    
    private var operative: Operative? {
        // The person's own row (`personDedupeKey`); an empty email never matches another no-email row.
        guard let user = userStore.currentUser else { return nil }
        return operativeStore.operativeRow(for: user)
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
                .environmentObject(notificationService)
                .environmentObject(userStore)
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
                    .accessibilityIdentifier("operativeQualificationsReadOnly.repairing")
                    .buttonStyle(.borderedProminent)
                    .disabled(isRepairingLink)
                    .navigationTitle("My Qualifications")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                                .accessibilityIdentifier("operativeQualificationsReadOnly.done")
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
        // RULEBOOK 1.34.0 §11: a ghost is a users document only; never create an `operatives` row for one (an invited
        // ghost signs in only after accepting, which drops the ghost flag).
        guard !u.isGhost else { return }
        
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

/// RULEBOOK 1.35.0 §12: the Home avatar opens the one My Profile screen (`SettingsProfileDetailView`, the same screen as
/// Settings → My Profile) in a sheet, with the Settings gear and Done (Done asks first when the VAT / UTR draft is unsaved). Before 1.35 this was a separate read-only card
/// that labelled every rate "Day rate"; the merged screen reads the rate with `readStoredRates`.
private struct HomeProfileCardSheet: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var smartCache: SmartCacheService

    var body: some View {
        NavigationStack {
            // `userStore.currentUser` inside: the signed-in person's own users document for the open organisation.
            // `displayUser` (the old card) only adds the role-testing preset, which changes permissions, not personal
            // data, so the figures, rate and billing details are the person's own either way.
            SettingsProfileDetailView(isSheetRoot: true)
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
                .environmentObject(operativeStore)
                .environmentObject(holidayStore)
                .environmentObject(taskStore)
                .environmentObject(bookingStore)
                .environmentObject(managerScheduleStore)
                // The figures card opens Annual leave, My Schedule, Tasks and My Qualifications, which read these.
                .environmentObject(projectStore)
                .environmentObject(appSettings)
                .environmentObject(notificationService)
                .environmentObject(smartCache)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            SettingsView(popsNavigationOnBack: true)
                                .environmentObject(firebaseBackend)
                                .environmentObject(projectStore)
                                .environmentObject(operativeStore)
                                .environmentObject(bookingStore)
                                .environmentObject(taskStore)
                                .environmentObject(appSettings)
                                .environmentObject(userStore)
                                .environmentObject(notificationService)
                                .environmentObject(holidayStore)
                                .environmentObject(managerScheduleStore)
                        } label: {
                            Image(systemName: "gearshape.fill")
                        }
                        .accessibilityIdentifier("homeProfileCard.settings")
                        .accessibilityLabel("Settings")
                    }
                }
        }
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
                            .accessibilityIdentifier("homeQuickActionAdd.button")
                    }
                }
            }
            .navigationTitle("Add quick action")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("homeQuickActionAdd.cancel")
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
    var taskIncompleteCount: Int
    var isHomeProfileLoading: Bool
    var currentUserId: String?
    var worksRevision: Int
    var orgDataReady: Bool
}

private struct HomeOverviewMetrics: Equatable {
    var liveProjectCount: Int = 0
    var tasksDueToday: Int = 0
    var tasksDueThisWeek: Int = 0
    var tasksOverdue: Int = 0
    var outstandingTasksAllUsers: Int = 0
    var operativesOnSiteToday: Int = 0
    var managersOnSiteToday: Int = 0
    var peopleOnSiteToday: Int = 0
    var operativesOnALToday: Int = 0
    var managersOnALToday: Int = 0

    /// RULEBOOK 1.23.0 §23 `CanonicalBusinessEngine.homeOverviewMetrics`: every figure on the organisation day, each
    /// person once under all their ids (users with former / same-email ids, `operatives` and `managers` rows). Swift
    /// only maps the stores into plain rows; `liveProjectCount` stays `activeJobsCount` (§21).
    static func compute(
        tasks: [ProjectTask],
        viewerId: String?,
        userEmail: String?,
        operatives: [Operative],
        managers: [Manager],
        bookings: [Booking],
        managerBookings: [ManagerSiteBooking],
        holidays: [HolidayBooking],
        organizationUsers: [AppUser],
        liveProjectCount: Int,
        scopeJSON: Data? = nil,
        now: Date = Date()
    ) -> HomeOverviewMetrics {
        func optional(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
        var input: [String: Any] = [
            "nowMs": (now.timeIntervalSince1970 * 1000).rounded(),
            "timeZone": OrganizationRulebookContext.timeZoneIdentifier,
            "viewer": ["id": optional(viewerId), "email": optional(userEmail)],
            "roster": organizationUsers.map(RulebookRosterLists.levelRow),
            "operatives": operatives.map { operative -> [String: Any] in
                ["id": Booking.storedOperativeId(for: operative.id), "email": operative.email, "isActive": operative.isActive]
            },
            "managers": managers.map { ["id": $0.id.uuidString, "email": $0.email] as [String: Any] },
            "tasks": tasks.map { task -> [String: Any] in
                [
                    "status": task.status.rawValue,
                    "dueDate": task.dueDate.map { ($0.timeIntervalSince1970 * 1000).rounded() as Any } ?? NSNull(),
                    "assignedOperativeIds": task.assignedOperativeIds.map { Booking.storedOperativeId(for: $0) },
                    "assignedOperativeId": task.assignedOperativeId.map { Booking.storedOperativeId(for: $0) as Any } ?? NSNull(),
                    "assignedManagerIds": task.assignedManagerIds.map(\.uuidString),
                    "assignedManagerId": task.assignedManagerId.map { $0.uuidString as Any } ?? NSNull(),
                ]
            },
            "bookings": bookings.map { booking -> [String: Any] in
                [
                    "operativeId": Booking.storedOperativeId(for: booking.operativeId),
                    "dayKey": OrganizationRulebookContext.dayKey(booking.date),
                    "status": booking.status.rawValue,
                ]
            },
            "managerSiteBookings": managerBookings.map { booking -> [String: Any] in
                [
                    "userId": booking.userId,
                    "dayKey": OrganizationRulebookContext.dayKey(booking.date),
                    "locationType": booking.locationType.rawValue,
                ]
            },
            "holidays": holidays.map(\.rulebookLeaveRecord.json),
            "nonWorkingDayKeys": OrganizationBankHolidays.dayKeys,
        ]
        // RULEBOOK 1.33.0 §6, §23 `scope` (`dailyOverviewScopeFor`): missing counts everyone.
        if let scopeJSON, let scope = try? JSONSerialization.jsonObject(with: scopeJSON) {
            input["scope"] = scope
        }
        guard let figures = CanonicalBusinessEngine.homeOverviewMetrics(input) else {
            return HomeOverviewMetrics(liveProjectCount: liveProjectCount)
        }
        return HomeOverviewMetrics(
            liveProjectCount: liveProjectCount,
            tasksDueToday: figures.tasksDueToday,
            tasksDueThisWeek: figures.tasksDueThisWeek,
            tasksOverdue: figures.tasksOverdue,
            outstandingTasksAllUsers: figures.outstandingTasksAllUsers,
            operativesOnSiteToday: figures.operativesOnSiteToday,
            managersOnSiteToday: figures.managersOnSiteToday,
            peopleOnSiteToday: figures.peopleOnSiteToday,
            operativesOnALToday: figures.operativesOnALToday,
            managersOnALToday: figures.managersOnALToday
        )
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
