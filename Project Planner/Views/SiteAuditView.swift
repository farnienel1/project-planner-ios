import SwiftUI
import PhotosUI
import UIKit
import FirebaseAuth

enum SiteAuditType: String, CaseIterable, Codable, Identifiable {
    case preStart = "Pre-Start"
    case general = "General"
    case variations = "Variations"
    case snags = "Snags"
    var id: String { rawValue }
}

enum SiteAuditProjectFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case upcoming = "Upcoming"
    case completed = "Completed"
    var id: String { rawValue }
}

struct SiteAuditItem: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var location: String
    var assignee: String
    var comments: String
    var annotations: String
    var imageURL: String?
    var imageCapturedAt: Date?
    var createdAt: Date
}

struct SiteAudit: Identifiable, Codable, Hashable {
    let id: UUID
    var projectId: UUID
    var projectJobNumber: String
    var projectName: String
    var type: SiteAuditType
    /// Optional headline shown on cards and PDF (e.g. "Plant room snags").
    var customTitle: String
    var authorName: String
    var date: Date
    var items: [SiteAuditItem]
    var createdAt: Date
    var createdByUserId: String
    /// When false, operative-mode users do not see this audit in lists (managers/admins always see all).
    var visibleToOperatives: Bool
}

struct SiteAuditDraftItem: Identifiable {
    let id: UUID
    var title: String
    var location: String
    var assignee: String
    var comments: String
    var annotations: String
    var image: UIImage?
    var capturedAt: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        location: String = "",
        assignee: String = "",
        comments: String = "",
        annotations: String = "",
        image: UIImage? = nil,
        capturedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.assignee = assignee
        self.comments = comments
        self.annotations = annotations
        self.image = image
        self.capturedAt = capturedAt
        self.createdAt = createdAt
    }
}

enum SiteAuditWorksBrowserKind: String, Identifiable {
    case projects
    case smallWorks

    var id: String { rawValue }

    var navigationTitle: String {
        switch self {
        case .projects: return "Projects"
        case .smallWorks: return "Small works"
        }
    }

    func includes(_ project: Project) -> Bool {
        switch self {
        case .projects: return project.jobType != .smallWorks
        case .smallWorks: return project.jobType == .smallWorks
        }
    }
}

private struct SiteAuditProjectAccess {
    /// `ProjectStore.smallWorks` is a subset of `projects` — never concatenate the two.
    static func uniqueById(_ projects: [Project]) -> [Project] {
        ProjectWorksMerge.uniqueById(projects)
    }

    static func uniqueWorks(_ projects: [Project]) -> [Project] {
        ProjectWorksMerge.uniqueWorks(projects)
    }

    static func visibleWorks(
        userStore: UserStore,
        projectStore: ProjectStore,
        bookingStore: BookingStore,
        operativeStore: OperativeStore
    ) -> [Project] {
        let all = uniqueWorks(projectStore.projects)
        if !userStore.canViewSiteAudit() {
            return []
        }
        guard userStore.isOperativeMode() else {
            if let currentUser = userStore.currentUser,
               !userStore.hasAdminAccess(),
               currentUser.permissions.manager {
                return all.filter { !$0.hiddenManagerUserIds.contains(currentUser.id) }
            }
            return all
        }

        guard let email = userStore.currentUser?.email.lowercased(),
              let operative = operativeStore.allOperatives.first(where: { $0.email.lowercased() == email }),
              let currentUserId = userStore.currentUser?.id else {
            return []
        }

        let assigned = Set(bookingStore.bookings.filter {
            $0.operativeId == operative.id && ($0.status == .confirmed || $0.status == .tentative)
        }.map(\.projectId))
        return all.filter { assigned.contains($0.id) && !$0.hiddenOperativeUserIds.contains(currentUserId) }
    }

    static func visibleProjects(
        userStore: UserStore,
        projectStore: ProjectStore,
        bookingStore: BookingStore,
        operativeStore: OperativeStore
    ) -> [Project] {
        visibleWorks(
            userStore: userStore,
            projectStore: projectStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore
        ).filter { $0.jobType != .smallWorks }
    }

    static func visibleSmallWorks(
        userStore: UserStore,
        projectStore: ProjectStore,
        bookingStore: BookingStore,
        operativeStore: OperativeStore
    ) -> [Project] {
        visibleWorks(
            userStore: userStore,
            projectStore: projectStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore
        ).filter { $0.jobType == .smallWorks }
    }
}

fileprivate func siteAuditsForCurrentUser(_ audits: [SiteAudit], userStore: UserStore) -> [SiteAudit] {
    guard userStore.isOperativeMode() else { return audits }
    guard let uid = userStore.currentUser?.id else {
        return audits.filter(\.visibleToOperatives)
    }
    return audits.filter { $0.visibleToOperatives || $0.createdByUserId == uid }
}

fileprivate func canEditSiteAudit(_ audit: SiteAudit, userStore: UserStore, firebaseBackend: FirebaseBackend) -> Bool {
    if userStore.hasAdminAccess() { return true }
    if userStore.displayUser?.permissions.manager == true { return true }
    let firebaseUid = firebaseBackend.currentUser?.uid
    let appUserId = userStore.currentUser?.id
    if let firebaseUid, audit.createdByUserId == firebaseUid { return true }
    if let appUserId, audit.createdByUserId == appUserId { return true }
    return false
}

