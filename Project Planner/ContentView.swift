//
//  ContentView.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import SwiftUI
import FirebaseAuth
import UserNotifications

// Preference key to track if we're in a detail view (should hide bottom menu)
struct HideBottomMenuKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue() || value
    }
}

// Environment key to track navigation depth
struct NavigationDepthKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    var navigationDepth: Int {
        get { self[NavigationDepthKey.self] }
        set { self[NavigationDepthKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var notificationService: NotificationService
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab = 0
    @State private var showMoreMenu = false
    @State private var previousTab: Int? = nil
    @State private var hideBottomMenu = false
    @State private var showingHolidaySheet = false
    @State private var holidaySheetShowRequests = false
    @State private var showingBookingToast = false
    @State private var bookingToastText: String?
    @State private var isReorderingTabs = false
    @State private var orderedMovableTabTags: [Int] = []
    @State private var jiggleTabs = false
    @State private var jiggleTask: Task<Void, Never>?
    @State private var tabButtonFrames: [Int: CGRect] = [:]
    
    /// Drives TabView `.id` so the page controller is recreated when role preview adds/removes tabs (avoids UIPageViewController deadlock on invalid selection).
    private var tabViewIdentity: String {
        var keys: [String] = ["0", "5", "8"]
        if !userStore.isOperativeMode() { keys.append("6") }
        if userStore.canViewProjects() { keys.append(contentsOf: ["1", "2"]) }
        if userStore.canViewOperatives() { keys.append("3") }
        if userStore.hasAdminAccess() { keys.append(contentsOf: ["4", "7"]) }
        if userStore.canManageSubcontractors() { keys.append("9") }
        let preset = userStore.roleTestingPreset.map(\.rawValue) ?? "none"
        return preset + "|" + keys.sorted().joined(separator: ",")
    }
    
    init() {
        UITabBar.appearance().isHidden = true
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if userStore.roleTestingPreset != nil, let preset = userStore.roleTestingPreset {
                roleTestingBanner(preset: preset)
            }
            mainTabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .preference(key: HideBottomMenuKey.self, value: false)
            if !hideBottomMenu {
                bottomBar
            }
        }
        .background(Color(.systemGroupedBackground))
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .tint(Color.theme.primary(for: appSettings.settings.colorScheme))
        .onPreferenceChange(HideBottomMenuKey.self) { value in
            withAnimation(.easeInOut(duration: 0.3)) {
                hideBottomMenu = value
            }
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            // Always reset to home when home tab is selected
            if newValue == 0 {
                // Home tab selected - ensure we're on home
                // Clear previous tab to prevent navigation issues
                previousTab = nil
            }
        }
        .onChange(of: tabViewIdentity) { _, _ in
            showMoreMenu = false
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if !isValidTabTag(selectedTab) {
                    selectedTab = 0
                }
            }
            syncMovableTabOrderWithCurrentPermissions()
        }
        .onChange(of: firebaseBackend.currentUser?.uid) { _, _ in
            syncMovableTabOrderWithCurrentPermissions()
        }
        .onAppear {
            syncMovableTabOrderWithCurrentPermissions()
            // Connect Firebase backend to stores first
            print("🔥🔥🔥 DEBUG: Connecting Firebase backend to stores in ContentView...")
            projectStore.setFirebaseBackend(firebaseBackend)
            operativeStore.setFirebaseBackend(firebaseBackend)
            bookingStore.setFirebaseBackend(firebaseBackend)
            userStore.setFirebaseBackend(firebaseBackend)
            print("🔥🔥🔥 DEBUG: Firebase backend connection complete in ContentView")
            
            // Normal load should happen automatically via auth state listener
            // Only trigger recovery if organization is still nil after a delay (meaning normal load failed)
            if firebaseBackend.isAuthenticated && firebaseBackend.currentOrganization == nil {
                print("🔥🔥🔥 DEBUG: ⚠️ Organization is nil on app appear, waiting for normal load...")
                Task {
                    // Wait 2 seconds for normal load to complete
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    // Only recover if still nil after normal load attempt
                    if firebaseBackend.currentOrganization == nil {
                        print("🔥🔥🔥 DEBUG: ⚠️ Organization still nil after normal load, attempting recovery...")
                        if let userId = firebaseBackend.currentUser?.uid {
                            await firebaseBackend.loadUserOrganizationWithRecovery(userId: userId)
                        }
                    }
                }
            }
            
            // Load all data after a brief delay to ensure Firebase connection is established
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
                await loadInitialData()
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
        .task(id: firebaseBackend.isAuthenticated) {
            guard firebaseBackend.isAuthenticated else { return }
            // Defer first poll so startup Firestore traffic and home layout aren’t all fighting the main actor.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while firebaseBackend.isAuthenticated {
                await notificationService.loadNotifications()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .onChange(of: notificationService.bookingToastMessage) { _, newValue in
            guard let text = newValue, !text.isEmpty else { return }
            bookingToastText = text
            withAnimation(.easeInOut(duration: 0.2)) { showingBookingToast = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.easeInOut(duration: 0.2)) { showingBookingToast = false }
                notificationService.bookingToastMessage = nil
            }
        }
        .onChange(of: firebaseBackend.currentOrganization) { oldValue, newValue in
            // Reload all data when organization changes or is loaded
            let oldOrgId = oldValue?.firestoreDocumentId
            let newOrgId = newValue?.firestoreDocumentId
            if let newOrgId, newOrgId != oldOrgId {
                print("🔥🔥🔥 DEBUG: Organization changed to \(newOrgId) - reloading all data once")
                Task {
                    await loadInitialData()
                }
            } else if oldValue != nil && newValue == nil {
                // Organization was lost - try to recover
                print("🔥🔥🔥 DEBUG: ⚠️ Organization was lost, attempting recovery...")
                Task {
                    if let userId = firebaseBackend.currentUser?.uid {
                        await firebaseBackend.loadUserOrganizationWithRecovery(userId: userId)
                    }
                }
            }
        }
        .onChange(of: userStore.currentUser?.id) { _, _ in
            Task {
                await notificationService.refreshDailyMaterialCutOffReminder()
                await notificationService.refreshQualificationExpiryReminders()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await notificationService.refreshQualificationExpiryReminders() }
            }
        }
        .onChange(of: appSettings.settings.notifications.materialOrderCutOff) { _, _ in
            Task { await notificationService.refreshDailyMaterialCutOffReminder() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("goBackToPreviousTab"))) { _ in
            // Go back to home tab when back button is pressed from secondary tabs (Operatives/Settings)
            // Always go to home (tab 0) when coming from secondary tabs
            selectTab(0)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("selectTab"))) { notification in
            // Handle tab selection from HomeView navigation tiles
            // Use async to prevent immediate re-triggering and potential loops
            DispatchQueue.main.async {
                if let userInfo = notification.userInfo,
                   let tab = userInfo["tab"] as? Int {
                    selectTab(tab)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("openHoliday"))) { notification in
            DispatchQueue.main.async {
                holidaySheetShowRequests = (notification.userInfo?["showRequests"] as? Bool) ?? false
                showingHolidaySheet = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qualificationExpiryScheduleRefresh)) { _ in
            Task { await notificationService.refreshQualificationExpiryReminders() }
        }
        .onChange(of: isReorderingTabs) { _, newValue in
            if newValue {
                showMoreMenu = true
                jiggleTask?.cancel()
                jiggleTask = Task {
                    while !Task.isCancelled {
                        await MainActor.run {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                jiggleTabs.toggle()
                            }
                        }
                        try? await Task.sleep(nanoseconds: 120_000_000)
                    }
                }
            } else {
                jiggleTask?.cancel()
                jiggleTask = nil
                jiggleTabs = false
            }
        }
        .sheet(isPresented: $showingHolidaySheet) {
            HolidayView(showRequests: holidaySheetShowRequests, presentedAsSheet: true)
                .environmentObject(holidayStore)
                .environmentObject(userStore)
                .environmentObject(operativeStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
                .environmentObject(appSettings)
        }
        .overlay(alignment: .top) {
            if showingBookingToast, let bookingToastText {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.plus")
                        .foregroundStyle(.white)
                    Text(bookingToastText)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.green.opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
    
    private func loadInitialData() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await projectStore.loadData() }
            group.addTask { await operativeStore.loadData() }
            group.addTask { await bookingStore.loadData() }
            group.addTask { await userStore.loadCurrentUser() }
            group.addTask { await appSettings.loadSettings() }
            group.addTask { await taskStore.loadData() }
            group.addTask { await holidayStore.loadData() }
            group.addTask { await subcontractorStore.loadData() }
        }
        await userStore.syncActiveOperativesWithUserAccounts(operativeStore: operativeStore)
        await notificationService.refreshDailyMaterialCutOffReminder()
        await notificationService.refreshQualificationExpiryReminders()
    }
    
