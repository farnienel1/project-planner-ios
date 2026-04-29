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
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var notificationService: NotificationService

    @State private var selectedTab = 0
    @State private var showMoreMenu = false
    @State private var previousTab: Int? = nil
    @State private var hideBottomMenu = false
    @State private var showingHolidaySheet = false
    @State private var holidaySheetShowRequests = false
    @State private var showingBookingToast = false
    @State private var bookingToastText: String?
    
    /// Drives TabView `.id` so the page controller is recreated when role preview adds/removes tabs (avoids UIPageViewController deadlock on invalid selection).
    private var tabViewIdentity: String {
        var keys: [String] = ["0", "5", "8"]
        if !userStore.isOperativeMode() { keys.append("6") }
        if userStore.canViewProjects() { keys.append(contentsOf: ["1", "2"]) }
        if userStore.canViewOperatives() { keys.append("3") }
        if userStore.hasAdminAccess() { keys.append(contentsOf: ["4", "7"]) }
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
                .preference(key: HideBottomMenuKey.self, value: false)
            if !hideBottomMenu {
                bottomBar
            }
        }
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
                selectedTab = 0
            }
        }
        .onAppear {
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
            while firebaseBackend.isAuthenticated {
                await notificationService.loadNotifications()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
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
            if newValue != nil {
                print("🔥🔥🔥 DEBUG: Organization changed/loaded - reloading all data")
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
        .sheet(isPresented: $showingHolidaySheet) {
            HolidayView(showRequests: holidaySheetShowRequests)
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
        }
        await userStore.syncActiveOperativesWithUserAccounts(operativeStore: operativeStore)
    }
    
    @ViewBuilder
    private var mainTabContent: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView()
            }
            .tag(0)
            .id(0) // Add ID to force reset when tab changes
            
            if userStore.canViewProjects() {
                NavigationStack {
                    ProjectsView()
                }
                .tag(1)
                .id(1) // Add ID to force reset when tab changes
            }
            
            if userStore.canViewProjects() {
                NavigationStack {
                    SmallWorksView()
                }
                .tag(2)
                .id(2) // Add ID to force reset when tab changes
            }
            
            if userStore.canViewOperatives() {
                NavigationStack {
                    OperativesView()
                }
                .tag(3)
                .id(3) // Add ID to force reset when tab changes
            }
            
            if userStore.hasAdminAccess() {
                NavigationStack {
                    ManagersView()
                }
                .tag(4)
                .id(4) // Add ID to force reset when tab changes
            }
            
            NavigationStack {
                SettingsView()
            }
            .tag(5)
            .id(5) // Add ID to force reset when tab changes
            
            if !userStore.isOperativeMode() {
                NavigationStack {
                    HelpView()
                }
                .tag(6)
                .id(6) // Add ID to force reset when tab changes
            }
            
            if userStore.hasAdminAccess() {
                NavigationStack {
                    WholesalersView()
                }
                .tag(7)
                .id(7) // Add ID to force reset when tab changes
            }

            NavigationStack {
                HolidayView(showRequests: false)
            }
            .tag(8)
            .id(8)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .toolbar(.hidden, for: .tabBar)
        .id(tabViewIdentity)
    }
    
    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if showMoreMenu, !secondaryTabItems.isEmpty {
                tabRow(for: secondaryTabItems, isSecondary: true)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            tabRow(for: primaryTabItems, isSecondary: false)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
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
    private struct TabButtonConfig: Identifiable {
        let tag: Int
        let title: String
        let icon: String
        let multilineTitle: Bool
        let requiresPermission: Bool
        
        var id: Int { tag }
    }
    
    private var primaryTabItems: [TabButtonConfig] {
        var items: [TabButtonConfig] = [
            TabButtonConfig(tag: 0, title: "Home", icon: "house.fill", multilineTitle: false, requiresPermission: true)
        ]
        
        // Operative mode: Only show Home, Projects, Small Works, Settings
        if userStore.isOperativeMode() {
            if userStore.canViewProjects() {
                items.append(TabButtonConfig(tag: 1, title: "Projects", icon: "folder.fill", multilineTitle: false, requiresPermission: true))
                items.append(TabButtonConfig(tag: 2, title: "Small\nWorks", icon: "hammer.fill", multilineTitle: true, requiresPermission: true))
            }
        } else {
            // Full mode: Show all tabs
            if userStore.canViewProjects() {
                items.append(TabButtonConfig(tag: 1, title: "Projects", icon: "folder.fill", multilineTitle: false, requiresPermission: true))
                items.append(TabButtonConfig(tag: 2, title: "Small\nWorks", icon: "hammer.fill", multilineTitle: true, requiresPermission: true))
            }
            
            if userStore.canViewOperatives() {
                items.append(TabButtonConfig(tag: 3, title: "Operatives", icon: "person.3.fill", multilineTitle: false, requiresPermission: true))
            }
        }
        
        return items
    }
    
    private var secondaryTabItems: [TabButtonConfig] {
        var items: [TabButtonConfig] = []
        
        // Operative mode: Holiday + Settings
        if userStore.isOperativeMode() {
            items.append(TabButtonConfig(tag: 8, title: "Holiday", icon: "sun.max.fill", multilineTitle: false, requiresPermission: true))
            items.append(TabButtonConfig(tag: 5, title: "Settings", icon: "gearshape.fill", multilineTitle: false, requiresPermission: true))
        } else {
            // Full mode: Show all secondary tabs
            items.append(TabButtonConfig(tag: 8, title: "Holiday", icon: "sun.max.fill", multilineTitle: false, requiresPermission: true))
            if userStore.canViewManagers() {
                items.append(TabButtonConfig(tag: 4, title: "Managers", icon: "person.badge.key.fill", multilineTitle: false, requiresPermission: true))
            }
            
            // Add Wholesalers for admins/managers
            if userStore.hasAdminAccess() || userStore.canViewManagers() {
                items.append(TabButtonConfig(tag: 7, title: "Wholesalers", icon: "building.2.fill", multilineTitle: false, requiresPermission: true))
            }
            
            items.append(TabButtonConfig(tag: 5, title: "Settings", icon: "gearshape.fill", multilineTitle: false, requiresPermission: true))
            
            items.append(TabButtonConfig(tag: 6, title: "Help", icon: "questionmark.circle.fill", multilineTitle: false, requiresPermission: false))
        }
        
        return items
    }
    
    @ViewBuilder
    private func tabRow(for items: [TabButtonConfig], isSecondary: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(items) { item in
                tabButton(for: item)
            }
            
            if !isSecondary {
                if secondaryTabItems.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    Button {
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
        Button {
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
        }
    }
    
    private func selectTab(_ tag: Int) {
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
}

#Preview {
    ContentView()
        .environmentObject(FirebaseBackend())
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(BookingStore())
        .environmentObject(AppSettingsStore())
}