struct SiteAuditHubView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    @State private var showingCreate = false
    @State private var worksBrowserKind: SiteAuditWorksBrowserKind?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Site Audit")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(SiteAuditColors.text)
                    Text("Capture site evidence, notes, and produce a polished shareable PDF.")
                        .font(.system(size: 14))
                        .foregroundStyle(SiteAuditColors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { showingCreate = true } label: {
                    hubTile(icon: "plus", title: "New site audit", subtitle: "Start a new walkthrough", tint: SiteAuditColors.primary)
                }

                Button { worksBrowserKind = .projects } label: {
                    hubTile(icon: "folder.fill", title: "Projects", subtitle: "Browse audits by project", tint: SiteAuditColors.success)
                }

                Button { worksBrowserKind = .smallWorks } label: {
                    hubTile(icon: "wrench.and.screwdriver.fill", title: "Small works", subtitle: "Browse audits by small works job", tint: SiteAuditColors.purple)
                }

                Spacer()
            }
            .padding(20)
            .siteAuditScreenBackground()
            .navigationTitle("Site Audit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingCreate) {
                SiteAuditCreateFlowView()
                    .environmentObject(projectStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
            }
            .sheet(item: $worksBrowserKind) { kind in
                SiteAuditProjectsBrowserView(kind: kind)
                    .environmentObject(projectStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
            }
        }
    }

    private func hubTile(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        SiteAuditCard {
            HStack(spacing: 12) {
                SiteAuditRowIconChip(systemName: icon, tint: tint, background: tint.opacity(0.12), size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(SiteAuditColors.text)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(SiteAuditColors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SiteAuditColors.textDisabled)
            }
            .padding(14)
        }
    }
}

struct SiteAuditProjectsBrowserView: View {
    let kind: SiteAuditWorksBrowserKind

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @State private var selectedFilter: SiteAuditProjectFilter = .all
    @State private var selectedProject: Project?
    @State private var authoredAuditProjectIds: Set<UUID> = []

    private var mergedWorksForSiteAudit: [Project] {
        let visible: [Project] = {
            switch kind {
            case .projects:
                return SiteAuditProjectAccess.visibleProjects(
                    userStore: userStore,
                    projectStore: projectStore,
                    bookingStore: bookingStore,
                    operativeStore: operativeStore
                )
            case .smallWorks:
                return SiteAuditProjectAccess.visibleSmallWorks(
                    userStore: userStore,
                    projectStore: projectStore,
                    bookingStore: bookingStore,
                    operativeStore: operativeStore
                )
            }
        }()
        let fromAuthored = SiteAuditProjectAccess.uniqueById(projectStore.projects)
            .filter { kind.includes($0) && authoredAuditProjectIds.contains($0.id) }
        var byId: [UUID: Project] = [:]
        for project in visible { byId[project.id] = project }
        for project in fromAuthored { byId[project.id] = project }
        return Array(byId.values)
    }

    private var filteredProjects: [Project] {
        let scoped = mergedWorksForSiteAudit.filter { kind.includes($0) }
        switch selectedFilter {
        case .all: return scoped.sorted { $0.jobNumber.localizedStandardCompare($1.jobNumber) == .orderedAscending }
        case .active: return scoped.filter { $0.status == .active }.sorted { $0.jobNumber.localizedStandardCompare($1.jobNumber) == .orderedAscending }
        case .upcoming: return scoped.filter { $0.status == .upcoming }.sorted { $0.jobNumber.localizedStandardCompare($1.jobNumber) == .orderedAscending }
        case .completed: return scoped.filter { $0.status == .completed }.sorted { $0.jobNumber.localizedStandardCompare($1.jobNumber) == .orderedAscending }
        }
    }

