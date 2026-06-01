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
    @State private var selectedStatus: ProjectStatus? = nil
    @State private var selectedProject: Project? = nil
    @State private var showingEditProject = false
    @State private var navigationPath = NavigationPath()
    @State private var searchText = ""
    @State private var showingCreateSmallWorks = false

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
                ProjectWorksRevampColors.canvas.ignoresSafeArea()
                smallWorksRootContent
            }
            .navigationTitle("Small works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                    }) {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Color.white)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(ProjectWorksRevampColors.searchBorder, lineWidth: 0.5))
                    }
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
                                .background(ProjectWorksRevampColors.blue)
                                .clipShape(Circle())
                        }
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
                    selectedStatus = nil
                }
            }
            .onAppear {
                if selectedStatus == .inactive {
                    selectedStatus = nil
                }
            }
            .sheet(isPresented: $showingEditProject) {
                if let project = selectedProject {
                    EditProjectView(project: project)
                        .environmentObject(projectStore)
                        .environmentObject(operativeStore)
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

    private var smallWorksRootContent: some View {
        Group {
            if projectStore.isLoading {
                ProgressView("Loading small works...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if smallWorksBeforeStatusFilter.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        WorksListStatsRow(counts: listCounts)
                        WorksListSearchRow(text: $searchText, placeholder: "Search small works…") {
                            Menu {
                                Button("All · \(listCounts.all)") { selectedStatus = nil }
                                Button("Active · \(listCounts.active)") { selectedStatus = .active }
                                Button("Upcoming · \(listCounts.upcoming)") { selectedStatus = .upcoming }
                                Button("Completed · \(listCounts.completed)") { selectedStatus = .completed }
                            } label: {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.blue)
                            }
                        }
                        filterChipsRow
                        if searchFilteredSmallWorks.isEmpty {
                            if filteredSmallWorks.isEmpty {
                                emptyStateView
                            } else {
                                emptySearchState
                            }
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(searchFilteredSmallWorks) { project in
                                    NavigationLink(value: project) {
                                        SmallWorksDetailRowView(project: project)
                                            .environmentObject(userStore)
                                            .environmentObject(operativeStore)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.bottom, 8)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
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
                    selectedForeground: ProjectWorksRevampColors.activeGreen
                ) { selectedStatus = nil }
                WorksRevampFilterChip(
                    title: "Active · \(listCounts.active)",
                    isSelected: selectedStatus == .active,
                    selectedForeground: ProjectWorksRevampColors.activeGreen
                ) { selectedStatus = .active }
                WorksRevampFilterChip(
                    title: "Upcoming · \(listCounts.upcoming)",
                    isSelected: selectedStatus == .upcoming,
                    selectedForeground: ProjectWorksRevampColors.upcomingAmber
                ) { selectedStatus = .upcoming }
                WorksRevampFilterChip(
                    title: "Completed · \(listCounts.completed)",
                    isSelected: selectedStatus == .completed,
                    selectedForeground: ProjectWorksRevampColors.muted
                ) { selectedStatus = .completed }
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
            Image(systemName: "hammer.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No small works found")
                .font(.headline)
                .foregroundColor(.secondary)
            
            if isEmptyDueToStatusFilterOnly {
                Text("The current filter hides older or completed jobs. Choose “All” or “Completed” above to see everything.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Show all small works") {
                    selectedStatus = nil
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Add small works via the menu on the home screen.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
                assignedProjectIds.contains($0.id) && !$0.hiddenOperativeUserIds.contains(currentUserId)
            }
        } else if let currentUser = userStore.currentUser,
                  !userStore.hasAdminAccess(),
                  currentUser.permissions.manager {
            works = works.filter { !$0.hiddenManagerUserIds.contains(currentUser.id) }
        }
        
        return works
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

// Custom row view for Small Works - same style as ProjectDetailRowView but tailored for Small Works
struct SmallWorksDetailRowView: View {
    let project: Project
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject private var userStore: UserStore
    
    var body: some View {
        Group {
            if userStore.isOperativeMode() {
                operativeCompactCard
            } else {
                fullDetailCard
            }
        }
    }
    
    private var operativeCompactCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.jobNumber)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Text(project.siteName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Text(project.siteAddress)
                .font(.system(size: 11))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }
    
    private var fullDetailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.jobNumber)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .tracking(-0.2)
                    Text(project.siteName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                }
                Spacer(minLength: 8)
                statusPill
            }

            VStack(alignment: .leading, spacing: 6) {
                rowIcon("building.2", project.client.name)
                rowIcon("mappin.and.ellipse", project.siteAddress)
                rowIcon("person", managerDisplayName)
                rowIcon("calendar", dateRangeDisplay)
            }

            listProgressSection
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func rowIcon(_ system: String, _ text: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: system)
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
                .frame(width: 14, alignment: .center)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dateRangeDisplay: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return "\(f.string(from: project.startDate)) – \(f.string(from: project.endDate))"
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            if project.status == .completed {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
            } else {
                Circle()
                    .fill(statusAccent)
                    .frame(width: 5, height: 5)
            }
            Text(project.status.rawValue)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(statusPillForeground)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(statusPillBackground)
        .clipShape(Capsule())
    }

    private var statusAccent: Color {
        switch project.status {
        case .active: return ProjectWorksRevampColors.activeGreen
        case .upcoming: return ProjectWorksRevampColors.upcomingAmber
        case .completed, .inactive: return ProjectWorksRevampColors.muted
        }
    }

    private var statusPillForeground: Color {
        switch project.status {
        case .active: return ProjectWorksRevampColors.activeGreen
        case .upcoming: return ProjectWorksRevampColors.upcomingAmber
        case .completed, .inactive: return ProjectWorksRevampColors.muted
        }
    }

    private var statusPillBackground: Color {
        switch project.status {
        case .active: return Color(red: 0.882, green: 0.961, blue: 0.933)
        case .upcoming: return Color(red: 1, green: 0.965, blue: 0.882)
        case .completed, .inactive: return Color(red: 0.949, green: 0.953, blue: 0.961)
        }
    }

    private var listProgressSection: some View {
        let pct = WorksListProgress.fraction(for: project)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Progress")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Spacer()
                Text("\(Int(pct * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(project.status == .completed ? ProjectWorksRevampColors.muted : ProjectWorksRevampColors.ink)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ProjectWorksRevampColors.border)
                        .frame(height: 5)
                    Capsule()
                        .fill(
                            project.status == .completed
                                ? AnyShapeStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
                                : AnyShapeStyle(
                                    LinearGradient(
                                        colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                        .frame(width: max(4, geo.size.width * pct), height: 5)
                }
            }
            .frame(height: 5)
        }
        .padding(.top, 4)
    }
    
    private var managerDisplayName: String {
        // If managerId exists, try to resolve the actual manager name
        if let managerId = project.managerId {
            if let manager = operativeStore.allManagers.first(where: { $0.id == managerId }) {
                return "\(manager.firstName) \(manager.lastName)"
            } else {
                // Manager ID exists but manager not found in list - might not be loaded yet
                print("🔥🔥🔥 DEBUG: [SmallWorksCard] Manager ID \(managerId.uuidString) not found in managers list (count: \(operativeStore.allManagers.count))")
            }
        }
        // Otherwise, fall back to the legacy enum display name
        return project.manager.displayName
    }
    
}

#Preview {
    SmallWorksView()
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(BookingStore())
}

