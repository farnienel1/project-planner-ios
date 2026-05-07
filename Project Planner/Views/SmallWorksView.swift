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
    @EnvironmentObject var appSettings: AppSettingsStore
    @State private var selectedStatus: ProjectStatus? = nil
    @State private var selectedProject: Project? = nil
    @State private var showingEditProject = false
    @State private var navigationPath = NavigationPath()
    
    private var smallWorksProjects: [Project] {
        projectStore.smallWorks
    }
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(alignment: .leading, spacing: 0) {
                // Title row (indented; large nav title is not affected by content padding)
                Text("Small Works")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                
                // Filter Section
                filterSection
                
                // Small Works List
                smallWorksList
            }
            .padding(.horizontal, 16)
            .navigationTitle("Small Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                    }) {
                        Image(systemName: "chevron.left")
                            .foregroundColor(Color.theme.primary(for: appSettings.settings.colorScheme))
                            .font(.system(size: 17, weight: .semibold))
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
            .background(
                // This will be overridden by child views that set preference to true
                Color.clear
                    .preference(key: HideBottomMenuKey.self, value: false)
            )
        }
    }
    
    private var filterSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                FilterChip(
                    title: "All",
                    isSelected: selectedStatus == nil,
                    action: { selectedStatus = nil }
                )
                
                FilterChip(
                    title: "Active",
                    isSelected: selectedStatus == .active,
                    action: { selectedStatus = .active }
                )
                
                ForEach(ProjectStatus.allCases.filter { $0 != .active && $0 != .inactive }, id: \.self) { status in
                    FilterChip(
                        title: status.rawValue,
                        isSelected: selectedStatus == status,
                        action: { selectedStatus = status }
                    )
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
    
    private var smallWorksList: some View {
        Group {
            if projectStore.isLoading {
                ProgressView("Loading small works...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSmallWorks.isEmpty {
                emptyStateView
            } else {
                List(filteredSmallWorks) { project in
                    NavigationLink(value: project) {
                        SmallWorksDetailRowView(project: project)
                            .environmentObject(userStore)
                            .environmentObject(operativeStore)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                }
                .navigationDestination(for: Project.self) { project in
                    ProjectDetailView(project: project)
                        .environmentObject(bookingStore)
                        .environmentObject(operativeStore)
                        .environmentObject(projectStore)
                        .background(
                            // Use background to ensure preference propagates
                            Color.clear
                                .preference(key: HideBottomMenuKey.self, value: true)
                        )
                }
                .listStyle(PlainListStyle())
                .refreshable {
                    projectStore.loadData()
                }
            }
        }
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
                  !currentUser.isSuperAdmin,
                  !currentUser.permissions.adminAccess,
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
                .font(.headline)
                .fontWeight(.bold)
            Text(project.siteName)
                .font(.subheadline)
                .foregroundColor(.primary)
            Text(project.siteAddress)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    private var fullDetailCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.jobNumber)
                        .font(.headline)
                        .fontWeight(.bold)
                    
                    Text(project.siteName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    statusBadge
                    jobTypeBadge
                }
            }
            
            // Details
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label(project.client.name, systemImage: "building.2")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Label(project.siteAddress, systemImage: "location")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Label(managerDisplayName, systemImage: "person")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Label(dateRange, systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Progress bar for active small works
            if project.status == .active {
                progressBar
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    private var statusBadge: some View {
        Text(project.status.rawValue)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.2))
            .foregroundColor(statusColor)
            .cornerRadius(4)
    }
    
    private var jobTypeBadge: some View {
        Text(project.customJobType ?? "N/A")
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.2))
            .foregroundColor(.orange)
            .cornerRadius(4)
    }
    
    private var dateRange: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return "\(formatter.string(from: project.startDate)) - \(formatter.string(from: project.endDate))"
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
    
    private var statusColor: Color {
        switch project.status {
        case .upcoming: return .blue
        case .active: return .green
        case .completed: return .gray
        case .inactive: return .red
        }
    }
    
    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Progress")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(progressPercentage * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ProgressView(value: progressPercentage)
                .progressViewStyle(LinearProgressViewStyle(tint: .orange))
        }
    }
    
    private var progressPercentage: Double {
        let now = Date()
        let totalDuration = project.endDate.timeIntervalSince(project.startDate)
        let elapsed = now.timeIntervalSince(project.startDate)
        return min(max(elapsed / totalDuration, 0), 1)
    }
}

#Preview {
    SmallWorksView()
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(BookingStore())
}