    private var emptyTitle: String {
        kind == .projects ? "No Projects" : "No Small Works"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Filter", selection: $selectedFilter) {
                    ForEach(SiteAuditProjectFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                if filteredProjects.isEmpty {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: kind == .projects ? "folder" : "wrench.and.screwdriver",
                        description: Text(
                            userStore.isOperativeMode()
                            ? "Shows \(kind == .projects ? "projects" : "small works") you are booked onto, plus any job where you previously submitted a site audit."
                            : "Try switching the filter to All."
                        )
                    )
                } else {
                    List(filteredProjects) { project in
                        Button {
                            selectedProject = project
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.jobNumber).font(.headline)
                                Text(project.siteName).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(kind.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $selectedProject) { project in
                SiteAuditProjectAuditsView(project: project)
                    .environmentObject(projectStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
            }
            .task { await loadAuthoredAuditProjectIds() }
        }
    }

    private func loadAuthoredAuditProjectIds() async {
        guard userStore.isOperativeMode(),
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId,
              let uid = userStore.currentUser?.id else {
            await MainActor.run { authoredAuditProjectIds = [] }
            return
        }
        do {
            let audits = try await firebaseBackend.loadSiteAudits(organizationId: orgId, createdByUserId: uid)
            await MainActor.run {
                authoredAuditProjectIds = Set(audits.map(\.projectId))
            }
        } catch {
            await MainActor.run { authoredAuditProjectIds = [] }
        }
    }
}

struct SiteAuditProjectAuditsView: View {
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var smartCache: SmartCacheService

    @State private var audits: [SiteAudit] = []
    @State private var selectedTypeTab = "All"
    @State private var isLoading = false
    @State private var selectedAudit: SiteAudit?
    @State private var showingCreate = false

    private var visibleAudits: [SiteAudit] {
        siteAuditsForCurrentUser(audits, userStore: userStore)
    }

    var body: some View {
        NavigationStack {
            SiteAuditProjectListView(
                project: project,
                audits: .constant(visibleAudits),
                selectedTypeTab: $selectedTypeTab,
                isLoading: isLoading,
                onSelect: { selectedAudit = $0 },
                onCreate: { showingCreate = true },
                showsCreateButton: true
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadAudits() }
            .sheet(isPresented: $showingCreate, onDismiss: {
                Task { await loadAudits() }
            }) {
                SiteAuditCreateFlowView(initialProject: project, lockProjectSelection: true)
                    .environmentObject(projectStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
            }
            .sheet(item: $selectedAudit, onDismiss: {
                Task { await loadAudits() }
            }) { audit in
                SiteAuditDetailView(audit: audit, project: project, onAuditUpdated: {
                    Task { await loadAudits() }
                })
            }
        }
    }

    private func loadAudits() async {
        guard smartCache.isOnline else {
            await MainActor.run {
                audits = []
                isLoading = false
            }
            return
        }
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            audits = try await firebaseBackend.loadSiteAudits(organizationId: orgId, projectId: project.id)
        } catch {
            print("Site audit load error: \(error.localizedDescription)")
        }
    }
}

/// Site audits scoped to one project or small works job (from project detail).
struct SiteAuditProjectHubView: View {
    let project: Project
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var smartCache: SmartCacheService

    @State private var audits: [SiteAudit] = []
    @State private var selectedTypeTab = "All"
    @State private var isLoading = false
    @State private var selectedAudit: SiteAudit?
    @State private var showingCreate = false

    private var visibleAudits: [SiteAudit] {
        siteAuditsForCurrentUser(audits, userStore: userStore)
    }

    var body: some View {
        SiteAuditProjectListView(
            project: project,
            audits: .constant(visibleAudits),
            selectedTypeTab: $selectedTypeTab,
            isLoading: isLoading,
            onSelect: { selectedAudit = $0 },
            onCreate: { showingCreate = true }
        )
        .task { await loadAudits() }
        .sheet(isPresented: $showingCreate, onDismiss: {
            Task { await loadAudits() }
        }) {
            SiteAuditCreateFlowView(initialProject: project, lockProjectSelection: true)
                .environmentObject(projectStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .sheet(item: $selectedAudit, onDismiss: {
            Task { await loadAudits() }
        }) { audit in
            SiteAuditDetailView(audit: audit, project: project, onAuditUpdated: {
                Task { await loadAudits() }
            })
        }
    }

    private func loadAudits() async {
        guard smartCache.isOnline else {
            await MainActor.run {
                audits = []
                isLoading = false
            }
            return
        }
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            audits = try await firebaseBackend.loadSiteAudits(organizationId: orgId, projectId: project.id)
        } catch {
            print("Site audit load error: \(error.localizedDescription)")
        }
    }
}

struct SiteAuditCreateFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var smartCache: SmartCacheService

    /// When set, the flow starts on this project and optionally locks the picker.
    var initialProject: Project? = nil
    var lockProjectSelection: Bool = false
    /// When set, preloads fields and updates the existing audit on submit.
    var existingAudit: SiteAudit? = nil
    var onFinished: (() -> Void)? = nil

    @State private var step = 1
    @State private var selectedType: SiteAuditType = .general
    @State private var selectedProject: Project?
    @State private var selectedProjectFilter: SiteAuditProjectFilter = .all
    @State private var customTitle = ""
    @State private var authorName = ""
    @State private var selectedDate = Date()
    @State private var showingProjectPicker = false

    @State private var items: [SiteAuditDraftItem] = []
    @State private var editingItem: SiteAuditDraftItem?
    @State private var multiSelection: [PhotosPickerItem] = []
    @State private var isSubmitting = false
    @State private var submitStatusMessage = ""
    @State private var isProcessingPhotos = false
    @State private var errorMessage: String?

    @State private var showingSubmitSuccess = false
    @State private var submitSuccessPDFURL: URL?
    /// When true, operatives can see this audit in the app; when false, only admins/managers (not in operative mode).
    @State private var operativeAccessVisibleToOperatives = true
    @State private var didBootstrapExisting = false
    @State private var savedOffline = false

    private var isEditing: Bool { existingAudit != nil }

    private var canGoNext: Bool {
        selectedProject != nil && !authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleProjectsForPicker: [Project] {
        SiteAuditProjectAccess.uniqueWorks(
            SiteAuditProjectAccess.visibleWorks(
                userStore: userStore,
                projectStore: projectStore,
                bookingStore: bookingStore,
                operativeStore: operativeStore
            )
        )
    }

    private var flowNavigationTitle: String {
        switch step {
        case 1: return isEditing ? "Edit audit" : "New audit"
        case 2: return "Items"
        default: return isEditing ? "Update preview" : "Audit preview"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case 1: detailsStep
                case 2: itemsStep
                default: previewStep
                }
            }
            .navigationTitle(flowNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SiteAuditToolbarPill(title: "Back", filled: false) {
                        if step == 1 { dismiss() }
                        else if step == 2 { step = 1 }
                        else { step = 2 }
                    }
                }
                ToolbarItem(placement: .principal) {
                    if step == 2 {
                        VStack(spacing: 0) {
                            Text("\(selectedType.rawValue) ›")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(SiteAuditColors.textSecondary)
                            Text("Items · \(items.count)")
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if step == 1 {
                        SiteAuditToolbarPill(title: "Next", filled: true, disabled: !canGoNext) { step = 2 }
                    } else if step == 2 {
                        if isEditing {
                            SiteAuditToolbarPill(title: isSubmitting ? "Saving…" : "Save", filled: true, disabled: items.isEmpty || isSubmitting) {
                                submitAudit()
                            }
                        } else {
                            SiteAuditToolbarPill(title: "Preview", filled: true, disabled: items.isEmpty) { step = 3 }
                        }
                    }
                }
            }
                .sheet(item: $editingItem) { item in
                    SiteAuditAddItemView(item: item) { updated in
                        if let idx = items.firstIndex(where: { $0.id == updated.id }) {
                            items[idx] = updated
                        } else {
                            items.append(updated)
                        }
                    }
                }
                .sheet(isPresented: $showingProjectPicker) {
                    SiteAuditProjectPickerView(
                        selectedProject: $selectedProject,
                        selectedFilter: $selectedProjectFilter,
                        availableProjects: visibleProjectsForPicker
                    )
                }
                .sheet(isPresented: $showingSubmitSuccess, onDismiss: {
                    submitSuccessPDFURL = nil
                }) {
                    SiteAuditSubmitSuccessView(
                        pdfURL: submitSuccessPDFURL,
                        itemCount: items.count,
                        isUpdate: isEditing,
                        savedOffline: savedOffline,
                        onDone: {
                            showingSubmitSuccess = false
                            submitSuccessPDFURL = nil
                            onFinished?()
                            dismiss()
                        }
                    )
                }
                .onChange(of: multiSelection) { _, newValue in
                    if !newValue.isEmpty { Task { await addMultiPhotos(from: newValue) } }
                }
                .onAppear {
                    if let existing = existingAudit, !didBootstrapExisting {
                        bootstrapFromExisting(existing)
                        didBootstrapExisting = true
                    }
                    if authorName.isEmpty {
                        authorName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
                    }
                    if let p = initialProject {
                        selectedProject = p
                    }
                    if existingAudit == nil {
                        operativeAccessVisibleToOperatives = true
                    }
                }
                .alert("Site Audit", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(errorMessage ?? "")
                }
        }
    }

    private var detailsStep: some View {
        SiteAuditDetailsStepView(
            selectedType: $selectedType,
            selectedProject: $selectedProject,
            customTitle: $customTitle,
            authorName: $authorName,
            selectedDate: $selectedDate,
            operativeAccessVisibleToOperatives: $operativeAccessVisibleToOperatives,
            lockProjectSelection: lockProjectSelection,
            initialProject: initialProject,
            canManageVisibility: userStore.canManageSiteAuditOperativeVisibility(),
            onPickProject: { showingProjectPicker = true }
        )
    }

    @ViewBuilder
    private var itemsStep: some View {
        if let project = selectedProject ?? initialProject {
            SiteAuditItemsStepView(
                auditType: selectedType,
                project: project,
                authorName: authorName,
                items: $items,
                multiSelection: $multiSelection,
                isProcessingPhotos: isProcessingPhotos,
                onAddItem: { editingItem = SiteAuditDraftItem(assignee: authorName) },
                onEditItem: { editingItem = $0 },
                onDelete: { items.remove(atOffsets: $0) }
            )
        } else {
            ContentUnavailableView("Select a project", systemImage: "folder")
        }
    }

    @ViewBuilder
    private var previewStep: some View {
        if let project = selectedProject ?? initialProject {
            SiteAuditPreviewStepView(
                auditType: selectedType,
                project: project,
                customTitle: customTitle,
                authorName: authorName,
                date: selectedDate,
                clientName: project.client.name,
                items: items,
                organizationName: firebaseBackend.currentOrganization?.name,
                onEdit: { step = 2 },
                onSubmit: { submitAudit() },
                isSubmitting: isSubmitting,
                submitStatusMessage: submitStatusMessage,
                submitButtonTitle: isEditing ? "Update & generate PDF" : "Submit & generate PDF"
            )
        }
    }

    private func resolveProject(id: UUID) -> Project? {
        projectStore.projects.first { $0.id == id }
    }

    private func bootstrapFromExisting(_ existing: SiteAudit) {
        selectedType = existing.type
        customTitle = existing.customTitle
        authorName = existing.authorName
        selectedDate = existing.date
        operativeAccessVisibleToOperatives = existing.visibleToOperatives
        if selectedProject == nil {
            selectedProject = initialProject ?? resolveProject(id: existing.projectId)
        }
        items = existing.items.map { item in
            SiteAuditDraftItem(
                id: item.id,
                title: item.title,
                location: item.location,
                assignee: item.assignee,
                comments: item.comments,
                annotations: item.annotations,
                image: nil,
                capturedAt: item.imageCapturedAt,
                createdAt: item.createdAt
            )
        }
        Task { await hydrateItemImages(from: existing.items) }
    }

    private func hydrateItemImages(from saved: [SiteAuditItem]) async {
        var updated = items
        for item in saved {
            guard let urlString = item.imageURL,
                  let url = URL(string: urlString),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  let idx = updated.firstIndex(where: { $0.id == item.id }) else { continue }
            let normalized = await Task.detached(priority: .utility) {
                SiteAuditMediaProcessor.normalizedForDisplay(image)
            }.value
            updated[idx].image = normalized
        }
        await MainActor.run { items = updated }
    }

    private func addMultiPhotos(from selection: [PhotosPickerItem]) async {
        await MainActor.run {
            isProcessingPhotos = true
            submitStatusMessage = "Processing \(selection.count) photo\(selection.count == 1 ? "" : "s")…"
        }
        var newItems: [SiteAuditDraftItem] = []
        newItems.reserveCapacity(selection.count)
        for (index, entry) in selection.enumerated() {
            guard let data = try? await entry.loadTransferable(type: Data.self) else { continue }
            let captured = Date()
            let stamped = await Task.detached(priority: .userInitiated) {
                SiteAuditMediaProcessor.draftImage(from: data, capturedAt: captured)
            }.value
            guard let stamped else { continue }
            newItems.append(SiteAuditDraftItem(
                title: "Photo item",
                image: stamped,
                capturedAt: captured
            ))
            await MainActor.run {
                submitStatusMessage = "Processed \(index + 1) of \(selection.count) photos…"
            }
        }
        await MainActor.run {
            items.append(contentsOf: newItems)
            multiSelection = []
            isProcessingPhotos = false
            submitStatusMessage = ""
        }
    }

    private func submitAudit() {
        guard let selectedProject else {
            errorMessage = "Please select a project before submitting."
            return
        }

        isSubmitting = true
        let auditId = existingAudit?.id ?? UUID()
        let createdAt = existingAudit?.createdAt ?? Date()
        let createdByUserId = existingAudit?.createdByUserId ?? firebaseBackend.currentUser?.uid ?? "unknown"
        let project = selectedProject
        let drafts = items
        let type = selectedType
        let author = authorName
        let date = selectedDate
        let title = customTitle
        let visibilityChoice = operativeAccessVisibleToOperatives
        let existingItemsById = Dictionary(uniqueKeysWithValues: (existingAudit?.items ?? []).map { ($0.id, $0) })

        Task {
            let cachedOrgId = firebaseBackend.currentOrganization?.firestoreDocumentId
            let orgId: String?
            if smartCache.isOnline {
                orgId = await firebaseBackend.resolveOrganizationIdForFirebaseWrites(preferredFallback: cachedOrgId)
                    ?? cachedOrgId
            } else {
                orgId = cachedOrgId
            }
            guard let orgId, !orgId.isEmpty else {
                await MainActor.run {
                    isSubmitting = false
                    submitStatusMessage = ""
                    errorMessage = "Could not resolve your organization. Open Settings, tap Force Reload Data, wait until projects load, then try again."
                }
                return
            }

            if !smartCache.isOnline && !isEditing {
                await finishOfflineSubmit(
                    auditId: auditId,
                    organizationId: orgId,
                    project: project,
                    drafts: drafts,
                    type: type,
                    author: author,
                    date: date,
                    title: title,
                    visibilityChoice: visibilityChoice,
                    createdAt: createdAt,
                    createdByUserId: createdByUserId
                )
                return
            }

            var savedItems: [SiteAuditItem] = []
            var uploadFailures = 0
            let uploadCount = drafts.filter { draft in
                guard draft.image != nil else { return false }
                if isEditing,
                   let priorURL = existingItemsById[draft.id]?.imageURL,
                   !priorURL.isEmpty,
                   draft.capturedAt == existingItemsById[draft.id]?.imageCapturedAt {
                    return false
                }
                return true
            }.count
            var uploadIndex = 0
            for draft in drafts {
                var remoteURL: String?
                if let image = draft.image {
                    let priorURL = existingItemsById[draft.id]?.imageURL
                    let priorCapturedAt = existingItemsById[draft.id]?.imageCapturedAt
                    let imageUnchanged = isEditing
                        && priorURL != nil
                        && draft.capturedAt == priorCapturedAt
                    if imageUnchanged {
                        remoteURL = priorURL
                    } else {
                        uploadIndex += 1
                        let currentUpload = uploadIndex
                        await MainActor.run {
                            submitStatusMessage = uploadCount > 0
                                ? "Uploading photo \(currentUpload) of \(uploadCount)…"
                                : "Uploading photos…"
                        }
                        do {
                            remoteURL = try await firebaseBackend.uploadSiteAuditImage(
                                image,
                                auditId: auditId,
                                organizationId: orgId,
                                imageName: "site_audit_item_\(draft.id.uuidString)"
                            )
                        } catch {
                            uploadFailures += 1
                            remoteURL = priorURL
                        }
                    }
                } else {
                    remoteURL = existingItemsById[draft.id]?.imageURL
                }
                savedItems.append(SiteAuditItem(
                    id: draft.id,
                    title: draft.title,
                    location: draft.location,
                    assignee: draft.assignee,
                    comments: draft.comments,
                    annotations: draft.annotations,
                    imageURL: remoteURL,
                    imageCapturedAt: draft.capturedAt,
                    createdAt: draft.createdAt
                ))
            }

            let visibilityToOperatives: Bool = {
                if userStore.isOperativeMode() { return true }
                if userStore.canManageSiteAuditOperativeVisibility() { return visibilityChoice }
                return true
            }()
            let audit = SiteAudit(
                id: auditId,
                projectId: project.id,
                projectJobNumber: project.jobNumber,
                projectName: project.siteName,
                type: type,
                customTitle: title.trimmingCharacters(in: .whitespacesAndNewlines),
                authorName: author,
                date: date,
                items: savedItems,
                createdAt: createdAt,
                createdByUserId: createdByUserId,
                visibleToOperatives: visibilityToOperatives
            )

            do {
                await MainActor.run { submitStatusMessage = "Saving audit…" }
                try await firebaseBackend.saveSiteAudit(audit, organizationId: orgId)
                await MainActor.run { submitStatusMessage = "Generating PDF…" }
                let logoImage = await loadOrganizationLogoImage()
                let orgName = await MainActor.run { firebaseBackend.currentOrganization?.name }
                let pdfURL = await SiteAuditPDFBuilder.makePDFAsync(
                    audit: audit,
                    localItems: drafts,
                    organizationName: orgName,
                    logoImage: logoImage,
                    clientName: project.client.name,
                    siteAddress: project.siteAddress
                )
                await MainActor.run {
                    isSubmitting = false
                    submitStatusMessage = ""
                    if let pdfURL {
                        submitSuccessPDFURL = pdfURL
                        showingSubmitSuccess = true
                        if uploadFailures > 0 {
                            errorMessage = "Saved successfully. \(uploadFailures) photo\(uploadFailures == 1 ? "" : "s") could not be uploaded to cloud storage, but they are included in this PDF."
                        } else {
                            errorMessage = nil
                        }
                    } else {
                        errorMessage = "Audit saved, but PDF generation failed. Try opening the audit again to regenerate the PDF."
                    }
                }
            } catch {
                if !smartCache.isOnline || isOfflineNetworkError(error) {
                    if !isEditing {
                        await finishOfflineSubmit(
                            auditId: auditId,
                            organizationId: orgId,
                            project: project,
                            drafts: drafts,
                            type: type,
                            author: author,
                            date: date,
                            title: title,
                            visibilityChoice: visibilityChoice,
                            createdAt: createdAt,
                            createdByUserId: createdByUserId
                        )
                        return
                    }
                }
                await MainActor.run {
                    isSubmitting = false
                    submitStatusMessage = ""
                    errorMessage = isEditing
                        ? "Update failed: \(error.localizedDescription)"
                        : "Submit failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func finishOfflineSubmit(
        auditId: UUID,
        organizationId: String,
        project: Project,
        drafts: [SiteAuditDraftItem],
        type: SiteAuditType,
        author: String,
        date: Date,
        title: String,
        visibilityChoice: Bool,
        createdAt: Date,
        createdByUserId: String
    ) async {
        let visibilityToOperatives: Bool = {
            if userStore.isOperativeMode() { return true }
            if userStore.canManageSiteAuditOperativeVisibility() { return visibilityChoice }
            return true
        }()
        let savedItems = drafts.map { draft in
            SiteAuditItem(
                id: draft.id,
                title: draft.title,
                location: draft.location,
                assignee: draft.assignee,
                comments: draft.comments,
                annotations: draft.annotations,
                imageURL: nil,
                imageCapturedAt: draft.capturedAt,
                createdAt: draft.createdAt
            )
        }
        let audit = SiteAudit(
            id: auditId,
            projectId: project.id,
            projectJobNumber: project.jobNumber,
            projectName: project.siteName,
            type: type,
            customTitle: title.trimmingCharacters(in: .whitespacesAndNewlines),
            authorName: author,
            date: date,
            items: savedItems,
            createdAt: createdAt,
            createdByUserId: createdByUserId,
            visibleToOperatives: visibilityToOperatives
        )
        do {
            try SiteAuditOfflineStore.shared.enqueue(
                audit: audit,
                organizationId: organizationId,
                draftItems: drafts
            )
            let pdfURL = await SiteAuditPDFBuilder.makePDFAsync(
                audit: audit,
                localItems: drafts,
                organizationName: firebaseBackend.currentOrganization?.name,
                logoImage: nil,
                clientName: project.client.name,
                siteAddress: project.siteAddress
            )
            await MainActor.run {
                isSubmitting = false
                submitStatusMessage = ""
                savedOffline = true
                submitSuccessPDFURL = pdfURL
                showingSubmitSuccess = true
                errorMessage = nil
            }
        } catch {
            await MainActor.run {
                isSubmitting = false
                submitStatusMessage = ""
                errorMessage = "Could not save offline: \(error.localizedDescription)"
            }
        }
    }

    private func isOfflineNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorNotConnectedToInternet
        }
        return false
    }

    private func loadOrganizationLogoImage() async -> UIImage? {
        guard let logoURL = firebaseBackend.currentOrganization?.companyLogoURL,
              let url = URL(string: logoURL),
              url.scheme?.hasPrefix("http") == true else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}

// MARK: - Submit success (saved + share)

private struct SiteAuditSubmitSuccessView: View {
    let pdfURL: URL?
    let itemCount: Int
    var isUpdate = false
    var savedOffline = false
    let onDone: () -> Void

    @State private var showShareSheet = false

    private var headline: String {
        if savedOffline { return "Saved offline" }
        return isUpdate ? "Audit updated" : "Audit submitted"
    }
    private var subtitle: String {
        if savedOffline { return "Will sync when you're back online · PDF ready" }
        return isUpdate ? "Changes saved · PDF ready" : "Saved to cloud · PDF ready"
    }
    private var navigationTitle: String { isUpdate ? "Audit updated" : "Audit submitted" }

    private var shareActivityItems: [Any] {
        if let pdfURL { return [pdfURL] }
        return ["Site audit saved."]
    }

    private var fileName: String {
        pdfURL?.lastPathComponent ?? "Site audit.pdf"
    }

    private var fileSizeLabel: String {
        guard let pdfURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: pdfURL.path),
              let size = attrs[.size] as? Int64 else { return "" }
        let kb = Double(size) / 1024.0
        if kb < 1024 { return String(format: "%.0fKB", kb) }
        return String(format: "%.1fMB", kb / 1024.0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [SiteAuditColors.success, Color(red: 0.176, green: 0.639, blue: 0.490)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 78, height: 78)
                            .overlay {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 36, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .shadow(color: SiteAuditColors.success.opacity(0.25), radius: 16, y: 8)

                        Text(headline)
                            .font(.system(size: 19, weight: .medium))
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(SiteAuditColors.textSecondary)
                    }
                    .padding(.vertical, 22)

                    SiteAuditCard {
                        HStack(spacing: 11) {
                            pdfThumbnail
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fileName)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text("\(itemCount) item\(itemCount == 1 ? "" : "s")\(fileSizeLabel.isEmpty ? "" : " · \(fileSizeLabel)") · just now")
                                    .font(.system(size: 10))
                                    .foregroundStyle(SiteAuditColors.textSecondary)
                            }
                        }
                        .padding(12)
                    }
                    .padding(.bottom, 14)

                    SiteAuditPrimaryButton(title: "Share PDF", systemImage: "square.and.arrow.up", style: .success) {
                        showShareSheet = true
                    }
                    .padding(.bottom, 7)

                    if let pdfURL {
                        ShareLink(item: pdfURL) {
                            Text("Download")
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .foregroundStyle(SiteAuditColors.primary)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(SiteAuditColors.primary, lineWidth: 1)
                                )
                        }
                        .padding(.bottom, 7)
                    }

                    SiteAuditPrimaryButton(title: "Done", style: .secondary, action: onDone)
                        .padding(.bottom, 22)

                    Text("Tap Done to return to audits list")
                        .font(.system(size: 10))
                        .foregroundStyle(SiteAuditColors.textDisabled)
                }
                .padding(.horizontal, 16)
            }
            .siteAuditScreenBackground()
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SiteAuditIconCircleButton(systemName: "xmark", action: onDone)
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(activityItems: shareActivityItems)
            }
        }
    }

    private var pdfThumbnail: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white)
                .frame(width: 44, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(SiteAuditColors.borderStrong, lineWidth: 1)
                )
            Text("PDF")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(SiteAuditColors.danger)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
        }
        .frame(width: 44, height: 52)
    }
}

