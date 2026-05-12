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
import UIKit

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
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var appSettings: AppSettingsStore

    private let projectId: UUID
    private let fallbackProject: Project
    
    /// Latest row from the store so Save on Edit Project / Small Works refreshes this screen.
    private var project: Project {
        projectStore.projects.first(where: { $0.id == projectId }) ?? fallbackProject
    }
    
    @State private var selectedWeek: Date = Date()
    @State private var showingScheduleOperative = false
    @State private var showingScheduleSubcontractor = false
    @State private var showingEditProject = false
    @State private var showingMapOptions = false
    @State private var region: MKCoordinateRegion
    @State private var mapItem: MKMapItem?
    @available(iOS 17.0, *)
    @State private var cameraPosition: MapCameraPosition = .automatic
    @EnvironmentObject var taskStore: ProjectTaskStore
    
    private enum DetailTile: String, CaseIterable, Identifiable {
        case scheduling = "Scheduling"
        case visibility = "View"
        case tasks = "My Tasks"
        case materials = "Materials"
        case siteAudit = "Site Audit"
        case location = "Location"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .scheduling: return "calendar"
            case .visibility: return "eye"
            case .tasks: return "checklist"
            case .materials: return "shippingbox"
            case .siteAudit: return "clipboard.fill"
            case .location: return "mappin.and.ellipse"
            }
        }
    }
    
    
    // Initialize region from project address
    init(project: Project) {
        self.projectId = project.id
        self.fallbackProject = project
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
            VStack(alignment: .leading, spacing: 16) {
                detailHeroCard
                sectionHeading("Manage")
                overviewTiles
                sectionHeading("Details")
                detailSummaryCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle(detailRootTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Color.white)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(ProjectWorksRevampColors.searchBorder, lineWidth: 0.5))
                }
            }
            if canEditCurrentWorkItem {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingEditProject = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 36, height: 36)
                            .background(Color.white)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(ProjectWorksRevampColors.searchBorder, lineWidth: 0.5))
                    }
                    .accessibilityLabel("Edit project details")
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
                .environmentObject(holidayStore)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
                .preference(key: HideBottomMenuKey.self, value: true)
        }
        .sheet(isPresented: $showingScheduleSubcontractor) {
            ScheduleSubcontractorView(project: project)
                .environmentObject(subcontractorStore)
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
        .onChange(of: project.updatedAt) { _, _ in
            geocodeAddress()
        }
        .onChange(of: selectedWeek) { _, _ in
            loadWeekBookings()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("managerScheduleDidChange"))) { _ in
            loadWeekBookings()
        }
        .onDisappear {
            // When leaving, the preference will automatically reset
            // because the view is removed from the hierarchy
        }
    }
    
    // MARK: - Detail layout (revamp)

    private var detailRootTitle: String {
        project.jobType == .smallWorks ? "Small work" : "Project"
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .tracking(0.4)
            .padding(.leading, 4)
    }

    private var primaryGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.theme.primary(for: appSettings.settings.colorScheme),
                ProjectWorksRevampColors.blueLight
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var detailHeroCard: some View {
        let pct = WorksListProgress.fraction(for: project)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(project.jobNumber)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                            .tracking(-0.3)
                        if let pill = heroJobTypePillText {
                            Text(pill)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.22))
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .tracking(0.3)
                        }
                    }
                    Text(project.siteName)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer(minLength: 8)
                heroStatusPill
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(height: 5)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(6, geo.size.width * CGFloat(pct)), height: 5)
                }
            }
            .frame(height: 5)
            .padding(.top, 2)

            HStack {
                Text("\(Int(pct * 100))% complete")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(daysLeftCaption)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(primaryGradient)
        )
    }

    private var heroJobTypePillText: String? {
        if project.jobType == .smallWorks { return nil }
        if let c = project.customJobType, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return c.uppercased()
        }
        return project.jobType.rawValue
    }

    private var heroStatusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.white)
                .frame(width: 5, height: 5)
            Text(project.status.rawValue)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.18))
        .clipShape(Capsule())
    }

    private var daysLeftCaption: String {
        switch project.status {
        case .completed:
            return "Completed"
        case .inactive:
            return "Inactive"
        default:
            let cal = Calendar.current
            let d = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: project.endDate)).day ?? 0
            if d < 0 { return "Ended" }
            return "\(d) days left"
        }
    }

    private var schedulingAttentionCount: Int {
        bookingStore.bookings.filter { $0.projectId == project.id && $0.status == .tentative }.count
    }

    private var openTasksCount: Int {
        taskStore.tasks.filter { $0.projectId == project.id && $0.status != .completed }.count
    }

    private var detailSummaryCard: some View {
        VStack(spacing: 0) {
            summaryRow(
                icon: "building.2.fill",
                title: "Client",
                value: project.client.name,
                iconTint: ProjectWorksRevampColors.blue,
                iconBackground: Color(red: 0.902, green: 0.945, blue: 0.984)
            )
            Divider().overlay(ProjectWorksRevampColors.border)
            summaryRow(
                icon: "person.fill.checkmark",
                title: "Manager",
                value: managerDisplayName,
                iconTint: Color(red: 0.325, green: 0.29, blue: 0.718),
                iconBackground: ProjectWorksRevampColors.jobTypePillBg
            )
            Divider().overlay(ProjectWorksRevampColors.border)
            summaryRow(
                icon: "calendar",
                title: "Timeline",
                value: timelineDetailSummary,
                iconTint: ProjectWorksRevampColors.upcomingAmber,
                iconBackground: Color(red: 0.98, green: 0.933, blue: 0.855)
            )
            Divider().overlay(ProjectWorksRevampColors.border)
            let desc = project.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            summaryMultilineRow(
                icon: "text.alignleft",
                title: "Description",
                value: desc.isEmpty ? "No description added" : desc,
                valueColor: desc.isEmpty ? ProjectWorksRevampColors.placeholderInk : ProjectWorksRevampColors.ink,
                iconTint: ProjectWorksRevampColors.blue,
                iconBackground: Color(red: 0.902, green: 0.945, blue: 0.984)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var timelineDetailSummary: String {
        let f = DateFormatter()
        f.dateFormat = "dd MMM yy"
        return "\(f.string(from: project.startDate)) – \(f.string(from: project.endDate))"
    }

    private func summaryRow(icon: String, title: String, value: String, iconTint: Color, iconBackground: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconBackground)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(iconTint)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }

    private func summaryMultilineRow(
        icon: String,
        title: String,
        value: String,
        valueColor: Color,
        iconTint: Color,
        iconBackground: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconBackground)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(iconTint)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Text(value)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(valueColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }

    private var overviewTiles: some View {
        let availableTiles: [DetailTile] = {
            if userStore.isOperativeMode() {
                if userStore.canViewMaterials() {
                    return userStore.canViewSiteAudit() ? [.tasks, .materials, .siteAudit, .location] : [.tasks, .materials, .location]
                }
                return userStore.canViewSiteAudit() ? [.tasks, .siteAudit, .location] : [.tasks, .location]
            }
            var tiles: [DetailTile] = [.scheduling]
            if userStore.hasAdminAccess() {
                tiles.append(.visibility)
            }
            tiles.append(contentsOf: [.tasks, .materials, .siteAudit, .location])
            return tiles
        }()

        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(availableTiles) { tile in
                NavigationLink(destination: tileDestination(for: tile)) {
                    manageTileContents(for: tile)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func manageTileContents(for tile: DetailTile) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tileIconBackground(for: tile))
                    .frame(width: 36, height: 36)
                Image(systemName: tile.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(tileIconForeground(for: tile))
            }
            .overlay(alignment: .topTrailing) {
                if let badge = manageTileBadgeCount(for: tile), badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(minWidth: 14, minHeight: 14)
                        .padding(.horizontal, 3)
                        .background(manageTileBadgeColor(for: tile))
                        .clipShape(Capsule())
                        .offset(x: 6, y: -5)
                }
            }
            Text(tile.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func manageTileBadgeCount(for tile: DetailTile) -> Int? {
        switch tile {
        case .scheduling: return schedulingAttentionCount
        case .tasks: return openTasksCount
        default: return nil
        }
    }

    private func manageTileBadgeColor(for tile: DetailTile) -> Color {
        switch tile {
        case .scheduling: return Color(red: 0.639, green: 0.176, blue: 0.176)
        default: return ProjectWorksRevampColors.blue
        }
    }

    private func tileIconBackground(for tile: DetailTile) -> Color {
        switch tile {
        case .scheduling: return Color(red: 0.902, green: 0.945, blue: 0.984)
        case .visibility: return ProjectWorksRevampColors.jobTypePillBg
        case .tasks: return Color(red: 0.882, green: 0.961, blue: 0.933)
        case .materials: return Color(red: 0.98, green: 0.933, blue: 0.855)
        case .siteAudit: return Color(red: 0.98, green: 0.925, blue: 0.906)
        case .location: return Color(red: 0.984, green: 0.918, blue: 0.941)
        }
    }

    private func tileIconForeground(for tile: DetailTile) -> Color {
        switch tile {
        case .scheduling: return ProjectWorksRevampColors.blue
        case .visibility: return Color(red: 0.325, green: 0.29, blue: 0.718)
        case .tasks: return ProjectWorksRevampColors.activeGreen
        case .materials: return ProjectWorksRevampColors.upcomingAmber
        case .siteAudit: return Color(red: 0.6, green: 0.235, blue: 0.114)
        case .location: return Color(red: 0.6, green: 0.208, blue: 0.337)
        }
    }
    
    @ViewBuilder
    private func tileDestination(for tile: DetailTile) -> some View {
        switch tile {
        case .visibility:
            ProjectVisibilitySettingsView(projectId: project.id)
                .environmentObject(projectStore)
                .environmentObject(userStore)
        case .siteAudit:
            SiteAuditProjectHubView(project: project)
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
                .environmentObject(projectStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
        case .materials:
            // Materials contains its own `List` and expandable layout; nesting it inside `ScrollView` gives the
            // list an unbounded height and often collapses the rows to zero (looks like “nothing saved”).
            MaterialsView(project: project)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
                .navigationTitle(tile.rawValue)
                .navigationBarTitleDisplayMode(.inline)
        case .scheduling, .tasks, .location:
            ScrollView {
                VStack(spacing: 20) {
                    switch tile {
                    case .scheduling:
                        schedulingContent
                    case .tasks:
                        tasksContent
                    case .location:
                        siteLocationSection
                    default:
                        EmptyView()
                    }
                }
                .padding()
            }
            .navigationTitle(tile.rawValue)
            .navigationBarTitleDisplayMode(.inline)
        }
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
        let dayManagerBookings = managerBookingsForDate(date)
        let daySubcontractorBookings = subcontractorBookingsForDate(date)
        let isToday = Calendar.current.isDateInToday(date)
        
        let fullDateString = formattedFullDate(date)
        
        return VStack(alignment: .leading, spacing: 12) {
            // Full date label
            HStack {
                Text(fullDateString)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(isToday ? .white : .primary)
                
                Spacer()
            }
            
            // Managers, operatives and sub contractors list
            if !dayManagerBookings.isEmpty || !dayBookings.isEmpty || !daySubcontractorBookings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(dayManagerBookings, id: \.id) { booking in
                        let managerName = userStore.organizationUsers.first(where: { $0.id == booking.userId })?.fullName ?? "Unknown Manager"
                        let timeSlotText = booking.timeSlot.displayName
                        
                        HStack {
                            Text(managerName)
                                .font(.body)
                                .foregroundColor(isToday ? .white : .primary)
                            
                            Spacer()
                            
                            Text(timeSlotText)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(isToday ? .white.opacity(0.9) : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isToday ? Color.white.opacity(0.2) : Color.purple.opacity(0.15))
                                .cornerRadius(6)
                        }
                    }
                    
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
                    
                    ForEach(daySubcontractorBookings, id: \.id) { booking in
                        let subbie = subcontractorStore.subcontractors.first { $0.id == booking.subcontractorId }
                        let subbieName = subbie?.name ?? "Unknown Sub Contractor"
                        let timeSlotText = booking.timeSlot.displayName
                        
                        HStack {
                            Text(subbieName)
                                .font(.body)
                                .foregroundColor(isToday ? .white : .primary)
                            Spacer()
                            Text(timeSlotText)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(isToday ? .white.opacity(0.9) : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isToday ? Color.white.opacity(0.2) : Color.indigo.opacity(0.15))
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
        let dayManagerBookings = managerBookingsForDate(date)
        let daySubcontractorBookings = subcontractorBookingsForDate(date)
        let isToday = Calendar.current.isDateInToday(date)
        let fullDateString = formattedFullDate(date)
        
        return VStack(alignment: .leading, spacing: 6) {
            Text(fullDateString)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(2)
                .foregroundColor(isToday ? .white : .primary)
            if let managerBooking = dayManagerBookings.first {
                let managerName = userStore.organizationUsers.first(where: { $0.id == managerBooking.userId })?.fullName ?? "Manager"
                Text(managerName)
                    .font(.caption2)
                    .lineLimit(2)
                    .foregroundColor(isToday ? .white : .primary)
            } else if let booking = dayBookings.first {
                let operative = operativeStore.activeOperatives.first { $0.id == booking.operativeId }
                Text(operative?.name ?? "Unassigned")
                    .font(.caption2)
                    .lineLimit(2)
                    .foregroundColor(isToday ? .white : .primary)
            } else if let subbieBooking = daySubcontractorBookings.first {
                let subbie = subcontractorStore.subcontractors.first { $0.id == subbieBooking.subcontractorId }
                Text(subbie?.name ?? "Sub Contractor")
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
            
            if hasValidLocation {
                VStack(alignment: .leading, spacing: 8) {
                    Text(locationDisplayText)
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
        HStack(spacing: 10) {
            Button(action: { showingScheduleOperative = true }) {
                Text("Schedule Operative")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.theme.primary)
                    .cornerRadius(12)
            }
            Button(action: { showingScheduleSubcontractor = true }) {
                Text("Schedule Sub Contractor")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.indigo)
                    .cornerRadius(12)
            }
        }
    }
    
    // MARK: - Helper Properties
    
    private var hasValidAddress: Bool {
        !project.siteAddress.isEmpty && project.siteAddress != "Site Location not available"
    }

    /// Any stored WGS84 coordinates (map pin mode or optional pin alongside address).
    private var hasStoredMapCoordinate: Bool {
        project.latitude != nil && project.longitude != nil
    }

    private var hasValidLocation: Bool {
        hasValidAddress || hasStoredMapCoordinate
    }

    private var locationDisplayText: String {
        if hasValidAddress { return project.siteAddress }
        if hasStoredMapCoordinate, let la = project.latitude, let lo = project.longitude {
            return String(format: "%.5f, %.5f", la, lo)
        }
        return ""
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
                tasks = tasks.filter { $0.allAssignedOperativeIds.contains(operativeId) }
            }
        case .manager:
            if let managerId = taskFilter.managerId {
                tasks = tasks.filter { $0.allAssignedManagerIds.contains(managerId) }
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
               let operative = operativeStore.allOperatives.first(where: { $0.email.lowercased() == currentUserEmail.lowercased() }) {
                tasks = tasks.filter { task in
                    // Check both legacy single assignment and new multiple assignments
                    task.allAssignedOperativeIds.contains(operative.id)
                }
            } else {
                // No operative found for this user, show empty
                tasks = []
            }
        } else {
            let email = userStore.currentUser?.email
            tasks = tasks.filter { task in
                task.isAssignedToUser(
                    userEmail: email,
                    operatives: operativeStore.allOperatives,
                    managers: operativeStore.allManagers,
                    isOperativeMode: false
                )
            }
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
    
    private func subcontractorBookingsForDate(_ date: Date) -> [SubcontractorBooking] {
        subcontractorStore.bookings.filter { booking in
            Calendar.current.isDate(booking.date, inSameDayAs: date) &&
            booking.projectId == project.id &&
            (booking.status == .confirmed || booking.status == .tentative)
        }.sorted { $0.timeSlot.rawValue < $1.timeSlot.rawValue }
    }
    
    private func managerBookingsForDate(_ date: Date) -> [ManagerSiteBooking] {
        managerScheduleStore.managerSiteBookings.filter { booking in
            Calendar.current.isDate(booking.date, inSameDayAs: date) &&
            booking.locationId == project.id &&
            (booking.locationType == .project || booking.locationType == .smallWork)
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
        managerScheduleStore.loadData()
        Task { await subcontractorStore.loadData() }
    }
    
    private func formattedFullDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let day = calendar.component(.day, from: date)
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEEE"
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM"
        return "\(weekdayFormatter.string(from: date)) \(day)\(ordinalSuffix(for: day)) \(monthFormatter.string(from: date))"
    }
    
    private func ordinalSuffix(for day: Int) -> String {
        if (11...13).contains(day % 100) { return "th" }
        switch day % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
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
        if hasStoredMapCoordinate, let la = project.latitude, let lo = project.longitude {
            let coord = CLLocationCoordinate2D(latitude: la, longitude: lo)
            Task { @MainActor in
                let placemark = MKPlacemark(coordinate: coord)
                mapItem = MKMapItem(placemark: placemark)
                updateRegion(with: coord)
            }
            return
        }
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
        if hasStoredMapCoordinate, let la = project.latitude, let lo = project.longitude {
            let ll = "\(la),\(lo)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "comgooglemaps://?q=\(ll)&center=\(ll)&zoom=17") {
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                    return
                }
            }
            if let webUrl = URL(string: "https://www.google.com/maps/search/?api=1&query=\(ll)") {
                UIApplication.shared.open(webUrl)
            }
            return
        }
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
        if hasStoredMapCoordinate, let la = project.latitude, let lo = project.longitude {
            let name = project.siteName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "http://maps.apple.com/?ll=\(la),\(lo)&q=\(name)") {
                UIApplication.shared.open(url)
            }
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
        if hasStoredMapCoordinate, let la = project.latitude, let lo = project.longitude {
            return CLLocationCoordinate2D(latitude: la, longitude: lo)
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
            
            if canEditCurrentWorkItem {
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
    
    private var canEditCurrentWorkItem: Bool {
        guard let u = userStore.currentUser else { return false }
        if u.permissions.operativeMode { return false }
        if u.isSuperAdmin || u.permissions.adminAccess { return true }
        guard u.permissions.manager else { return false }
        return project.jobType == .smallWorks ? u.permissions.smallWorks : u.permissions.projects
    }
}

private struct ProjectVisibilitySettingsView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore
    
    let projectId: UUID
    @State private var selectedTab: VisibilityTab = .managers
    @State private var searchText = ""
    @State private var filterMode: VisibilityFilterMode = .active
    @State private var showSearch = false
    
    private enum VisibilityTab: String, CaseIterable, Identifiable {
        case managers = "Managers"
        case operatives = "Operatives"
        var id: String { rawValue }
    }
    
    private enum VisibilityFilterMode: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case inactive = "Inactive"
        case pending = "Pending"
        var id: String { rawValue }
    }
    
    private var project: Project? {
        projectStore.projects.first(where: { $0.id == projectId })
    }
    
    private var managers: [AppUser] {
        filteredUsers(base: userStore.organizationUsers.filter { user in
            !user.permissions.operativeMode && user.permissions.manager
        })
    }
    
    private var operatives: [AppUser] {
        filteredUsers(base: userStore.organizationUsers.filter { $0.permissions.operativeMode })
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("View")
                .font(.title2.bold())
            Text("View can be used to hide projects or small works from users, where access to site audits or materials is prohibited for that user on that particular job.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Picker("Role", selection: $selectedTab) {
                ForEach(VisibilityTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            
            HStack(spacing: 12) {
                Menu {
                    ForEach(VisibilityFilterMode.allCases) { mode in
                        Button(mode.rawValue) { filterMode = mode }
                    }
                } label: {
                    Label("Filter: \(filterMode.rawValue)", systemImage: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.bordered)
                
                Button {
                    withAnimation { showSearch.toggle() }
                    if !showSearch { searchText = "" }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
            }
            
            if showSearch {
                TextField("Search user", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            
            List {
                ForEach(selectedTab == .managers ? managers : operatives) { user in
                    Button {
                        toggleVisibility(for: user)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(user.fullName.isEmpty ? user.email : user.fullName)
                                    .foregroundColor(.primary)
                                Text(user.email)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: isVisible(user) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isVisible(user) ? .blue : .gray)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
        }
        .padding()
        .navigationTitle("View")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func filteredUsers(base: [AppUser]) -> [AppUser] {
        base.filter { user in
            switch filterMode {
            case .all:
                return true
            case .active:
                return user.passwordSet && user.isActive
            case .inactive:
                return user.passwordSet && !user.isActive
            case .pending:
                return !user.passwordSet
            }
        }
        .filter { user in
            searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            user.fullName.localizedCaseInsensitiveContains(searchText) ||
            user.email.localizedCaseInsensitiveContains(searchText)
        }
        .sorted { ($0.fullName.isEmpty ? $0.email : $0.fullName) < ($1.fullName.isEmpty ? $1.email : $1.fullName) }
    }
    
    private func isVisible(_ user: AppUser) -> Bool {
        guard let project else { return false }
        if selectedTab == .managers {
            return !project.hiddenManagerUserIds.contains(user.id)
        }
        return !project.hiddenOperativeUserIds.contains(user.id)
    }
    
    private func toggleVisibility(for user: AppUser) {
        guard var project else { return }
        if selectedTab == .managers {
            if project.hiddenManagerUserIds.contains(user.id) {
                project.hiddenManagerUserIds.remove(user.id)
            } else {
                project.hiddenManagerUserIds.insert(user.id)
            }
        } else {
            if project.hiddenOperativeUserIds.contains(user.id) {
                project.hiddenOperativeUserIds.remove(user.id)
            } else {
                project.hiddenOperativeUserIds.insert(user.id)
            }
        }
        Task { await projectStore.updateProject(project) }
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
        .environmentObject(ManagerScheduleStore())
        .environmentObject(OperativeStore())
        .environmentObject(ProjectStore())
        .environmentObject(UserStore())
        .environmentObject(HolidayStore())
        .environmentObject(SubcontractorStore())
        .environmentObject(FirebaseBackend())
        .environmentObject(NotificationService())
        .environmentObject(AppSettingsStore())
        .environmentObject(ProjectTaskStore())
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
                priorityBadge
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

    private var priorityBadge: some View {
        Text(task.priority.rawValue.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.3)
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(priorityBackgroundColor)
            .clipShape(Capsule())
    }

    private var priorityBackgroundColor: Color {
        switch task.priority {
        case .low: return Color(.systemGray)
        case .normal: return Color(red: 0.2, green: 0.45, blue: 0.95)
        case .high: return Color.orange
        case .urgent: return Color.red
        }
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
    
    @State private var taskTitle = ""
    @State private var taskDescription = ""
    @State private var checklistRows: [TaskItemForm] = []
    @State private var selectedOperatives: Set<UUID> = []
    @State private var selectedManagers: Set<UUID> = []
    @State private var assignmentTradePreset: String? = nil
    @State private var dueDate = Date()
    @State private var priority: ProjectTask.Priority = .normal
    @State private var creatorLocalChecklistTicks: Set<UUID> = []
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
    
    private var managerEmailsLowercased: Set<String> {
        Set(operativeStore.activeManagers.map {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }
    
    var body: some View {
        NavigationView {
            Form {
                titleDescriptionPrioritySection
                checklistSection
                assignmentsSection
                Section {
                    DatePicker("Schedule", selection: $dueDate, displayedComponents: .date)
                } header: {
                    Text("Schedule")
                } footer: {
                    Text("A due date is required for every task.")
                }
                attachImagesSection
                attachFileSection
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
                    OperativeMultiSelectView(
                        selectedOperatives: $selectedOperatives,
                        operatives: operativeStore.activeOperatives,
                        tradePresetFilter: assignmentTradePreset,
                        excludedEmailsLowercased: managerEmailsLowercased
                    )
                }
                .sheet(isPresented: $showingManagerSelection) {
                    ManagerMultiSelectView(
                        selectedManagers: $selectedManagers,
                        managers: operativeStore.activeManagers,
                        tradePresetFilter: assignmentTradePreset
                    )
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

    private var titleDescriptionPrioritySection: some View {
        Group {
            Section {
                TextField("Task title", text: $taskTitle)
                TextField("Description", text: $taskDescription, axis: .vertical)
                    .lineLimit(3...10)
            } header: {
                Text("Task")
            }
            Section {
                Picker("Priority", selection: $priority) {
                    ForEach(ProjectTask.Priority.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Priority")
            }
        }
    }

    private var checklistSection: some View {
        Section {
            if checklistRows.isEmpty {
                Text("Optional checklist steps appear here. Tap below to add lines assignees will tick off.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach($checklistRows) { $item in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            if creatorLocalChecklistTicks.contains(item.id) {
                                creatorLocalChecklistTicks.remove(item.id)
                            } else {
                                creatorLocalChecklistTicks.insert(item.id)
                            }
                        } label: {
                            Image(systemName: creatorLocalChecklistTicks.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundColor(creatorLocalChecklistTicks.contains(item.id) ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        TextField("Checklist item", text: $item.title)
                    }
                    .padding(.vertical, 2)
                }
            }
            Button(action: {
                checklistRows.append(TaskItemForm())
            }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.green)
                        .font(.title2)
                    Text("Add checklist item")
                        .foregroundColor(.green)
                }
            }
        } header: {
            Text("Checklist")
        } footer: {
            Text("Checklist lines are saved with the task. Ticks here are for your planning only; assignees track progress on the task screen.")
        }
    }

    private var assignmentsSection: some View {
        Section {
            Picker("Trade filter", selection: $assignmentTradePreset) {
                Text("All trades").tag(Optional<String>.none)
                ForEach(StaffTradeType.pickerCases) { trade in
                    Text(trade.rawValue).tag(Optional<String>.some(trade.rawValue))
                }
            }

            Button(action: {
                showingManagerSelection = true
            }) {
                HStack {
                    Text("Managers")
                    Spacer()
                    if selectedManagers.isEmpty {
                        Text("Tap to select")
                            .foregroundColor(.secondary)
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
                    if let manager = operativeStore.activeManagers.first(where: { $0.id == managerId }) {
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

            Button(action: {
                showingOperativeSelection = true
            }) {
                HStack {
                    Text("Operatives")
                    Spacer()
                    if selectedOperatives.isEmpty {
                        Text("Tap to select")
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
                    if let operative = operativeStore.activeOperatives.first(where: { $0.id == operativeId }) {
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
        } header: {
            Text("Assignments")
        } footer: {
            Text("Choose at least one manager and/or operative. Use trade filter to narrow each list. Emails that match a manager profile are excluded from the operative picker so they are only chosen as managers.")
        }
    }

    private var attachImagesSection: some View {
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
    }

    private var attachFileSection: some View {
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
        let titleOk = !taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let assignmentOk = !selectedOperatives.isEmpty || !selectedManagers.isEmpty
        return titleOk && assignmentOk && !isSaving
    }
    
    private func saveTask() {
        guard canSaveTask else { return }
        isSaving = true
        let creatorName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
        
        let trimmedTitle = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let descTrimmed = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailsValue: String? = descTrimmed.isEmpty ? nil : descTrimmed
        
        let items: [ProjectTaskItem] = checklistRows
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { item in
                ProjectTaskItem(
                    id: item.id,
                    title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : item.description.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        
            Task {
                let assignedOperativeIds = Array(selectedOperatives)
                let assignedManagerIds = Array(selectedManagers)
                
                var task = ProjectTask(
                    projectId: project.id,
                    title: trimmedTitle,
                    details: detailsValue,
                    createdBy: creatorName,
                    assignedOperativeId: assignedOperativeIds.first,
                    assignedManagerId: assignedManagerIds.first,
                    assignedOperativeIds: assignedOperativeIds,
                    assignedManagerIds: assignedManagerIds,
                    dueDate: dueDate,
                    priority: priority,
                    status: .todo,
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
    
    @State private var taskTitle: String
    @State private var taskDescription: String
    @State private var checklistRows: [TaskItemForm]
    @State private var selectedOperatives: Set<UUID>
    @State private var selectedManagers: Set<UUID>
    @State private var assignmentTradePreset: String?
    @State private var dueDate: Date
    @State private var status: ProjectTask.Status
    @State private var priority: ProjectTask.Priority
    @State private var isSaving = false
    @State private var showingOperativeSelection = false
    @State private var showingManagerSelection = false
    
    private var managerEmailsLowercased: Set<String> {
        Set(operativeStore.activeManagers.map {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }
    
    init(task: ProjectTask, project: Project, isPresented: Binding<Bool>) {
        self.task = task
        self.project = project
        self._isPresented = isPresented
        
        _taskTitle = State(initialValue: task.title)
        _taskDescription = State(initialValue: task.details ?? "")
        let rows = task.items.map { TaskItemForm(id: $0.id, title: $0.title, description: $0.description ?? "") }
        _checklistRows = State(initialValue: rows)
        
        _selectedOperatives = State(initialValue: Set(task.allAssignedOperativeIds))
        _selectedManagers = State(initialValue: Set(task.allAssignedManagerIds))
        _assignmentTradePreset = State(initialValue: nil)
        _dueDate = State(initialValue: task.dueDate ?? Date())
        _status = State(initialValue: task.status)
        _priority = State(initialValue: task.priority)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Task title", text: $taskTitle)
                    TextField("Description", text: $taskDescription, axis: .vertical)
                        .lineLimit(3...10)
                } header: {
                    Text("Task")
                }
                
                Section {
                    Picker("Priority", selection: $priority) {
                        ForEach(ProjectTask.Priority.allCases, id: \.self) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Priority")
                }
                
                Section {
                    if checklistRows.isEmpty {
                        Text("No checklist lines yet.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach($checklistRows) { $item in
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Checklist item", text: $item.title)
                                TextField("Note (optional)", text: $item.description, axis: .vertical)
                                    .lineLimit(2...4)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Button(action: {
                        checklistRows.append(TaskItemForm())
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                            Text("Add checklist item")
                                .foregroundColor(.green)
                        }
                    }
                } header: {
                    Text("Checklist")
                }
                
                Section {
                    Picker("Trade filter", selection: $assignmentTradePreset) {
                        Text("All trades").tag(Optional<String>.none)
                        ForEach(StaffTradeType.pickerCases) { trade in
                            Text(trade.rawValue).tag(Optional<String>.some(trade.rawValue))
                        }
                    }
                    
                    Button(action: {
                        showingManagerSelection = true
                    }) {
                        HStack {
                            Text("Managers")
                            Spacer()
                            if selectedManagers.isEmpty {
                                Text("Tap to select")
                                    .foregroundColor(.secondary)
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
                        ManagerMultiSelectView(
                            selectedManagers: $selectedManagers,
                            managers: operativeStore.activeManagers,
                            tradePresetFilter: assignmentTradePreset
                        )
                    }
                    
                    if !selectedManagers.isEmpty {
                        ForEach(Array(selectedManagers), id: \.self) { managerId in
                            if let manager = operativeStore.activeManagers.first(where: { $0.id == managerId }) {
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
                    
                    Button(action: {
                        showingOperativeSelection = true
                    }) {
                        HStack {
                            Text("Operatives")
                            Spacer()
                            if selectedOperatives.isEmpty {
                                Text("Tap to select")
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
                    .sheet(isPresented: $showingOperativeSelection) {
                        OperativeMultiSelectView(
                            selectedOperatives: $selectedOperatives,
                            operatives: operativeStore.activeOperatives,
                            tradePresetFilter: assignmentTradePreset,
                            excludedEmailsLowercased: managerEmailsLowercased
                        )
                    }
                    
                    if !selectedOperatives.isEmpty {
                        ForEach(Array(selectedOperatives), id: \.self) { operativeId in
                            if let operative = operativeStore.activeOperatives.first(where: { $0.id == operativeId }) {
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
                } header: {
                    Text("Assignments")
                }
                
                Section {
                    DatePicker("Schedule", selection: $dueDate, displayedComponents: .date)
                } header: {
                    Text("Schedule")
                }
                
                Section("Status") {
                    Picker("Status", selection: $status) {
                        ForEach(ProjectTask.Status.allCases, id: \.rawValue) { st in
                            Text(st.rawValue).tag(st)
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
        let titleOk = !taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let assignmentOk = !selectedOperatives.isEmpty || !selectedManagers.isEmpty
        return titleOk && assignmentOk && !isSaving
    }
    
    private func saveTask() {
        guard canSaveTask else { return }
        isSaving = true
        
        let trimmedTitle = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let descTrimmed = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailsValue: String? = descTrimmed.isEmpty ? nil : descTrimmed
        
        let items: [ProjectTaskItem] = checklistRows
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { item in
                ProjectTaskItem(
                    id: item.id,
                    title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : item.description.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        
        Task {
            var updatedTask = task
            updatedTask.title = trimmedTitle
            updatedTask.details = detailsValue
            updatedTask.items = items
            updatedTask.dueDate = dueDate
            updatedTask.priority = priority
            updatedTask.status = status
            updatedTask.updatedAt = Date()
            
            updatedTask.assignedOperativeIds = Array(selectedOperatives)
            updatedTask.assignedOperativeId = selectedOperatives.first
            updatedTask.assignedManagerIds = Array(selectedManagers)
            updatedTask.assignedManagerId = selectedManagers.first
            
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
    @State private var selectedImages: [TaskCapturedImage] = []
    @State private var selectedFiles: [URL] = []
    @State private var showingCameraPicker = false
    @State private var showingImagePicker = false
    @State private var showingFilePicker = false
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var validationMessage: String?
    
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
                        showingCameraPicker = true
                    }) {
                        Label("Take Photos", systemImage: "camera.fill")
                    }

                    Button(action: {
                        showingImagePicker = true
                    }) {
                        Label("Choose From Library", systemImage: "photo")
                    }
                    
                    if !selectedImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array(selectedImages.enumerated()), id: \.element.id) { index, captured in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: captured.image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 100, height: 100)
                                            .clipped()
                                            .cornerRadius(8)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Spacer()
                                            Text(Self.watermarkText(for: captured.capturedAt))
                                                .font(.caption2)
                                                .foregroundColor(.white)
                                                .padding(4)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color.black.opacity(0.35))
                                        }
                                        .frame(width: 100, height: 100)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        
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

                    if isMarkedComplete && selectedImages.isEmpty {
                        Text("At least 1 completion photo is required.")
                            .font(.caption)
                            .foregroundColor(.red)
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
                    .disabled(
                        !isMarkedComplete ||
                        isUploading ||
                        selectedImages.isEmpty ||
                        (displayTask.isMultiItemTask && !displayTask.allItemsTicked)
                    )
                }
            }
            .sheet(isPresented: $showingCameraPicker) {
                TaskCameraPicker { image in
                    selectedImages.append(TaskCapturedImage(image: image, capturedAt: Date()))
                }
            }
            .sheet(isPresented: $showingImagePicker) {
                CompletionImagePicker(images: $selectedImages)
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.item, .data],
                allowsMultipleSelection: true
            ) { result in
                handleFileSelection(result)
            }
            .alert("Cannot Submit Task", isPresented: Binding(
                get: { validationMessage != nil },
                set: { isPresented in if !isPresented { validationMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage ?? "")
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
        guard !selectedImages.isEmpty else {
            validationMessage = "Please take or upload at least 1 photo before completing this task."
            return
        }
        
        isUploading = true
        uploadProgress = 0
        
        Task {
            let completedBy = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
            var imageURLs: [String] = []
            var fileURLs: [String] = []
            let totalUploads = max(selectedImages.count + selectedFiles.count, 1)
            
            // Upload images
            for captured in selectedImages {
                let stamped = addTimestampWatermark(to: captured.image, at: captured.capturedAt)
                if let url = await uploadImage(stamped) {
                    imageURLs.append(url)
                }
                uploadProgress += 1.0 / Double(totalUploads)
            }
            
            // Upload files
            for file in selectedFiles {
                if let url = await uploadFile(file) {
                    fileURLs.append(url)
                }
                uploadProgress += 1.0 / Double(totalUploads)
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
    
    private func addTimestampWatermark(to image: UIImage, at date: Date) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let text = Self.watermarkText(for: date)
        let scale = max(image.size.width, image.size.height) / 1200.0
        let fontSize = max(20, 28 * scale)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: UIColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding: CGFloat = max(20, 24 * scale)
        let backgroundPadding: CGFloat = max(10, 12 * scale)
        
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            let backgroundRect = CGRect(
                x: padding - backgroundPadding,
                y: image.size.height - textSize.height - padding - backgroundPadding,
                width: textSize.width + backgroundPadding * 2,
                height: textSize.height + backgroundPadding * 2
            )
            UIBezierPath(roundedRect: backgroundRect, cornerRadius: 8).addClip()
            UIColor.black.withAlphaComponent(0.2).setFill()
            UIRectFill(backgroundRect)
            text.draw(
                at: CGPoint(
                    x: padding,
                    y: image.size.height - textSize.height - padding
                ),
                withAttributes: attributes
            )
        }
    }
    
    private static func watermarkText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss"
        return formatter.string(from: date)
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

private struct CompletionImagePicker: UIViewControllerRepresentable {
    @Binding var images: [TaskCapturedImage]
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
    
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: CompletionImagePicker
        
        init(_ parent: CompletionImagePicker) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            
            for result in results {
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    if let image = object as? UIImage {
                        DispatchQueue.main.async {
                            self.parent.images.append(TaskCapturedImage(image: image, capturedAt: Date()))
                        }
                    }
                }
            }
        }
    }
}

private struct TaskCapturedImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let capturedAt: Date
}

private struct TaskCameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
        } else {
            // Simulator fallback: keep flow usable by selecting from library.
            picker.sourceType = .photoLibrary
        }
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: TaskCameraPicker
        
        init(_ parent: TaskCameraPicker) {
            self.parent = parent
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
        
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
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
                        
                        if displayTask.completionImages.isEmpty {
                            Text("N/A")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemBackground))
                        } else {
                            ScrollView(.horizontal, showsIndicators: true) {
                                HStack(spacing: 16) {
                                    ForEach(displayTask.completionImages, id: \.self) { imageURL in
                                        TaskCompletionImageView(urlString: imageURL)
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
    var tradePresetFilter: String? = nil
    var excludedEmailsLowercased: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    
    private var displayedOperatives: [Operative] {
        var list = operatives
        if !excludedEmailsLowercased.isEmpty {
            list = list.filter { op in
                let em = op.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                return !excludedEmailsLowercased.contains(em)
            }
        }
        if let fp = tradePresetFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !fp.isEmpty {
            list = list.filter { ($0.tradeTypePreset ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == fp }
        }
        return list
    }
    
    var body: some View {
        NavigationView {
            List {
                ForEach(displayedOperatives) { operative in
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
    var tradePresetFilter: String? = nil
    @Environment(\.dismiss) private var dismiss
    
    private var displayedManagers: [Manager] {
        var list = managers
        if let fp = tradePresetFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !fp.isEmpty {
            list = list.filter { ($0.tradeTypePreset ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == fp }
        }
        return list
    }
    
    var body: some View {
        NavigationView {
            List {
                ForEach(displayedManagers) { manager in
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

