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

fileprivate enum ProjectTaskListScope: String, Identifiable, Hashable {
    case assignedToMe = "Assigned to me"
    case active = "Active"
    case overdue = "Overdue"
    case completed = "Completed"
    var id: String { rawValue }
    static let orderedScopes: [ProjectTaskListScope] = [.assignedToMe, .active, .overdue, .completed]
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

    /// Admins and managers with project/small-works management access can configure View visibility and see all tasks on the job.
    private var canConfigureProjectVisibility: Bool {
        guard let u = userStore.currentUser else { return false }
        if u.permissions.operativeMode { return false }
        if userStore.hasAdminAccess() { return true }
        guard u.permissions.manager else { return false }
        return project.jobType == .smallWorks ? u.permissions.smallWorks : u.permissions.projects
    }

    private var canViewAllTasksOnThisJob: Bool { canConfigureProjectVisibility }

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }
    
    @State private var selectedWeek: Date = Date()
    @State private var showingScheduleOperative = false
    /// When non-nil, operative schedule opens pre-filled to edit this booking (same project).
    @State private var scheduleOperativeSeedBooking: Booking? = nil
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
    @State private var selectedProjectTaskScope: ProjectTaskListScope = .assignedToMe
    @State private var projectTasksSearchText = ""
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
        .sheet(isPresented: $showingScheduleOperative, onDismiss: { scheduleOperativeSeedBooking = nil }) {
            ScheduleOperativeView(project: project, editingBooking: scheduleOperativeSeedBooking)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(projectStore)
                .environmentObject(holidayStore)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
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
            Task {
                await taskStore.loadData()
            }
        }
        .onChange(of: showingAddTask) { _, isOpen in
            if !isOpen {
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
            if canConfigureProjectVisibility {
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
            .navigationTitle(tile == .tasks ? "Tasks" : tile.rawValue)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private var schedulingContent: some View {
        VStack(spacing: 14) {
            schedulingProjectContextCard
            schedulingWeekPickerCard
            schedulingDualActions
            schedulingWeekOverviewSection
        }
    }

    /// Design reference: `project_planner_scheduling_with_overtime.html` (context card, week strip, dual CTAs, list rows + OT).
    private var schedulingProjectContextCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(project.jobNumber)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.blue)
                Text(project.siteName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if project.jobType == .smallWorks {
                    Text("SMALL WORKS")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.98, green: 0.933, blue: 0.855))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else if let pill = heroJobTypePillText {
                    Text(pill.uppercased())
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.jobTypePillInk)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(ProjectWorksRevampColors.jobTypePillBg)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
            Text(schedulingClientSubtitle)
                .font(.system(size: 10))
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var schedulingClientSubtitle: String {
        let loc = [project.townCity, project.postcode].filter { !$0.isEmpty }.joined(separator: " ")
        if loc.isEmpty { return project.client.name }
        return "\(project.client.name) · \(loc)"
    }

    private var schedulingWeekPickerCard: some View {
        HStack(alignment: .center) {
            Button(action: { changeWeek(by: -1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            .buttonStyle(.plain)
            VStack(spacing: 2) {
                Text(schedulingWeekOfTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(schedulingWeekCountsSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            .frame(maxWidth: .infinity)
            Button(action: { changeWeek(by: 1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var schedulingWeekOfTitle: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return "Week of \(f.string(from: weekStartDate))"
    }

    private var schedulingWeekCountsSubtitle: String {
        let c = schedulingWeekOperativeAndSubCounts
        let opLabel = c.ops == 1 ? "op" : "ops"
        let subLabel = c.subs == 1 ? "sub" : "subs"
        return "\(c.ops) \(opLabel) · \(c.subs) \(subLabel)"
    }

    private var schedulingWeekOperativeAndSubCounts: (ops: Int, subs: Int) {
        var ops = 0
        var subs = 0
        for day in weekDays {
            ops += bookingsForDate(day).count
            subs += subcontractorBookingsForDate(day).count
        }
        return (ops, subs)
    }

    private var schedulingOperativeGradient: LinearGradient {
        LinearGradient(
            colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var schedulingSubcontractorGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.325, green: 0.290, blue: 0.718), Color(red: 0.498, green: 0.467, blue: 0.867)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var schedulingDualActions: some View {
        HStack(spacing: 7) {
            Button(action: {
                scheduleOperativeSeedBooking = nil
                showingScheduleOperative = true
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                    Text("Operative")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(schedulingOperativeGradient)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            Button(action: { showingScheduleSubcontractor = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "person.2.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                    Text("Sub")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(schedulingSubcontractorGradient)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var schedulingWeekOverviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Week overview")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Spacer()
                Button(action: toggleWeekViewMode) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 11, weight: .medium))
                        Text("Calendar")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(ProjectWorksRevampColors.blue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(ProjectWorksRevampColors.searchBorder, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
            if isCompactWeekView {
                schedulingCompactWeekGrid
            } else {
                schedulingListWeekOverview
            }
        }
    }

    private var schedulingListWeekOverview: some View {
        VStack(spacing: 6) {
            ForEach(weekDays, id: \.self) { day in
                schedulingDayCard(for: day)
            }
        }
    }

    private var schedulingCompactWeekGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(weekDays.prefix(5), id: \.self) { day in
                    schedulingCompactDayCell(for: day)
                }
            }
            HStack(spacing: 8) {
                ForEach(weekDays.suffix(2), id: \.self) { day in
                    schedulingCompactDayCell(for: day)
                }
                Spacer()
            }
        }
    }

    private func schedulingShortDayTitle(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "EEE · d MMM"
        var s = df.string(from: date)
        if Calendar.current.isDateInToday(date) {
            s += " · Today"
        }
        return s
    }

    private func schedulingDayBookedCount(_ date: Date) -> Int {
        bookingsForDate(date).count
            + managerBookingsForDate(date).count
            + subcontractorBookingsForDate(date).count
    }

    private func schedulingDayOvertimeTotal(_ date: Date) -> Double {
        let p = payrollTimePolicy
        var t = 0.0
        for b in bookingsForDate(date) {
            t += b.overtimeHoursBeyondPaidStandard(policy: p)
        }
        for b in managerBookingsForDate(date) {
            t += b.overtimeHoursBeyondPaidStandard(policy: p)
        }
        return t
    }

    private func subcontractorApproximateHours(_ booking: SubcontractorBooking) -> Double {
        let p = payrollTimePolicy
        switch booking.timeSlot {
        case .fullDay, .customHours: return max(p.standardPaidHours, 0)
        case .morning, .afternoon: return max(p.standardPaidHours, 0) / 2
        case .evening: return 4
        case .overtime: return 2
        }
    }

    private func subcontractorScheduleLabel(_ booking: SubcontractorBooking) -> String {
        switch booking.timeSlot {
        case .fullDay:
            return "\(payrollTimePolicy.standardDayStart)–\(payrollTimePolicy.standardDayEnd)"
        default:
            return booking.timeSlot.displayName
        }
    }

    private func formatSchedulingOTHours(_ hours: Double) -> String {
        let rounded = (hours * 2).rounded() / 2
        if abs(rounded - rounded.rounded(.towardZero)) < 0.01 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }

    private func schedulingHoursPill(hours: Double, hasOvertime: Bool) -> some View {
        let text = "\(formatSchedulingOTHours(hours))h"
        let bg = hasOvertime ? Color(red: 0.98, green: 0.933, blue: 0.855) : Color(red: 0.882, green: 0.961, blue: 0.933)
        let fg = hasOvertime ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.activeGreen
        return Text(text)
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private func schedulingAvatar(initials: String, accent: LinearGradient) -> some View {
        Text(initials)
            .font(.system(size: 7, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(accent)
            .clipShape(Circle())
    }

    private func schedulingDayCard(for date: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        let count = schedulingDayBookedCount(date)
        let dayOT = schedulingDayOvertimeTotal(date)
        let opBookings = bookingsForDate(date)
        let mgrBookings = managerBookingsForDate(date)
        let subBookings = subcontractorBookingsForDate(date)
        let hasRows = count > 0

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(schedulingShortDayTitle(date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isToday ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.ink)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if dayOT > 0.05 {
                        Text("+\(formatSchedulingOTHours(dayOT))h OT")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                    }
                    if count > 0 {
                        Text("\(count) booked")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.blue)
                    } else {
                        Text("No bookings")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                }
            }
            if hasRows {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(mgrBookings, id: \.id) { booking in
                        schedulingManagerBookingRow(booking: booking)
                    }
                    ForEach(opBookings, id: \.id) { booking in
                        schedulingOperativeBookingRow(booking: booking) {
                            scheduleOperativeSeedBooking = booking
                            showingScheduleOperative = true
                        }
                    }
                    ForEach(subBookings, id: \.id) { booking in
                        schedulingSubcontractorBookingRow(booking: booking)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isToday ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.border, lineWidth: isToday ? 0.5 : 0.5)
        )
    }

    private func schedulingOperativeBookingRow(booking: Booking, onTap: @escaping () -> Void) -> some View {
        let op = operativeStore.activeOperatives.first { $0.id == booking.operativeId }
        let name = op?.name ?? "Unknown operative"
        let initials = PlannerUIInitials.from(name)
        let p = payrollTimePolicy
        let hrs = booking.paidBookedHours(policy: p)
        let ot = booking.overtimeHoursBeyondPaidStandard(policy: p)
        return Button(action: onTap) {
            HStack(spacing: 6) {
                schedulingAvatar(initials: initials, accent: schedulingOperativeGradient)
                Text(name)
                    .font(.system(size: 10))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(booking.scheduleLabel(policy: p))
                    .font(.system(size: 9))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                schedulingHoursPill(hours: hrs, hasOvertime: ot > 0.05)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.muted.opacity(0.7))
            }
            .padding(EdgeInsets(top: 4, leading: 7, bottom: 4, trailing: 7))
            .background(ProjectWorksRevampColors.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func schedulingManagerBookingRow(booking: ManagerSiteBooking) -> some View {
        let managerName = userStore.organizationUsers.first(where: { $0.id == booking.userId })?.fullName ?? "Manager"
        let initials = PlannerUIInitials.from(managerName)
        let p = payrollTimePolicy
        let hrs = booking.paidBookedHours(policy: p)
        let ot = booking.overtimeHoursBeyondPaidStandard(policy: p)
        return HStack(spacing: 6) {
            schedulingAvatar(initials: initials, accent: schedulingSubcontractorGradient)
            Text(managerName)
                .font(.system(size: 10))
                .foregroundStyle(ProjectWorksRevampColors.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(booking.scheduleLabel(policy: p))
                .font(.system(size: 9))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            schedulingHoursPill(hours: hrs, hasOvertime: ot > 0.05)
        }
        .padding(EdgeInsets(top: 4, leading: 7, bottom: 4, trailing: 7))
        .background(ProjectWorksRevampColors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func schedulingSubcontractorBookingRow(booking: SubcontractorBooking) -> some View {
        let sub = subcontractorStore.subcontractors.first { $0.id == booking.subcontractorId }
        let name = sub?.name ?? "Subcontractor"
        let initials = PlannerUIInitials.from(name)
        let hrs = subcontractorApproximateHours(booking)
        let ot = max(0, hrs - max(payrollTimePolicy.standardPaidHours, 0))
        return HStack(spacing: 6) {
            schedulingAvatar(initials: initials, accent: schedulingSubcontractorGradient)
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(ProjectWorksRevampColors.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(subcontractorScheduleLabel(booking))
                .font(.system(size: 9))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            schedulingHoursPill(hours: hrs, hasOvertime: ot > 0.05)
        }
        .padding(EdgeInsets(top: 4, leading: 7, bottom: 4, trailing: 7))
        .background(ProjectWorksRevampColors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func schedulingCompactDayCell(for date: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        let count = schedulingDayBookedCount(date)
        let df = DateFormatter()
        df.dateFormat = "EEE d"
        return VStack(alignment: .leading, spacing: 4) {
            Text(df.string(from: date))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isToday ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.ink)
                .lineLimit(1)
            if count == 0 {
                Text("—")
                    .font(.system(size: 9))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            } else {
                Text("\(count)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.blue)
                Text("booked")
                    .font(.system(size: 8))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isToday ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.border, lineWidth: 0.5)
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
    
    /// Tasks on this project that belong in “My tasks” (assigned to you and/or created by you), after advanced filters.
    private func myProjectTasksAfterFilters() -> [ProjectTask] {
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
        
        // Admins and managing users with access: all tasks on this job (after filter chips). Others: assigned only.
        if canViewAllTasksOnThisJob {
            return tasks
        }
        let email = userStore.currentUser?.email
        let emNorm = email?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if userStore.isOperativeMode() {
            if let operative = operativeStore.allOperatives.first(where: {
                $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == emNorm
            }) {
                tasks = tasks.filter { task in
                    task.allAssignedOperativeIds.contains(operative.id)
                }
            } else {
                tasks = []
            }
        } else {
            tasks = tasks.filter { task in
                task.isAssignedToUser(
                    userEmail: email,
                    operatives: operativeStore.allOperatives,
                    managers: operativeStore.allManagers,
                    isOperativeMode: false
                )
            }
        }
        
        return tasks
    }
    
    private func filteredTasks(for scope: ProjectTaskListScope) -> [ProjectTask] {
        var tasks = myProjectTasksAfterFilters()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        
        switch scope {
        case .active:
            tasks = tasks.filter { !$0.isCompleted }
        case .completed:
            tasks = tasks.filter { $0.isCompleted }
        case .assignedToMe:
            tasks = tasks.filter { !$0.isCompleted }
            tasks = tasks.filter { task in
                task.isAssignedToUser(
                    userEmail: userStore.currentUser?.email,
                    operatives: operativeStore.allOperatives,
                    managers: operativeStore.allManagers,
                    isOperativeMode: userStore.isOperativeMode()
                )
            }
        case .overdue:
            tasks = tasks.filter { !$0.isCompleted }
            tasks = tasks.filter { task in
                guard let due = task.dueDate else { return false }
                return cal.startOfDay(for: due) < startOfToday
            }
        }
        
        if !projectTasksSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = projectTasksSearchText.lowercased()
            tasks = tasks.filter {
                $0.title.lowercased().contains(q)
                    || ($0.details ?? "").lowercased().contains(q)
            }
        }
        
        return tasks.sorted { $0.createdAt > $1.createdAt }
    }
    
    private var projectMyTasksStats: (todo: Int, inProgress: Int, overdue: Int, done: Int) {
        let base = myProjectTasksAfterFilters()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let incomplete = base.filter { !$0.isCompleted }
        let todo = incomplete.filter { $0.status == .todo }.count
        let inProgress = incomplete.filter { $0.status == .inProgress }.count
        let overdue = incomplete.filter { task in
            guard let due = task.dueDate else { return false }
            return cal.startOfDay(for: due) < startOfToday
        }.count
        let done = base.filter { $0.isCompleted }.count
        return (todo, inProgress, overdue, done)
    }
    
    private var projectTasksListForCurrentScope: [ProjectTask] {
        filteredTasks(for: selectedProjectTaskScope)
    }
    
    private var emptyTitleForProjectTaskScope: String {
        switch selectedProjectTaskScope {
        case .active: return "No active tasks"
        case .completed: return "No completed tasks"
        case .assignedToMe: return "Nothing assigned to you"
        case .overdue: return "No overdue tasks"
        }
    }
    
    private var emptySubtitleForProjectTaskScope: String {
        switch selectedProjectTaskScope {
        case .active:
            return "Create your first task to get started. Break it into checklist items, assign it to your team, and set a deadline."
        case .completed:
            return "Completed tasks for this project will appear here."
        case .assignedToMe:
            return "When someone assigns you on a task, it will show here."
        case .overdue:
            return "Overdue tasks still appear under Active. This filter shows only tasks past their due date."
        }
    }
    
    private func projectStatChip(value: Int, label: String, valueColor: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(valueColor)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(ProjectMyTasksPalette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ProjectMyTasksPalette.border, lineWidth: 0.5))
    }
    
    private func projectScopePill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : ProjectMyTasksPalette.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isSelected ? ProjectMyTasksPalette.blue : Color.white)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color(red: 229 / 255, green: 231 / 255, blue: 235 / 255), lineWidth: isSelected ? 0 : 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func projectScopePillTitle(_ scope: ProjectTaskListScope, activeCount: Int, overdueCount: Int, completedCount: Int) -> String {
        switch scope {
        case .assignedToMe: return "Assigned to me"
        case .active: return "Active · \(activeCount)"
        case .overdue: return overdueCount > 0 ? "Overdue · \(overdueCount)" : "Overdue"
        case .completed: return completedCount > 0 ? "Completed · \(completedCount)" : "Completed"
        }
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
        let policy = payrollTimePolicy
        return bookingStore.bookings.filter { booking in
            Calendar.current.isDate(booking.date, inSameDayAs: date) &&
            booking.projectId == project.id &&
            (booking.status == .confirmed || booking.status == .tentative)
        }.sorted { $0.minutesSortKey(policy: policy) < $1.minutesSortKey(policy: policy) }
    }
    
    private func subcontractorBookingsForDate(_ date: Date) -> [SubcontractorBooking] {
        subcontractorStore.bookings.filter { booking in
            Calendar.current.isDate(booking.date, inSameDayAs: date) &&
            booking.projectId == project.id &&
            (booking.status == .confirmed || booking.status == .tentative)
        }.sorted { $0.timeSlot.rawValue < $1.timeSlot.rawValue }
    }
    
    private func managerBookingsForDate(_ date: Date) -> [ManagerSiteBooking] {
        let policy = payrollTimePolicy
        return managerScheduleStore.managerSiteBookings.filter { booking in
            Calendar.current.isDate(booking.date, inSameDayAs: date) &&
            booking.locationId == project.id &&
            (booking.locationType == .project || booking.locationType == .smallWork)
        }.sorted { $0.minutesSortKey(policy: policy) < $1.minutesSortKey(policy: policy) }
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
    
    // MARK: - Tasks (project “My tasks” — aligned with my-tasks redesign)
    
    private enum ProjectMyTasksPalette {
        static let canvas = Color(red: 247 / 255, green: 248 / 255, blue: 250 / 255)
        static let ink = Color(red: 11 / 255, green: 16 / 255, blue: 32 / 255)
        static let muted = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)
        static let border = Color(red: 238 / 255, green: 240 / 255, blue: 243 / 255)
        static let blue = Color(red: 24 / 255, green: 95 / 255, blue: 165 / 255)
        static let todoCount = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)
        static let inProgressCount = Color(red: 133 / 255, green: 79 / 255, blue: 11 / 255)
        static let overdueCount = Color(red: 163 / 255, green: 45 / 255, blue: 45 / 255)
        static let doneCount = Color(red: 15 / 255, green: 110 / 255, blue: 86 / 255)
    }
    
    private var tasksContent: some View {
        let stats = projectMyTasksStats
        let base = myProjectTasksAfterFilters()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let activeCount = base.filter { !$0.isCompleted }.count
        let overdueCount = base.filter { !$0.isCompleted }.filter { task in
            guard let due = task.dueDate else { return false }
            return cal.startOfDay(for: due) < startOfToday
        }.count
        let completedCount = base.filter { $0.isCompleted }.count
        
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer(minLength: 0)
                if !userStore.isOperativeMode() {
                    Button(action: { showingAddTask = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(ProjectMyTasksPalette.blue)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            
            HStack(spacing: 8) {
                projectStatChip(value: stats.todo, label: "To do", valueColor: ProjectMyTasksPalette.todoCount)
                projectStatChip(value: stats.inProgress, label: "In progress", valueColor: ProjectMyTasksPalette.inProgressCount)
                projectStatChip(value: stats.overdue, label: "Overdue", valueColor: ProjectMyTasksPalette.overdueCount)
                projectStatChip(value: stats.done, label: "Done", valueColor: ProjectMyTasksPalette.doneCount)
            }
            
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(ProjectMyTasksPalette.muted)
                TextField("Search tasks…", text: $projectTasksSearchText)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                Button { showingTaskFilter = true } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(ProjectMyTasksPalette.blue)
                }
                .buttonStyle(.plain)
                .opacity(userStore.isOperativeMode() ? 0.35 : 1)
                .disabled(userStore.isOperativeMode())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(red: 229 / 255, green: 231 / 255, blue: 235 / 255), lineWidth: 0.5))
            
            if !userStore.isOperativeMode() {
                Text(taskFilterDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(ProjectMyTasksPalette.muted)
                    .lineLimit(2)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ProjectTaskListScope.orderedScopes, id: \.self) { scope in
                        projectScopePill(
                            title: projectScopePillTitle(scope, activeCount: activeCount, overdueCount: overdueCount, completedCount: completedCount),
                            isSelected: selectedProjectTaskScope == scope
                        ) { selectedProjectTaskScope = scope }
                    }
                }
            }
            
            if projectTasksListForCurrentScope.isEmpty {
                VStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 230 / 255, green: 241 / 255, blue: 251 / 255))
                        .frame(width: 56, height: 56)
                        .overlay(
                            Image(systemName: "clipboard.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(ProjectMyTasksPalette.blue)
                        )
                    Text(emptyTitleForProjectTaskScope)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ProjectMyTasksPalette.ink)
                    Text(emptySubtitleForProjectTaskScope)
                        .font(.system(size: 12))
                        .foregroundStyle(ProjectMyTasksPalette.muted)
                        .multilineTextAlignment(.center)
                    if selectedProjectTaskScope == .active && !userStore.isOperativeMode() {
                        Button { showingAddTask = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                Text("Create a task")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(ProjectMyTasksPalette.blue)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(32)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ProjectMyTasksPalette.border, lineWidth: 0.5))
            } else {
                VStack(spacing: 10) {
                    ForEach(projectTasksListForCurrentScope) { task in
                        ProjectTaskRow(
                            task: task,
                            project: project,
                            operativeNames: operativeNames(for: task.allAssignedOperativeIds),
                            managerNames: managerNames(for: task.allAssignedManagerIds)
                        )
                        .environmentObject(taskStore)
                        .environmentObject(userStore)
                        .environmentObject(firebaseBackend)
                        .environmentObject(operativeStore)
                        .environmentObject(projectStore)
                        .environmentObject(notificationService)
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
            .environmentObject(notificationService)
            .environmentObject(firebaseBackend)
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
            !user.permissions.operativeMode && user.permissions.manager && !user.isExcludedFromManagerVisibilityHiding
        })
    }
    
    private var operatives: [AppUser] {
        filteredUsers(base: userStore.organizationUsers.filter { $0.permissions.operativeMode })
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("View")
                .font(.title2.bold())
            Text("This feature can be used to select who will not be able to view the project or small works. Admins always have access and cannot be hidden.")
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
        if user.isExcludedFromManagerVisibilityHiding { return }
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
    
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var projectStore: ProjectStore
    
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
            
            Text("Created by \(task.createdBy)")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showingTaskDetail = true
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .sheet(isPresented: $showingTaskDetail) {
            CompletedTaskDetailView(task: task)
                .environmentObject(taskStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(projectStore)
                .environmentObject(firebaseBackend)
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

private enum TaskPeoplePickRoute: String, Identifiable {
    case managers
    case operatives
    case combined
    var id: String { rawValue }
}

/// Colours aligned with `project_planner_new_task_redesign.html`.
private enum NewTaskScreenPalette {
    static let canvas = Color(red: 247 / 255, green: 248 / 255, blue: 250 / 255)
    static let ink = Color(red: 11 / 255, green: 16 / 255, blue: 32 / 255)
    static let muted = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)
    static let placeholder = Color(red: 197 / 255, green: 201 / 255, blue: 210 / 255)
    static let border = Color(red: 238 / 255, green: 240 / 255, blue: 243 / 255)
    static let requiredBg = Color(red: 252 / 255, green: 235 / 255, blue: 235 / 255)
    static let requiredFg = Color(red: 163 / 255, green: 45 / 255, blue: 45 / 255)
    static let blue = Color(red: 24 / 255, green: 95 / 255, blue: 165 / 255)
    static let blueLight = Color(red: 55 / 255, green: 138 / 255, blue: 221 / 255)
    static let managerIconBg = Color(red: 251 / 255, green: 234 / 255, blue: 240 / 255)
    static let managerIconFg = Color(red: 153 / 255, green: 53 / 255, blue: 86 / 255)
    static let operativeSelectedFill = Color(red: 230 / 255, green: 241 / 255, blue: 251 / 255)
    static let scheduleIconBg = Color(red: 250 / 255, green: 236 / 255, blue: 231 / 255)
    static let scheduleIconFg = Color(red: 153 / 255, green: 60 / 255, blue: 29 / 255)
    static let photoIconBg = Color(red: 225 / 255, green: 245 / 255, blue: 238 / 255)
    static let photoIconFg = Color(red: 15 / 255, green: 110 / 255, blue: 86 / 255)
    static let cameraIconBg = Color(red: 238 / 255, green: 237 / 255, blue: 254 / 255)
    static let cameraIconFg = Color(red: 83 / 255, green: 74 / 255, blue: 183 / 255)
    static let fileIconBg = Color(red: 230 / 255, green: 241 / 255, blue: 251 / 255)
    static let priorityMediumBg = Color(red: 250 / 255, green: 238 / 255, blue: 218 / 255)
    static let priorityMediumInk = Color(red: 133 / 255, green: 79 / 255, blue: 11 / 255)
    static let disabledButton = Color(red: 197 / 255, green: 201 / 255, blue: 210 / 255)
}

private struct TaskPeoplePickerSheet: View {
    let route: TaskPeoplePickRoute
    @Binding var selectedManagers: Set<UUID>
    @Binding var selectedOperatives: Set<UUID>
    let managers: [Manager]
    let operatives: [Operative]
    var excludedOperativeEmails: Set<String> = []

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var tradeFilter: String? = nil

    private var navigationTitle: String {
        switch route {
        case .managers: return "Select managers"
        case .operatives: return "Select operatives"
        case .combined: return "Managers & operatives"
        }
    }

    private func normalizeEmail(_ raw: String) -> String {
        raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func managerTradeLabel(_ m: Manager) -> String {
        let custom = m.tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        return (m.tradeTypePreset ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func operativeTradeLabel(_ o: Operative) -> String {
        let custom = o.tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        return (o.tradeTypePreset ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var operativesEligible: [Operative] {
        operatives.filter { op in
            let em = normalizeEmail(op.email)
            return !excludedOperativeEmails.contains(em)
        }
    }

    private var tradeChoices: [String] {
        var set = Set<String>()
        switch route {
        case .managers:
            for m in managers {
                let t = managerTradeLabel(m)
                if !t.isEmpty { set.insert(t) }
            }
        case .operatives:
            for o in operativesEligible {
                let t = operativeTradeLabel(o)
                if !t.isEmpty { set.insert(t) }
            }
        case .combined:
            for m in managers {
                let t = managerTradeLabel(m)
                if !t.isEmpty { set.insert(t) }
            }
            for o in operativesEligible {
                let t = operativeTradeLabel(o)
                if !t.isEmpty { set.insert(t) }
            }
        }
        return set.sorted()
    }

    private var filteredManagers: [Manager] {
        var list = managers
        if let t = tradeFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            list = list.filter { managerTradeLabel($0) == t }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter {
                $0.fullName.localizedCaseInsensitiveContains(q)
                    || $0.email.localizedCaseInsensitiveContains(q)
                    || managerTradeLabel($0).localizedCaseInsensitiveContains(q)
            }
        }
        return list.sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    private var filteredOperatives: [Operative] {
        var list = operativesEligible
        if let t = tradeFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            list = list.filter { operativeTradeLabel($0) == t }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                    || $0.email.localizedCaseInsensitiveContains(q)
                    || operativeTradeLabel($0).localizedCaseInsensitiveContains(q)
            }
        }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    selectedChipsSection
                    searchFieldCard
                    tradeFilterCard
                    if route == .managers || route == .combined {
                        pickerSectionHeader("Managers", count: filteredManagers.count)
                        LazyVStack(spacing: 0) {
                            ForEach(filteredManagers) { manager in
                                managerRow(manager)
                            }
                        }
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
                    }
                    if route == .operatives || route == .combined {
                        pickerSectionHeader("Operatives", count: filteredOperatives.count)
                        LazyVStack(spacing: 0) {
                            ForEach(filteredOperatives) { operative in
                                operativeRow(operative)
                            }
                        }
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .background(NewTaskScreenPalette.canvas.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NewTaskScreenPalette.blue)
                }
            }
        }
    }

    private func pickerSectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NewTaskScreenPalette.muted)
                .tracking(0.4)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NewTaskScreenPalette.placeholder)
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var selectedChipsSection: some View {
        let mgrSelections = managers.filter { selectedManagers.contains($0.id) }.sorted { $0.fullName < $1.fullName }
        let opSelections = operativesEligible.filter { selectedOperatives.contains($0.id) }.sorted { $0.name < $1.name }
        if mgrSelections.isEmpty && opSelections.isEmpty {
            Text("Tick people below — selected names appear here and you can remove them.")
                .font(.system(size: 12))
                .foregroundStyle(NewTaskScreenPalette.muted)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(mgrSelections) { m in
                        selectionChip(label: m.fullName, systemImage: "person.fill.star") {
                            selectedManagers.remove(m.id)
                        }
                    }
                    ForEach(opSelections) { o in
                        selectionChip(label: o.name, systemImage: "person.fill") {
                            selectedOperatives.remove(o.id)
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
        }
    }

    private func selectionChip(label: String, systemImage: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NewTaskScreenPalette.blue)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NewTaskScreenPalette.ink)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(NewTaskScreenPalette.placeholder)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(NewTaskScreenPalette.operativeSelectedFill)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
    }

    private var searchFieldCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(NewTaskScreenPalette.placeholder)
            TextField("Search name, email, or trade…", text: $searchText)
                .font(.system(size: 15))
                .foregroundStyle(NewTaskScreenPalette.ink)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(NewTaskScreenPalette.placeholder)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
    }

    private var tradeFilterCard: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(NewTaskScreenPalette.fileIconBg)
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(NewTaskScreenPalette.blue)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Trade")
                    .font(.system(size: 11))
                    .foregroundStyle(NewTaskScreenPalette.muted)
                Menu {
                    Button("All trades") {
                        tradeFilter = nil
                    }
                    ForEach(tradeChoices, id: \.self) { t in
                        Button(t) {
                            tradeFilter = t
                        }
                    }
                } label: {
                    HStack {
                        Text(tradeFilter ?? "All trades")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NewTaskScreenPalette.ink)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NewTaskScreenPalette.placeholder)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
    }

    private func managerRow(_ manager: Manager) -> some View {
        let on = selectedManagers.contains(manager.id)
        let trade = managerTradeLabel(manager)
        return Button {
            if on {
                selectedManagers.remove(manager.id)
            } else {
                selectedManagers.insert(manager.id)
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(on ? NewTaskScreenPalette.blue : NewTaskScreenPalette.placeholder)
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.fullName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NewTaskScreenPalette.ink)
                    Text(trade.isEmpty ? manager.email : "\(trade) · \(manager.email)")
                        .font(.system(size: 11))
                        .foregroundStyle(NewTaskScreenPalette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private func operativeRow(_ operative: Operative) -> some View {
        let on = selectedOperatives.contains(operative.id)
        let trade = operativeTradeLabel(operative)
        return Button {
            if on {
                selectedOperatives.remove(operative.id)
            } else {
                selectedOperatives.insert(operative.id)
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(on ? NewTaskScreenPalette.blue : NewTaskScreenPalette.placeholder)
                VStack(alignment: .leading, spacing: 2) {
                    Text(operative.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NewTaskScreenPalette.ink)
                    Text(trade.isEmpty ? operative.email : "\(trade) · \(operative.email)")
                        .font(.system(size: 11))
                        .foregroundStyle(NewTaskScreenPalette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
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
    @State private var includeSelf = true
    @State private var includeManagers = false
    @State private var includeOperatives = false
    @State private var peoplePickRoute: TaskPeoplePickRoute? = nil
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
    @State private var showingCameraPicker = false
    @State private var uploadedImageURLs: [String] = []
    @State private var errorMessage: String?
    @State private var showingError = false
    private var managerEmailsLowercased: Set<String> {
        Set(operativeStore.activeManagers.map {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        heroCard
                        newTaskSectionHeader("Task", required: true)
                        taskFieldsCard
                        Text("Tip: Keep titles short and action-led — \"Replace fuse board\" not \"Some work to do\".")
                            .font(.system(size: 10))
                            .foregroundStyle(NewTaskScreenPalette.muted)
                            .padding(.leading, 4)
                        newTaskSectionHeader("Checklist", subtitle: "Optional")
                        checklistCard
                        Text("Assignees must tick all items to complete the task.")
                            .font(.system(size: 10))
                            .foregroundStyle(NewTaskScreenPalette.muted)
                            .padding(.leading, 4)
                        newTaskSectionHeader("Assign to", required: true)
                        assignToThreeButtonRow
                        assigneePickerRow
                        Text(assignToFooterHint)
                            .font(.system(size: 10))
                            .foregroundStyle(NewTaskScreenPalette.muted)
                            .padding(.leading, 4)
                        newTaskSectionHeader("Priority")
                        priorityGrid
                        newTaskSectionHeader("Schedule", subtitle: "Required")
                        scheduleCard
                        Text("Every task must have a due date.")
                            .font(.system(size: 10))
                            .foregroundStyle(NewTaskScreenPalette.muted)
                            .padding(.leading, 4)
                        newTaskSectionHeader("Attachments", subtitle: "Optional")
                        attachmentActionRow
                        Text("Files up to 10MB. Photos, PDFs, drawings supported.")
                            .font(.system(size: 10))
                            .foregroundStyle(NewTaskScreenPalette.muted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        if !selectedImages.isEmpty {
                            selectedImagesPreview
                        }
                        if selectedFileName != nil {
                            selectedFileCard
                        }
                        if isUploadingImages {
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: uploadProgress)
                                Text("Uploading images…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(NewTaskScreenPalette.muted)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .background(NewTaskScreenPalette.canvas.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomCreateBar
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NewTaskScreenPalette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
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
            .sheet(isPresented: $showingCameraPicker) {
                TaskCameraImagePicker(images: $selectedImages)
            }
            .sheet(item: $peoplePickRoute) { route in
                TaskPeoplePickerSheet(
                    route: route,
                    selectedManagers: $selectedManagers,
                    selectedOperatives: $selectedOperatives,
                    managers: operativeStore.activeManagers,
                    operatives: operativeStore.activeOperatives,
                    excludedOperativeEmails: managerEmailsLowercased
                )
            }
            .onChange(of: includeManagers) { _, on in
                if !on { selectedManagers.removeAll() }
            }
            .onChange(of: includeOperatives) { _, on in
                if !on { selectedOperatives.removeAll() }
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

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [NewTaskScreenPalette.blue, NewTaskScreenPalette.blueLight],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                Image(systemName: "checklist")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(NewTaskScreenPalette.canvas, lineWidth: 2))
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(NewTaskScreenPalette.blue)
                }
                .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Create a new task")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(NewTaskScreenPalette.ink)
                    .tracking(-0.2)
                Text("Assign to a manager or operative")
                    .font(.system(size: 12))
                    .foregroundStyle(NewTaskScreenPalette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
    }

    private func newTaskSectionHeader(_ title: String, required: Bool = false, subtitle: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NewTaskScreenPalette.muted)
                .tracking(0.4)
            if required {
                Text("REQUIRED")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(NewTaskScreenPalette.requiredFg)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(NewTaskScreenPalette.requiredBg)
                    .clipShape(Capsule())
            }
            if let subtitle {
                Text("· \(subtitle)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(NewTaskScreenPalette.placeholder)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
    }

    private var taskFieldsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Task title…", text: $taskTitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(NewTaskScreenPalette.ink)
            TextField("Add a description (optional)", text: $taskDescription, axis: .vertical)
                .font(.system(size: 12))
                .lineLimit(3...8)
                .foregroundStyle(NewTaskScreenPalette.ink)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
    }

    private var checklistCard: some View {
        VStack(spacing: 0) {
            ForEach($checklistRows) { $item in
                HStack(alignment: .center, spacing: 12) {
                    Button {
                        if creatorLocalChecklistTicks.contains(item.id) {
                            creatorLocalChecklistTicks.remove(item.id)
                        } else {
                            creatorLocalChecklistTicks.insert(item.id)
                        }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(NewTaskScreenPalette.placeholder, lineWidth: 1.5)
                                .frame(width: 18, height: 18)
                            if creatorLocalChecklistTicks.contains(item.id) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(NewTaskScreenPalette.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    TextField("Checklist item", text: $item.title)
                        .font(.system(size: 13))
                        .foregroundStyle(NewTaskScreenPalette.ink)
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 14))
                        .foregroundStyle(NewTaskScreenPalette.placeholder)
                    Button {
                        let rid = item.id
                        creatorLocalChecklistTicks.remove(rid)
                        checklistRows.removeAll { $0.id == rid }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(NewTaskScreenPalette.placeholder.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 11)
                Divider()
                    .overlay(NewTaskScreenPalette.border)
            }
            Button {
                checklistRows.append(TaskItemForm())
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(NewTaskScreenPalette.placeholder, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(NewTaskScreenPalette.placeholder)
                        )
                    Text("Add checklist item")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NewTaskScreenPalette.blue)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
    }

    private var assignToThreeButtonRow: some View {
        HStack(spacing: 8) {
            assignModePill(title: "Myself", isOn: $includeSelf) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 15, weight: .medium))
            }
            assignModePill(title: "Manager", isOn: $includeManagers) {
                Image(systemName: "person.fill")
                    .font(.system(size: 15, weight: .medium))
            }
            assignModePill(title: "Operatives", isOn: $includeOperatives) {
                assignOperativesClusterIcon(isOn: includeOperatives)
            }
        }
    }

    private func assignOperativesClusterIcon(isOn: Bool) -> some View {
        let c = isOn ? NewTaskScreenPalette.blue : NewTaskScreenPalette.muted
        return ZStack {
            Image(systemName: "person.fill")
                .font(.system(size: 9, weight: .medium))
                .offset(x: -5, y: 2)
                .foregroundStyle(c)
            Image(systemName: "person.fill")
                .font(.system(size: 9, weight: .medium))
                .offset(x: 5, y: 2)
                .foregroundStyle(c)
            Image(systemName: "person.fill")
                .font(.system(size: 8, weight: .medium))
                .offset(y: -4)
                .foregroundStyle(c.opacity(0.92))
        }
        .frame(width: 28, height: 20)
    }

    private func assignModePill<Icon: View>(title: String, isOn: Binding<Bool>, @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            VStack(spacing: 4) {
                icon()
                    .foregroundStyle(isOn.wrappedValue ? NewTaskScreenPalette.blue : NewTaskScreenPalette.muted)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isOn.wrappedValue ? NewTaskScreenPalette.blue : NewTaskScreenPalette.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
            .padding(.vertical, 10)
            .background(isOn.wrappedValue ? NewTaskScreenPalette.operativeSelectedFill : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isOn.wrappedValue ? NewTaskScreenPalette.blue : NewTaskScreenPalette.border, lineWidth: isOn.wrappedValue ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var assigneePickerRow: some View {
        if includeManagers || includeOperatives {
            Button {
                openPeoplePicker()
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(NewTaskScreenPalette.fileIconBg)
                        .frame(width: 34, height: 34)
                        .overlay(
                            Image(systemName: "person.2.badge.plus")
                                .font(.system(size: 15))
                                .foregroundStyle(NewTaskScreenPalette.blue)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(assigneePickerTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NewTaskScreenPalette.ink)
                        Text(assigneePickerSubtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(NewTaskScreenPalette.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NewTaskScreenPalette.placeholder)
                }
                .padding(14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    private var assigneePickerTitle: String {
        switch (includeManagers, includeOperatives) {
        case (true, true): return "Managers & operatives"
        case (true, false): return "Select managers"
        case (false, true): return "Select operatives"
        default: return ""
        }
    }

    private var assigneePickerSubtitle: String {
        let m = selectedManagers.count
        let o = selectedOperatives.count
        if includeManagers && includeOperatives {
            return m == 0 && o == 0 ? "Tap to choose people — search and trade filters inside" : "\(m) manager(s), \(o) operative(s)"
        }
        if includeManagers {
            return m == 0 ? "Tap to choose — tick names to build your list" : "\(m) manager(s) selected"
        }
        return o == 0 ? "Tap to choose — tick names to build your list" : "\(o) operative(s) selected"
    }

    private var assignToFooterHint: String {
        let sets = mergedAssignmentSets()
        if sets.managers.isEmpty && sets.operatives.isEmpty {
            return "Use Myself if you have a manager or operative profile, or enable Manager / Operative and pick people."
        }
        return "You can assign managers and operatives together. Open the picker to search, filter by trade, and tick people."
    }

    private func openPeoplePicker() {
        if includeManagers && includeOperatives {
            peoplePickRoute = .combined
        } else if includeManagers {
            peoplePickRoute = .managers
        } else if includeOperatives {
            peoplePickRoute = .operatives
        }
    }

    private func managerIdForCurrentUserEmail() -> UUID? {
        guard let em = userStore.currentUser?.email else { return nil }
        let n = em.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return operativeStore.allManagers.first(where: {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == n
        })?.id
    }

    private func operativeIdForCurrentUserEmail() -> UUID? {
        guard let em = userStore.currentUser?.email else { return nil }
        let n = em.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return operativeStore.allOperatives.first(where: {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == n
        })?.id
    }

    private func mergedAssignmentSets() -> (managers: Set<UUID>, operatives: Set<UUID>) {
        var mgr = Set<UUID>()
        var op = Set<UUID>()
        if includeManagers { mgr.formUnion(selectedManagers) }
        if includeOperatives { op.formUnion(selectedOperatives) }
        if includeSelf {
            if let id = managerIdForCurrentUserEmail() { mgr.insert(id) }
            if let id = operativeIdForCurrentUserEmail() { op.insert(id) }
        }
        return (mgr, op)
    }

    private var priorityGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                priorityChip(.low)
                priorityChip(.normal)
            }
            HStack(spacing: 8) {
                priorityChip(.high)
                priorityChip(.urgent)
            }
        }
    }

    private func priorityChip(_ level: ProjectTask.Priority) -> some View {
        let selected = priority == level
        return Button {
            priority = level
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(priorityDotColor(level))
                    .frame(width: 8, height: 8)
                Text(priorityShortLabel(level))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(priorityLabelColor(level, selected: selected))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(priorityBackground(level, selected: selected))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(priorityBorder(level, selected: selected), lineWidth: selected && level == .normal ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func priorityShortLabel(_ level: ProjectTask.Priority) -> String {
        switch level {
        case .low: return "Low"
        case .normal: return "Medium"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }

    private func priorityDotColor(_ level: ProjectTask.Priority) -> Color {
        switch level {
        case .low: return NewTaskScreenPalette.muted
        case .normal: return NewTaskScreenPalette.priorityMediumInk
        case .high: return NewTaskScreenPalette.requiredFg
        case .urgent: return Color(red: 120 / 255, green: 20 / 255, blue: 20 / 255)
        }
    }

    private func priorityLabelColor(_ level: ProjectTask.Priority, selected: Bool) -> Color {
        switch level {
        case .normal:
            return selected ? NewTaskScreenPalette.priorityMediumInk : NewTaskScreenPalette.muted
        default:
            return selected ? NewTaskScreenPalette.ink : NewTaskScreenPalette.muted
        }
    }

    private func priorityBackground(_ level: ProjectTask.Priority, selected: Bool) -> Color {
        if level == .normal, selected {
            return NewTaskScreenPalette.priorityMediumBg
        }
        return Color.white
    }

    private func priorityBorder(_ level: ProjectTask.Priority, selected: Bool) -> Color {
        if level == .normal, selected {
            return NewTaskScreenPalette.priorityMediumInk
        }
        if level == .urgent, selected {
            return NewTaskScreenPalette.requiredFg
        }
        if selected {
            return NewTaskScreenPalette.blue
        }
        return NewTaskScreenPalette.border
    }

    private var scheduleCard: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(NewTaskScreenPalette.scheduleIconBg)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: "flag.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(NewTaskScreenPalette.scheduleIconFg)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Due date")
                    .font(.system(size: 11))
                    .foregroundStyle(NewTaskScreenPalette.muted)
                DatePicker("", selection: $dueDate, displayedComponents: .date)
                    .labelsHidden()
                    .tint(NewTaskScreenPalette.blue)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NewTaskScreenPalette.placeholder)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
    }

    private var attachmentActionRow: some View {
        HStack(spacing: 8) {
            attachmentShortcutButton(
                title: "Photo",
                systemImage: "photo",
                iconBg: NewTaskScreenPalette.photoIconBg,
                iconFg: NewTaskScreenPalette.photoIconFg
            ) {
                showingImagePicker = true
            }
            attachmentShortcutButton(
                title: "Camera",
                systemImage: "camera.fill",
                iconBg: NewTaskScreenPalette.cameraIconBg,
                iconFg: NewTaskScreenPalette.cameraIconFg
            ) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showingCameraPicker = true
                }
            }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            .opacity(UIImagePickerController.isSourceTypeAvailable(.camera) ? 1 : 0.45)
            attachmentShortcutButton(
                title: "File",
                systemImage: "paperclip",
                iconBg: NewTaskScreenPalette.fileIconBg,
                iconFg: NewTaskScreenPalette.blue
            ) {
                showingFilePicker = true
            }
        }
    }

    private func attachmentShortcutButton(
        title: String,
        systemImage: String,
        iconBg: Color,
        iconFg: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconBg)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: systemImage)
                            .font(.system(size: 15))
                            .foregroundStyle(iconFg)
                    )
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NewTaskScreenPalette.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(NewTaskScreenPalette.placeholder)
            )
        }
        .buttonStyle(.plain)
    }

    private var selectedImagesPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 100, height: 100)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button {
                            selectedImages.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                        }
                        .padding(4)
                    }
                }
            }
        }
    }

    private var selectedFileCard: some View {
        Group {
            if let fileName = selectedFileName {
                HStack {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(NewTaskScreenPalette.blue)
                    Text(fileName)
                        .font(.system(size: 13))
                        .foregroundStyle(NewTaskScreenPalette.ink)
                    Spacer()
                    Button("Remove") {
                        selectedFile = nil
                        selectedFileName = nil
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NewTaskScreenPalette.requiredFg)
                }
                .padding(14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NewTaskScreenPalette.border, lineWidth: 0.5))
            }
        }
    }

    private var bottomCreateBar: some View {
        VStack(spacing: 8) {
            Button {
                saveTask()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 17, weight: .medium))
                    Text("Create task")
                        .font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canSaveTask && !isSaving ? NewTaskScreenPalette.blue : NewTaskScreenPalette.disabledButton)
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(!canSaveTask || isSaving)
            if isSaving {
                Text("Saving…")
                    .font(.system(size: 10))
                    .foregroundStyle(NewTaskScreenPalette.muted)
                    .frame(maxWidth: .infinity)
            } else if !canSaveTask {
                Text("Add a title and assignee to continue")
                    .font(.system(size: 10))
                    .foregroundStyle(NewTaskScreenPalette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            Color.white
                .shadow(color: .black.opacity(0.06), radius: 10, y: -2)
        )
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
        let sets = mergedAssignmentSets()
        let assignmentOk = !sets.managers.isEmpty || !sets.operatives.isEmpty
        return titleOk && assignmentOk && !isSaving
    }
    
    private func saveTask() {
        guard canSaveTask else { return }
        isSaving = true
        let creatorName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
        let sets = mergedAssignmentSets()
        let assignedManagerIds = Array(sets.managers)
        let assignedOperativeIds = Array(sets.operatives)
        
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

private enum CompleteTaskUXPalette {
    static let canvas = Color(red: 247 / 255, green: 248 / 255, blue: 250 / 255)
    static let ink = Color(red: 11 / 255, green: 16 / 255, blue: 32 / 255)
    static let muted = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)
    static let border = Color(red: 238 / 255, green: 240 / 255, blue: 243 / 255)
    static let blue = Color(red: 24 / 255, green: 95 / 255, blue: 165 / 255)
    static let blueLight = Color(red: 55 / 255, green: 138 / 255, blue: 221 / 255)
    static let green = Color(red: 15 / 255, green: 110 / 255, blue: 86 / 255)
    static let greenLight = Color(red: 45 / 255, green: 163 / 255, blue: 125 / 255)
    static let requiredBg = Color(red: 252 / 255, green: 235 / 255, blue: 235 / 255)
    static let requiredFg = Color(red: 163 / 255, green: 45 / 255, blue: 45 / 255)
    static let photoIconBg = Color(red: 238 / 255, green: 237 / 255, blue: 254 / 255)
    static let photoIconFg = Color(red: 83 / 255, green: 74 / 255, blue: 183 / 255)
    static let libraryIconBg = Color(red: 225 / 255, green: 245 / 255, blue: 238 / 255)
    static let disabledBar = Color(red: 197 / 255, green: 201 / 255, blue: 210 / 255)
}

struct TaskCompletionPopupView: View {
    let task: ProjectTask
    @Binding var isPresented: Bool
    /// completionNotes may be nil or empty when the user leaves notes blank.
    let onComplete: (String, [String], [String], String?) -> Void
    
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var projectStore: ProjectStore
    
    @State private var selectedImages: [TaskCapturedImage] = []
    @State private var selectedFiles: [URL] = []
    @State private var completionNotes: String = ""
    @State private var showingCameraPicker = false
    @State private var showingImagePicker = false
    @State private var showingFilePicker = false
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var validationMessage: String?
    
    private var displayTask: ProjectTask {
        taskStore.tasks.first(where: { $0.id == task.id }) ?? task
    }
    
    private var markCompleteEnabled: Bool {
        displayTask.allItemsTicked
    }
    
    private var checklistProgress: CGFloat {
        let items = displayTask.effectiveItems
        guard !items.isEmpty else { return 0 }
        let ids = Set(items.map(\.id))
        let done = Set(displayTask.completedItemIds).intersection(ids).count
        return CGFloat(done) / CGFloat(items.count)
    }
    
    private var checklistDoneLabel: String {
        let items = displayTask.effectiveItems
        let ids = Set(items.map(\.id))
        let done = Set(displayTask.completedItemIds).intersection(ids).count
        return "\(done) of \(items.count)"
    }
    
    private var tickRemainingHint: String {
        let items = displayTask.effectiveItems
        let ids = Set(items.map(\.id))
        let done = Set(displayTask.completedItemIds).intersection(ids).count
        let left = max(0, ids.count - done)
        if left <= 0 { return "" }
        return left == 1 ? "Tick 1 more item to enable" : "Tick \(left) more items to enable"
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    completeHeroCard
                    completeChecklistBlock
                    proofOfWorkBlock
                    notesBlock
                    if isUploading {
                        ProgressView(value: uploadProgress)
                            .tint(CompleteTaskUXPalette.blue)
                        Text("Uploading…")
                            .font(.system(size: 11))
                            .foregroundStyle(CompleteTaskUXPalette.muted)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
            .background(CompleteTaskUXPalette.canvas.ignoresSafeArea())
            .navigationTitle("Complete task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(CompleteTaskUXPalette.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color(red: 229 / 255, green: 231 / 255, blue: 235 / 255), lineWidth: 0.5))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 9) {
                    Button {
                        submitCompletion()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 18, weight: .medium))
                            Text("Mark task complete")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(Color.white)
                        .background(markCompleteEnabled && !isUploading ? CompleteTaskUXPalette.blue : CompleteTaskUXPalette.disabledBar)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .disabled(!markCompleteEnabled || isUploading)
                    if !markCompleteEnabled {
                        Text(tickRemainingHint)
                            .font(.system(size: 11))
                            .foregroundStyle(CompleteTaskUXPalette.muted)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 18)
                .background(Color.white)
                .overlay(Rectangle().frame(height: 0.5).foregroundStyle(CompleteTaskUXPalette.border), alignment: .top)
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
            .alert("Cannot complete task", isPresented: Binding(
                get: { validationMessage != nil },
                set: { isPresented in if !isPresented { validationMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage ?? "")
            }
        }
    }
    
    private var completeHeroCard: some View {
        HStack(alignment: .center, spacing: 16) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [CompleteTaskUXPalette.green, CompleteTaskUXPalette.greenLight],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 58, height: 58)
                .overlay(
                    Image(systemName: "checklist")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTask.title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(CompleteTaskUXPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(heroSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(CompleteTaskUXPalette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(CompleteTaskUXPalette.border, lineWidth: 0.5))
    }
    
    private var heroSubtitle: String {
        if let p = projectStore.projects.first(where: { $0.id == displayTask.projectId }) {
            return "\(p.jobNumber) \(p.siteName)"
        }
        if let sw = projectStore.smallWorks.first(where: { $0.id == displayTask.projectId }) {
            return "\(sw.jobNumber) \(sw.siteName)"
        }
        return ""
    }
    
    private var completeChecklistBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("CHECKLIST")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CompleteTaskUXPalette.muted)
                    .tracking(0.5)
                if displayTask.isMultiItemTask {
                    Text("REQUIRED")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CompleteTaskUXPalette.requiredFg)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(CompleteTaskUXPalette.requiredBg)
                        .clipShape(Capsule())
                }
                Spacer()
                Text(checklistDoneLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CompleteTaskUXPalette.muted)
            }
            .padding(.leading, 4)
            
            VStack(spacing: 0) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(CompleteTaskUXPalette.border)
                            .frame(height: 5)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [CompleteTaskUXPalette.blue, CompleteTaskUXPalette.blueLight],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(8, geo.size.width * checklistProgress), height: 5)
                    }
                }
                .frame(height: 5)
                .padding(.bottom, 16)
                
                ForEach(Array(displayTask.effectiveItems.enumerated()), id: \.element.id) { index, item in
                    let ticked = displayTask.completedItemIds.contains(item.id)
                    Button {
                        toggleItemTicked(itemId: item.id)
                    } label: {
                        HStack(alignment: .center, spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(ticked ? CompleteTaskUXPalette.green : Color.clear)
                                    .frame(width: 24, height: 24)
                                if !ticked {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Color(red: 197 / 255, green: 201 / 255, blue: 210 / 255), lineWidth: 1.5)
                                        .frame(width: 24, height: 24)
                                } else {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 14, weight: ticked ? .regular : .medium))
                                    .foregroundStyle(ticked ? CompleteTaskUXPalette.muted : CompleteTaskUXPalette.ink)
                                    .strikethrough(ticked, color: CompleteTaskUXPalette.muted)
                                if let desc = item.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.system(size: 12))
                                        .foregroundStyle(CompleteTaskUXPalette.muted)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    if index < displayTask.effectiveItems.count - 1 {
                        Divider().overlay(CompleteTaskUXPalette.border)
                    }
                }
            }
            .padding(16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(CompleteTaskUXPalette.border, lineWidth: 0.5))
            
            Text(displayTask.isMultiItemTask ? "Tick the last item to mark this task complete." : "Confirm the work is done, then mark complete below.")
                .font(.system(size: 11))
                .foregroundStyle(CompleteTaskUXPalette.muted)
                .padding(.leading, 4)
        }
    }
    
    private var proofOfWorkBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("PROOF OF WORK")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CompleteTaskUXPalette.muted)
                    .tracking(0.5)
                Text("· Optional")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color(red: 197 / 255, green: 201 / 255, blue: 210 / 255))
            }
            .padding(.leading, 4)
            
            HStack(spacing: 10) {
                proofShortcut(title: "Take photo", systemImage: "camera.fill", iconBg: CompleteTaskUXPalette.photoIconBg, iconFg: CompleteTaskUXPalette.photoIconFg) {
                    showingCameraPicker = true
                }
                proofShortcut(title: "From library", systemImage: "photo.on.rectangle", iconBg: CompleteTaskUXPalette.libraryIconBg, iconFg: CompleteTaskUXPalette.green) {
                    showingImagePicker = true
                }
                proofShortcut(title: "Add file", systemImage: "paperclip", iconBg: Color(red: 230 / 255, green: 241 / 255, blue: 251 / 255), iconFg: CompleteTaskUXPalette.blue) {
                    showingFilePicker = true
                }
            }
            
            if !selectedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(selectedImages.enumerated()), id: \.element.id) { index, captured in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: captured.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 78, height: 78)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                Button {
                                    selectedImages.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 22, height: 22)
                                        .background(CompleteTaskUXPalette.ink)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                }
                                .offset(x: 5, y: -5)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func proofShortcut(title: String, systemImage: String, iconBg: Color, iconFg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(iconBg)
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: systemImage)
                            .font(.system(size: 17))
                            .foregroundStyle(iconFg)
                    )
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CompleteTaskUXPalette.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .foregroundStyle(Color(red: 197 / 255, green: 201 / 255, blue: 210 / 255))
            )
        }
        .buttonStyle(.plain)
    }
    
    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("NOTES")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CompleteTaskUXPalette.muted)
                    .tracking(0.5)
                Text("· Optional")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color(red: 197 / 255, green: 201 / 255, blue: 210 / 255))
            }
            .padding(.leading, 4)
            TextField("", text: $completionNotes, prompt: Text("Anything the manager should know about how the job went…").foregroundStyle(CompleteTaskUXPalette.muted), axis: .vertical)
                .font(.system(size: 13))
                .lineLimit(4...8)
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(CompleteTaskUXPalette.border, lineWidth: 0.5))
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
        if !updatedTask.isCompleted {
            let effectiveIds = Set(updatedTask.effectiveItems.map(\.id))
            let done = Set(updatedTask.completedItemIds).intersection(effectiveIds)
            if done.isEmpty {
                updatedTask.status = .todo
            } else {
                updatedTask.status = .inProgress
            }
        }
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
        guard displayTask.allItemsTicked else {
            validationMessage = "Tick every checklist item before completing this task."
            return
        }
        
        isUploading = true
        uploadProgress = 0
        
        Task {
            let completedBy = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
            var imageURLs: [String] = []
            var fileURLs: [String] = []
            let totalUploads = max(selectedImages.count + selectedFiles.count, 1)
            
            for captured in selectedImages {
                let stamped = addTimestampWatermark(to: captured.image, at: captured.capturedAt)
                if let url = await uploadImage(stamped) {
                    imageURLs.append(url)
                }
                uploadProgress += 1.0 / Double(totalUploads)
            }
            
            for file in selectedFiles {
                if let url = await uploadFile(file) {
                    fileURLs.append(url)
                }
                uploadProgress += 1.0 / Double(totalUploads)
            }
            
            uploadProgress = 1.0
            
            let notesTrim = completionNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            let notesOut: String? = notesTrim.isEmpty ? nil : notesTrim
            
            await MainActor.run {
                isUploading = false
                onComplete(completedBy, imageURLs, fileURLs, notesOut)
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

// MARK: - Task camera (new task attachments)

private struct TaskCameraImagePicker: UIViewControllerRepresentable {
    @Binding var images: [UIImage]
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: TaskCameraImagePicker

        init(_ parent: TaskCameraImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            if let img = info[.originalImage] as? UIImage {
                DispatchQueue.main.async {
                    self.parent.images.append(img)
                    self.parent.dismiss()
                }
            } else {
                DispatchQueue.main.async {
                    self.parent.dismiss()
                }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            DispatchQueue.main.async {
                self.parent.dismiss()
            }
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

// MARK: - Completed Task Detail View (read-only + Carry out tasks)

struct CompletedTaskDetailView: View {
    let task: ProjectTask

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService

    @State private var showingCarryOut = false
    @State private var showingEditTask = false

    private var displayTask: ProjectTask {
        taskStore.tasks.first(where: { $0.id == task.id }) ?? task
    }

    private var canEditTask: Bool {
        userStore.hasAdminAccess() || userStore.displayUser?.permissions.manager == true
    }

    private var canEditTaskHere: Bool {
        canEditTask && projectStore.projects.first(where: { $0.id == displayTask.projectId }) != nil
    }

    private var canCarryOut: Bool {
        guard !displayTask.isCompleted else { return false }
        if userStore.hasAdminAccess() { return true }
        return displayTask.isAssignedToUser(
            userEmail: userStore.currentUser?.email,
            operatives: operativeStore.allOperatives,
            managers: operativeStore.allManagers,
            isOperativeMode: userStore.isOperativeMode()
        )
    }

    private var jobLine: String {
        if let p = projectStore.projects.first(where: { $0.id == displayTask.projectId }) {
            return "\(p.jobNumber) \(p.siteName)"
        }
        if let sw = projectStore.smallWorks.first(where: { $0.id == displayTask.projectId }) {
            return "\(sw.jobNumber) \(sw.siteName)"
        }
        return "Unknown job"
    }

    private var assignedSummary: String {
        let m = displayTask.allAssignedManagerIds.count
        let o = displayTask.allAssignedOperativeIds.count
        let total = m + o
        let me = displayTask.isAssignedToUser(
            userEmail: userStore.currentUser?.email,
            operatives: operativeStore.allOperatives,
            managers: operativeStore.allManagers,
            isOperativeMode: userStore.isOperativeMode()
        )
        if me && total > 1 {
            let others = max(0, total - 1)
            return others == 1 ? "You + 1 other" : "You + \(others) others"
        }
        if me { return "You" }
        var parts: [String] = []
        parts.append(contentsOf: displayTask.allAssignedManagerIds.compactMap { id in
            operativeStore.allManagers.first(where: { $0.id == id })?.fullName
        })
        parts.append(contentsOf: displayTask.allAssignedOperativeIds.compactMap { id in
            operativeStore.allOperatives.first(where: { $0.id == id })?.name
        })
        let joined = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        return joined.isEmpty ? "—" : joined
    }

    private var checklistDoneLabel: String {
        let items = displayTask.effectiveItems
        let ids = Set(items.map(\.id))
        let done = Set(displayTask.completedItemIds).intersection(ids).count
        return "\(done) of \(items.count) done"
    }

    private var checklistProgress: CGFloat {
        let items = displayTask.effectiveItems
        guard !items.isEmpty else { return 0 }
        let ids = Set(items.map(\.id))
        let done = Set(displayTask.completedItemIds).intersection(ids).count
        return CGFloat(done) / CGFloat(items.count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryHeroCard
                    sectionLabel("Details")
                    detailsCard
                    checklistHeader
                    readOnlyChecklistCard
                    attachmentsSection
                    if displayTask.isCompleted {
                        completionSummarySection
                    }
                    sectionLabel("Activity")
                    activityCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
            .background(CompleteTaskUXPalette.canvas.ignoresSafeArea())
            .navigationTitle("Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(CompleteTaskUXPalette.ink)
                            .frame(width: 36, height: 36)
                            .background(Color.white)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color(red: 229 / 255, green: 231 / 255, blue: 235 / 255), lineWidth: 0.5))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if canEditTaskHere {
                        Menu {
                            Button("Edit task") { showingEditTask = true }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(CompleteTaskUXPalette.ink)
                                .frame(width: 36, height: 36)
                                .background(Color.white)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color(red: 229 / 255, green: 231 / 255, blue: 235 / 255), lineWidth: 0.5))
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if canCarryOut {
                    HStack(spacing: 8) {
                        Button {
                            // Placeholder — messaging not wired
                        } label: {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 17))
                                .foregroundStyle(CompleteTaskUXPalette.ink)
                                .frame(width: 44, height: 44)
                                .background(Color(red: 247 / 255, green: 248 / 255, blue: 250 / 255))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(red: 229 / 255, green: 231 / 255, blue: 235 / 255), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        carryOutLabelButton
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .overlay(Rectangle().frame(height: 0.5).foregroundStyle(CompleteTaskUXPalette.border), alignment: .top)
                }
            }
            .sheet(isPresented: $showingCarryOut) {
                TaskCompletionPopupView(
                    task: displayTask,
                    isPresented: $showingCarryOut,
                    onComplete: { completedBy, images, files, notes in
                        Task {
                            await applyCompletion(completedBy: completedBy, images: images, files: files, notes: notes)
                        }
                    }
                )
                .environmentObject(firebaseBackend)
                .environmentObject(userStore)
                .environmentObject(taskStore)
                .environmentObject(projectStore)
            }
            .sheet(isPresented: $showingEditTask) {
                if let proj = projectStore.projects.first(where: { $0.id == displayTask.projectId }) {
                    EditProjectTaskView(
                        task: displayTask,
                        project: proj,
                        isPresented: $showingEditTask
                    )
                    .environmentObject(taskStore)
                    .environmentObject(operativeStore)
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
                }
            }
        }
    }

    private var summaryHeroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(displayTask.title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(CompleteTaskUXPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                statusCapsule
            }
            if let d = displayTask.details, !d.isEmpty {
                Text(d)
                    .font(.system(size: 13))
                    .foregroundStyle(CompleteTaskUXPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                priorityPill
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                    Text(jobLine)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(CompleteTaskUXPalette.blue)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color(red: 230 / 255, green: 241 / 255, blue: 251 / 255))
                .clipShape(Capsule())
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(CompleteTaskUXPalette.border, lineWidth: 0.5))
    }

    private var statusCapsule: some View {
        let (text, fg, bg, icon) = statusCapsuleParts
        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(bg)
        .clipShape(Capsule())
    }

    private var statusCapsuleParts: (String, Color, Color, String) {
        switch displayTask.status {
        case .todo:
            return ("To do", CompleteTaskUXPalette.muted, Color(red: 242 / 255, green: 243 / 255, blue: 245 / 255), "circle.dashed")
        case .inProgress:
            return ("In progress", Color(red: 133 / 255, green: 79 / 255, blue: 11 / 255), Color(red: 250 / 255, green: 238 / 255, blue: 218 / 255), "chart.line.uptrend.xyaxis")
        case .completed:
            return ("Done", CompleteTaskUXPalette.green, Color(red: 225 / 255, green: 245 / 255, blue: 238 / 255), "checkmark.circle.fill")
        }
    }

    private var priorityPill: some View {
        let (fg, bg, dot): (Color, Color, Color) = {
            switch displayTask.priority {
            case .low: return (CompleteTaskUXPalette.muted, Color(red: 242 / 255, green: 243 / 255, blue: 245 / 255), CompleteTaskUXPalette.muted)
            case .normal: return (Color(red: 133 / 255, green: 79 / 255, blue: 11 / 255), Color(red: 250 / 255, green: 238 / 255, blue: 218 / 255), Color(red: 133 / 255, green: 79 / 255, blue: 11 / 255))
            case .high, .urgent: return (CompleteTaskUXPalette.requiredFg, CompleteTaskUXPalette.requiredBg, CompleteTaskUXPalette.requiredFg)
            }
        }()
        return HStack(spacing: 4) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(displayTask.priority.rawValue)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(bg)
        .clipShape(Capsule())
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(CompleteTaskUXPalette.muted)
            .tracking(0.4)
            .padding(.leading, 4)
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            detailRow(icon: "person.fill", iconBg: Color(red: 238 / 255, green: 237 / 255, blue: 254 / 255), iconFg: Color(red: 83 / 255, green: 74 / 255, blue: 183 / 255), title: "Created by", value: createdByLine, showDivider: true)
            if let due = displayTask.dueDate {
                detailRow(icon: "flag.fill", iconBg: Color(red: 250 / 255, green: 236 / 255, blue: 231 / 255), iconFg: Color(red: 153 / 255, green: 60 / 255, blue: 29 / 255), title: "Due", value: dueLine(due), showDivider: true)
            }
            assignedRow
        }
        .padding(.horizontal, 14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(CompleteTaskUXPalette.border, lineWidth: 0.5))
    }

    private var createdByLine: String {
        let df = DateFormatter()
        df.dateFormat = "d MMM"
        return "\(displayTask.createdBy) · \(df.string(from: displayTask.createdAt))"
    }

    private func dueLine(_ due: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE d MMM yyyy"
        let base = df.string(from: due)
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        let tail = rel.localizedString(for: due, relativeTo: Date())
        let cal = Calendar.current
        if cal.startOfDay(for: due) >= cal.startOfDay(for: Date()) {
            return "\(base) · \(tail)"
        }
        return base
    }

    private func detailRow(icon: String, iconBg: Color, iconFg: Color, title: String, value: String, showDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconBg)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: icon).font(.system(size: 15)).foregroundStyle(iconFg))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(CompleteTaskUXPalette.muted)
                    Text(value)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CompleteTaskUXPalette.ink)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 11)
            if showDivider {
                Divider().overlay(CompleteTaskUXPalette.border)
            }
        }
    }

    private var assignedRow: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 230 / 255, green: 241 / 255, blue: 251 / 255))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "person.2.fill").font(.system(size: 15)).foregroundStyle(CompleteTaskUXPalette.blue))
            VStack(alignment: .leading, spacing: 2) {
                Text("Assigned to")
                    .font(.system(size: 11))
                    .foregroundStyle(CompleteTaskUXPalette.muted)
                Text(assignedSummary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CompleteTaskUXPalette.ink)
            }
            Spacer(minLength: 0)
            assigneeAvatarStack
        }
        .padding(.vertical, 11)
    }

    private var assigneeAvatarStack: some View {
        let initials = assigneeInitialsList
        return HStack(spacing: -6) {
            ForEach(Array(initials.enumerated()), id: \.offset) { _, ini in
                Text(ini)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        LinearGradient(
                            colors: [CompleteTaskUXPalette.blue, CompleteTaskUXPalette.blueLight],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            }
        }
    }

    private var assigneeInitialsList: [String] {
        var out: [String] = []
        for id in displayTask.allAssignedManagerIds {
            if let m = operativeStore.allManagers.first(where: { $0.id == id }) {
                out.append(Self.initials(from: m.fullName))
            }
        }
        for id in displayTask.allAssignedOperativeIds {
            if let o = operativeStore.allOperatives.first(where: { $0.id == id }) {
                out.append(Self.initials(from: o.name))
            }
        }
        return Array(out.prefix(4))
    }

    private static func initials(from fullName: String) -> String {
        let parts = fullName.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        if let p = parts.first { return String(p.prefix(2)).uppercased() }
        return "?"
    }

    private var checklistHeader: some View {
        HStack {
            Text("CHECKLIST")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CompleteTaskUXPalette.muted)
                .tracking(0.4)
            Spacer()
            Text(checklistDoneLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CompleteTaskUXPalette.blue)
        }
        .padding(.leading, 4)
    }

    private var readOnlyChecklistCard: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(CompleteTaskUXPalette.border)
                        .frame(height: 5)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [CompleteTaskUXPalette.blue, CompleteTaskUXPalette.blueLight],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * checklistProgress), height: 5)
                }
            }
            .frame(height: 5)
            .padding(.bottom, 14)
            ForEach(Array(displayTask.effectiveItems.enumerated()), id: \.element.id) { index, item in
                let ticked = displayTask.completedItemIds.contains(item.id)
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ticked ? CompleteTaskUXPalette.blue : Color.clear)
                            .frame(width: 20, height: 20)
                        if !ticked {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color(red: 197 / 255, green: 201 / 255, blue: 210 / 255), lineWidth: 1.5)
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundStyle(ticked ? CompleteTaskUXPalette.muted : CompleteTaskUXPalette.ink)
                        .strikethrough(ticked, color: CompleteTaskUXPalette.muted)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                if index < displayTask.effectiveItems.count - 1 {
                    Divider().overlay(CompleteTaskUXPalette.border)
                }
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(CompleteTaskUXPalette.border, lineWidth: 0.5))
    }

    private var carryOutLabelButton: some View {
        Button {
            showingCarryOut = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 16))
                Text("Carry out tasks")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(CompleteTaskUXPalette.blue)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var attachmentsSection: some View {
        Group {
            let n = (displayTask.attachedFileURL != nil ? 1 : 0) + displayTask.attachedImageURLs.count
            if n > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text("ATTACHMENTS")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CompleteTaskUXPalette.muted)
                            .tracking(0.4)
                        Text("· \(n) file\(n == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color(red: 197 / 255, green: 201 / 255, blue: 210 / 255))
                    }
                    .padding(.leading, 4)
                    VStack(spacing: 0) {
                        if let fileURL = displayTask.attachedFileURL {
                            attachmentRow(icon: "doc.fill", iconBg: CompleteTaskUXPalette.requiredBg, iconFg: CompleteTaskUXPalette.requiredFg, title: displayTask.attachedFileName ?? "File", subtitle: "Tap to open", url: fileURL, showDivider: !displayTask.attachedImageURLs.isEmpty)
                        }
                        ForEach(Array(displayTask.attachedImageURLs.enumerated()), id: \.offset) { idx, url in
                            attachmentRow(icon: "photo", iconBg: Color(red: 225 / 255, green: 245 / 255, blue: 238 / 255), iconFg: CompleteTaskUXPalette.green, title: "Image \(idx + 1)", subtitle: "Tap to open", url: url, showDivider: idx < displayTask.attachedImageURLs.count - 1)
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(CompleteTaskUXPalette.border, lineWidth: 0.5))
                }
            }
        }
    }

    private func attachmentRow(icon: String, iconBg: Color, iconFg: Color, title: String, subtitle: String, url: String, showDivider: Bool) -> some View {
        VStack(spacing: 0) {
            Button {
                if let u = URL(string: url) { UIApplication.shared.open(u) }
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconBg)
                        .frame(width: 32, height: 32)
                        .overlay(Image(systemName: icon).font(.system(size: 17)).foregroundStyle(iconFg))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(CompleteTaskUXPalette.ink)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(CompleteTaskUXPalette.muted)
                    }
                    Spacer()
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(CompleteTaskUXPalette.blue)
                }
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            if showDivider { Divider().overlay(CompleteTaskUXPalette.border) }
        }
    }

    private var completionSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Completion")
            VStack(alignment: .leading, spacing: 8) {
                if let by = displayTask.completedBy {
                    Text("Completed by \(by)")
                        .font(.system(size: 13))
                }
                if let at = displayTask.completedAt {
                    Text(at.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(CompleteTaskUXPalette.muted)
                }
                if let notes = displayTask.completionNotes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 13))
                        .foregroundStyle(CompleteTaskUXPalette.ink)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(CompleteTaskUXPalette.border, lineWidth: 0.5))
        }
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            activityRow(initials: Self.initials(from: displayTask.createdBy), gradient: [CompleteTaskUXPalette.blue, CompleteTaskUXPalette.blueLight], title: "\(displayTask.createdBy) created this task", subtitle: displayTask.createdAt.formatted(date: .abbreviated, time: .shortened))
            if displayTask.updatedAt > displayTask.createdAt.addingTimeInterval(60) {
                activityRow(initials: "•", gradient: [CompleteTaskUXPalette.muted, CompleteTaskUXPalette.muted], title: "Task updated", subtitle: displayTask.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(CompleteTaskUXPalette.border, lineWidth: 0.5))
    }

    private func activityRow(initials: String, gradient: [Color], title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(initials.count > 2 ? String(initials.prefix(2)) : initials)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(CompleteTaskUXPalette.ink)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(CompleteTaskUXPalette.muted)
            }
        }
    }

    private func applyCompletion(completedBy: String, images: [String], files: [String], notes: String?) async {
        var updatedTask = displayTask
        updatedTask.status = .completed
        updatedTask.completedBy = completedBy
        updatedTask.completedAt = Date()
        updatedTask.completionImages = images
        updatedTask.completionFiles = files
        updatedTask.completionNotes = notes
        updatedTask.updatedAt = Date()
        await taskStore.updateTask(updatedTask)
        if let creatorId = userStore.currentUser?.id {
            await notificationService.notifyTaskCompleted(
                taskId: updatedTask.id,
                taskTitle: updatedTask.title,
                completedBy: completedBy,
                assignedToUserId: creatorId
            )
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