struct SiteAuditProjectPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedProject: Project?
    @Binding var selectedFilter: SiteAuditProjectFilter
    let availableProjects: [Project]

    private var filteredProjects: [Project] {
        switch selectedFilter {
        case .all: return availableProjects.sorted { $0.jobNumber < $1.jobNumber }
        case .active: return availableProjects.filter { $0.status == .active }.sorted { $0.jobNumber < $1.jobNumber }
        case .upcoming: return availableProjects.filter { $0.status == .upcoming }.sorted { $0.jobNumber < $1.jobNumber }
        case .completed: return availableProjects.filter { $0.status == .completed }.sorted { $0.jobNumber < $1.jobNumber }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Filter", selection: $selectedFilter) {
                    ForEach(SiteAuditProjectFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                }
                .pickerStyle(.segmented)
                .padding()
                List(filteredProjects) { project in
                    Button {
                        selectedProject = project
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.jobNumber).font(.headline)
                            Text(project.siteName).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
            .navigationTitle("Select Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
    }
}

struct SiteAuditAddItemView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SiteAuditDraftItem
    @State private var showingCamera = false
    @State private var showingLibrary = false
    let onSubmit: (SiteAuditDraftItem) -> Void

    init(item: SiteAuditDraftItem = SiteAuditDraftItem(), onSubmit: @escaping (SiteAuditDraftItem) -> Void) {
        self._draft = State(initialValue: item)
        self.onSubmit = onSubmit
    }

    private var canSave: Bool {
        draft.image != nil && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SiteAuditSectionLabel(title: "Photo")
                    photoBlock
                    HStack(spacing: 6) {
                        secondaryPhotoButton("Retake", icon: "camera.fill") { showingCamera = true }
                        secondaryPhotoButton("Library", icon: "photo.on.rectangle.angled") { showingLibrary = true }
                    }

                    SiteAuditSectionLabel(title: "Details")
                    SiteAuditCard {
                        VStack(spacing: 0) {
                            fieldBlock("Title", required: true) {
                                TextField("Front courtyard", text: $draft.title)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            divider
                            fieldBlock("Comments", required: false) {
                                TextField("Notes…", text: $draft.comments, axis: .vertical)
                                    .lineLimit(3...6)
                                    .font(.system(size: 12))
                            }
                            divider
                            assigneeRow
                            divider
                            fieldBlock("Location tag", required: false) {
                                TextField("e.g. Front entrance courtyard", text: $draft.location)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            divider
                            annotationsRow
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .siteAuditScreenBackground()
            .navigationTitle("New item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SiteAuditToolbarPill(title: "Cancel", filled: false) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SiteAuditToolbarPill(title: "Save", filled: true, disabled: !canSave) {
                        onSubmit(draft)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingCamera) {
                SiteAuditCameraPicker { applyPhoto($0) }
            }
            .sheet(isPresented: $showingLibrary) {
                SiteAuditPhotoLibraryPicker { applyPhoto($0) }
            }
        }
    }

    @ViewBuilder
    private var photoBlock: some View {
        if let image = draft.image {
            SiteAuditBoundedImage(image: image)
        } else {
            ZStack {
                LinearGradient(
                    colors: [SiteAuditColors.primaryTint, SiteAuditColors.primary.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Button { showingCamera = true } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                            .font(.title2)
                        Text("Add photo")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(SiteAuditColors.primary)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var assigneeRow: some View {
        HStack(spacing: 10) {
            SiteAuditRowIconChip(systemName: "person.fill", tint: SiteAuditColors.pink, background: SiteAuditColors.pinkTint, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Assignee")
                    .font(.system(size: 10))
                    .foregroundStyle(SiteAuditColors.textSecondary)
                TextField("Name", text: $draft.assignee)
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(.vertical, 11)
    }

    private var annotationsRow: some View {
        HStack(spacing: 10) {
            SiteAuditRowIconChip(systemName: "pencil.tip", tint: SiteAuditColors.warn, background: SiteAuditColors.warnTint, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Annotations")
                    .font(.system(size: 10))
                    .foregroundStyle(SiteAuditColors.textSecondary)
                TextField("Notes on photo", text: $draft.annotations)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SiteAuditColors.primary)
            }
        }
        .padding(.vertical, 11)
    }

    private var divider: some View {
        Rectangle().fill(SiteAuditColors.border).frame(height: 0.5)
    }

    private func fieldBlock<Content: View>(_ label: String, required: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text(label)
                if required { Text("*").foregroundStyle(SiteAuditColors.danger) }
            }
            .font(.system(size: 10))
            .foregroundStyle(SiteAuditColors.textSecondary)
            content()
        }
        .padding(.vertical, 11)
    }

    private func secondaryPhotoButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(SiteAuditColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(SiteAuditColors.borderStrong, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func applyPhoto(_ image: UIImage) {
        let now = Date()
        let normalized = SiteAuditMediaProcessor.normalizedForDisplay(image)
        draft.image = SiteAuditMediaProcessor.addTimestampWatermark(to: normalized, at: now)
        draft.capturedAt = now
    }
}

struct SiteAuditDetailView: View {
    let audit: SiteAudit
    var project: Project?
    var onAuditUpdated: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore

    @State private var displayAudit: SiteAudit
    @State private var resolvedProject: Project?
    @State private var selectedImageURL: String?
    @State private var pdfURL: URL?
    @State private var showShare = false
    @State private var showingEdit = false

    init(audit: SiteAudit, project: Project? = nil, onAuditUpdated: (() -> Void)? = nil) {
        self.audit = audit
        self.project = project
        self.onAuditUpdated = onAuditUpdated
        _displayAudit = State(initialValue: audit)
        _resolvedProject = State(initialValue: project)
    }

    private var canEdit: Bool {
        canEditSiteAudit(displayAudit, userStore: userStore, firebaseBackend: firebaseBackend)
    }

    private var clientProject: Project? {
        resolvedProject ?? project
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if canEdit {
                        SiteAuditAuditListCard(audit: displayAudit, onTap: { showingEdit = true })
                            .accessibilityLabel("Edit audit details")
                            .accessibilityHint("Opens the edit flow for this site audit")
                    } else {
                        SiteAuditAuditListCard(audit: displayAudit, showsChevron: false)
                    }
                    HStack(spacing: 8) {
                        SiteAuditPrimaryButton(title: "Share", systemImage: "square.and.arrow.up", style: .primary) {
                            Task {
                                if pdfURL == nil {
                                    await buildPDFPreview()
                                }
                                if pdfURL != nil {
                                    showShare = true
                                }
                            }
                        }
                        if canEdit {
                            SiteAuditPrimaryButton(title: "Edit Site Audit", systemImage: "square.and.pencil", style: .greyFilled) {
                                showingEdit = true
                            }
                        }
                    }
                    SiteAuditSectionLabel(title: "Summary")
                    SiteAuditCard {
                        VStack(spacing: 0) {
                            summaryLine("Author", displayAudit.authorName)
                            if !displayAudit.customTitle.isEmpty {
                                divider
                                summaryLine("Title", displayAudit.customTitle)
                            }
                            divider
                            summaryLine("Date", displayAudit.date.formatted(date: .abbreviated, time: .omitted))
                            if let clientProject {
                                divider
                                summaryLine("Client", clientProject.client.name)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    SiteAuditSectionLabel(title: "Items", suffix: "· \(displayAudit.items.count)")
                    ForEach(Array(displayAudit.items.enumerated()), id: \.element.id) { index, item in
                        itemCard(index: index + 1, item: item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .siteAuditScreenBackground()
            .navigationTitle("Audit detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if resolvedProject == nil {
                    resolvedProject = projectStore.projects.first { $0.id == displayAudit.projectId }
                }
                await buildPDFPreview()
            }
            .sheet(isPresented: $showShare) {
                if let pdfURL {
                    ShareSheet(activityItems: [pdfURL])
                }
            }
            .sheet(isPresented: $showingEdit) {
                SiteAuditCreateFlowView(
                    initialProject: clientProject,
                    lockProjectSelection: true,
                    existingAudit: displayAudit,
                    onFinished: {
                        Task {
                            await reloadAudit()
                            onAuditUpdated?()
                        }
                    }
                )
                .environmentObject(projectStore)
                .environmentObject(bookingStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
            }
            .sheet(isPresented: Binding(
                get: { selectedImageURL != nil },
                set: { if !$0 { selectedImageURL = nil } }
            )) {
                NavigationStack {
                    AsyncImage(url: URL(string: selectedImageURL ?? "")) { image in
                        image.resizable().scaledToFit()
                    } placeholder: { ProgressView() }
                    .padding()
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { selectedImageURL = nil } } }
                }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(SiteAuditColors.border).frame(height: 0.5)
    }

    private func summaryLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(SiteAuditColors.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.vertical, 11)
    }

    private func itemCard(index: Int, item: SiteAuditItem) -> some View {
        SiteAuditCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(index). \(item.title.isEmpty ? "Untitled" : item.title)")
                    .font(.system(size: 12, weight: .medium))
                if !item.location.isEmpty {
                    Text(item.location).font(.system(size: 10)).foregroundStyle(SiteAuditColors.textSecondary)
                }
                if !item.comments.isEmpty {
                    Text(item.comments).font(.system(size: 11))
                }
                if let url = item.imageURL, let imageURL = URL(string: url) {
                    Button { selectedImageURL = url } label: {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFill()
                            default: SiteAuditColors.primaryTint
                            }
                        }
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }

    private func reloadAudit() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        do {
            let audits = try await firebaseBackend.loadSiteAudits(
                organizationId: orgId,
                projectId: displayAudit.projectId
            )
            guard let fresh = audits.first(where: { $0.id == displayAudit.id }) else { return }
            await MainActor.run { displayAudit = fresh }
            if resolvedProject == nil {
                await MainActor.run {
                    resolvedProject = projectStore.projects.first { $0.id == fresh.projectId }
                }
            }
            await buildPDFPreview()
        } catch {
            print("Site audit reload error: \(error.localizedDescription)")
        }
    }

    private func buildPDFPreview() async {
        let logo = await loadLogo()
        var drafts: [SiteAuditDraftItem] = []
        for item in displayAudit.items {
            var image: UIImage?
            if let urlString = item.imageURL, let url = URL(string: urlString),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let loaded = UIImage(data: data) {
                image = await Task.detached(priority: .utility) {
                    SiteAuditMediaProcessor.normalizedForDisplay(loaded)
                }.value
            }
            drafts.append(SiteAuditDraftItem(
                id: item.id,
                title: item.title,
                location: item.location,
                assignee: item.assignee,
                comments: item.comments,
                annotations: item.annotations,
                image: image,
                capturedAt: item.imageCapturedAt,
                createdAt: item.createdAt
            ))
        }
        let audit = displayAudit
        let orgName = firebaseBackend.currentOrganization?.name
        let client = clientProject?.client.name
        let address = clientProject?.siteAddress
        let generated = await SiteAuditPDFBuilder.makePDFAsync(
            audit: audit,
            localItems: drafts,
            organizationName: orgName,
            logoImage: logo,
            clientName: client,
            siteAddress: address
        )
        await MainActor.run { pdfURL = generated }
    }

    private func loadLogo() async -> UIImage? {
        guard let logoURL = firebaseBackend.currentOrganization?.companyLogoURL,
              let url = URL(string: logoURL),
              url.scheme?.hasPrefix("http") == true,
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}

private struct SiteAuditPhotoLibraryPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: SiteAuditPhotoLibraryPicker
        init(_ parent: SiteAuditPhotoLibraryPicker) { self.parent = parent }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }
    }
}

private struct SiteAuditCameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
        } else {
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
        let parent: SiteAuditCameraPicker

        init(_ parent: SiteAuditCameraPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        guard let popover = uiViewController.popoverPresentationController else { return }
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let anchor = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return }
        popover.sourceView = anchor
        popover.sourceRect = CGRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }
}

