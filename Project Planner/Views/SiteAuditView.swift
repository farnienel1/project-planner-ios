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
    var assignee: String
    var comments: String
    var annotations: String
    var image: UIImage?
    var capturedAt: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        assignee: String = "",
        comments: String = "",
        annotations: String = "",
        image: UIImage? = nil,
        capturedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.assignee = assignee
        self.comments = comments
        self.annotations = annotations
        self.image = image
        self.capturedAt = capturedAt
        self.createdAt = createdAt
    }
}

private struct SiteAuditProjectAccess {
    static func visibleProjects(
        userStore: UserStore,
        projectStore: ProjectStore,
        bookingStore: BookingStore,
        operativeStore: OperativeStore
    ) -> [Project] {
        let all = projectStore.projects + projectStore.smallWorks
        if !userStore.canViewSiteAudit() {
            return []
        }
        guard userStore.isOperativeMode() else {
            if let currentUser = userStore.currentUser,
               !currentUser.isSuperAdmin,
               !currentUser.permissions.adminAccess,
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
}

fileprivate func siteAuditsForCurrentUser(_ audits: [SiteAudit], userStore: UserStore) -> [SiteAudit] {
    guard userStore.isOperativeMode() else { return audits }
    guard let uid = userStore.currentUser?.id else {
        return audits.filter(\.visibleToOperatives)
    }
    return audits.filter { $0.visibleToOperatives || $0.createdByUserId == uid }
}

struct SiteAuditHubView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    @State private var showingCreate = false
    @State private var showingProjects = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Site Audit")
                        .font(.largeTitle.bold())
                    Text("Capture site evidence, notes, and produce a polished shareable PDF.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { showingCreate = true } label: {
                    tile(icon: "plus.square.fill", title: "Create Site Audit", tint: .indigo)
                }

                Button { showingProjects = true } label: {
                    tile(icon: "folder.fill", title: "Projects", tint: .blue)
                }

                Spacer()
            }
            .padding(20)
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
            .sheet(isPresented: $showingProjects) {
                SiteAuditProjectsBrowserView()
                    .environmentObject(projectStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
            }
        }
    }

    private func tile(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            Text(title).font(.headline).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
    }
}

