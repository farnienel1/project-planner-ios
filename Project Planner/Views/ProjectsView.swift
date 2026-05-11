//
//  ProjectsView.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var appSettings: AppSettingsStore
    /// Default to all projects so completed / past jobs are not hidden (Active only includes jobs whose dates span today).
    @State private var selectedStatus: ProjectStatus? = nil
    @State private var navigationPath = NavigationPath()
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(alignment: .leading, spacing: 0) {
                // Title row (indented; large nav title is not affected by content padding)
                Text("Projects")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                
                // Filter Section
                filterSection
                
                // Projects List
                projectsList
            }
            .padding(.horizontal, 16)
            .navigationTitle("Projects")
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
            .background(
                // This will be overridden by child views that set preference to true
                Color.clear
                    .preference(key: HideBottomMenuKey.self, value: false)
            )
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("resetNavigationForTab"))) { notification in
                if let userInfo = notification.userInfo,
                   let tab = userInfo["tab"] as? Int,
                   tab == 1 {
                    // Reset navigation to root
                    navigationPath.removeLast(navigationPath.count)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("selectTab"))) { notification in
                if let userInfo = notification.userInfo,
                   let tab = userInfo["tab"] as? Int,
                   tab == 1 {
                    // Reset navigation when Projects tab is selected
                    navigationPath.removeLast(navigationPath.count)
                    selectedStatus = nil
                }
            }
            .onAppear {
                // Ensure active or All is selected (Inactive filter removed from UI)
                if selectedStatus == .inactive {
                    selectedStatus = .active
                }
            }
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
    
    private var projectsList: some View {
        Group {
            if projectStore.isLoading {
                ProgressView("Loading projects...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredProjects.isEmpty {
                emptyStateView
            } else {
                List(filteredProjects) { project in
                    NavigationLink(value: project) {
                        ProjectDetailRowView(project: project)
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
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No projects found")
                .font(.headline)
                .foregroundColor(.secondary)
            
            if isEmptyDueToStatusFilterOnly {
                Text("The current filter hides older or completed jobs. Choose “All” or “Completed” above to see everything.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Show all projects") {
                    selectedStatus = nil
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Get started by adding your first project")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    /// Regular projects (not small works), with operative visibility applied but without status chip filter.
    private var projectsBeforeStatusFilter: [Project] {
        var projects = projectStore.projects.filter { $0.jobType != .smallWorks }
        
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
            projects = projects.filter {
                assignedProjectIds.contains($0.id) && !$0.hiddenOperativeUserIds.contains(currentUserId)
            }
        } else if let currentUser = userStore.currentUser,
                  !currentUser.isSuperAdmin,
                  !currentUser.permissions.adminAccess,
                  currentUser.permissions.manager {
            projects = projects.filter { !$0.hiddenManagerUserIds.contains(currentUser.id) }
        }
        
        return projects
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
        return !projectsBeforeStatusFilter.isEmpty && filteredProjects.isEmpty
    }
    
    private var filteredProjects: [Project] {
        var projects = projectsBeforeStatusFilter
        
        if let status = selectedStatus {
            projects = projects.filter { $0.status == status }
        }
        
        return projects
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
    }
}

struct ProjectDetailRowView: View {
    let project: Project
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
                    Label(project.manager.displayName, systemImage: "person")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Label(dateRange, systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Progress bar for active projects
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
        Text(project.jobType.rawValue)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(jobTypeColor.opacity(0.2))
            .foregroundColor(jobTypeColor)
            .cornerRadius(4)
    }
    
    private var dateRange: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return "\(formatter.string(from: project.startDate)) - \(formatter.string(from: project.endDate))"
    }
    
    private var statusColor: Color {
        switch project.status {
        case .upcoming: return .blue
        case .active: return .green
        case .completed: return .gray
        case .inactive: return .red
        }
    }
    
    private var jobTypeColor: Color {
        switch project.jobType {
        case .catA: return .blue
        case .catB: return .green
        case .smallWorks: return .orange
        case .maintenance: return .purple
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
                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
        }
    }
    
    private var progressPercentage: Double {
        let now = Date()
        let totalDuration = project.endDate.timeIntervalSince(project.startDate)
        let elapsed = now.timeIntervalSince(project.startDate)
        return min(max(elapsed / totalDuration, 0), 1)
    }
}

struct AddProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var projectStore: ProjectStore
    
    @State private var jobNumber = ""
    @State private var siteName = ""
    @State private var siteAddress = ""
    @State private var selectedClient: Client?
    @State private var startDate = Date()
    @State private var endDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var selectedJobType: JobType = .catA
    @State private var selectedManager: ManagerLegacy = .farnie
    @State private var description = ""
    @State private var notes = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("Project Details") {
                    TextField("Job Number", text: $jobNumber)
                    TextField("Site Name", text: $siteName)
                    TextField("Site Address", text: $siteAddress, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section("Client & Type") {
                    Picker("Client", selection: $selectedClient) {
                        Text("Select Client").tag(nil as Client?)
                        ForEach(projectStore.clients) { client in
                            Text(client.name).tag(client as Client?)
                        }
                    }
                    
                    Picker("Job Type", selection: $selectedJobType) {
                        ForEach(JobType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                }
                
                Section("Schedule") {
                    DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                    DatePicker("End Date", selection: $endDate, displayedComponents: .date)
                    
                    Picker("Manager", selection: $selectedManager) {
                        ForEach(ManagerLegacy.allCases) { manager in
                            Text(manager.displayName).tag(manager)
                        }
                    }
                }
                
                Section("Additional Info") {
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Add Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveProject()
                    }
                    .disabled(!isFormValid)
                }
            }
        }
    }
    
    private var isFormValid: Bool {
        !jobNumber.isEmpty && 
        !siteName.isEmpty && 
        !siteAddress.isEmpty && 
        selectedClient != nil
    }
    
    private func saveProject() {
        guard let client = selectedClient else { return }
        
        let project = Project(
            jobNumber: jobNumber,
            siteName: siteName,
            siteAddress: siteAddress,
            client: client,
            startDate: startDate,
            endDate: endDate,
            jobType: selectedJobType,
            manager: selectedManager,
            description: description.isEmpty ? nil : description,
            notes: notes.isEmpty ? nil : notes
        )
        
        Task {
            do {
                try await projectStore.addProject(project)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                print("🔥🔥🔥 DEBUG: Error adding project: \(error.localizedDescription)")
                // You might want to show an alert to the user here
            }
        }
    }
}

#Preview {
    ProjectsView()
        .environmentObject(ProjectStore())
}