    /// Single visible root (no `TabView`). Hiding the system tab bar + `TabView` left the main area blank on recent iOS SDKs; we already use a custom bottom bar.
    @ViewBuilder
    private var mainTabContent: some View {
        Group {
            switch selectedTab {
            case 0:
                NavigationStack {
                    HomeView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case 1:
                if userStore.canViewProjects() {
                    NavigationStack { ProjectsView() }
                } else {
                    NavigationStack { HomeView() }
                }
            case 2:
                if userStore.canViewProjects() {
                    NavigationStack { SmallWorksView() }
                } else {
                    NavigationStack { HomeView() }
                }
            case 3:
                if userStore.canViewOperatives() {
                    NavigationStack { OperativesView() }
                } else {
                    NavigationStack { HomeView() }
                }
            case 4:
                if userStore.hasAdminAccess() {
                    NavigationStack {
                        ManagersView()
                            .toolbar(.hidden, for: .navigationBar)
                    }
                } else {
                    NavigationStack { HomeView() }
                }
            case 5:
                NavigationStack { SettingsView() }
            case 6:
                if !userStore.isOperativeMode() {
                    NavigationStack { HelpView() }
                } else {
                    NavigationStack { HomeView() }
                }
            case 7:
                if userStore.hasAdminAccess() {
                    NavigationStack { WholesalersView() }
                } else {
                    NavigationStack { HomeView() }
                }
            case 8:
                NavigationStack {
                    HolidayView(showRequests: false)
                        .environmentObject(holidayStore)
                        .environmentObject(userStore)
                        .environmentObject(operativeStore)
                        .environmentObject(firebaseBackend)
                        .environmentObject(notificationService)
                        .environmentObject(appSettings)
                        .toolbar(.hidden, for: .navigationBar)
                }
            case 9:
                if userStore.canManageSubcontractors() {
                    NavigationStack {
                        SubcontractorsView()
                            .environmentObject(subcontractorStore)
                    }
                } else {
                    NavigationStack { HomeView() }
                }
            default:
                NavigationStack { HomeView() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Avoid `.id(tabViewIdentity)` here: when the profile loads, permissions change and rebuilding the entire
        // `NavigationStack` for every tab can freeze the home shell on iOS 18+ (we no longer use `TabView`).
    }
    
    @ViewBuilder
    private var bottomBar: some View {
        let topSecondary = Array(secondaryTabItems.prefix(2))
        let bottomSecondary = Array(secondaryTabItems.dropFirst(2))
        
        VStack(spacing: 8) {
            if isReorderingTabs {
                HStack {
                    Spacer()
                    Text("Drag icons to reorder")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.theme.primary(for: appSettings.settings.colorScheme).opacity(0.15))
                        .foregroundColor(Color.theme.primary(for: appSettings.settings.colorScheme))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 12)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            
            if (showMoreMenu || isReorderingTabs), !secondaryTabItems.isEmpty {
                if !topSecondary.isEmpty {
                    tabRow(for: topSecondary, isSecondary: false, showsMoreToggle: false)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !bottomSecondary.isEmpty {
                    tabRow(for: bottomSecondary, isSecondary: true)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            
            tabRow(for: primaryTabItems, isSecondary: false, showsMoreToggle: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .coordinateSpace(name: "tabReorderArea")
        .onPreferenceChange(TabFramePreferenceKey.self) { frames in
            tabButtonFrames = frames
        }
        .background(
            Color(.systemBackground).opacity(0.9)
                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: -2)
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: -2)
        )
    }
    
    private func roleTestingBanner(preset: RoleTestingPreset) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "theatermasks.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Role preview: \(preset.title)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Navigation matches this role. Firebase still uses your real account — some actions may fail if your real permissions differ.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.95))
            }
            Spacer(minLength: 0)
            Button {
                userStore.roleTestingPreset = nil
            } label: {
                Text("Reset")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel("Stop role preview")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.gradient)
    }
}

extension ContentView {
    private struct TabFramePreferenceKey: PreferenceKey {
        static var defaultValue: [Int: CGRect] = [:]
        static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private struct TabButtonConfig: Identifiable {
        let tag: Int
        let title: String
        let icon: String
        let multilineTitle: Bool
        let requiresPermission: Bool
        
        var id: Int { tag }
    }
    
    private var primaryTabItems: [TabButtonConfig] {
        let defaultPrimaryMovableCount = defaultPrimaryTabItems.count - 1
        let movable = orderedMovableTabItems
        let primaryMovable = Array(movable.prefix(max(defaultPrimaryMovableCount, 0)))
        
        var items: [TabButtonConfig] = [
            TabButtonConfig(tag: 0, title: "Home", icon: "house.fill", multilineTitle: false, requiresPermission: true)
        ]
        items.append(contentsOf: primaryMovable)
        return items
    }
    
    private var secondaryTabItems: [TabButtonConfig] {
        let defaultPrimaryMovableCount = defaultPrimaryTabItems.count - 1
        let movable = orderedMovableTabItems
        return Array(movable.dropFirst(max(defaultPrimaryMovableCount, 0)))
    }
    
    @ViewBuilder
    private func tabRow(for items: [TabButtonConfig], isSecondary: Bool, showsMoreToggle: Bool = true) -> some View {
        HStack(spacing: 12) {
            ForEach(items) { item in
                tabButton(for: item)
            }
            
            if isSecondary {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        isReorderingTabs.toggle()
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: isReorderingTabs ? "checkmark.circle.fill" : "pencil.circle")
                            .font(.title3)
                        Text(isReorderingTabs ? "Done" : "Edit")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundColor(isReorderingTabs ? Color.theme.primary(for: appSettings.settings.colorScheme) : .primary)
                }
            } else {
                if !showsMoreToggle || secondaryTabItems.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    Button {
                        if isReorderingTabs {
                            return
                        }
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            showMoreMenu.toggle()
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: showMoreMenu ? "ellipsis.circle.fill" : "ellipsis.circle")
                                .font(.title3)
                            Text("More")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundColor(.primary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
        )
    }
    
    private func tabButton(for config: TabButtonConfig) -> some View {
        let isMovable = config.tag != 0
        return Button {
            if isReorderingTabs && isMovable {
                return
            }
            selectTab(config.tag)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: config.icon)
                    .font(.title2)
                Text(config.title)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(config.multilineTitle ? 2 : 1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
                    .foregroundColor(selectedTab == config.tag ? Color.theme.primary(for: appSettings.settings.colorScheme) : Color.primary.opacity(0.85))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selectedTab == config.tag ? Color.theme.primary(for: appSettings.settings.colorScheme).opacity(0.18) : Color.clear)
                    .blur(radius: selectedTab == config.tag ? 0 : 0)
            )
            .rotationEffect(isReorderingTabs && isMovable ? .degrees(jiggleTabs ? 1.4 : -1.4) : .degrees(0))
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TabFramePreferenceKey.self,
                        value: [config.tag: geo.frame(in: .named("tabReorderArea"))]
                    )
                }
            )
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("tabReorderArea"))
                .onChanged { value in
                    guard isReorderingTabs, isMovable else { return }
                    guard let destinationTag = tabButtonFrames.first(where: { _, frame in
                        frame.contains(value.location)
                    })?.key else { return }
                    swapMovableTabs(config.tag, destinationTag)
                }
                .onEnded { _ in
                    // no-op
                }
        )
    }