struct SiteAuditProjectsBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @State private var selectedFilter: SiteAuditProjectFilter = .all
    @State private var selectedProject: Project?
    @State private var authoredAuditProjectIds: Set<UUID> = []

    private var mergedProjectsForSiteAudit: [Project] {
        let visible = SiteAuditProjectAccess.visibleProjects(
            userStore: userStore,
            projectStore: projectStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore
        )
        let fromAuthored = (projectStore.projects + projectStore.smallWorks).filter { authoredAuditProjectIds.contains($0.id) }
        var byId: [UUID: Project] = [:]
        for p in visible { byId[p.id] = p }
        for p in fromAuthored { byId[p.id] = p }
        return Array(byId.values)
    }

    private var filteredProjects: [Project] {
        switch selectedFilter {
        case .all: return mergedProjectsForSiteAudit.sorted { $0.jobNumber < $1.jobNumber }
        case .active: return mergedProjectsForSiteAudit.filter { $0.status == .active }.sorted { $0.jobNumber < $1.jobNumber }
        case .upcoming: return mergedProjectsForSiteAudit.filter { $0.status == .upcoming }.sorted { $0.jobNumber < $1.jobNumber }
        case .completed: return mergedProjectsForSiteAudit.filter { $0.status == .completed }.sorted { $0.jobNumber < $1.jobNumber }
        }
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
                        "No Projects",
                        systemImage: "folder",
                        description: Text(
                            userStore.isOperativeMode()
                            ? "Shows jobs you are booked onto, plus any job where you previously submitted a site audit."
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
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $selectedProject) { project in
                SiteAuditProjectAuditsView(project: project)
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

    @State private var audits: [SiteAudit] = []
    @State private var selectedTypeTab = "All"
    @State private var isLoading = false
    @State private var selectedAudit: SiteAudit?

    private var filteredAudits: [SiteAudit] {
        let base = selectedTypeTab == "All" ? audits : audits.filter { $0.type.rawValue == selectedTypeTab }
        return siteAuditsForCurrentUser(base, userStore: userStore)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Type", selection: $selectedTypeTab) {
                    Text("All").tag("All")
                    ForEach(SiteAuditType.allCases) { type in Text(type.rawValue).tag(type.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding()

                if isLoading {
                    ProgressView("Loading site audits...").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredAudits.isEmpty {
                    ContentUnavailableView("No Site Audits", systemImage: "doc.text.magnifyingglass")
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(filteredAudits) { audit in
                                Button { selectedAudit = audit } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(audit.type.rawValue).font(.headline)
                                            Spacer()
                                            Text(audit.date.formatted(date: .abbreviated, time: .omitted))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text("\(audit.projectJobNumber) \(audit.projectName)")
                                            .font(.subheadline)
                                        HStack {
                                            Label(audit.authorName, systemImage: "person.fill")
                                                .font(.caption).foregroundStyle(.secondary)
                                            Spacer()
                                            Label("\(audit.items.count) items", systemImage: "list.bullet")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(14)
                                    .background(Color(.systemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("\(project.jobNumber) \(project.siteName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await loadAudits() }
            .sheet(item: $selectedAudit) { audit in
                SiteAuditDetailView(audit: audit)
            }
        }
    }

    private func loadAudits() async {
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

    @State private var audits: [SiteAudit] = []
    @State private var selectedTypeTab = "All"
    @State private var isLoading = false
    @State private var selectedAudit: SiteAudit?
    @State private var showingCreate = false

    private var filteredAudits: [SiteAudit] {
        let base = selectedTypeTab == "All" ? audits : audits.filter { $0.type.rawValue == selectedTypeTab }
        return siteAuditsForCurrentUser(base, userStore: userStore)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Type", selection: $selectedTypeTab) {
                Text("All").tag("All")
                ForEach(SiteAuditType.allCases) { type in Text(type.rawValue).tag(type.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding()

            if isLoading {
                ProgressView("Loading site audits...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredAudits.isEmpty {
                ContentUnavailableView("No Site Audits", systemImage: "doc.text.magnifyingglass")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(filteredAudits) { audit in
                            Button { selectedAudit = audit } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(audit.type.rawValue).font(.headline)
                                        Spacer()
                                        Text(audit.date.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text("\(audit.projectJobNumber) \(audit.projectName)")
                                        .font(.subheadline)
                                    HStack {
                                        Label(audit.authorName, systemImage: "person.fill")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Label("\(audit.items.count) items", systemImage: "list.bullet")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(14)
                                .background(Color(.systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Site Audits")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCreate = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .accessibilityLabel("Create site audit")
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
        .sheet(item: $selectedAudit) { audit in
            SiteAuditDetailView(audit: audit)
        }
    }

    private func loadAudits() async {
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

    /// When set, the flow starts on this project and optionally locks the picker.
    var initialProject: Project? = nil
    var lockProjectSelection: Bool = false

    @State private var step = 1
    @State private var selectedType: SiteAuditType = .general
    @State private var selectedProject: Project?
    @State private var selectedProjectFilter: SiteAuditProjectFilter = .all
    @State private var authorName = ""
    @State private var selectedDate = Date()
    @State private var showingProjectPicker = false

    @State private var items: [SiteAuditDraftItem] = []
    @State private var editingItem: SiteAuditDraftItem?
    @State private var multiSelection: [PhotosPickerItem] = []
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    @State private var showingSubmitSuccess = false
    @State private var submitSuccessPDFURL: URL?
    /// When true, operatives can see this audit in the app; when false, only admins/managers (not in operative mode).
    @State private var operativeAccessVisibleToOperatives = true

    private var canGoNext: Bool {
        selectedProject != nil && !authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleProjectsForPicker: [Project] {
        SiteAuditProjectAccess.visibleProjects(
            userStore: userStore,
            projectStore: projectStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore
        )
    }

    private var flowNavigationTitle: String {
        step == 1 ? "Create Site Audit" : "Items"
    }

    var body: some View {
        NavigationStack {
            Group { step == 1 ? AnyView(detailsStep) : AnyView(itemsStep) }
                .navigationTitle(flowNavigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(step == 1 ? "Cancel" : "Back") {
                            step == 1 ? dismiss() : (step = 1)
                        }
                    }
                    // Trailing items: on step 2, Submit is outermost (right); Edit sits to its left.
                    ToolbarItem(placement: .topBarTrailing) {
                        if step == 1 {
                            Button("Next") { step = 2 }.disabled(!canGoNext)
                        } else {
                            Button(isSubmitting ? "Submitting..." : "Submit") { submitAudit() }
                                .disabled(items.isEmpty || isSubmitting)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if step == 2 {
                            EditButton()
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
                        onDone: {
                            showingSubmitSuccess = false
                            submitSuccessPDFURL = nil
                            dismiss()
                        }
                    )
                }
                .onChange(of: multiSelection) { _, newValue in
                    if !newValue.isEmpty { Task { await addMultiPhotos(from: newValue) } }
                }
                .onAppear {
                    if authorName.isEmpty {
                        authorName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
                    }
                    if let p = initialProject {
                        selectedProject = p
                    }
                    operativeAccessVisibleToOperatives = true
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
        Form {
            Section("Site Audit Type") {
                Picker("Type", selection: $selectedType) {
                    ForEach(SiteAuditType.allCases) { type in Text(type.rawValue).tag(type) }
                }
            }
            Section("Job Number and Name") {
                if lockProjectSelection, let p = selectedProject ?? initialProject {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.jobNumber).font(.headline)
                            Text(p.siteName).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    Button {
                        showingProjectPicker = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedProject?.jobNumber ?? "Select Project").font(.headline)
                                Text(selectedProject?.siteName ?? "Tap to choose from projects")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if userStore.canManageSiteAuditOperativeVisibility() {
                Section {
                    Picker("Operative access", selection: $operativeAccessVisibleToOperatives) {
                        Text("Visible to operatives").tag(true)
                        Text("Hidden from operatives").tag(false)
                    }
                } footer: {
                    Text("Choose whether users in operative mode can see this audit for this job.")
                }
            }
            Section("Author Name") { TextField("Author", text: $authorName) }
            Section("Date") { DatePicker("Date", selection: $selectedDate, displayedComponents: .date) }
        }
    }

    private var itemsStep: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    editingItem = SiteAuditDraftItem()
                } label: {
                    Label("Add Item", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                PhotosPicker(selection: $multiSelection, maxSelectionCount: 20, matching: .images) {
                    Label("Multi Add", systemImage: "photo.on.rectangle.angled").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            if items.isEmpty {
                ContentUnavailableView("No Items Yet", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(items) { item in
                        Button {
                            editingItem = item
                        } label: {
                            HStack(spacing: 12) {
                                if let image = item.image {
                                    Image(uiImage: image)
                                        .resizable().scaledToFill().frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(.systemGray5)).frame(width: 60, height: 60)
                                        .overlay(Image(systemName: "doc.text"))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title.isEmpty ? "Untitled Item" : item.title).font(.headline)
                                    if !item.assignee.isEmpty {
                                        Text("Assignee: \(item.assignee)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if !item.comments.isEmpty {
                                        Text(item.comments).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in items.remove(atOffsets: idx) }
                    .onMove { from, to in items.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.plain)
            }
        }
    }

    private func addMultiPhotos(from selection: [PhotosPickerItem]) async {
        for entry in selection {
            if let data = try? await entry.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                let captured = Date()
                let stamped = SiteAuditMediaProcessor.addTimestampWatermark(to: image, at: captured)
                await MainActor.run {
                    items.append(SiteAuditDraftItem(
                        title: "Photo item",
                        image: stamped,
                        capturedAt: captured
                    ))
                }
            }
        }
        await MainActor.run { multiSelection = [] }
    }

    private func submitAudit() {
        guard let selectedProject else {
            errorMessage = "Please select a project before submitting."
            return
        }

        isSubmitting = true
        let auditId = UUID()
        let project = selectedProject
        let drafts = items
        let type = selectedType
        let author = authorName
        let date = selectedDate
        let visibilityChoice = operativeAccessVisibleToOperatives

        Task { @MainActor in
            let orgId = await firebaseBackend.resolveOrganizationIdForFirebaseWrites(
                preferredFallback: firebaseBackend.currentOrganization?.firestoreDocumentId
            )
            guard let orgId, !orgId.isEmpty else {
                isSubmitting = false
                errorMessage = "Could not resolve your organization. Open Settings, tap Force Reload Data, wait until projects load, then try again."
                return
            }

            var savedItems: [SiteAuditItem] = []
            var uploadFailures = 0
            for draft in drafts {
                var remoteURL: String?
                if let image = draft.image {
                    do {
                        remoteURL = try await firebaseBackend.uploadSiteAuditImage(
                            image,
                            auditId: auditId,
                            organizationId: orgId,
                            imageName: "site_audit_item_\(UUID().uuidString)"
                        )
                    } catch {
                        // Do not block submit/PDF generation when cloud photo upload is denied.
                        // Keep local image for PDF output and save the audit item without remote URL.
                        uploadFailures += 1
                        remoteURL = nil
                    }
                }
                savedItems.append(SiteAuditItem(
                    id: draft.id,
                    title: draft.title,
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
                authorName: author,
                date: date,
                items: savedItems,
                createdAt: Date(),
                createdByUserId: firebaseBackend.currentUser?.uid ?? "unknown",
                visibleToOperatives: visibilityToOperatives
            )

            do {
                try await firebaseBackend.saveSiteAudit(audit, organizationId: orgId)
                let logoImage = await loadOrganizationLogoImage()
                let pdfURL = SiteAuditPDFBuilder.makePDF(audit: audit, localItems: drafts, organizationName: firebaseBackend.currentOrganization?.name, logoImage: logoImage)
                submitSuccessPDFURL = pdfURL
                isSubmitting = false
                showingSubmitSuccess = true
                if uploadFailures > 0 {
                    errorMessage = "Saved successfully. \(uploadFailures) photo\(uploadFailures == 1 ? "" : "s") could not be uploaded to cloud storage, but they are included in this PDF."
                } else {
                    errorMessage = nil
                }
            } catch {
                isSubmitting = false
                errorMessage = "Submit failed: \(error.localizedDescription)"
            }
        }
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
    let onDone: () -> Void

    @State private var showShareSheet = false

    private var shareActivityItems: [Any] {
        if let pdfURL {
            return [pdfURL]
        }
        return ["Site audit saved."]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 32)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(.green)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)

                Text("Saved")
                    .font(.title.bold())
                    .padding(.top, 20)

                Text("Your site audit was saved to the cloud.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.top, 8)

                Spacer()

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .accessibilityHint("Opens the share sheet to send the PDF or a message.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone)
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(activityItems: shareActivityItems)
            }
        }
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
    let onSubmit: (SiteAuditDraftItem) -> Void

    init(item: SiteAuditDraftItem = SiteAuditDraftItem(), onSubmit: @escaping (SiteAuditDraftItem) -> Void) {
        self._draft = State(initialValue: item)
        self.onSubmit = onSubmit
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    Button { showingCamera = true } label: { Label("Open Camera", systemImage: "camera.fill") }
                    if let image = draft.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                Section("Details") {
                    TextField("Item Title", text: $draft.title)
                    TextField("Assignee", text: $draft.assignee)
                    TextField("Comments", text: $draft.comments, axis: .vertical).lineLimit(3...6)
                    TextField("Annotations", text: $draft.annotations, axis: .vertical).lineLimit(2...4)
                }
            }
            .navigationTitle("Site Audit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Submit") {
                        onSubmit(draft)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingCamera) {
                SiteAuditCameraPicker { captured in
                    let now = Date()
                    draft.image = SiteAuditMediaProcessor.addTimestampWatermark(to: captured, at: now)
                    draft.capturedAt = now
                }
            }
        }
    }
}

struct SiteAuditDetailView: View {
    let audit: SiteAudit
    @Environment(\.dismiss) private var dismiss
    @State private var selectedImageURL: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    detailRow("Type", audit.type.rawValue)
                    detailRow("Project", "\(audit.projectJobNumber) \(audit.projectName)")
                    detailRow("Author", audit.authorName)
                    detailRow("Date", audit.date.formatted(date: .abbreviated, time: .omitted))
                }
                Section("Items") {
                    ForEach(audit.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(.headline)
                            if !item.assignee.isEmpty { Text("Assignee: \(item.assignee)").font(.subheadline).foregroundStyle(.secondary) }
                            if !item.comments.isEmpty { Text(item.comments).font(.subheadline) }
                            if !item.annotations.isEmpty { Text("Annotations: \(item.annotations)").font(.caption).foregroundStyle(.secondary) }
                            if let url = item.imageURL {
                                Button {
                                    selectedImageURL = url
                                } label: {
                                    AsyncImage(url: URL(string: url)) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Rectangle().fill(Color(.systemGray5))
                                    }
                                    .frame(height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Audit Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: Binding(
                get: { selectedImageURL != nil },
                set: { if !$0 { selectedImageURL = nil } }
            )) {
                NavigationStack {
                    AsyncImage(url: URL(string: selectedImageURL ?? "")) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView()
                    }
                    .padding()
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { selectedImageURL = nil } } }
                }
            }
        }
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}

private enum SiteAuditMediaProcessor {
    static func addTimestampWatermark(to image: UIImage, at date: Date) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss"
        let text = formatter.string(from: date)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: max(20, image.size.width / 30)),
            .foregroundColor: UIColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            let box = CGRect(x: 20, y: image.size.height - textSize.height - 30, width: textSize.width + 20, height: textSize.height + 10)
            UIColor.black.withAlphaComponent(0.25).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: 8).fill()
            text.draw(at: CGPoint(x: 30, y: image.size.height - textSize.height - 25), withAttributes: attributes)
        }
    }
}

private enum SiteAuditPDFBuilder {
    static func makePDF(audit: SiteAudit, localItems: [SiteAuditDraftItem], organizationName: String?, logoImage: UIImage?) -> URL? {
        let name = "SiteAudit-\(audit.projectJobNumber)-\(Int(Date().timeIntervalSince1970)).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        do {
            try renderer.writePDF(to: url) { ctx in
                ctx.beginPage()
                var y: CGFloat = 28
                let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 22)]
                let textAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
                let subtitleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 13)]
                "SITE AUDIT REPORT".draw(at: CGPoint(x: 24, y: y), withAttributes: titleAttrs)
                if let logoImage {
                    let logoBox = CGRect(x: 455, y: 20, width: 115, height: 48)
                    if let prepared = compressedImageForPDF(logoImage, maxWidth: 460) {
                        prepared.draw(in: aspectFitRect(for: prepared.size, in: logoBox))
                    }
                }
                y += 30
                if let organizationName, !organizationName.isEmpty {
                    "Organisation: \(organizationName)".draw(at: CGPoint(x: 24, y: y), withAttributes: textAttrs)
                    y += 16
                }
                "Type: \(audit.type.rawValue)".draw(at: CGPoint(x: 24, y: y), withAttributes: textAttrs); y += 16
                "Project: \(audit.projectJobNumber) \(audit.projectName)".draw(at: CGPoint(x: 24, y: y), withAttributes: textAttrs); y += 16
                "Author: \(audit.authorName)".draw(at: CGPoint(x: 24, y: y), withAttributes: textAttrs); y += 16
                "Date: \(audit.date.formatted(date: .abbreviated, time: .omitted))".draw(at: CGPoint(x: 24, y: y), withAttributes: textAttrs); y += 22

                for (idx, item) in audit.items.enumerated() {
                    if y > 760 { ctx.beginPage(); y = 24 }
                    "\(idx + 1). \(item.title.isEmpty ? "Untitled Item" : item.title)"
                        .draw(at: CGPoint(x: 24, y: y), withAttributes: subtitleAttrs); y += 16
                    "Assignee: \(item.assignee.isEmpty ? "-" : item.assignee)".draw(at: CGPoint(x: 30, y: y), withAttributes: textAttrs); y += 14
                    "Comments: \(item.comments.isEmpty ? "-" : item.comments)".draw(at: CGPoint(x: 30, y: y), withAttributes: textAttrs); y += 14
                    "Annotations: \(item.annotations.isEmpty ? "-" : item.annotations)".draw(at: CGPoint(x: 30, y: y), withAttributes: textAttrs); y += 14
                    if let image = localItems[safe: idx]?.image {
                        compressedImageForPDF(image, maxWidth: 900)?.draw(in: CGRect(x: 30, y: y + 6, width: 180, height: 120))
                        y += 132
                    }
                    y += 10
                }
            }
            return url
        } catch {
            print("PDF generation error: \(error.localizedDescription)")
            return nil
        }
    }

    private static func compressedImageForPDF(_ image: UIImage, maxWidth: CGFloat) -> UIImage? {
        let source = image
        let resized: UIImage
        if source.size.width > maxWidth {
            let scale = maxWidth / source.size.width
            let newSize = CGSize(width: maxWidth, height: source.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            resized = renderer.image { _ in
                source.draw(in: CGRect(origin: .zero, size: newSize))
            }
        } else {
            resized = source
        }
        guard let data = resized.jpegData(compressionQuality: 0.55) else { return resized }
        return UIImage(data: data) ?? resized
    }

    private static func aspectFitRect(for imageSize: CGSize, in box: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return box }
        let widthScale = box.width / imageSize.width
        let heightScale = box.height / imageSize.height
        let scale = min(widthScale, heightScale)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let x = box.minX + (box.width - fittedSize.width) / 2
        let y = box.minY + (box.height - fittedSize.height) / 2
        return CGRect(origin: CGPoint(x: x, y: y), size: fittedSize)
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

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
