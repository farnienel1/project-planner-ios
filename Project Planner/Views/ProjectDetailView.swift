//
//  ProjectDetailView.swift
//  Project Planner
//
//  Created by Assistant on 22/10/2025.
//

import SwiftUI
import MapKit
import UniformTypeIdentifiers
import PhotosUI
import FirebaseAuth

fileprivate enum TaskTab: String, CaseIterable, Identifiable {
    case active = "Active"
    case completed = "Completed"
    var id: String { rawValue }
}

fileprivate enum TaskFilterType: String, CaseIterable, Identifiable {
    case all = "All Tasks"
    case operative = "By Operative"
    case manager = "By Manager"
    case dateRange = "Date Range"
    
    var id: String { rawValue }
}

fileprivate struct TaskFilter {
    var type: TaskFilterType = .all
    var operativeId: UUID?
    var managerId: UUID?
    var dateRange: ClosedRange<Date>?
    
    mutating func reset() {
        type = .all
        operativeId = nil
        managerId = nil
        dateRange = nil
    }
}

struct ProjectDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService
    
    let project: Project
    
    @State private var selectedWeek: Date = Date()
    @State private var showingScheduleOperative = false
    @State private var showingEditProject = false
    @State private var showingMapOptions = false
    @State private var region: MKCoordinateRegion
    @State private var mapItem: MKMapItem?
    @available(iOS 17.0, *)
    @State private var cameraPosition: MapCameraPosition = .automatic
    @EnvironmentObject var taskStore: ProjectTaskStore
    
    private enum DetailTile: String, CaseIterable, Identifiable {
        case scheduling = "Scheduling"
        case tasks = "My Tasks"
        case materials = "Materials"
        case settings = "Settings"
        case location = "Location"
        
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .scheduling: return "calendar.badge.clock"
            case .tasks: return "checklist"
            case .materials: return "cube.box.fill"
            case .settings: return "gearshape"
            case .location: return "map"
            }
        }
    }
    
    
    // Initialize region from project address
    init(project: Project) {
        self.project = project
        // Default to London coordinates - will be updated if address is geocoded
        let defaultRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        _region = State(initialValue: defaultRegion)
        if #available(iOS 17.0, *) {
            _cameraPosition = State(initialValue: .region(defaultRegion))
        }
    }
    
    @Environment(\.navigationDepth) private var navigationDepth
    @State private var isCompactWeekView = false
    @State private var showingAddTask = false
    @State private var showingTaskFilter = false
    @State private var selectedTaskTab: TaskTab = .active
    @State private var taskFilter = TaskFilter()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                projectHeader
                overviewTiles
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(Color.theme.primary)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            
        }
        .preference(key: HideBottomMenuKey.self, value: true)
        .background(
            // Use background to ensure preference propagates through NavigationStack
            Color.clear
                .preference(key: HideBottomMenuKey.self, value: true)
        )
        .sheet(isPresented: $showingScheduleOperative) {
            ScheduleOperativeView(project: project)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(projectStore)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
                .preference(key: HideBottomMenuKey.self, value: true)
        }
        .sheet(isPresented: $showingEditProject) {
            EditProjectView(project: project)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .preference(key: HideBottomMenuKey.self, value: true)
        }
        .confirmationDialog("Open in Maps", isPresented: $showingMapOptions, titleVisibility: .visible) {
            Button("Open in Google Maps") {
                openInGoogleMaps()
            }
            Button("Open in Apple Maps") {
                openInAppleMaps()
            }
            Button("Cancel", role: .cancel) {
                showingMapOptions = false
            }
        } message: {
            Text("Choose how you'd like to open the location")
        }
        .onAppear {
            geocodeAddress()
            loadWeekBookings()
            loadWeekViewPreference()
            if taskStore.tasks.isEmpty {
                Task {
                    await taskStore.loadData()
                }
            }
        }
        .onChange(of: selectedWeek) { _, _ in
            loadWeekBookings()
        }
        .onDisappear {
            // When leaving, the preference will automatically reset
            // because the view is removed from the hierarchy
        }
    }
    
    // MARK: - Project Header
    
    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.jobNumber)
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(Color.theme.primary)
            
            Text(project.siteName)
                .font(.title2)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var overviewTiles: some View {
        let availableTiles: [DetailTile] = userStore.isOperativeMode() 
            ? [.tasks, .materials, .location]
            : DetailTile.allCases
        
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
            ForEach(availableTiles) { tile in
                NavigationLink(destination: tileDestination(for: tile)) {
                    VStack(spacing: 12) {
                        Image(systemName: tile.icon)
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundColor(Color.theme.primary)
                        Text(tile.rawValue)
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.systemBackground))
                            .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                    )
                }
            }
        }
    }
    
    @ViewBuilder
    private func tileDestination(for tile: DetailTile) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                switch tile {
                case .scheduling:
                    schedulingContent
                case .tasks:
                    tasksContent
                case .materials:
                    materialsContent
                case .settings:
                    settingsContent
                case .location:
                    siteLocationSection
                }
            }
            .padding()
        }
        .navigationTitle(tile.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var schedulingContent: some View {
        VStack(spacing: 20) {
            weekNavigation
            scheduleOperativeButton
            weekOverview
        }
    }
    
    // MARK: - Week Navigation
    
    private var weekNavigation: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: { changeWeek(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.theme.primary)
                        .cornerRadius(8)
                }
                
                Spacer()
                
                Button("Change Week") {
                    // Could show date picker here
                }
                .font(.headline)
                .foregroundColor(.white)
                
                Spacer()
                
                Button(action: { changeWeek(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.theme.primary)
                        .cornerRadius(8)
                }
            }
            .padding()
            .background(Color.theme.primary)
            .cornerRadius(12)
            
            Text(weekOfString)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.primary)
        }
    }
    
    // MARK: - Week Overview
    
    private var weekOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Week Overview")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Button(action: toggleWeekViewMode) {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.split.3x1")
                        Text("Change View")
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray5))
                    .cornerRadius(8)
                }
            }
            
            if isCompactWeekView {
                compactWeekOverview
            } else {
                standardWeekOverview
            }
        }
    }
    
    private var standardWeekOverview: some View {
        VStack(spacing: 12) {
            ForEach(weekDays, id: \.self) { day in
                dayBubble(for: day)
            }
        }
    }
    
    private var compactWeekOverview: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(weekDays.prefix(5), id: \.self) { day in
                    compactDayBubble(for: day)
                }
            }
            HStack(spacing: 8) {
                ForEach(weekDays.suffix(2), id: \.self) { day in
                    compactDayBubble(for: day)
                }
                Spacer()
            }
        }
    }
    
    private func dayBubble(for date: Date) -> some View {
        let dayBookings = bookingsForDate(date)
        let isToday = Calendar.current.isDateInToday(date)
        
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE" // Full day name (Monday, Tuesday, etc.)
        let dayName = dayFormatter.string(from: date)
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMM" // Day number and month (1 Jan)
        let dateString = dateFormatter.string(from: date)
        
        return VStack(alignment: .leading, spacing: 12) {
            // Day of week at top left
            HStack {
                Text(dayName)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(isToday ? .white : .primary)
                
                Spacer()
                
                Text(dateString)
                    .font(.subheadline)
                    .foregroundColor(isToday ? .white.opacity(0.9) : .secondary)
            }
            
            // Operatives list
            if !dayBookings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(dayBookings, id: \.id) { booking in
                        let operative = operativeStore.activeOperatives.first { $0.id == booking.operativeId }
                        let operativeName = operative?.name ?? "Unknown Operative"
                        let timeSlotText = booking.timeSlot.displayName
                        
                        HStack {
                            Text(operativeName)
                                .font(.body)
                                .foregroundColor(isToday ? .white : .primary)
                            
                            Spacer()
                            
                            Text(timeSlotText)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(isToday ? .white.opacity(0.9) : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isToday ? Color.white.opacity(0.2) : Color(.systemGray5))
                                .cornerRadius(6)
                        }
                    }
                }
            } else {
                Text("No bookings")
                    .font(.subheadline)
                    .foregroundColor(isToday ? .white.opacity(0.7) : .secondary)
                    .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isToday ? Color.theme.primary : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isToday ? Color.clear : Color(.systemGray4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isToday ? 0.2 : 0.05), radius: isToday ? 4 : 2, x: 0, y: 2)
    }
    
    private func compactDayBubble(for date: Date) -> some View {
        let dayBookings = bookingsForDate(date)
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        let shortDay = formatter.string(from: date)
        let isToday = Calendar.current.isDateInToday(date)
        
        return VStack(alignment: .leading, spacing: 6) {
            Text(shortDay)
                .font(.headline)
                .foregroundColor(isToday ? .white : .primary)
            Text(date, style: .date)
                .font(.caption2)
                .foregroundColor(isToday ? .white.opacity(0.8) : .secondary)
            if let booking = dayBookings.first {
                let operative = operativeStore.activeOperatives.first { $0.id == booking.operativeId }
                Text(operative?.name ?? "Unassigned")
                    .font(.caption2)
                    .lineLimit(2)
                    .foregroundColor(isToday ? .white : .primary)
            } else {
                Text("No bookings")
                    .font(.caption2)
                    .foregroundColor(isToday ? .white.opacity(0.7) : .secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isToday ? Color.theme.primary : Color(.secondarySystemBackground))
        )
    }
    
    // MARK: - Site Location Section
    
    private var siteLocationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(Color.theme.primary)
                Text("Site Location")
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            
            if hasValidAddress {
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.siteAddress)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    
                    Button(action: { showingMapOptions = true }) {
                        Text("Open in Maps")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.theme.primary)
                            .cornerRadius(8)
                    }
                    
                    // Map view
                    if #available(iOS 17.0, *) {
                        Map(position: $cameraPosition, interactionModes: []) {
                            if let coordinate = currentCoordinate {
                                Marker(project.siteName, coordinate: coordinate)
                            }
                        }
                        .frame(height: 200)
                        .cornerRadius(12)
                    } else {
                        Map(coordinateRegion: $region, interactionModes: [])
                            .frame(height: 200)
                            .cornerRadius(12)
                    }
                }
            } else {
                Text("Site Location not available")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    // MARK: - Schedule Operative Button
    
    private var scheduleOperativeButton: some View {
        Button(action: { showingScheduleOperative = true }) {
            Text("Schedule Operative")
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.theme.primary)
                .cornerRadius(12)
        }
    }
    
    // MARK: - Helper Properties
    
    private var hasValidAddress: Bool {
        !project.siteAddress.isEmpty && project.siteAddress != "Site Location not available"
    }
    
    private var weekOfString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "'Week Of' d MMM yyyy"
        return formatter.string(from: weekStartDate)
    }
    
    private var weekStartDate: Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: selectedWeek)
        return calendar.date(from: components) ?? selectedWeek
    }
    
    private var weekDays: [Date] {
        let calendar = Calendar.current
        let start = weekStartDate
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    
    private func filteredTasks(for tab: TaskTab) -> [ProjectTask] {
        var tasks = taskStore.tasks(for: project.id, includeCompleted: true)
        
        switch taskFilter.type {
        case .all:
            break
        case .operative:
            if let operativeId = taskFilter.operativeId {
                tasks = tasks.filter { $0.assignedOperativeId == operativeId }
            }
        case .manager:
            if let managerId = taskFilter.managerId {
                tasks = tasks.filter { $0.assignedManagerId == managerId }
            }
        case .dateRange:
            if let range = taskFilter.dateRange {
                tasks = tasks.filter { task in
                    if let dueDate = task.dueDate {
                        return range.contains(dueDate)
                    }
                    return false
                }
            }
        }
        
        tasks = tasks.filter { tab == .active ? !$0.isCompleted : $0.isCompleted }
        
        // Filter tasks based on user permissions
        if userStore.isOperativeMode() {
            // Operative mode: only show tasks assigned to this operative
            if let currentUserEmail = userStore.currentUser?.email,
               let operative = operativeStore.allOperatives.first(where: { $0.email == currentUserEmail }) {
                tasks = tasks.filter { task in
                    // Check both legacy single assignment and new multiple assignments
                    task.allAssignedOperativeIds.contains(operative.id)
                }
            } else {
                // No operative found for this user, show empty
                tasks = []
            }
        } else {
            // Regular users: Super Admin and Admins see all tasks, others see tasks assigned to them
            if !userStore.canManageUsers() {
                // Not super admin or admin - only show tasks assigned to them
                if userStore.currentUser?.id != nil {
                    // Check if task is assigned to this user (as manager or operative)
                    tasks = tasks.filter { task in
                        // Check if user is assigned as manager or operative
                        // For now, we'll show all tasks if user has project access
                        // This can be refined based on actual assignment logic
                        return true // Show all for now, can be refined
                    }
                }
            }
            // Super Admin and Admins see all tasks (no filtering needed)
        }
        
        return tasks.sorted { $0.createdAt > $1.createdAt }
    }
    
    private func operativeName(for id: UUID?) -> String? {
        guard let id = id else { return nil }
        return operativeStore.allOperatives.first(where: { $0.id == id })?.name
    }
    
    private func operativeNames(for ids: [UUID]) -> [String] {
        ids.compactMap { id in
            operativeStore.allOperatives.first(where: { $0.id == id })?.name
        }
    }
    
    private func managerName(for id: UUID?) -> String? {
        guard let id = id else { return nil }
        return operativeStore.allManagers.first(where: { $0.id == id })?.fullName
    }
    
    private func managerNames(for ids: [UUID]) -> [String] {
        ids.compactMap { id in
            operativeStore.allManagers.first(where: { $0.id == id })?.fullName
        }
    }
    
    private var managerDisplayName: String {
        if let managerId = project.managerId,
           let manager = operativeStore.managers.first(where: { $0.id == managerId }) {
            return manager.fullName
        }
        return project.manager.displayName
    }
    
    private var taskFilterDescription: String {
        switch taskFilter.type {
        case .all:
            return "Showing all tasks"
        case .operative:
            if let name = operativeName(for: taskFilter.operativeId) {
                return "Filtered by operative: \(name)"
            }
            return "Filtered by operative"
        case .manager:
            if let name = managerName(for: taskFilter.managerId) {
                return "Filtered by manager: \(name)"
            }
            return "Filtered by manager"
        case .dateRange:
            if let range = taskFilter.dateRange {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                return "Filtered by date: \(formatter.string(from: range.lowerBound)) - \(formatter.string(from: range.upperBound))"
            }
            return "Filtered by date range"
        }
    }
    
    @ViewBuilder
    private func infoRow(title: String, value: String, emphasis: Color? = nil) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.body)
                .foregroundColor(emphasis ?? .primary)
        }
    }
    
    private func bookingsForDate(_ date: Date) -> [Booking] {
        bookingStore.bookings.filter { booking in
            Calendar.current.isDate(booking.date, inSameDayAs: date) &&
            booking.projectId == project.id &&
            (booking.status == .confirmed || booking.status == .tentative)
        }.sorted { $0.timeSlot.rawValue < $1.timeSlot.rawValue }
    }
    
    // MARK: - Helper Methods
    
    private func changeWeek(by weeks: Int) {
        if let newWeek = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: selectedWeek) {
            selectedWeek = newWeek
        }
    }
    
    private func loadWeekBookings() {
        bookingStore.loadData()
    }
    
    private var weekViewPreferenceKey: String {
        "compactWeekView_\(project.id.uuidString)"
    }
    
    private func toggleWeekViewMode() {
        isCompactWeekView.toggle()
        UserDefaults.standard.set(isCompactWeekView, forKey: weekViewPreferenceKey)
    }
    
    private func loadWeekViewPreference() {
        isCompactWeekView = UserDefaults.standard.bool(forKey: weekViewPreferenceKey)
    }
    
    private func geocodeAddress() {
        guard hasValidAddress else { return }
        
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = project.siteAddress
        let search = MKLocalSearch(request: request)
        
        Task {
            do {
                let response = try await search.start()
                if let firstItem = response.mapItems.first {
                    await MainActor.run {
                        mapItem = firstItem
                        if let coordinate = coordinate(from: firstItem) {
                            updateRegion(with: coordinate)
                        }
                    }
                }
            } catch {
                print("🔥🔥🔥 DEBUG: Geocoding failed: \(error.localizedDescription)")
            }
        }
    }
    
    @MainActor
    private func updateRegion(with coordinate: CLLocationCoordinate2D) {
        let newRegion = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        region = newRegion
        if #available(iOS 17.0, *) {
            cameraPosition = .region(newRegion)
        }
    }
    
    private func openInGoogleMaps() {
        let address = project.siteAddress.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "comgooglemaps://?q=\(address)") {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            } else if let webUrl = URL(string: "https://www.google.com/maps/search/?api=1&query=\(address)") {
                UIApplication.shared.open(webUrl)
            }
        }
    }
    
    private func openInAppleMaps() {
        if let mapItem = mapItem {
            mapItem.openInMaps()
            return
        }
        
        let address = project.siteAddress.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "http://maps.apple.com/?q=\(address)") {
            UIApplication.shared.open(url)
        }
    }
    
    private func coordinate(from item: MKMapItem) -> CLLocationCoordinate2D? {
        item.placemark.coordinate
    }
    
    private var currentCoordinate: CLLocationCoordinate2D? {
        if let item = mapItem {
            return coordinate(from: item)
        }
        return nil
    }
    
    // MARK: - Tasks
    
    private var tasksContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Project Tasks")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                if !userStore.isOperativeMode() {
                    Button(action: {
                        showingAddTask = true
                    }) {
                        Label("Add Task", systemImage: "plus")
                            .font(.subheadline)
                    }
                }
            }
            
            Picker("Task Tab", selection: $selectedTaskTab) {
                ForEach(TaskTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            
            if !userStore.isOperativeMode() {
                HStack {
                    Text(taskFilterDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Filters") {
                        showingTaskFilter = true
                    }
                    .font(.subheadline)
                }
            }
            
            let tasks = filteredTasks(for: selectedTaskTab)
            if tasks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text(selectedTaskTab == .active ? "No tasks yet" : "No completed tasks")
                        .font(.body)
                        .foregroundColor(.secondary)
                    if selectedTaskTab == .active {
                        Text("Tap “Add Task” to create one.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            } else {
                VStack(spacing: 12) {
                    ForEach(tasks) { task in
                        ProjectTaskRow(
                            task: task,
                            project: project,
                            operativeNames: operativeNames(for: task.allAssignedOperativeIds),
                            managerNames: managerNames(for: task.allAssignedManagerIds),
                            onStatusToggle: { newStatus in
                                Task {
                                    await taskStore.toggleTaskStatus(task, to: newStatus)
                                }
                            }
                        )
                        .environmentObject(taskStore)
                        .environmentObject(userStore)
                        .environmentObject(firebaseBackend)
                        .environmentObject(operativeStore)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddTask) {
            AddProjectTaskView(
                project: project,
                isPresented: $showingAddTask
            )
            .environmentObject(taskStore)
            .environmentObject(operativeStore)
            .environmentObject(userStore)
        }
        .sheet(isPresented: $showingTaskFilter) {
            ProjectTaskFilterSheet(
                filter: $taskFilter,
                isPresented: $showingTaskFilter,
                operatives: operativeStore.allOperatives,
                managers: operativeStore.managers
            )
        }
    }
    
    // MARK: - Materials Content
    
    private var materialsContent: some View {
        MaterialsView(project: project)
            .environmentObject(userStore)
            .environmentObject(firebaseBackend)
    }
    
    private var settingsContent: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                infoRow(title: "Job Number", value: project.jobNumber)
                infoRow(title: "Type", value: project.customJobType ?? project.jobType.rawValue)
                infoRow(title: "Manager", value: managerDisplayName)
                if !userStore.isOperativeMode() {
                    infoRow(title: "Client", value: project.client.name)
                }
                infoRow(title: "Status", value: project.isLive ? "Live" : "Inactive", emphasis: project.isLive ? .green : .orange)
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 2)
            
            Button(action: { showingEditProject = true }) {
                HStack {
                    Image(systemName: "square.and.pencil")
                    Text("Edit Project Details")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.theme.primary)
                .cornerRadius(12)
            }
            
            if let notes = project.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes")
                        .font(.headline)
                    Text(notes)
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(12)
            }
        }
    }
}

