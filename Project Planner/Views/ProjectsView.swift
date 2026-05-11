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
    @EnvironmentObject var notificationService: NotificationService
    /// Default to all projects so completed / past jobs are not hidden (Active only includes jobs whose dates span today).
    @State private var selectedStatus: ProjectStatus? = nil
    @State private var navigationPath = NavigationPath()
    @State private var searchText = ""
    @State private var showingCreateProject = false

    private var listCounts: WorksListStatusCounts {
        WorksListStatusCounts.from(projectsBeforeStatusFilter)
    }

    private var canCreateProjects: Bool {
        guard let u = userStore.currentUser else { return false }
        if u.permissions.operativeMode { return false }
        if u.isSuperAdmin || u.permissions.adminAccess { return true }
        return u.permissions.manager && u.permissions.projects
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                ProjectWorksRevampColors.canvas.ignoresSafeArea()
                projectsRootContent
            }
            .navigationTitle("Projects")
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
                if canCreateProjects {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingCreateProject = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(ProjectWorksRevampColors.blue)
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("New project")
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
            .sheet(isPresented: $showingCreateProject) {
                CreateProjectView()
                    .environmentObject(projectStore)
                    .environmentObject(operativeStore)
                    .environmentObject(notificationService)
                    .environmentObject(userStore)
            }
        }
    }

    private var projectsRootContent: some View {
        Group {
            if projectStore.isLoading {
                ProgressView("Loading projects...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if projectsBeforeStatusFilter.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        WorksListStatsRow(counts: listCounts)
                        WorksListSearchRow(text: $searchText, placeholder: "Search projects, addresses…") {
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
                        if searchFilteredProjects.isEmpty {
                            if filteredProjects.isEmpty {
                                emptyStateView
                            } else {
                                emptySearchState
                            }
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(searchFilteredProjects) { project in
                                    NavigationLink(value: project) {
                                        ProjectDetailRowView(project: project)
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

    private var searchFilteredProjects: [Project] {
        let base = filteredProjects
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
        Text("No projects match your search.")
            .font(.subheadline)
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
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

struct ProjectDetailRowView: View {
    let project: Project
    @EnvironmentObject private var userStore: UserStore
    @EnvironmentObject private var operativeStore: OperativeStore

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
                    HStack(spacing: 8) {
                        Text(project.jobNumber)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .tracking(-0.2)
                        jobTypePill
                    }
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

    private var jobTypePill: some View {
        Text(jobTypeLabel)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.jobTypePillInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ProjectWorksRevampColors.jobTypePillBg)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .tracking(0.3)
    }

    private var jobTypeLabel: String {
        if let c = project.customJobType, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return c.uppercased()
        }
        return project.jobType.rawValue
    }

    private var managerDisplayName: String {
        if let managerId = project.managerId,
           let manager = operativeStore.allManagers.first(where: { $0.id == managerId }) {
            return "\(manager.firstName) \(manager.lastName)"
        }
        return project.manager.displayName
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
        case .active: return Color(red: 0.882, green: 0.961, blue: 0.933) // #E1F5EE
        case .upcoming: return Color(red: 1, green: 0.965, blue: 0.882)
        case .completed, .inactive: return Color(red: 0.949, green: 0.953, blue: 0.961) // #F2F3F5
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
        .environmentObject(OperativeStore())
        .environmentObject(BookingStore())
        .environmentObject(UserStore())
        .environmentObject(AppSettingsStore())
        .environmentObject(NotificationService())
}
