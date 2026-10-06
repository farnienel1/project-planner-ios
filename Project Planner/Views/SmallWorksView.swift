//
//  SmallWorksView.swift
//  Project Planner
//
//  Created by Assistant on 27/10/2025.
//

import SwiftUI
import UIKit

struct SmallWorksView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    /// Default to Active so the list opens on current jobs; use All / Completed chips for older work.
    @State private var selectedStatus: ProjectStatus? = .active
    @State private var selectedProject: Project? = nil
    @State private var showingEditProject = false
    @State private var navigationPath = NavigationPath()
    @State private var searchText = ""
    @State private var showingCreateSmallWorks = false
    @State private var deadlineAssignedProjectIds: Set<UUID> = []

    private var listCounts: WorksListStatusCounts {
        WorksListStatusCounts.from(smallWorksBeforeStatusFilter)
    }

    private var canCreateSmallWorks: Bool {
        guard let u = userStore.currentUser else { return false }
        if u.permissions.operativeMode { return false }
        if u.isSuperAdmin || u.permissions.adminAccess { return true }
        return u.permissions.manager && u.permissions.smallWorks
    }
    
    private var smallWorksProjects: [Project] {
        projectStore.smallWorks
    }
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                WorksDashboardPalette.bg.ignoresSafeArea()
                smallWorksRootContent
            }
            .navigationTitle("Small works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(WorksDashboardPalette.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("")
                        .accessibilityHidden(true)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                    }) {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(WorksDashboardPalette.ink)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(WorksDashboardPalette.soft)
                            .clipShape(Circle())
                    }
                        .accessibilityIdentifier("smallWorks.gobacktoprevioustab")
                }
                if canCreateSmallWorks {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingCreateSmallWorks = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(WorksDashboardListStyle.smallWorks.accent)
                                .clipShape(Circle())
                        }
                        .accessibilityIdentifier("smallWorks.add")
                        .accessibilityLabel("New small work")
                    }
                }
            }
            .navigationBarBackButtonHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("resetNavigationForTab"))) { notification in
                if let userInfo = notification.userInfo,
                   let tab = userInfo["tab"] as? Int,
                   tab == 2 {
                    // Reset navigation to root
                    navigationPath.removeLast(navigationPath.count)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("selectTab"))) { notification in
                if let userInfo = notification.userInfo,
                   let tab = userInfo["tab"] as? Int,
                   tab == 2 {
                    // Reset navigation when Small Works tab is selected
                    navigationPath.removeLast(navigationPath.count)
                    selectedStatus = .active
                }
            }
            .onAppear {
                if selectedStatus == .inactive || selectedStatus == nil {
                    selectedStatus = .active
                }
            }
            .task {
                await refreshDeadlineAssignedProjectIds()
            }
            .sheet(isPresented: $showingEditProject) {
                if let project = selectedProject {
                    EditProjectView(project: project)
                        .environmentObject(projectStore)
                        .environmentObject(operativeStore)
                        .environmentObject(userStore)
                }
            }
            .sheet(isPresented: $showingCreateSmallWorks) {
                CreateSmallWorksView()
                    .environmentObject(projectStore)
                    .environmentObject(operativeStore)
                    .environmentObject(notificationService)
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
            }
            .background(
                Color.clear
                    .preference(key: HideBottomMenuKey.self, value: false)
            )
        }
    }

    private var showsBlockingLoader: Bool {
        let storeHasSmallWorks = !projectStore.smallWorks.isEmpty
        if projectStore.isLoading && !storeHasSmallWorks && smallWorksBeforeStatusFilter.isEmpty {
            return true
        }
        return false
    }

    private var isWaitingForVisibilityData: Bool {
        guard userStore.isOperativeMode() else { return false }
        if operativeStore.isLoading || bookingStore.isLoading { return true }
        return userStore.currentUser == nil
    }

    private var smallWorksRootContent: some View {
        Group {
            if showsBlockingLoader {
                ProgressView("Loading small works...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        WorksDashboardHero(style: .smallWorks)
                        WorksDashboardStatsRow(counts: listCounts, selectedStatus: $selectedStatus)
                            .padding(.bottom, 14)
                        WorksDashboardSearchRow(text: $searchText, placeholder: WorksDashboardListStyle.smallWorks.searchPlaceholder) {
                            Menu {
                                Button("All · \(listCounts.all)") { selectedStatus = nil }
                                    .accessibilityIdentifier("smallWorks.filter.all")
                                Button("Active · \(listCounts.active)") { selectedStatus = .active }
                                    .accessibilityIdentifier("smallWorks.filter.active")
                                Button("Upcoming · \(listCounts.upcoming)") { selectedStatus = .upcoming }
                                    .accessibilityIdentifier("smallWorks.filter.upcoming")
                                Button("Completed · \(listCounts.completed)") { selectedStatus = .completed }
                                    .accessibilityIdentifier("smallWorks.filter.completed")
                            } label: {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(WorksDashboardListStyle.smallWorks.accent)
                            }
                                .accessibilityIdentifier("smallWorks.all")
                        }
                        .padding(.bottom, 12)
                        filterChipsRow
                            .padding(.bottom, 14)
                        if isWaitingForVisibilityData {
                            ProgressView("Finding jobs assigned to you...")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        } else if searchFilteredSmallWorks.isEmpty {
                            if filteredSmallWorks.isEmpty {
                                emptyStateView
                            } else {
                                emptySearchState
                            }
                        } else {
                            LazyVStack(spacing: 13) {
                                ForEach(searchFilteredSmallWorks) { project in
                                    NavigationLink(value: project) {
                                        WorksDashboardCard(
                                            project: project,
                                            listAccent: WorksDashboardListStyle.smallWorks.accent,
                                            showsClientAndManager: !userStore.isOperativeMode()
                                        )
                                        .environmentObject(operativeStore)
                                    }
                                    .accessibilityIdentifier("smallWorks.row.\(project.id)")
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.bottom, 8)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                }
                .navigationDestination(for: Project.self) { project in
                    ProjectDetailView(project: project)
                        .environmentObject(bookingStore)
                        .environmentObject(operativeStore)
                        .environmentObject(projectStore)
                        .background(
                            Color.clear
                                .preference(key: HideBottomMenuKey.self, value: true)
                        )
                }
                .refreshable {
                    projectStore.loadData()
                }
            }
        }
    }

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                WorksRevampFilterChip(
                    title: "All · \(listCounts.all)",
                    isSelected: selectedStatus == nil,
                    selectedForeground: WorksDashboardPalette.ink,
                    selectedFill: WorksDashboardListStyle.smallWorks.accent,
                    titleFont: .subheadline.weight(.semibold),
                    horizontalPadding: 15,
                    verticalPadding: 9
                ,
                    accessibilityIdentifier: "smallWorks.filter.all",
                    action: { selectedStatus = nil }
                )
                WorksRevampFilterChip(
                    title: "Active · \(listCounts.active)",
                    isSelected: selectedStatus == .active,
                    selectedForeground: WorksDashboardPalette.ink,
                    selectedFill: WorksDashboardListStyle.smallWorks.accent,
                    titleFont: .subheadline.weight(.semibold),
                    horizontalPadding: 15,
                    verticalPadding: 9
                ,
                    accessibilityIdentifier: "smallWorks.filter.active",
                    action: { selectedStatus = .active }
                )
                WorksRevampFilterChip(
                    title: "Upcoming · \(listCounts.upcoming)",
                    isSelected: selectedStatus == .upcoming,
                    selectedForeground: WorksDashboardPalette.ink,
                    selectedFill: WorksDashboardListStyle.smallWorks.accent,
                    titleFont: .subheadline.weight(.semibold),
                    horizontalPadding: 15,
                    verticalPadding: 9
                ,
                    accessibilityIdentifier: "smallWorks.filter.upcoming",
                    action: { selectedStatus = .upcoming }
                )
                WorksRevampFilterChip(
                    title: "Completed · \(listCounts.completed)",
                    isSelected: selectedStatus == .completed,
                    selectedForeground: WorksDashboardPalette.ink,
                    selectedFill: WorksDashboardListStyle.smallWorks.accent,
                    titleFont: .subheadline.weight(.semibold),
                    horizontalPadding: 15,
                    verticalPadding: 9
                ,
                    accessibilityIdentifier: "smallWorks.filter.completed",
                    action: { selectedStatus = .completed }
                )
            }
        }
    }

    private var searchFilteredSmallWorks: [Project] {
        let base = filteredSmallWorks
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { p in
            p.jobNumber.lowercased().contains(q)
                || p.siteName.lowercased().contains(q)
                || p.siteAddress.lowercased().contains(q)
                || p.client.name.lowercased().contains(q)
        }
    }

    private var emptySearchState: some View {
        Text("No small works match your search.")
            .font(.subheadline)
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text(emptyStateTitle)
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text(emptyStateMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if isEmptyDueToStatusFilterOnly {
                Button("Show all small works") {
                    selectedStatus = nil
                }
                .accessibilityIdentifier("smallWorks.showAllSmallWorks")
                .buttonStyle(.borderedProminent)
            } else if projectStore.lastWorkLoadUnreliable || projectStore.errorMessage != nil || isUnmatchedOperativeWithJobs {
                Button("Retry") {
                    projectStore.loadData()
                }
                .accessibilityIdentifier("smallWorks.retry")
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal)
    }

    private var emptyStateIcon: String {
        if projectStore.lastWorkLoadUnreliable || projectStore.errorMessage != nil {
            return "wifi.exclamationmark"
        }
        return "hammer.fill"
    }

    private var emptyStateTitle: String {
        if isEmptyDueToStatusFilterOnly {
            return "No small works in this filter"
        }
        if isUnmatchedOperativeWithJobs {
            return "Jobs couldn’t be matched to you"
        }
        if projectStore.lastWorkLoadUnreliable || projectStore.errorMessage != nil {
            return "Couldn’t load small works"
        }
        return "No small works found"
    }

    private var emptyStateMessage: String {
        if isEmptyDueToStatusFilterOnly {
            return "The current filter hides older or completed jobs. Choose “All” or “Completed” above to see everything."
        }
        if isUnmatchedOperativeWithJobs {
            return "Your account isn’t matched to an operative record yet, so assigned jobs can’t be listed. Pull to refresh, or ask an admin to check the email on your operative profile."
        }
        if projectStore.lastWorkLoadUnreliable || projectStore.errorMessage != nil {
            return "This is a load problem, not deleted jobs. Pull down to retry. Existing jobs stay on the server and on web."
        }
        if canCreateSmallWorks {
            return WorksDashboardListStyle.smallWorks.emptyCreatePrompt
        }
        return "Nothing here right now."
    }

    private var isUnmatchedOperativeWithJobs: Bool {
        userStore.isOperativeMode()
            && resolvedCurrentOperative == nil
            && !projectStore.smallWorks.isEmpty
    }
    
    /// Small works with operative visibility applied but without status chip filter.
    private var smallWorksBeforeStatusFilter: [Project] {
        var works = smallWorksProjects
        
        if userStore.isOperativeMode() {
            guard let operative = resolvedCurrentOperative,
                  let currentUserId = userStore.currentUser?.id else {
                return []
            }
            let assignedProjectIds = Set(bookingStore.bookings
                .filter {
                    $0.operativeId == operative.id &&
                    ($0.status == .confirmed || $0.status == .tentative)
                }
                .map { $0.projectId })
            works = works.filter {
                (assignedProjectIds.contains($0.id) || deadlineAssignedProjectIds.contains($0.id))
                    && !$0.hiddenOperativeUserIds.contains(currentUserId)
            }
        } else if let currentUser = userStore.currentUser,
                  !userStore.hasAdminAccess(),
                  currentUser.permissions.manager {
            works = works.filter { !$0.hiddenManagerUserIds.contains(currentUser.id) }
        }

        var seen = Set<UUID>()
        return works.filter { seen.insert($0.id).inserted }
    }

    private func refreshDeadlineAssignedProjectIds() async {
        guard userStore.isOperativeMode(),
              let userId = userStore.currentUser?.id,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId ?? userStore.currentUser?.organizationId else {
            await MainActor.run { deadlineAssignedProjectIds = [] }
            return
        }
        let ids = await firebaseBackend.loadDeadlineAssignedProjectIds(userId: userId, organizationId: orgId)
        await MainActor.run { deadlineAssignedProjectIds = ids }
    }

    private var resolvedCurrentOperative: Operative? {
        let normalizedEmail = userStore.currentUser?.email
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedEmail, !normalizedEmail.isEmpty,
           let byEmail = operativeStore.allOperatives.first(where: {
               $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedEmail
           }) {
            return byEmail
        }
        let first = userStore.currentUser?.firstName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let last = userStore.currentUser?.surname.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !first.isEmpty || !last.isEmpty else { return nil }
        return operativeStore.allOperatives.first(where: {
            $0.firstName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == first &&
            $0.lastName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == last
        })
    }
    
    private var isEmptyDueToStatusFilterOnly: Bool {
        guard selectedStatus != nil else { return false }
        return !smallWorksBeforeStatusFilter.isEmpty && filteredSmallWorks.isEmpty
    }
    
    private var filteredSmallWorks: [Project] {
        var works = smallWorksBeforeStatusFilter
        
        if let status = selectedStatus {
            works = works.filter { $0.status == status }
        }
        
        return works
    }
}

#Preview {
    SmallWorksView()
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(BookingStore())
}