#Preview {
    NavigationView {
        ProjectDetailView(project: Project(
            jobNumber: "C646",
            siteName: "Lancelot Place",
            siteAddress: "8 Lancelot Place, SW7 1DR, London",
            client: Client(name: "Test Client"),
            startDate: Date(),
            endDate: Date(),
            jobType: .catA,
            manager: .na
        ))
        .environmentObject(BookingStore())
        .environmentObject(OperativeStore())
        .environmentObject(ProjectStore())
        .environmentObject(UserStore())
        .environmentObject(FirebaseBackend())
    }
}

// MARK: - Supporting Views

private struct ProjectTaskRow: View {
    let task: ProjectTask
    let project: Project
    let operativeNames: [String]
    let managerNames: [String]
    let onStatusToggle: (ProjectTask.Status) -> Void
    
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var notificationService: NotificationService
    
    @State private var showingCompletionPopup = false
    @State private var showingTaskDetail = false
    @State private var showingEditTask = false
    
    /// Settings cog only for super admins, admins, and managers — not for operative-only users.
    private var canShowSettingsCog: Bool {
        userStore.hasAdminAccess() || userStore.displayUser?.permissions.manager == true
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.title)
                    .font(.headline)
                Spacer()
                HStack(spacing: 8) {
                    if canShowSettingsCog {
                        Button(action: {
                            showingEditTask = true
                        }) {
                            Image(systemName: "gearshape")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    statusBadge
                }
            }
            
            if let details = task.details, !details.isEmpty {
                Text(details)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                if !operativeNames.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(operativeNames.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if !managerNames.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person.text.rectangle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(managerNames.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let dueDate = task.dueDate {
                    Label {
                        Text(dueDate, style: .date)
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            HStack {
                Text("Created by \(task.createdBy)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if task.isCompleted {
                    Button("View Details") {
                        showingTaskDetail = true
                    }
                    .font(.caption)
                } else {
                    Button("Mark Complete") {
                        showingCompletionPopup = true
                    }
                    .font(.caption)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showingTaskDetail = true
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .sheet(isPresented: $showingTaskDetail) {
            CompletedTaskDetailView(
                task: task,
                onStatusChange: { newStatus in
                    Task {
                        await taskStore.toggleTaskStatus(task, to: newStatus)
                    }
                }
            )
            .environmentObject(taskStore)
            .environmentObject(operativeStore)
            .environmentObject(userStore)
        }
        .sheet(isPresented: $showingCompletionPopup) {
            TaskCompletionPopupView(
                task: task,
                isPresented: $showingCompletionPopup,
                onComplete: { completedBy, images, files in
                    Task {
                        await completeTask(completedBy: completedBy, images: images, files: files)
                    }
                }
            )
            .environmentObject(firebaseBackend)
            .environmentObject(userStore)
            .environmentObject(notificationService)
        }
        .sheet(isPresented: $showingEditTask) {
            EditProjectTaskView(
                task: task,
                project: project,
                isPresented: $showingEditTask
            )
            .environmentObject(taskStore)
            .environmentObject(operativeStore)
            .environmentObject(userStore)
        }
    }
    
    private func completeTask(completedBy: String, images: [String], files: [String]) async {
        var updatedTask = task
        updatedTask.status = .completed
        updatedTask.completedBy = completedBy
        updatedTask.completedAt = Date()
        updatedTask.completionImages = images
        updatedTask.completionFiles = files
        updatedTask.updatedAt = Date()
        
        await taskStore.updateTask(updatedTask)
        
        // Send notification to task creator
        if let creatorId = userStore.currentUser?.id {
            await notificationService.notifyTaskCompleted(
                taskId: task.id,
                taskTitle: task.title,
                completedBy: completedBy,
                assignedToUserId: creatorId
            )
        }
        
        onStatusToggle(.completed)
    }
    
    private var statusBadge: some View {
        Text(task.status.rawValue)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.1))
            .foregroundColor(statusColor)
            .cornerRadius(8)
    }
    
    private var statusColor: Color {
        switch task.status {
        case .todo: return .orange
        case .inProgress: return .blue
        case .completed: return .green
        }
    }
}

private struct ProjectTaskFilterSheet: View {
    @Binding var filter: TaskFilter
    @Binding var isPresented: Bool
    let operatives: [Operative]
    let managers: [Manager]
    
    @State private var localFilter: TaskFilter
    
    init(filter: Binding<TaskFilter>, isPresented: Binding<Bool>, operatives: [Operative], managers: [Manager]) {
        self._filter = filter
        self._isPresented = isPresented
        self.operatives = operatives
        self.managers = managers
        var initialFilter = filter.wrappedValue
        if initialFilter.type == .dateRange && initialFilter.dateRange == nil {
            let today = Date()
            initialFilter.dateRange = today...today
        }
        _localFilter = State(initialValue: initialFilter)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("Filter Type") {
                    Picker("Filter", selection: $localFilter.type) {
                        ForEach(TaskFilterType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                }
                
                if localFilter.type == .operative {
                    Section("Operative") {
                        Picker("Operative", selection: Binding(
                            get: { localFilter.operativeId ?? operatives.first?.id },
                            set: { localFilter.operativeId = $0 }
                        )) {
                            ForEach(operatives) { operative in
                                Text(operative.name).tag(operative.id as UUID?)
                            }
                        }
                    }
                }
                
                if localFilter.type == .manager {
                    Section("Manager") {
                        Picker("Manager", selection: Binding(
                            get: { localFilter.managerId ?? managers.first?.id },
                            set: { localFilter.managerId = $0 }
                        )) {
                            ForEach(managers) { manager in
                                Text(manager.fullName).tag(manager.id as UUID?)
                            }
                        }
                    }
                }
                
                if localFilter.type == .dateRange {
                    Section("Date Range") {
                        DatePicker(
                            "Start Date",
                            selection: Binding(
                                get: { localFilter.dateRange?.lowerBound ?? Date() },
                                set: { newValue in
                                    if let upper = localFilter.dateRange?.upperBound {
                                        localFilter.dateRange = newValue...upper
                                    } else {
                                        localFilter.dateRange = newValue...newValue
                                    }
                                }
                            ),
                            displayedComponents: .date
                        )
                        DatePicker(
                            "End Date",
                            selection: Binding(
                                get: { localFilter.dateRange?.upperBound ?? Date() },
                                set: { newValue in
                                    if let lower = localFilter.dateRange?.lowerBound {
                                        localFilter.dateRange = lower...newValue
                                    } else {
                                        localFilter.dateRange = newValue...newValue
                                    }
                                }
                            ),
                            displayedComponents: .date
                        )
                    }
                }
                
                Section {
                    Button("Reset Filters") {
                        localFilter.reset()
                    }
                }
            }
            .navigationTitle("Task Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Apply") {
                        filter = localFilter
                        isPresented = false
                    }
                }
            }
            .onChange(of: localFilter.type) { oldValue, newValue in
                if newValue == .dateRange && localFilter.dateRange == nil {
                    let today = Date()
                    localFilter.dateRange = today...today
                }
            }
        }
    }
}

private struct TaskItemForm: Identifiable {
    var id: UUID = UUID()
    var title: String = ""
    var description: String = ""
}

private struct AddProjectTaskView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let project: Project
    @Binding var isPresented: Bool
    
    @State private var taskItems: [TaskItemForm] = [TaskItemForm()]
    @State private var assignmentType: AssignmentType = .operative
    @State private var selectedOperative: UUID?
    @State private var selectedManager: UUID?
    @State private var selectedOperatives: Set<UUID> = []
    @State private var selectedManagers: Set<UUID> = []
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var status: ProjectTask.Status = .todo
    @State private var isSaving = false
    @State private var selectedFile: URL?
    @State private var selectedFileName: String?
    @State private var selectedImages: [UIImage] = []
    @State private var isUploadingImages = false
    @State private var uploadProgress: Double = 0
    @State private var showingFilePicker = false
    @State private var showingImagePicker = false
    @State private var showingOperativeSelection = false
    @State private var showingManagerSelection = false
    @State private var uploadedImageURLs: [String] = []
    @State private var errorMessage: String?
    @State private var showingError = false
    
    enum AssignmentType: String, CaseIterable {
        case operative = "Operative"
        case manager = "Manager"
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach($taskItems) { $item in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Item title", text: $item.title)
                            TextField("Description (optional)", text: $item.description, axis: .vertical)
                                .lineLimit(2...4)
                        }
                        .padding(.vertical, 4)
                    }
                    Button(action: {
                        taskItems.append(TaskItemForm())
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                            Text("Add item")
                                .foregroundColor(.green)
                        }
                    }
                } header: {
                    Text("Task items")
                } footer: {
                    Text("Add one or more items. Assignees must tick all items (when more than one) before marking the task complete.")
                }
                
                Section("Assignments") {
                    Picker("Assign To", selection: $assignmentType) {
                        ForEach(AssignmentType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    
                    if assignmentType == .operative {
                        Button(action: {
                            showingOperativeSelection = true
                        }) {
                            HStack {
                                Text("Select Operatives")
                                Spacer()
                                if selectedOperatives.isEmpty {
                                    Text("None selected")
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("\(selectedOperatives.count) selected")
                                        .foregroundColor(.blue)
                                }
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                        
                        if !selectedOperatives.isEmpty {
                            ForEach(Array(selectedOperatives), id: \.self) { operativeId in
                                if let operative = operativeStore.allOperatives.first(where: { $0.id == operativeId }) {
                                    HStack {
                                        Text(operative.name)
                                        Spacer()
                                        Button(action: {
                                            selectedOperatives.remove(operativeId)
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.red)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        Button(action: {
                            showingManagerSelection = true
                        }) {
                            HStack {
                                Text("Select Managers")
                                    .foregroundColor(selectedManagers.isEmpty ? .red : .primary)
                                Spacer()
                                if selectedManagers.isEmpty {
                                    Text("Required")
                                        .foregroundColor(.red)
                                } else {
                                    Text("\(selectedManagers.count) selected")
                                        .foregroundColor(.blue)
                                }
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                        
                        if !selectedManagers.isEmpty {
                            ForEach(Array(selectedManagers), id: \.self) { managerId in
                                if let manager = operativeStore.managers.first(where: { $0.id == managerId }) {
                                    HStack {
                                        Text(manager.fullName)
                                        Spacer()
                                        Button(action: {
                                            selectedManagers.remove(managerId)
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.red)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                
                Section("Attach Images") {
                    Button(action: {
                        showingImagePicker = true
                    }) {
                        Label("Add Images", systemImage: "photo")
                    }
                    
                    if !selectedImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 100, height: 100)
                                            .clipped()
                                            .cornerRadius(8)
                                        
                                        Button(action: {
                                            selectedImages.remove(at: index)
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.red)
                                                .background(Color.white)
                                                .clipShape(Circle())
                                        }
                                        .padding(4)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    
                    if isUploadingImages {
                        ProgressView(value: uploadProgress)
                        Text("Uploading images...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section("Attach File") {
                    if let fileName = selectedFileName {
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundColor(.blue)
                            Text(fileName)
                                .font(.subheadline)
                            Spacer()
                            Button("Remove") {
                                selectedFile = nil
                                selectedFileName = nil
                            }
                            .foregroundColor(.red)
                        }
                    } else {
                        Button(action: {
                            showingFilePicker = true
                        }) {
                            Label("Add File (Max 10MB)", systemImage: "paperclip")
                        }
                    }
                    
                }
                .fileImporter(
                    isPresented: $showingFilePicker,
                    allowedContentTypes: [UTType.item, UTType.image, UTType.pdf, UTType.text, UTType.data],
                    allowsMultipleSelection: false
                ) { result in
                    handleFileSelection(result)
                }
                .sheet(isPresented: $showingImagePicker) {
                    ImagePicker(images: $selectedImages)
                }
                .sheet(isPresented: $showingOperativeSelection) {
                    OperativeMultiSelectView(selectedOperatives: $selectedOperatives, operatives: operativeStore.allOperatives)
                }
                .sheet(isPresented: $showingManagerSelection) {
                    ManagerMultiSelectView(selectedManagers: $selectedManagers, managers: operativeStore.managers)
                }
                
                Section("Due Date") {
                    Toggle("Set Due Date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due Date", selection: $dueDate, displayedComponents: .date)
                    }
                }
                
                Section("Status") {
                    Picker("Status", selection: $status) {
                        ForEach(ProjectTask.Status.allCases, id: \.rawValue) { status in
                            Text(status.rawValue).tag(status)
                        }
                    }
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveTask()
                    }
                    .disabled(!canSaveTask || isSaving)
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") {
                    showingError = false
                }
            } message: {
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                }
            }
        }
    }
    
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            // File importer URLs are security-scoped; copy to temp so we can read when saving (upload happens in saveTask with real task ID)
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
            
            // Check file size (10MB limit)
            if let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
               fileSize > 10 * 1024 * 1024 {
                return
            }
            
            let fileName = url.lastPathComponent
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + fileName)
            do {
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }
                try FileManager.default.copyItem(at: url, to: tempURL)
                selectedFile = tempURL
                selectedFileName = fileName
            } catch {
                print("🔥🔥🔥 DEBUG: Error copying selected file: \(error.localizedDescription)")
            }
        case .failure(let error):
            print("File selection error: \(error.localizedDescription)")
        }
    }
    
    private var canSaveTask: Bool {
        let atLeastOneItemWithTitle = taskItems.contains { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let assignmentValid = (assignmentType == .operative && !selectedOperatives.isEmpty) || 
                              (assignmentType == .manager && !selectedManagers.isEmpty)
        return atLeastOneItemWithTitle && assignmentValid
    }
    
    private func saveTask() {
        guard canSaveTask else { return }
        isSaving = true
        let creatorName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
        
        let items: [ProjectTaskItem] = taskItems
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { item in
                ProjectTaskItem(
                    id: item.id,
                    title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : item.description.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        guard !items.isEmpty else { isSaving = false; return }
        let firstTitle = items[0].title
        let firstDetails = items[0].description
        
            Task {
                let assignedOperativeIds = assignmentType == .operative ? Array(selectedOperatives) : []
                let assignedManagerIds = assignmentType == .manager ? Array(selectedManagers) : []
                
                var task = ProjectTask(
                    projectId: project.id,
                    title: firstTitle,
                    details: firstDetails,
                    createdBy: creatorName,
                    assignedOperativeIds: assignedOperativeIds,
                    assignedManagerIds: assignedManagerIds,
                    dueDate: hasDueDate ? dueDate : nil,
                    status: status,
                    attachedFileURL: nil,
                    attachedFileName: selectedFileName,
                    attachedImageURLs: [],
                    items: items,
                    completedItemIds: []
                )
                
                // Upload images first if any
                var imageURLs: [String] = []
                if !selectedImages.isEmpty {
                    isUploadingImages = true
                    let totalImages = selectedImages.count
                    for (index, image) in selectedImages.enumerated() {
                        if let url = await uploadImageForTask(image, taskId: task.id) {
                            imageURLs.append(url)
                        }
                        uploadProgress = Double(index + 1) / Double(totalImages) * 0.5
                    }
                    isUploadingImages = false
                    task.attachedImageURLs = imageURLs
                }
                
                // Upload file if any (to Firebase Storage under this task's ID so it's accessible to users with task access)
                if let selectedFile = selectedFile {
                    if let url = await uploadFileForTask(selectedFile, taskId: task.id) {
                        task.attachedFileURL = url
                    }
                }
                
                do {
                    try await taskStore.addTask(task)
                    
                    // Send notification for task creation
                    await notificationService.notifyTaskCreated(
                        taskId: task.id,
                        taskTitle: task.title,
                        createdBy: creatorName,
                        assignedOperativeIds: assignedOperativeIds,
                        assignedManagerIds: assignedManagerIds
                    )
                    
                    await MainActor.run {
                        isSaving = false
                        isPresented = false
                    }
                } catch {
                    await MainActor.run {
                        isSaving = false
                        errorMessage = error.localizedDescription
                        showingError = true
                    }
                }
            }
    }
    
    private func uploadImageForTask(_ image: UIImage, taskId: UUID) async -> String? {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            return nil
        }
        
        do {
            let imageName = "task_image_\(UUID().uuidString)"
            let url = try await firebaseBackend.uploadTaskImage(image, taskId: taskId, organizationId: organizationId, imageName: imageName)
            return url
        } catch {
            print("🔥🔥🔥 DEBUG: Error uploading task image: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func uploadFileForTask(_ fileURL: URL, taskId: UUID) async -> String? {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            return nil
        }
        
        do {
            let fileName = fileURL.lastPathComponent
            let url = try await firebaseBackend.uploadTaskFile(fileURL, taskId: taskId, organizationId: organizationId, fileName: fileName)
            return url
        } catch {
            print("🔥🔥🔥 DEBUG: Error uploading task file: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func uploadImage(_ image: UIImage) async -> String? {
        // TODO: Implement Firebase Storage upload for images
        // For now, return placeholder
        return nil
    }
}

// MARK: - Edit Project Task View

private struct EditProjectTaskView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let task: ProjectTask
    let project: Project
    @Binding var isPresented: Bool
    
    @State private var taskItems: [TaskItemForm]
    @State private var assignmentType: AssignmentType
    @State private var selectedOperatives: Set<UUID>
    @State private var selectedManagers: Set<UUID>
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var status: ProjectTask.Status
    @State private var isSaving = false
    @State private var showingOperativeSelection = false
    @State private var showingManagerSelection = false
    
    enum AssignmentType: String, CaseIterable {
        case operative = "Operative"
        case manager = "Manager"
    }
    
    init(task: ProjectTask, project: Project, isPresented: Binding<Bool>) {
        self.task = task
        self.project = project
        self._isPresented = isPresented
        
        let effective = task.effectiveItems
        let initialItems = effective.isEmpty ? [TaskItemForm()] : effective.map { TaskItemForm(id: $0.id, title: $0.title, description: $0.description ?? "") }
        _taskItems = State(initialValue: initialItems)
        
        let hasOperatives = !task.allAssignedOperativeIds.isEmpty
        _assignmentType = State(initialValue: hasOperatives ? .operative : .manager)
        
        _selectedOperatives = State(initialValue: Set(task.allAssignedOperativeIds))
        _selectedManagers = State(initialValue: Set(task.allAssignedManagerIds))
        _hasDueDate = State(initialValue: task.dueDate != nil)
        _dueDate = State(initialValue: task.dueDate ?? Date())
        _status = State(initialValue: task.status)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach($taskItems) { $item in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Item title", text: $item.title)
                            TextField("Description (optional)", text: $item.description, axis: .vertical)
                                .lineLimit(2...4)
                        }
                        .padding(.vertical, 4)
                    }
                    Button(action: {
                        taskItems.append(TaskItemForm())
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                            Text("Add item")
                                .foregroundColor(.green)
                        }
                    }
                } header: {
                    Text("Task items")
                }
                
                Section("Assignments *") {
                    Picker("Assign To", selection: $assignmentType) {
                        ForEach(AssignmentType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    
                    if assignmentType == .operative {
                        Button(action: {
                            showingOperativeSelection = true
                        }) {
                            HStack {
                                Text("Select Operatives")
                                    .foregroundColor(selectedOperatives.isEmpty ? .red : .primary)
                                Spacer()
                                if selectedOperatives.isEmpty {
                                    Text("Required")
                                        .foregroundColor(.red)
                                } else {
                                    Text("\(selectedOperatives.count) selected")
                                        .foregroundColor(.blue)
                                }
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                        .sheet(isPresented: $showingOperativeSelection) {
                            OperativeMultiSelectView(selectedOperatives: $selectedOperatives, operatives: operativeStore.allOperatives)
                        }
                    } else {
                        Button(action: {
                            showingManagerSelection = true
                        }) {
                            HStack {
                                Text("Select Managers")
                                    .foregroundColor(selectedManagers.isEmpty ? .red : .primary)
                                Spacer()
                                if selectedManagers.isEmpty {
                                    Text("Required")
                                        .foregroundColor(.red)
                                } else {
                                    Text("\(selectedManagers.count) selected")
                                        .foregroundColor(.blue)
                                }
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                        .sheet(isPresented: $showingManagerSelection) {
                            ManagerMultiSelectView(selectedManagers: $selectedManagers, managers: operativeStore.managers)
                        }
                    }
                }
                
                Section("Due Date") {
                    Toggle("Set Due Date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due Date", selection: $dueDate, displayedComponents: .date)
                    }
                }
                
                Section("Status") {
                    Picker("Status", selection: $status) {
                        ForEach(ProjectTask.Status.allCases, id: \.rawValue) { status in
                            Text(status.rawValue).tag(status)
                        }
                    }
                }
            }
            .navigationTitle("Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveTask()
                    }
                    .disabled(!canSaveTask || isSaving)
                }
            }
        }
    }
    
    private var canSaveTask: Bool {
        let atLeastOneItemWithTitle = taskItems.contains { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let assignmentValid = (assignmentType == .operative && !selectedOperatives.isEmpty) || 
                              (assignmentType == .manager && !selectedManagers.isEmpty)
        return atLeastOneItemWithTitle && assignmentValid
    }
    
    private func saveTask() {
        guard canSaveTask else { return }
        isSaving = true
        
        let items: [ProjectTaskItem] = taskItems
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { item in
                ProjectTaskItem(
                    id: item.id,
                    title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : item.description.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        guard !items.isEmpty else { isSaving = false; return }
        
        Task {
            var updatedTask = task
            updatedTask.items = items
            updatedTask.title = items[0].title
            updatedTask.details = items[0].description
            updatedTask.dueDate = hasDueDate ? dueDate : nil
            updatedTask.status = status
            updatedTask.updatedAt = Date()
            
            if assignmentType == .operative {
                updatedTask.assignedOperativeIds = Array(selectedOperatives)
                updatedTask.assignedOperativeId = selectedOperatives.first
                updatedTask.assignedManagerIds = []
                updatedTask.assignedManagerId = nil
            } else {
                updatedTask.assignedManagerIds = Array(selectedManagers)
                updatedTask.assignedManagerId = selectedManagers.first
                updatedTask.assignedOperativeIds = []
                updatedTask.assignedOperativeId = nil
            }
            
            await taskStore.updateTask(updatedTask)
            
            await MainActor.run {
                isSaving = false
                isPresented = false
            }
        }
    }
}

// MARK: - Task Completion Popup

struct TaskCompletionPopupView: View {
    let task: ProjectTask
    @Binding var isPresented: Bool
    let onComplete: (String, [String], [String]) -> Void
    
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    
    @State private var isMarkedComplete = false
    @State private var selectedImages: [UIImage] = []
    @State private var selectedFiles: [URL] = []
    @State private var showingImagePicker = false
    @State private var showingFilePicker = false
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    
    private var displayTask: ProjectTask {
        taskStore.tasks.first(where: { $0.id == task.id }) ?? task
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("Task items") {
                    ForEach(displayTask.effectiveItems) { item in
                        if displayTask.isMultiItemTask {
                            Button(action: { toggleItemTicked(itemId: item.id) }) {
                                HStack(spacing: 12) {
                                    Image(systemName: displayTask.completedItemIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(displayTask.completedItemIds.contains(item.id) ? .green : .secondary)
                                        .font(.title2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        if let desc = item.description, !desc.isEmpty {
                                            Text(desc)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.headline)
                                if let desc = item.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if displayTask.isMultiItemTask && !displayTask.allItemsTicked {
                        Text("Tick all items above before you can mark the task complete.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section("Mark as Completed") {
                    Toggle("Mark as completed", isOn: $isMarkedComplete)
                        .disabled(displayTask.isMultiItemTask && !displayTask.allItemsTicked)
                }
                
                Section("Upload Image") {
                    Button(action: {
                        showingImagePicker = true
                    }) {
                        Label("Add Image", systemImage: "photo")
                    }
                    
                    if !selectedImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 100, height: 100)
                                            .clipped()
                                            .cornerRadius(8)
                                        
                                        Button(action: {
                                            selectedImages.remove(at: index)
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.red)
                                                .background(Color.white)
                                                .clipShape(Circle())
                                        }
                                        .padding(4)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                
                Section("Upload File") {
                    Button(action: {
                        showingFilePicker = true
                    }) {
                        Label("Add File", systemImage: "doc")
                    }
                    
                    if !selectedFiles.isEmpty {
                        ForEach(Array(selectedFiles.enumerated()), id: \.offset) { index, file in
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundColor(.blue)
                                Text(file.lastPathComponent)
                                    .font(.subheadline)
                                Spacer()
                                Button(action: {
                                    selectedFiles.remove(at: index)
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                }
                
                if isUploading {
                    Section {
                        ProgressView(value: uploadProgress)
                        Text("Uploading...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Complete Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Submit") {
                        submitCompletion()
                    }
                    .disabled(!isMarkedComplete || isUploading || (displayTask.isMultiItemTask && !displayTask.allItemsTicked))
                }
            }
            .sheet(isPresented: $showingImagePicker) {
                ImagePicker(images: $selectedImages)
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.item, .data],
                allowsMultipleSelection: true
            ) { result in
                handleFileSelection(result)
            }
        }
    }
    
    private func toggleItemTicked(itemId: UUID) {
        var updatedTask = displayTask
        if updatedTask.completedItemIds.contains(itemId) {
            updatedTask.completedItemIds.removeAll { $0 == itemId }
        } else {
            updatedTask.completedItemIds.append(itemId)
        }
        updatedTask.updatedAt = Date()
        Task {
            await taskStore.updateTask(updatedTask)
        }
    }
    
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                // Copy to temp so we can read when uploading (file importer URLs are security-scoped)
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                let tempDir = FileManager.default.temporaryDirectory
                let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent)
                do {
                    if FileManager.default.fileExists(atPath: tempURL.path) {
                        try FileManager.default.removeItem(at: tempURL)
                    }
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    selectedFiles.append(tempURL)
                } catch {
                    print("🔥🔥🔥 DEBUG: Error copying file for completion: \(error.localizedDescription)")
                }
            }
        case .failure(let error):
            print("File selection error: \(error.localizedDescription)")
        }
    }
    
    private func submitCompletion() {
        guard isMarkedComplete else { return }
        
        isUploading = true
        uploadProgress = 0
        
        Task {
            let completedBy = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
            var imageURLs: [String] = []
            var fileURLs: [String] = []
            
            // Upload images
            for image in selectedImages {
                if let url = await uploadImage(image) {
                    imageURLs.append(url)
                }
                uploadProgress += 0.5 / Double(selectedImages.count + selectedFiles.count)
            }
            
            // Upload files
            for file in selectedFiles {
                if let url = await uploadFile(file) {
                    fileURLs.append(url)
                }
                uploadProgress += 0.5 / Double(selectedImages.count + selectedFiles.count)
            }
            
            uploadProgress = 1.0
            
            await MainActor.run {
                isUploading = false
                onComplete(completedBy, imageURLs, fileURLs)
                isPresented = false
            }
        }
    }
    
    private func uploadImage(_ image: UIImage) async -> String? {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            return nil
        }
        
        do {
            let imageName = "completion_image_\(UUID().uuidString)"
            let url = try await firebaseBackend.uploadTaskImage(image, taskId: task.id, organizationId: organizationId, imageName: imageName)
            return url
        } catch {
            print("🔥🔥🔥 DEBUG: Error uploading completion image: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func uploadFile(_ file: URL) async -> String? {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            return nil
        }
        
        do {
            let fileName = file.lastPathComponent
            let url = try await firebaseBackend.uploadTaskFile(file, taskId: task.id, organizationId: organizationId, fileName: fileName)
            return url
        } catch {
            print("🔥🔥🔥 DEBUG: Error uploading completion file: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Image Picker

private struct ImagePicker: UIViewControllerRepresentable {
    @Binding var images: [UIImage]
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 10
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            
            for result in results {
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, error in
                    if let image = object as? UIImage {
                        DispatchQueue.main.async {
                            self.parent.images.append(image)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Task file row (opens Firebase Storage URL in browser / system handler)

private struct TaskCompletionFileRow: View {
    let urlString: String
    let label: String
    
    init(urlString: String, label: String? = nil) {
        self.urlString = urlString
        self.label = label ?? (URL(string: urlString)?.lastPathComponent ?? "File")
    }
    
    var body: some View {
        Button(action: {
            if let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: "doc.fill")
                    .foregroundColor(.blue)
                    .font(.title3)
                Text(label)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.blue)
                    .font(.caption)
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Task completion image loader (loads from Firebase Storage URLs via URLSession)

private struct TaskCompletionImageView: View {
    let urlString: String
    @State private var image: UIImage?
    @State private var failed = false
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("Failed to load")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    )
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                    .overlay(ProgressView())
            }
        }
        .task(id: urlString) {
            guard let url = URL(string: urlString), image == nil else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let uiImage = UIImage(data: data) {
                    await MainActor.run { image = uiImage }
                } else {
                    await MainActor.run { failed = true }
                }
            } catch {
                await MainActor.run { failed = true }
            }
        }
    }
}

// MARK: - Completed Task Detail View

private struct CompletedTaskDetailView: View {
    let task: ProjectTask
    let onStatusChange: (ProjectTask.Status) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    
    /// Use latest task from store so completion images/files are shown after marking complete.
    private var displayTask: ProjectTask {
        taskStore.tasks.first(where: { $0.id == task.id }) ?? task
    }
    
    init(task: ProjectTask, onStatusChange: @escaping (ProjectTask.Status) -> Void) {
        self.task = task
        self.onStatusChange = onStatusChange
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    // Task Summary Section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Task Summary")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)
                            .padding(.top)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            if displayTask.effectiveItems.count > 1 {
                                Text("Items")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                ForEach(displayTask.effectiveItems) { item in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        if let desc = item.description, !desc.isEmpty {
                                            Text(desc)
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Title")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .textCase(.uppercase)
                                    Text(displayTask.title)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                }
                                if let details = displayTask.details, !details.isEmpty {
                                    Divider()
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Details")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .textCase(.uppercase)
                                        Text(details)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                    }
                                }
                            }
                            
                            Divider()
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Created By")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                Text(displayTask.createdBy)
                                    .font(.body)
                                    .foregroundColor(.primary)
                            }
                            
                            if let dueDate = displayTask.dueDate {
                                Divider()
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Due Date")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .textCase(.uppercase)
                                    Text(dueDate, style: .date)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                }
                            }
                            
                            // Only show completion info if task is completed
                            if displayTask.isCompleted {
                                if let completedBy = displayTask.completedBy {
                                    Divider()
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Completed By")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .textCase(.uppercase)
                                        Text(completedBy)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                    }
                                }
                                
                                if let completedAt = displayTask.completedAt {
                                    Divider()
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Completed At")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .textCase(.uppercase)
                                        Text(completedAt, style: .date)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                    }
                                }
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemBackground))
                    }
                    .background(Color(.secondarySystemBackground))
                    
                    // Completion Details Section with Slider
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Completion Details")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)
                            .padding(.top)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Status")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                Spacer()
                            }
                            
                            HStack(spacing: 16) {
                                Text("Not Completed")
                                    .font(.body)
                                    .foregroundColor(displayTask.isCompleted ? .secondary : .primary)
                                    .frame(minWidth: 100, alignment: .trailing)
                                
                                Toggle("", isOn: Binding(
                                    get: { displayTask.isCompleted },
                                    set: { handleStatusChange($0) }
                                ))
                                    .labelsHidden()
                                
                                Text("Completed")
                                    .font(.body)
                                    .foregroundColor(displayTask.isCompleted ? .primary : .secondary)
                                    .frame(minWidth: 100, alignment: .leading)
                            }
                            .padding(.vertical, 8)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemBackground))
                    }
                    .background(Color(.secondarySystemBackground))
                    
                    // Task attachments (from when task was created) — accessible to anyone with task access
                    if !displayTask.attachedImageURLs.isEmpty || displayTask.attachedFileURL != nil {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Attachments (from task)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .padding(.horizontal)
                                .padding(.top)
                            
                            if let fileURL = displayTask.attachedFileURL {
                                TaskCompletionFileRow(urlString: fileURL, label: displayTask.attachedFileName ?? URL(string: fileURL)?.lastPathComponent ?? "Attached file")
                            }
                            if !displayTask.attachedImageURLs.isEmpty {
                                ScrollView(.horizontal, showsIndicators: true) {
                                    HStack(spacing: 16) {
                                        ForEach(displayTask.attachedImageURLs, id: \.self) { imageURL in
                                            TaskCompletionImageView(urlString: imageURL)
                                                .frame(width: 120, height: 120)
                                                .clipped()
                                                .cornerRadius(12)
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                                .padding(.vertical, 8)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemBackground))
                        .background(Color(.secondarySystemBackground))
                    }
                    
                    // Files section: "Task Files" when active, "Completion Files" when completed
                    VStack(alignment: .leading, spacing: 16) {
                        Text(displayTask.isCompleted ? "Completion Files" : "Task Files")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)
                            .padding(.top)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            if displayTask.completionFiles.isEmpty {
                                Text("N/A")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ForEach(displayTask.completionFiles, id: \.self) { fileURL in
                                    TaskCompletionFileRow(urlString: fileURL)
                                }
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemBackground))
                    }
                    .background(Color(.secondarySystemBackground))
                    
                    // Images section: "Task Images" when active, "Completion Images" when completed
                    VStack(alignment: .leading, spacing: 16) {
                        Text(displayTask.isCompleted ? "Completion Images" : "Task Images")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)
                            .padding(.top)
                        
                        if task.completionImages.isEmpty {
                            Text("N/A")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemBackground))
                        } else {
                            ScrollView(.horizontal, showsIndicators: true) {
                                HStack(spacing: 16) {
                                    ForEach(task.completionImages, id: \.self) { imageURL in
                                        AsyncImage(url: URL(string: imageURL)) { image in
                                            image
                                                .resizable()
                                                .scaledToFill()
                                        } placeholder: {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color(.systemGray5))
                                                .overlay(ProgressView())
                                        }
                                        .frame(width: 200, height: 200)
                                        .clipped()
                                        .cornerRadius(12)
                                        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                                    }
                                }
                                .padding(.horizontal)
                            }
                            .padding(.vertical)
                            .background(Color(.systemBackground))
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                }
            }
            .navigationTitle("Task Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func handleStatusChange(_ isCompleted: Bool) {
        Task {
            if isCompleted {
                // Mark as completed - keep existing completion data or set if not exists
                var updatedTask = displayTask
                if updatedTask.completedBy == nil {
                    // If marking as completed for the first time, set completion data
                    let userName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
                    updatedTask.completedBy = userName
                    updatedTask.completedAt = Date()
                }
                updatedTask.status = .completed
                updatedTask.updatedAt = Date()
                await taskStore.updateTask(updatedTask)
                onStatusChange(.completed)
            } else {
                // Mark as not completed - move back to active
                // Keep completion images/files even when marked as not completed (per user requirement)
                var updatedTask = displayTask
                updatedTask.status = .inProgress
                // Don't clear completedBy, completedAt, completionImages, or completionFiles
                // These should persist for others to view
                updatedTask.updatedAt = Date()
                
                await taskStore.updateTask(updatedTask)
                onStatusChange(.inProgress)
            }
        }
    }
}

// MARK: - Multi-Select Views

private struct OperativeMultiSelectView: View {
    @Binding var selectedOperatives: Set<UUID>
    let operatives: [Operative]
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                ForEach(operatives) { operative in
                    Button(action: {
                        if selectedOperatives.contains(operative.id) {
                            selectedOperatives.remove(operative.id)
                        } else {
                            selectedOperatives.insert(operative.id)
                        }
                    }) {
                        HStack {
                            Text(operative.name)
                            Spacer()
                            if selectedOperatives.contains(operative.id) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Operatives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ManagerMultiSelectView: View {
    @Binding var selectedManagers: Set<UUID>
    let managers: [Manager]
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                ForEach(managers) { manager in
                    Button(action: {
                        if selectedManagers.contains(manager.id) {
                            selectedManagers.remove(manager.id)
                        } else {
                            selectedManagers.insert(manager.id)
                        }
                    }) {
                        HStack {
                            Text(manager.fullName)
                            Spacer()
                            if selectedManagers.contains(manager.id) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Managers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