    private func swapMovableTabs(_ sourceTag: Int, _ destinationTag: Int) {
        guard sourceTag != destinationTag,
              let sourceIndex = orderedMovableTabTags.firstIndex(of: sourceTag),
              let destinationIndex = orderedMovableTabTags.firstIndex(of: destinationTag) else {
            return
        }
        
        var updated = orderedMovableTabTags
        updated.swapAt(sourceIndex, destinationIndex)
        if updated != orderedMovableTabTags {
            orderedMovableTabTags = updated
            persistMovableTabOrder(updated)
        }
    }
    
    /// Whether `tag` exists on `mainTabContent`'s `TabView` (keep in sync with conditional tabs there).
    private func isValidTabTag(_ tag: Int) -> Bool {
        switch tag {
        case 0, 5, 8: return true
        case 1, 2: return userStore.canViewProjects()
        case 3: return userStore.canViewOperatives()
        case 4: return userStore.hasAdminAccess()
        case 6: return !userStore.isOperativeMode()
        case 7: return userStore.hasAdminAccess()
        case 9: return userStore.canManageSubcontractors()
        default: return false
        }
    }
    
    private func selectTab(_ tag: Int) {
        let tag = isValidTabTag(tag) ? tag : 0
        // Prevent infinite loops - don't process if already on this tab (unless it's home)
        if selectedTab == tag && tag != 0 {
            // Already on this tab, just reset navigation if needed
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("resetNavigationForTab"),
                    object: nil,
                    userInfo: ["tab": tag]
                )
            }
            return
        }
        
        // If selecting Home (tab 0), always ensure we go to Home, not Projects
        let targetTab = tag
        
        withAnimation(.easeInOut(duration: 0.15)) {
            // Store previous tab before switching (for navigation from secondary tabs)
            if selectedTab != targetTab {
                previousTab = selectedTab
            }
            
            // If selecting Home (tab 0), ensure we reset any navigation state first
            if targetTab == 0 {
                // Clear previous tab to ensure clean navigation to home
                previousTab = nil
            }
            
            // Explicitly set selectedTab FIRST to prevent navigation loops
            selectedTab = targetTab
            
            // Post notification to reset navigation for the selected tab
            // This ensures each tab resets to its start page
            // Use async dispatch to prevent immediate re-triggering
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("resetNavigationForTab"),
                    object: nil,
                    userInfo: ["tab": targetTab]
                )
            }
            
            // Always close more menu when selecting a tab
            if showMoreMenu {
                showMoreMenu = false
            }
        }
    }
    
    func goBack() {
        if let previousTab = previousTab {
            selectTab(previousTab)
            self.previousTab = nil
        } else {
            // Default to home if no previous tab
            selectTab(0)
        }
    }
    
    private var defaultPrimaryTabItems: [TabButtonConfig] {
        var items: [TabButtonConfig] = [
            TabButtonConfig(tag: 0, title: "Home", icon: "house.fill", multilineTitle: false, requiresPermission: true)
        ]
        
        if userStore.canViewProjects() {
            items.append(TabButtonConfig(tag: 1, title: "Projects", icon: "folder.fill", multilineTitle: false, requiresPermission: true))
            items.append(TabButtonConfig(tag: 2, title: "Small\nWorks", icon: "hammer.fill", multilineTitle: true, requiresPermission: true))
        }
        
        if !userStore.isOperativeMode(), userStore.canViewOperatives() {
            items.append(TabButtonConfig(tag: 3, title: "Operatives", icon: "person.3.fill", multilineTitle: false, requiresPermission: true))
        }
        
        return items
    }
    
    private var defaultSecondaryTabItems: [TabButtonConfig] {
        var items: [TabButtonConfig] = [
            TabButtonConfig(tag: 8, title: "Holiday", icon: "sun.max.fill", multilineTitle: false, requiresPermission: true)
        ]
        
        if userStore.isOperativeMode() {
            items.append(TabButtonConfig(tag: 5, title: "Settings", icon: "gearshape.fill", multilineTitle: false, requiresPermission: true))
            return items
        }
        
        if userStore.canViewManagers() {
            items.append(TabButtonConfig(tag: 4, title: "Managers", icon: "person.badge.key.fill", multilineTitle: false, requiresPermission: true))
        }
        
        if userStore.hasAdminAccess() || userStore.canViewManagers() {
            items.append(TabButtonConfig(tag: 7, title: "Wholesalers", icon: "building.2.fill", multilineTitle: false, requiresPermission: true))
            if userStore.canManageSubcontractors() {
                items.append(TabButtonConfig(tag: 9, title: "Sub Contractors", icon: "person.2.badge.gearshape.fill", multilineTitle: true, requiresPermission: true))
            }
        }
        
        items.append(TabButtonConfig(tag: 5, title: "Settings", icon: "gearshape.fill", multilineTitle: false, requiresPermission: true))
        items.append(TabButtonConfig(tag: 6, title: "Help", icon: "questionmark.circle.fill", multilineTitle: false, requiresPermission: false))
        return items
    }
    
    private var defaultMovableTabItems: [TabButtonConfig] {
        let combined = defaultPrimaryTabItems.dropFirst() + defaultSecondaryTabItems
        var seen: Set<Int> = []
        var items: [TabButtonConfig] = []
        for item in combined where !seen.contains(item.tag) {
            seen.insert(item.tag)
            items.append(item)
        }
        return items
    }
    
    private var orderedMovableTabItems: [TabButtonConfig] {
        let defaults = defaultMovableTabItems
        guard !orderedMovableTabTags.isEmpty else { return defaults }
        
        let map = Dictionary(uniqueKeysWithValues: defaults.map { ($0.tag, $0) })
        return orderedMovableTabTags.compactMap { map[$0] }
    }
    
    private var movableTabOrderStorageKey: String {
        let uid = firebaseBackend.currentUser?.uid ?? "anonymous"
        return "bottomBarMovableTabOrder.\(uid)"
    }
    
    private func loadPersistedMovableTabOrder() -> [Int] {
        let raw = UserDefaults.standard.string(forKey: movableTabOrderStorageKey) ?? ""
        return raw.split(separator: ",").compactMap { Int($0) }
    }
    
    private func persistMovableTabOrder(_ tags: [Int]) {
        let raw = tags.map(String.init).joined(separator: ",")
        UserDefaults.standard.set(raw, forKey: movableTabOrderStorageKey)
    }
    
    private func syncMovableTabOrderWithCurrentPermissions() {
        let defaults = defaultMovableTabItems.map(\.tag)
        guard !defaults.isEmpty else {
            orderedMovableTabTags = []
            UserDefaults.standard.removeObject(forKey: movableTabOrderStorageKey)
            return
        }
        
        let stored = loadPersistedMovableTabOrder()
        
        var filtered: [Int] = stored.filter { defaults.contains($0) }
        for tag in defaults where !filtered.contains(tag) {
            filtered.append(tag)
        }
        
        orderedMovableTabTags = filtered
        persistMovableTabOrder(filtered)
    }
    
}

#Preview {
    ContentView()
        .environmentObject(FirebaseBackend())
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(BookingStore())
        .environmentObject(UserStore())
        .environmentObject(ProjectTaskStore())
        .environmentObject(HolidayStore())
        .environmentObject(SubcontractorStore())
        .environmentObject(AppSettingsStore())
        .environmentObject(NotificationService())
}