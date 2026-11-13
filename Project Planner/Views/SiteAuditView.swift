import SwiftUI
import FirebaseFirestore
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

extension SiteAuditProjectFilter {
    /// The job-list chip this filter is (RULEBOOK §21 `worksInTab`; nil = All).
    var worksChip: ProjectStatus? {
        switch self {
        case .all: return nil
        case .active: return .active
        case .upcoming: return .upcoming
        case .completed: return .completed
        }
    }
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
    /// RULEBOOK 1.8.0 §1: the stored `type` text when it is not one of `SiteAuditType` (web may write other types).
    /// The audit shows as General and a save writes the stored text back unchanged.
    var storedType: String? = nil

    /// The `type` text a save writes.
    var storedTypeText: String {
        if let storedType, SiteAuditType(rawValue: storedType) == nil, type == .general { return storedType }
        return type.rawValue
    }
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
        case .projects: return !project.isSmallWorksDocument
        case .smallWorks: return project.isSmallWorksDocument
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
        operativeStore: OperativeStore,
        managerBookings: [ManagerSiteBooking] = [],
        taskStore: ProjectTaskStore? = nil,
        extraProjectIds: Set<UUID> = []
    ) -> [Project] {
        if !userStore.canViewSiteAudit() {
            return []
        }
        return WorkAccess.visibleWorks(
            from: projectStore.projects + projectStore.smallWorks,
            catalogue: .all,
            userStore: userStore,
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            managerBookings: managerBookings,
            taskStore: taskStore,
            deadlineAssignedProjectIds: extraProjectIds
        )
    }

    static func visibleProjects(
        userStore: UserStore,
        projectStore: ProjectStore,
        bookingStore: BookingStore,
        operativeStore: OperativeStore,
        managerBookings: [ManagerSiteBooking] = [],
        taskStore: ProjectTaskStore? = nil,
        extraProjectIds: Set<UUID> = []
    ) -> [Project] {
        visibleWorks(
            userStore: userStore,
            projectStore: projectStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore,
            managerBookings: managerBookings,
            taskStore: taskStore,
            extraProjectIds: extraProjectIds
        ).filter { !$0.isSmallWorksDocument }
    }

    static func visibleSmallWorks(
        userStore: UserStore,
        projectStore: ProjectStore,
        bookingStore: BookingStore,
        operativeStore: OperativeStore,
        managerBookings: [ManagerSiteBooking] = [],
        taskStore: ProjectTaskStore? = nil,
        extraProjectIds: Set<UUID> = []
    ) -> [Project] {
        visibleWorks(
            userStore: userStore,
            projectStore: projectStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore,
            managerBookings: managerBookings,
            taskStore: taskStore,
            extraProjectIds: extraProjectIds
        ).filter { $0.isSmallWorksDocument }
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
    @State private var showingPersonal = false
    /// Unfinished audits saved on this phone for the signed-in person in this organisation (owner decision 12 Nov).
    @State private var drafts: [SiteAuditDraft] = []
    @State private var resumingDraft: SiteAuditDraft?
    @State private var draftPendingDelete: SiteAuditDraft?

    private var draftOwner: (userId: String, organizationId: String)? {
        guard let userId = firebaseBackend.currentUser?.uid, !userId.isEmpty,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId, !organizationId.isEmpty else { return nil }
        return (userId, organizationId)
    }

    private func reloadDrafts() {
        guard let owner = draftOwner else { drafts = []; return }
        drafts = SiteAuditDraftStore.shared.drafts(userId: owner.userId, organizationId: owner.organizationId)
    }

    private func draftSavedText(_ draft: SiteAuditDraft) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(draft.itemCountText) · saved \(formatter.localizedString(for: draft.updatedAt, relativeTo: Date()))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PPNavyPageTitle(
                        title: "Site Audit",
                        subtitle: "Capture site evidence, notes, and produce a polished shareable PDF."
                    )
                    .padding(.horizontal, PPMetrics.screenGutter)
                    .padding(.top, 12)
                    .padding(.bottom, PPMetrics.headerBottomPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ppNavyHeader()

                    VStack(alignment: .leading, spacing: 0) {
                        PPGroupLabel(text: "Start")
                        PPGroupedCard {
                            Button { showingCreate = true } label: {
                                hubTile(icon: "plus", title: "New site audit", subtitle: "Start a new walkthrough", family: .plan)
                            }
                                .accessibilityIdentifier("siteAuditHub.button")
                                .buttonStyle(PPMenuRowButtonStyle())
                        }
                        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))

                        if !drafts.isEmpty {
                            PPGroupLabel(text: "Drafts on this phone")
                            PPGroupedCard {
                                ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                                    if index > 0 { PPRowDivider() }
                                    HStack(spacing: 0) {
                                        Button { resumingDraft = draft } label: {
                                            hubTile(icon: "doc.badge.ellipsis", title: draft.listTitle, subtitle: draftSavedText(draft), family: .plan)
                                        }
                                        .accessibilityIdentifier("siteAuditHub.draft.\(draft.id.uuidString)")
                                        .buttonStyle(PPMenuRowButtonStyle())
                                        Button(role: .destructive) { draftPendingDelete = draft } label: {
                                            Image(systemName: "trash")
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(SiteAuditColors.danger)
                                                .frame(width: 44, height: 44)
                                        }
                                        .accessibilityLabel("Delete draft")
                                        .accessibilityIdentifier("siteAuditHub.deleteDraft.\(draft.id.uuidString)")
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 6)
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                            Text("Kept only on this phone until you submit. Signing out removes them.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, PPMetrics.screenGutter)
                                .padding(.top, 6)
                        }

                        PPGroupLabel(text: "Browse")
                        PPGroupedCard {
                            Button { worksBrowserKind = .projects } label: {
                                hubTile(icon: "folder.fill", title: "Projects", subtitle: "Browse audits by project", family: .sites)
                            }
                                .accessibilityIdentifier("siteAuditHub.folderFill")
                                .buttonStyle(PPMenuRowButtonStyle())

                            PPRowDivider()

                            Button { worksBrowserKind = .smallWorks } label: {
                                hubTile(icon: "wrench.and.screwdriver.fill", title: "Small works", subtitle: "Browse audits by small works job", family: .trade)
                            }
                                .accessibilityIdentifier("siteAuditHub.wrenchAndScrewdriverFill")
                                .buttonStyle(PPMenuRowButtonStyle())

                            PPRowDivider()

                            // RULEBOOK 1.30.0 §26: the signed-in person's own audits, not linked to a job (owner only).
                            Button { showingPersonal = true } label: {
                                hubTile(
                                    icon: "person.fill",
                                    title: CanonicalBusinessEngine.payeClaimText("PERSONAL_SITE_AUDIT_SECTION_LABEL", fallback: "Personal"),
                                    subtitle: "Your own audits, not linked to a job — only you can see them",
                                    family: .plan
                                )
                            }
                                .accessibilityIdentifier("siteAuditHub.personal")
                                .buttonStyle(PPMenuRowButtonStyle())
                        }
                        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                    }
                    .padding(.bottom, 28)
                    .ppContentSheet()
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Site Audit")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .accessibilityIdentifier("siteAuditHub.done") } }
            .sheet(isPresented: $showingCreate, onDismiss: reloadDrafts) {
                SiteAuditCreateFlowView()
                    .environmentObject(projectStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
            }
            .sheet(item: $resumingDraft, onDismiss: reloadDrafts) { draft in
                SiteAuditCreateFlowView(resumeDraft: draft)
                    .environmentObject(projectStore)
                    .environmentObject(bookingStore)
                    .environmentObject(operativeStore)
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
            }
            .confirmationDialog(
                "Delete this draft?",
                isPresented: Binding(get: { draftPendingDelete != nil }, set: { if !$0 { draftPendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: draftPendingDelete
            ) { draft in
                Button("Delete draft", role: .destructive) {
                    SiteAuditDraftStore.shared.delete(draftId: draft.id, userId: draft.userId, organizationId: draft.organizationId)
                    draftPendingDelete = nil
                    reloadDrafts()
                }
                .accessibilityIdentifier("siteAuditHub.confirmDeleteDraft")
            } message: { _ in
                Text("Its items and photos are removed from this phone. Nothing was sent, so nothing else changes.")
            }
            .task(id: draftOwner.map { "\($0.userId)|\($0.organizationId)" } ?? "") { reloadDrafts() }
            .onAppear(perform: reloadDrafts)
            .sheet(isPresented: $showingPersonal) {
                PersonalSiteAuditsView()
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

    private func hubTile(icon: String, title: String, subtitle: String, family: PPFamily) -> some View {
        PPMenuRowLabel(title: title, symbol: icon, family: family, subtitle: subtitle)
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
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @State private var selectedFilter: SiteAuditProjectFilter = .all
    @State private var selectedProject: Project?
    @State private var authoredAuditProjectIds: Set<UUID> = []
    @State private var extraVisibleProjectIds: Set<UUID> = []

    private var mergedWorksForSiteAudit: [Project] {
        let visible: [Project] = {
            switch kind {
            case .projects:
                return SiteAuditProjectAccess.visibleProjects(
                    userStore: userStore,
                    projectStore: projectStore,
                    bookingStore: bookingStore,
                    operativeStore: operativeStore,
                    managerBookings: managerScheduleStore.managerSiteBookings,
                    taskStore: taskStore,
                    extraProjectIds: extraVisibleProjectIds
                )
            case .smallWorks:
                return SiteAuditProjectAccess.visibleSmallWorks(
                    userStore: userStore,
                    projectStore: projectStore,
                    bookingStore: bookingStore,
                    operativeStore: operativeStore,
                    managerBookings: managerScheduleStore.managerSiteBookings,
                    taskStore: taskStore,
                    extraProjectIds: extraVisibleProjectIds
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
        // RULEBOOK 1.21.0 §21 `worksInTab`: an inactive job is under Completed; All is every job.
        return WorksListStatusCounts.jobs(scoped, chip: selectedFilter.worksChip)
            .sorted { $0.jobNumber.localizedStandardCompare($1.jobNumber) == .orderedAscending }
    }

    private var emptyTitle: String {
        kind == .projects ? "No Projects" : "No Small Works"
    }

    private var listCounts: WorksListStatusCounts {
        WorksListStatusCounts.from(mergedWorksForSiteAudit.filter { kind.includes($0) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    browserNavyHeader

                    VStack(alignment: .leading, spacing: 12) {
                        filterChipsRow
                        if filteredProjects.isEmpty {
                            emptyStateView
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(filteredProjects) { project in
                                    Button {
                                        selectedProject = project
                                    } label: {
                                        ProjectDetailRowView(project: project)
                                            .environmentObject(userStore)
                                            .environmentObject(operativeStore)
                                    }
                                    .accessibilityIdentifier("siteAuditProjectsBrowser.row.\(project.id)")
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.bottom, 8)
                        }
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 20)
                    .ppContentSheet()
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle(kind.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .accessibilityIdentifier("siteAuditProjectsBrowser.done") } }
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

    /// Navy header with the counts the filter chips already show.
    private var browserNavyHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPOverviewTitle(
                eyebrow: "Site audit",
                count: "\(listCounts.all)",
                countLabel: kind == .projects ? "projects" : "small works"
            )
            HStack(alignment: .top, spacing: 12) {
                PPStat(value: "\(listCounts.active)", label: "Active")
                PPStatDivider()
                PPStat(value: "\(listCounts.upcoming)", label: "Upcoming")
                PPStatDivider()
                PPStat(value: "\(listCounts.completed)", label: "Completed")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                WorksRevampFilterChip(
                    title: "All · \(listCounts.all)",
                    isSelected: selectedFilter == .all,
                    selectedForeground: ProjectWorksRevampColors.activeGreen
                ,
                    accessibilityIdentifier: "siteAuditProjectsBrowser.filter.all",
                    action: { selectedFilter = .all }
                )
                WorksRevampFilterChip(
                    title: "Active · \(listCounts.active)",
                    isSelected: selectedFilter == .active,
                    selectedForeground: ProjectWorksRevampColors.activeGreen
                ,
                    accessibilityIdentifier: "siteAuditProjectsBrowser.filter.active",
                    action: { selectedFilter = .active }
                )
                WorksRevampFilterChip(
                    title: "Upcoming · \(listCounts.upcoming)",
                    isSelected: selectedFilter == .upcoming,
                    selectedForeground: ProjectWorksRevampColors.upcomingAmber
                ,
                    accessibilityIdentifier: "siteAuditProjectsBrowser.filter.upcoming",
                    action: { selectedFilter = .upcoming }
                )
                WorksRevampFilterChip(
                    title: "Completed · \(listCounts.completed)",
                    isSelected: selectedFilter == .completed,
                    selectedForeground: ProjectWorksRevampColors.muted
                ,
                    accessibilityIdentifier: "siteAuditProjectsBrowser.filter.completed",
                    action: { selectedFilter = .completed }
                )
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            PPIconTile(
                symbol: kind == .projects ? "folder.fill" : "wrench.and.screwdriver.fill",
                family: kind == .projects ? .sites : .trade,
                size: 56,
                lifted: true
            )
            Text(emptyTitle)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.primary)
            Text(
                userStore.isOperativeMode()
                ? "Shows \(kind == .projects ? "projects" : "small works") you are booked onto, plus any job where you previously submitted a site audit."
                : "Try switching the filter to All."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 16)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private func loadAuthoredAuditProjectIds() async {
        guard userStore.isOperativeMode() else {
            await MainActor.run {
                authoredAuditProjectIds = []
                extraVisibleProjectIds = []
            }
            return
        }
        let email = userStore.currentUser?.email
        let operative = operativeStore.allOperatives.first(where: {
            $0.email.lowercased() == (email ?? "").lowercased()
        })
        var extras = WorkAccess.taskAssignedProjectIds(
            currentUser: userStore.currentUser,
            taskStore: taskStore,
            operatives: operative.map { [$0] } ?? [],
            managers: operativeStore.allManagers
        )
        if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId,
           let uid = userStore.currentUser?.id {
            extras.formUnion(await firebaseBackend.loadDeadlineAssignedProjectIds(userId: uid, organizationId: orgId, jobIds: projectStore.projects.map(\.documentId)))
            do {
                let audits = try await firebaseBackend.loadSiteAudits(organizationId: orgId, createdByUserId: uid)
                await MainActor.run {
                    authoredAuditProjectIds = Set(audits.map(\.projectId))
                    extraVisibleProjectIds = extras
                }
                return
            } catch {
                await MainActor.run {
                    authoredAuditProjectIds = []
                    extraVisibleProjectIds = extras
                }
                return
            }
        }
        await MainActor.run {
            authoredAuditProjectIds = []
            extraVisibleProjectIds = extras
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
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("siteAuditProjectAudits.done")
                }
            }
            .task(id: firebaseBackend.currentOrganization?.firestoreDocumentId ?? "") {
                guard !(firebaseBackend.currentOrganization?.firestoreDocumentId ?? "").isEmpty else { return }
                await loadAudits()
            }
            .listensWhileOpen("siteAudits", key: "siteAudits.projectAudits", targetSuffix: project.id.uuidString,
                              firebaseBackend: firebaseBackend,
                              query: { $0.collection("siteAudits").whereField("projectId", in: JobKeys.queryValues(for: project.id)) }) {
                await loadAudits()
            }
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
        .task(id: firebaseBackend.currentOrganization?.firestoreDocumentId ?? "") {
            guard !(firebaseBackend.currentOrganization?.firestoreDocumentId ?? "").isEmpty else { return }
            await loadAudits()
        }
        .listensWhileOpen("siteAudits", key: "siteAudits.projectHub", targetSuffix: project.id.uuidString,
                          firebaseBackend: firebaseBackend,
                          query: { $0.collection("siteAudits").whereField("projectId", in: JobKeys.queryValues(for: project.id)) }) {
            await loadAudits()
        }
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
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore

    /// When set, the flow starts on this project and optionally locks the picker.
    var initialProject: Project? = nil
    var lockProjectSelection: Bool = false
    /// When set, preloads fields and updates the existing audit on submit.
    var existingAudit: SiteAudit? = nil
    /// When set, the flow reopens this unfinished audit saved on the phone (owner decision 12 Nov, item 6).
    var resumeDraft: SiteAuditDraft? = nil
    var onFinished: (() -> Void)? = nil

    @Environment(\.scenePhase) private var scenePhase
    @State private var step = 1
    @State private var selectedType: SiteAuditType = .general
    @State private var selectedProject: Project?
    @State private var selectedProjectFilter: SiteAuditProjectFilter = .active
    @State private var customTitle = ""
    @State private var authorName = ""
    @State private var selectedDate = Date()
    @State private var showingProjectPicker = false

    @State private var items: [SiteAuditDraftItem] = []
    @State private var editingItem: SiteAuditDraftItem?
    @State private var multiSelection: [PhotosPickerItem] = []
    @State private var isSubmitting = false
    @State private var submitStatusMessage = ""
    /// Multi-add placeholders whose photo is still loading (shown with a spinner, not editable yet).
    @State private var loadingPhotoIds: Set<UUID> = []
    /// Multi-add batches and the existing-audit photo download; cancelled when the flow closes.
    @State private var multiAddTasks: [UUID: Task<Void, Never>] = [:]
    @State private var hydrateTask: Task<Void, Never>?
    /// Photos that could not be loaded, summed across batches; shown in the items step and in the item editor
    /// (an alert would not show while the editor sheet is open). Cleared when the person dismisses it.
    @State private var failedPhotoLoads = 0
    @State private var errorMessage: String?

    @State private var showingSubmitSuccess = false
    @State private var submitSuccessPDFURL: URL?
    /// When true, operatives can see this audit in the app; when false, only admins/managers (not in operative mode).
    @State private var operativeAccessVisibleToOperatives = true
    @State private var didBootstrapExisting = false
    @State private var extraVisibleProjectIds: Set<UUID> = []
    /// The draft's id, and the audit's id once submitted (so a draft submitted twice is one audit).
    @State private var draftId = UUID()
    @State private var draftAutosaver: SiteAuditDraftAutosaver?
    @State private var didBootstrapDraft = false
    /// Items whose photo is being read back from the draft on disk (kept in the draft while they load).
    @State private var draftPhotosLoading: Set<UUID> = []
    /// The audit queued by Submit; the success sheet follows its upload.
    @State private var submittedAuditId: UUID?

    private var isEditing: Bool { existingAudit != nil }

    /// Items on screen whose Multi-add photo has not loaded yet. Preview and Save wait for these only;
    /// deleting a stuck placeholder lets the person carry on.
    private var photosStillLoading: Int {
        items.reduce(0) { $0 + (loadingPhotoIds.contains($1.id) ? 1 : 0) }
    }

    private var canGoNext: Bool {
        selectedProject != nil && !authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleProjectsForPicker: [Project] {
        SiteAuditProjectAccess.uniqueWorks(
            SiteAuditProjectAccess.visibleWorks(
                userStore: userStore,
                projectStore: projectStore,
                bookingStore: bookingStore,
                operativeStore: operativeStore,
                managerBookings: managerScheduleStore.managerSiteBookings,
                taskStore: taskStore,
                extraProjectIds: extraVisibleProjectIds
            )
        )
    }

    private func extraIdsForCurrentUser() -> Set<UUID> {
        guard userStore.isOperativeMode() else { return [] }
        let email = userStore.currentUser?.email
        let operative = operativeStore.allOperatives.first(where: {
            $0.email.lowercased() == (email ?? "").lowercased()
        })
        return WorkAccess.taskAssignedProjectIds(
            currentUser: userStore.currentUser,
            taskStore: taskStore,
            operatives: operative.map { [$0] } ?? [],
            managers: operativeStore.allManagers
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
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SiteAuditToolbarPill(title: "Back", filled: false, onNavy: true) {
                        if step == 1 { dismiss() }
                        else if step == 2 { step = 1 }
                        else { step = 2 }
                    }
                }
                ToolbarItem(placement: .principal) {
                    if step == 2 {
                        VStack(spacing: 0) {
                            Text("\(selectedType.rawValue) ›")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(PPColor.onNavySecondary)
                            Text("Items · \(items.count)")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.white)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if step == 1 {
                        SiteAuditToolbarPill(title: "Next", filled: true, disabled: !canGoNext, onNavy: true) { step = 2 }
                    } else if step == 2 {
                        if isEditing {
                            SiteAuditToolbarPill(title: isSubmitting ? "Saving…" : "Save", filled: true, disabled: items.isEmpty || isSubmitting || photosStillLoading > 0, onNavy: true) {
                                submitAudit()
                            }
                        } else {
                            SiteAuditToolbarPill(title: "Preview", filled: true, disabled: items.isEmpty || photosStillLoading > 0, onNavy: true) { step = 3 }
                        }
                    }
                }
            }
                .sheet(item: $editingItem) { item in
                    SiteAuditAddItemView(
                        item: item,
                        failedPhotoLoads: $failedPhotoLoads,
                        // An existing audit's photo that finishes downloading while this editor is open is passed
                        // in, so the editor shows it and saving keeps it.
                        arrivedImage: items.first(where: { $0.id == item.id })?.image
                    ) { updated in
                        if let idx = items.firstIndex(where: { $0.id == updated.id }) {
                            var merged = updated
                            if merged.image == nil, let arrived = items[idx].image {
                                // Never wipe a photo that arrived while the editor was open.
                                merged.image = arrived
                                merged.capturedAt = items[idx].capturedAt
                            }
                            items[idx] = merged
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
                        auditId: submittedAuditId,
                        queue: SiteAuditOfflineStore.shared,
                        smartCache: smartCache,
                        onDone: {
                            showingSubmitSuccess = false
                            submitSuccessPDFURL = nil
                            onFinished?()
                            dismiss()
                        }
                    )
                }
                .onChange(of: multiSelection) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    let batch = UUID()
                    multiAddTasks[batch] = Task {
                        await addMultiPhotos(from: newValue)
                        multiAddTasks[batch] = nil
                    }
                }
                .onAppear {
                    if let existing = existingAudit, !didBootstrapExisting {
                        bootstrapFromExisting(existing)
                        didBootstrapExisting = true
                    }
                    if let draft = resumeDraft, !didBootstrapDraft {
                        bootstrapFromDraft(draft)
                        didBootstrapDraft = true
                    }
                    startDraftAutosaverIfNeeded()
                    if authorName.isEmpty {
                        authorName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
                    }
                    if let p = initialProject, resumeDraft == nil || selectedProject == nil {
                        selectedProject = p
                    }
                    if existingAudit == nil, resumeDraft == nil {
                        operativeAccessVisibleToOperatives = true
                    }
                }
                .task {
                    extraVisibleProjectIds = extraIdsForCurrentUser()
                    if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId,
                       let uid = userStore.currentUser?.id,
                       userStore.isOperativeMode() {
                        extraVisibleProjectIds.formUnion(
                            await firebaseBackend.loadDeadlineAssignedProjectIds(userId: uid, organizationId: orgId, jobIds: projectStore.projects.map(\.documentId))
                        )
                    }
                }
                .alert("Site Audit", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { }
                        .accessibilityIdentifier("siteAuditCreateFlow.ok")
                } message: {
                    Text(errorMessage ?? "")
                }
        }
        // On the NavigationStack, not the step Group: modifiers on a Group apply to each step view, so they
        // would fire on every step change. This fires only when the whole flow closes.
        .onChange(of: draftSignature) { _, _ in
            if let snapshot = draftSnapshot() { draftAutosaver?.schedule(snapshot) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app: save the draft now, not after the pause.
            if phase != .active, let snapshot = draftSnapshot() { draftAutosaver?.saveNow(snapshot) }
        }
        .onDisappear {
            if let snapshot = draftSnapshot() { draftAutosaver?.saveNow(snapshot) }
            multiAddTasks.values.forEach { $0.cancel() }
            multiAddTasks = [:]
            hydrateTask?.cancel()
            hydrateTask = nil
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
                photosStillLoading: photosStillLoading,
                loadingItemIds: loadingPhotoIds,
                failedPhotoLoads: $failedPhotoLoads,
                // Drafts (owner decision 12 Nov): a new audit is kept on the phone as the person works.
                savedLabel: isEditing ? "Not saved until you submit" : "Draft saved on this phone",
                onAddItem: { editingItem = SiteAuditDraftItem(assignee: authorName) },
                onEditItem: { item in
                    guard !loadingPhotoIds.contains(item.id), !draftPhotosLoading.contains(item.id) else { return }
                    editingItem = item
                },
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
                organizationAbbreviation: firebaseBackend.currentOrganization?.documentAbbreviation,
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
        hydrateTask = Task { await hydrateItemImages(from: existing.items) }
    }

    /// Fills each saved item's photo in place, by id, as it downloads. It never replaces the whole list, so
    /// Multi-add placeholders, photos already loaded and edits made meanwhile are kept; an item the person
    /// deleted, or whose photo they replaced, is left alone.
    private func hydrateItemImages(from saved: [SiteAuditItem]) async {
        for item in saved {
            if Task.isCancelled { return }
            guard let urlString = item.imageURL,
                  let url = URL(string: urlString),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { continue }
            let normalized = await Task.detached(priority: .utility) {
                SiteAuditMediaProcessor.displayImage(from: data)
            }.value
            guard let normalized,
                  let idx = items.firstIndex(where: { $0.id == item.id }),
                  items[idx].image == nil else { continue }
            items[idx].image = normalized
        }
    }

    /// Multi-add: every picked photo becomes an item at once (a placeholder with a spinner), and each
    /// placeholder gets its photo as soon as that one is ready — a few at a time, not one after another.
    /// Batches may overlap (Multi-add stays available while one is loading).
    /// Before, nothing appeared until every photo had loaded, and one photo stuck downloading from iCloud held
    /// the whole batch ("Processing… / Items · 0"). Local only: nothing is uploaded until Submit.
    private func addMultiPhotos(from selection: [PhotosPickerItem]) async {
        let picked = selection
        multiSelection = []
        // capturedAt (and the watermark time) is the moment the photo was picked.
        let placeholders = picked.map { _ in SiteAuditDraftItem(title: "Photo item", capturedAt: Date()) }
        items.append(contentsOf: placeholders)
        loadingPhotoIds.formUnion(placeholders.map(\.id))
        let jobs: [(id: UUID, capturedAt: Date, entry: PhotosPickerItem)] = zip(placeholders, picked).map {
            ($0.id, $0.capturedAt ?? Date(), $1)
        }
        var failed = 0
        await withTaskGroup(of: (UUID, UIImage?).self) { group in
            var next = 0
            while next < min(Self.multiAddParallelLoads, jobs.count) {
                let job = jobs[next]
                group.addTask { (job.id, await Self.loadDraftPhoto(job.entry, capturedAt: job.capturedAt)) }
                next += 1
            }
            for await (id, image) in group {
                loadingPhotoIds.remove(id)
                if Task.isCancelled { continue }
                if let image {
                    if let idx = items.firstIndex(where: { $0.id == id }) { items[idx].image = image }
                } else {
                    failed += 1
                    items.removeAll { $0.id == id }
                }
                if next < jobs.count, !Task.isCancelled {
                    let job = jobs[next]
                    group.addTask { (job.id, await Self.loadDraftPhoto(job.entry, capturedAt: job.capturedAt)) }
                    next += 1
                }
            }
        }
        // A closed screen shows nothing; a second batch adds to the first batch's count.
        if failed > 0, !Task.isCancelled { failedPhotoLoads += failed }
    }

    private static let multiAddParallelLoads = 3

    nonisolated private static func loadDraftPhoto(_ entry: PhotosPickerItem, capturedAt: Date) async -> UIImage? {
        guard !Task.isCancelled,
              let data = try? await entry.loadTransferable(type: Data.self),
              !Task.isCancelled else { return nil }
        return await Task.detached(priority: .userInitiated) {
            SiteAuditMediaProcessor.draftImage(from: data, capturedAt: capturedAt)
        }.value
    }

    // MARK: Drafts (owner decision 12 Nov, item 6)

    /// A new audit only: an edit of a saved audit is not a draft.
    private func startDraftAutosaverIfNeeded() {
        guard !isEditing, draftAutosaver == nil,
              let userId = firebaseBackend.currentUser?.uid, !userId.isEmpty,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId, !organizationId.isEmpty else { return }
        if let draft = resumeDraft { draftId = draft.id }
        draftAutosaver = SiteAuditDraftAutosaver(draftId: draftId, userId: userId, organizationId: organizationId)
    }

    /// Changes whenever anything the draft keeps changes (drives the autosave).
    private var draftSignature: String {
        var parts: [String] = [
            selectedType.rawValue,
            selectedProject?.id.uuidString ?? "",
            customTitle,
            authorName,
            String(selectedDate.timeIntervalSince1970),
            String(operativeAccessVisibleToOperatives),
            String(step),
        ]
        for item in items where !loadingPhotoIds.contains(item.id) {
            parts.append(contentsOf: [
                item.id.uuidString, item.title, item.location, item.assignee, item.comments, item.annotations,
                item.image.map { String(describing: ObjectIdentifier($0)) } ?? "-",
                item.capturedAt.map { String($0.timeIntervalSince1970) } ?? "-",
                draftPhotosLoading.contains(item.id) ? "loading" : "",
            ])
        }
        return parts.joined(separator: "\u{1F}")
    }

    /// What the draft keeps now, or nil when there is nothing worth keeping yet (a new audit nobody has started).
    private func draftSnapshot() -> SiteAuditDraftAutosaver.Snapshot? {
        guard let autosaver = draftAutosaver, !autosaver.isStopped else { return nil }
        let started = step >= 2 || !items.isEmpty
            || !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || resumeDraft != nil
        guard started else { return nil }
        let project = selectedProject ?? initialProject
        var images: [UUID: UIImage] = [:]
        // Multi-add placeholders still loading from the photo library are left out until their photo arrives;
        // a photo still being read back from the draft keeps its file.
        let records: [SiteAuditDraftItemRecord] = items.compactMap { item in
            guard !loadingPhotoIds.contains(item.id) else { return nil }
            if let image = item.image { images[item.id] = image }
            return SiteAuditDraftItemRecord(
                id: item.id,
                title: item.title,
                location: item.location,
                assignee: item.assignee,
                comments: item.comments,
                annotations: item.annotations,
                capturedAt: item.capturedAt,
                createdAt: item.createdAt,
                hasPhoto: item.image != nil || draftPhotosLoading.contains(item.id)
            )
        }
        let draft = SiteAuditDraft(
            id: autosaver.draftId,
            userId: autosaver.userId,
            organizationId: autosaver.organizationId,
            projectId: project?.id,
            projectJobNumber: project?.jobNumber ?? resumeDraft?.projectJobNumber ?? "",
            projectName: project?.siteName ?? resumeDraft?.projectName ?? "",
            typeRawValue: selectedType.rawValue,
            customTitle: customTitle,
            authorName: authorName,
            date: selectedDate,
            visibleToOperatives: operativeAccessVisibleToOperatives,
            items: records,
            createdAt: resumeDraft?.createdAt ?? items.map(\.createdAt).min() ?? Date(),
            updatedAt: Date()
        )
        return .init(draft: draft, images: images)
    }

    private func bootstrapFromDraft(_ draft: SiteAuditDraft) {
        draftId = draft.id
        selectedType = SiteAuditType(rawValue: draft.typeRawValue) ?? .general
        customTitle = draft.customTitle
        if !draft.authorName.isEmpty { authorName = draft.authorName }
        selectedDate = draft.date
        operativeAccessVisibleToOperatives = draft.visibleToOperatives
        // A job the person can no longer see is picked again on the details step.
        if let projectId = draft.projectId,
           let project = visibleProjectsForPicker.first(where: { $0.id == projectId }) ?? resolveProject(id: projectId) {
            selectedProject = project
        }
        items = draft.items.map { record in
            SiteAuditDraftItem(
                id: record.id,
                title: record.title,
                location: record.location,
                assignee: record.assignee,
                comments: record.comments,
                annotations: record.annotations,
                image: nil,
                capturedAt: record.capturedAt,
                createdAt: record.createdAt
            )
        }
        let withPhotos = draft.items.filter(\.hasPhoto).map(\.id)
        draftPhotosLoading = Set(withPhotos)
        step = (selectedProject != nil && !items.isEmpty) ? 2 : 1
        hydrateTask = Task { await loadDraftPhotos(draft: draft, itemIds: withPhotos) }
    }

    private func loadDraftPhotos(draft: SiteAuditDraft, itemIds: [UUID]) async {
        let store = SiteAuditDraftStore.shared
        for itemId in itemIds {
            if Task.isCancelled { return }
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = store.photoData(draftId: draft.id, itemId: itemId, userId: draft.userId, organizationId: draft.organizationId) else { return nil }
                return UIImage(data: data)
            }.value
            if let image, let idx = items.firstIndex(where: { $0.id == itemId }), items[idx].image == nil {
                draftAutosaver?.markPhotoOnDisk(itemId: itemId, image: image)
                items[idx].image = image
            }
            draftPhotosLoading.remove(itemId)
        }
    }

    // MARK: Submit (owner decision 12 Nov, item 5a)

    /// "Submit & generate PDF" / "Update & generate PDF": the audit is queued on the phone (photos written as JPEGs)
    /// and the PDF is built from the photos on the phone, both at once; the PDF shows as soon as both are done. The
    /// upload and the Firestore save then run in the background through `SiteAuditOfflineStore` (the same queue,
    /// claims and retry timer as an audit made offline), and the success sheet says whether it is saved yet.
    private func submitAudit() {
        guard let selectedProject else {
            errorMessage = "Please select a project before submitting."
            return
        }
        if isEditing && !smartCache.isOnline {
            // Editing a saved audit stays online only, as before.
            errorMessage = "Connect to the internet to update this audit."
            return
        }

        isSubmitting = true
        submitStatusMessage = "Preparing PDF…"
        let auditId = existingAudit?.id ?? draftId
        let createdAt = existingAudit?.createdAt ?? Date()
        let createdByUserId = existingAudit?.createdByUserId ?? firebaseBackend.currentUser?.uid ?? "unknown"
        let project = selectedProject
        let drafts = items
        let existingItemsById = Dictionary((existingAudit?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visibilityToOperatives: Bool = {
            if userStore.isOperativeMode() { return true }
            if userStore.canManageSiteAuditOperativeVisibility() { return operativeAccessVisibleToOperatives }
            return true
        }()
        let audit = SiteAudit(
            id: auditId,
            projectId: project.id,
            projectJobNumber: project.jobNumber,
            projectName: project.siteName,
            type: selectedType,
            customTitle: customTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            authorName: authorName,
            date: selectedDate,
            items: drafts.map { draft in
                // An edit keeps the stored URL of every photo it did not change (and of a photo still downloading);
                // a new or replaced photo has no URL yet and is uploaded from the queue.
                let prior = existingItemsById[draft.id]
                let priorURL = (prior?.imageURL?.isEmpty == false) ? prior?.imageURL : nil
                let keepsPrior = isEditing && priorURL != nil
                    && (draft.image == nil || draft.capturedAt == prior?.imageCapturedAt)
                return SiteAuditItem(
                    id: draft.id,
                    title: draft.title,
                    location: draft.location,
                    assignee: draft.assignee,
                    comments: draft.comments,
                    annotations: draft.annotations,
                    imageURL: keepsPrior ? priorURL : (draft.image == nil ? priorURL : nil),
                    imageCapturedAt: draft.capturedAt,
                    createdAt: draft.createdAt
                )
            },
            createdAt: createdAt,
            createdByUserId: createdByUserId,
            visibleToOperatives: visibilityToOperatives
        )
        let orgName = firebaseBackend.currentOrganization?.name
        let orgAbbrev = firebaseBackend.currentOrganization?.documentAbbreviation
        let logoURL = firebaseBackend.currentOrganization?.companyLogoURL

        Task {
            let cachedOrgId = firebaseBackend.currentOrganization?.firestoreDocumentId
            var orgId = cachedOrgId
            if (orgId ?? "").isEmpty, smartCache.isOnline {
                orgId = await firebaseBackend.resolveOrganizationIdForFirebaseWrites(preferredFallback: cachedOrgId)
            }
            guard let orgId, !orgId.isEmpty else {
                isSubmitting = false
                submitStatusMessage = ""
                errorMessage = "Could not resolve your organization. Open Settings, tap Force Reload Data, wait until projects load, then try again."
                return
            }

            let pdfTask = Task {
                let logo = await SiteAuditLogoLoader.logo(urlString: logoURL)
                return await SiteAuditPDFBuilder.makePDFAsync(
                    audit: audit,
                    localItems: drafts,
                    organizationName: orgName,
                    organizationAbbreviation: orgAbbrev,
                    logoImage: logo,
                    clientName: project.client.name,
                    siteAddress: project.siteAddress
                )
            }
            do {
                try await SiteAuditOfflineStore.shared.enqueue(audit: audit, organizationId: orgId, draftItems: drafts)
            } catch {
                pdfTask.cancel()
                isSubmitting = false
                submitStatusMessage = ""
                errorMessage = "Could not keep this audit on the phone: \(error.localizedDescription). Nothing was sent; your work is still here."
                return
            }
            // Queued: from here the audit survives the app closing, so the draft is no longer needed.
            draftAutosaver?.stop(deleteDraft: true)
            SiteAuditBackgroundUpload.start(smartCache: smartCache)

            let pdfURL = await pdfTask.value
            submittedAuditId = auditId
            isSubmitting = false
            submitStatusMessage = ""
            submitSuccessPDFURL = pdfURL
            showingSubmitSuccess = true
            errorMessage = pdfURL == nil
                ? "The audit is kept and will upload, but the PDF could not be made. Open the audit again to share its PDF."
                : nil
        }
    }
}

// MARK: - Submit success (saved + share)

private struct SiteAuditSubmitSuccessView: View {
    let pdfURL: URL?
    let itemCount: Int
    var isUpdate = false
    /// The queued audit this sheet follows (owner decision 12 Nov, item 5a). Nil: shown as saved.
    var auditId: UUID? = nil
    @ObservedObject var queue: SiteAuditOfflineStore
    @ObservedObject var smartCache: SmartCacheService
    let onDone: () -> Void

    @State private var showShareSheet = false

    private var uploadState: SiteAuditUploadState {
        guard let auditId else { return .saved }
        return SiteAuditUploadState.resolve(
            isQueued: queue.isQueued(id: auditId),
            isUploading: queue.claimedAuditIds.contains(auditId),
            isOnline: smartCache.isOnline,
            attemptCount: queue.attemptCount(id: auditId),
            maxAutoAttempts: SiteAuditOfflineStore.maxAutoAttempts
        )
    }

    private var headline: String {
        guard uploadState.isSaved else { return "PDF ready" }
        return isUpdate ? "Audit updated" : "Audit submitted"
    }
    private var subtitle: String {
        guard uploadState.isSaved else { return uploadState.statusText }
        return isUpdate ? "Changes saved · PDF ready" : "Saved · PDF ready"
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
                    VStack(spacing: 10) {
                        PPIconTile(symbol: uploadState.isSaved ? "checkmark" : "icloud.and.arrow.up", family: .sites, size: 78, lifted: true)
                            .padding(.bottom, 6)

                        Text(headline)
                            .font(.system(.title2, design: .rounded))
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 6) {
                            if uploadState == .uploading { ProgressView().controlSize(.small) }
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(SiteAuditColors.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("siteAuditSubmitSuccess.uploadStatus")
                        if let detail = uploadState.detailText {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(SiteAuditColors.textDisabled)
                                .multilineTextAlignment(.center)
                        }
                        if uploadState.showsRetryButton {
                            Button("Retry upload") {
                                SiteAuditBackgroundUpload.start(smartCache: smartCache, userRetry: true)
                            }
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("siteAuditSubmitSuccess.retryUpload")
                        }
                    }
                    .padding(.top, 28)
                    .padding(.bottom, 24)

                    SiteAuditCard {
                        HStack(spacing: 13) {
                            pdfThumbnail
                            VStack(alignment: .leading, spacing: 3) {
                                Text(fileName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(itemCount) item\(itemCount == 1 ? "" : "s")\(fileSizeLabel.isEmpty ? "" : " · \(fileSizeLabel)") · just now")
                                    .font(.footnote)
                                    .foregroundStyle(SiteAuditColors.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                    }
                    .padding(.bottom, 16)

                    SiteAuditPrimaryButton(title: "Share PDF", systemImage: "square.and.arrow.up", style: .success) {
                        showShareSheet = true
                    }
                    .padding(.bottom, 10)

                    if let pdfURL {
                        ShareLink(item: pdfURL) {
                            Text("Download")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .foregroundStyle(SiteAuditColors.primary)
                                .background(PPColor.card)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(SiteAuditColors.primary, lineWidth: 1)
                                )
                        }
                        .accessibilityIdentifier("siteAuditSubmitSuccess.download")
                        .padding(.bottom, 10)
                    }

                    SiteAuditPrimaryButton(title: "Done", style: .secondary, action: onDone)
                        .padding(.bottom, 22)

                    Text("Tap Done to return to audits list")
                        .font(.footnote)
                        .foregroundStyle(SiteAuditColors.textDisabled)
                }
                .padding(.horizontal, PPMetrics.screenGutter)
                .padding(.bottom, 24)
            }
            .siteAuditScreenBackground()
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SiteAuditIconCircleButton(systemName: "xmark", onNavy: true, action: onDone)
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(activityItems: shareActivityItems)
            }
        }
    }

    private var pdfThumbnail: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(PPColor.page)
                .frame(width: 44, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
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
    @State private var showingSmallWorks = false

    private var scopedJobs: [Project] {
        availableProjects.filter { showingSmallWorks ? $0.isSmallWorksDocument : !$0.isSmallWorksDocument }
    }

    private var filteredProjects: [Project] {
        // RULEBOOK 1.21.0 §21 `worksInTab`: an inactive job is under Completed; All is every job.
        let base = WorksListStatusCounts.jobs(scopedJobs, chip: selectedFilter.worksChip)
        var seen = Set<UUID>()
        return base
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.jobNumber.localizedStandardCompare($1.jobNumber) == .orderedAscending }
    }

    private var listStyle: WorksDashboardListStyle {
        showingSmallWorks ? .smallWorks : .projects
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Job type", selection: $showingSmallWorks) {
                    Text("Projects").tag(false)
                    Text("Small Works").tag(true)
                }
                .accessibilityIdentifier("siteAuditProjectPicker.jobType")
                .pickerStyle(.segmented)
                .padding(.horizontal, PPMetrics.screenGutter)
                .padding(.top, 14)
                .padding(.bottom, 10)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(SiteAuditProjectFilter.allCases) { filter in
                            WorksRevampFilterChip(
                                title: filter.rawValue,
                                isSelected: selectedFilter == filter,
                                selectedForeground: WorksDashboardPalette.ink,
                                selectedFill: listStyle.accent,
                                titleFont: .subheadline.weight(.semibold),
                                horizontalPadding: 15,
                                verticalPadding: 9
                            ,
                                accessibilityIdentifier: "siteAuditProjectPicker.filter.\(AccessibilityID.token(filter.rawValue))",
                                action: { selectedFilter = filter }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }

                if filteredProjects.isEmpty {
                    ContentUnavailableView(
                        showingSmallWorks ? "No small works" : "No projects",
                        systemImage: "folder",
                        description: Text("Nothing is \(selectedFilter.rawValue.lowercased()) in this list. Try another filter.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 13) {
                            ForEach(filteredProjects) { project in
                                Button {
                                    selectedProject = project
                                    dismiss()
                                } label: {
                                    WorksDashboardCard(
                                        project: project,
                                        listAccent: listStyle.accent,
                                        showsClientAndManager: true
                                    )
                                }
                                .accessibilityIdentifier("siteAuditProjectPicker.row.\(project.id)")
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle(showingSmallWorks ? "Small Works" : "Projects")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("siteAuditProjectPicker.close")
                }
            }
        }
    }
}

struct SiteAuditAddItemView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SiteAuditDraftItem
    @State private var showingCamera = false
    @State private var showingLibrary = false
    /// Multi-add load failures from the flow behind this sheet (an alert there would not show over the sheet).
    @Binding var failedPhotoLoads: Int
    /// The item's photo as the flow behind this sheet has it now (an existing audit's photo may finish
    /// downloading after the editor opened). Taken only while the draft has no photo of its own.
    var arrivedImage: UIImage?
    let onSubmit: (SiteAuditDraftItem) -> Void

    init(
        item: SiteAuditDraftItem = SiteAuditDraftItem(),
        failedPhotoLoads: Binding<Int> = .constant(0),
        arrivedImage: UIImage? = nil,
        onSubmit: @escaping (SiteAuditDraftItem) -> Void
    ) {
        self._draft = State(initialValue: item)
        self._failedPhotoLoads = failedPhotoLoads
        self.arrivedImage = arrivedImage
        self.onSubmit = onSubmit
    }

    private func takeArrivedImageIfNeeded() {
        guard draft.image == nil, let arrivedImage else { return }
        draft.image = arrivedImage
    }

    private var canSave: Bool {
        draft.image != nil && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SiteAuditPhotoLoadFailureBanner(count: $failedPhotoLoads)
                    SiteAuditSectionLabel(title: "Photo")
                    photoBlock
                    HStack(spacing: 10) {
                        secondaryPhotoButton("Retake", icon: "camera.fill") { showingCamera = true }
                        secondaryPhotoButton("Library", icon: "photo.on.rectangle.angled") { showingLibrary = true }
                    }

                    SiteAuditSectionLabel(title: "Details")
                    SiteAuditCard {
                        VStack(spacing: 0) {
                            fieldBlock("Title", required: true) {
                                TextField("Front courtyard", text: $draft.title)
                                    .accessibilityIdentifier("siteAuditAddItem.frontCourtyard")
                                    .font(.body)
                                    .siteAuditClearButton($draft.title, label: "Clear title", identifier: "siteAuditAddItem.clearTitle")
                            }
                            divider
                            fieldBlock("Comments", required: false) {
                                TextField("Notes…", text: $draft.comments, axis: .vertical)
                                    .accessibilityIdentifier("siteAuditAddItem.notes")
                                    .lineLimit(3...6)
                                    .font(.body)
                                    .siteAuditClearButton($draft.comments, label: "Clear comments", identifier: "siteAuditAddItem.clearComments", alignment: .top)
                            }
                            divider
                            assigneeRow
                            divider
                            fieldBlock("Location tag", required: false) {
                                TextField("e.g. Front entrance courtyard", text: $draft.location)
                                    .accessibilityIdentifier("siteAuditAddItem.eGFrontEntranceCourtyard")
                                    .font(.body)
                                    .siteAuditClearButton($draft.location, label: "Clear location tag", identifier: "siteAuditAddItem.clearLocation")
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
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("New item")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SiteAuditToolbarPill(title: "Cancel", filled: false, onNavy: true) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SiteAuditToolbarPill(title: "Save", filled: true, disabled: !canSave, onNavy: true) {
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
            .onAppear { takeArrivedImageIfNeeded() }
            .onChange(of: arrivedImage) { _, _ in takeArrivedImageIfNeeded() }
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
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(SiteAuditColors.primary)
                }
                    .accessibilityIdentifier("siteAuditAddItem.cameraFill")
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        }
    }

    private var assigneeRow: some View {
        HStack(spacing: 13) {
            SiteAuditRowIconChip(systemName: "person.fill", tint: SiteAuditColors.pink, background: SiteAuditColors.pinkTint, size: PPMetrics.menuIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text("Assignee")
                    .font(.footnote)
                    .foregroundStyle(SiteAuditColors.textSecondary)
                TextField("Name", text: $draft.assignee)
                    .accessibilityIdentifier("siteAuditAddItem.name")
                    .font(.body)
                    .siteAuditClearButton($draft.assignee, label: "Clear assignee", identifier: "siteAuditAddItem.clearAssignee")
            }
        }
        .padding(.vertical, 11)
    }

    private var annotationsRow: some View {
        HStack(spacing: 13) {
            SiteAuditRowIconChip(systemName: "pencil.tip", tint: SiteAuditColors.warn, background: SiteAuditColors.warnTint, size: PPMetrics.menuIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text("Annotations")
                    .font(.footnote)
                    .foregroundStyle(SiteAuditColors.textSecondary)
                TextField("Notes on photo", text: $draft.annotations)
                    .accessibilityIdentifier("siteAuditAddItem.notesOnPhoto")
                    .font(.body)
                    .foregroundStyle(SiteAuditColors.primary)
                    .siteAuditClearButton($draft.annotations, label: "Clear annotations", identifier: "siteAuditAddItem.clearAnnotations")
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
            .font(.footnote)
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
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(SiteAuditColors.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(SiteAuditColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityIdentifier("siteAuditAddItem.\(AccessibilityID.token(title))")
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
    @State private var isPreparingSharePDF = false
    @State private var showingEdit = false
    @State private var reportTarget: FileReportTarget?
    @State private var viewerReportTarget: FileReportTarget?

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
                VStack(alignment: .leading, spacing: 0) {
                    detailNavyHeader

                    VStack(alignment: .leading, spacing: 14) {
                        if canEdit {
                            SiteAuditAuditListCard(audit: displayAudit, onTap: { showingEdit = true })
                                .accessibilityLabel("Edit audit details")
                                .accessibilityHint("Opens the edit flow for this site audit")
                        } else {
                            SiteAuditAuditListCard(audit: displayAudit, showsChevron: false)
                        }
                        HStack(spacing: 8) {
                            SiteAuditPrimaryButton(
                                title: isPreparingSharePDF ? "Preparing…" : "Share",
                                systemImage: "square.and.arrow.up",
                                style: .primary
                            ) {
                                Task { await shareAuditPDF() }
                            }
                            .disabled(isPreparingSharePDF)
                            .opacity(isPreparingSharePDF ? 0.7 : 1)
                            if canEdit {
                                SiteAuditPrimaryButton(title: "Edit Site Audit", systemImage: "square.and.pencil", style: .greyFilled) {
                                    showingEdit = true
                                }
                            }
                        }
                        PPSectionHeader("Summary")
                            .padding(.bottom, -14)
                        PPGroupedCard {
                            summaryLine("Author", displayAudit.authorName, symbol: "person.fill", family: .people)
                            if !displayAudit.customTitle.isEmpty {
                                divider
                                summaryLine("Title", displayAudit.customTitle, symbol: "textformat", family: .plan)
                            }
                            divider
                            summaryLine("Date", displayAudit.date.formatted(date: .abbreviated, time: .omitted), symbol: "calendar", family: .plan)
                            if let clientProject {
                                divider
                                summaryLine("Client", clientProject.client.name, symbol: "building.2.fill", family: .sites)
                            }
                        }
                        PPSectionHeader("Items") {
                            Text("\(displayAudit.items.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, -14)
                        ForEach(Array(displayAudit.items.enumerated()), id: \.element.id) { index, item in
                            itemCard(index: index + 1, item: item)
                        }
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                    .ppContentSheet()
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Audit detail")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("siteAuditDetail.done")
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
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Menu {
                                FileReportMenuButton(
                                    target: photoReportTarget(selectedImageURL ?? ""),
                                    presented: $viewerReportTarget
                                )
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("More")
                        }
                        ToolbarItem(placement: .topBarTrailing) { Button("Close") { selectedImageURL = nil }
                        .accessibilityIdentifier("siteAuditDetail.close") }
                    }
                    .fileReportSheet($viewerReportTarget)
                }
            }
            .fileReportSheet($reportTarget)
        }
    }

    private func photoReportTarget(_ url: String) -> FileReportTarget {
        FileReportTarget(surface: "site_audit", parentId: displayAudit.id.uuidString, fileRef: url)
    }

    /// Navy header: audit type, job and the author, date and item count the page already shows.
    private var detailNavyHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            PPNavyPageTitle(
                eyebrow: displayAudit.type.rawValue,
                title: displayAudit.projectJobNumber,
                subtitle: displayAudit.projectName
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PPOnNavyPill(text: displayAudit.authorName, symbol: "person.fill")
                    PPOnNavyPill(text: displayAudit.date.formatted(date: .abbreviated, time: .omitted), symbol: "calendar")
                    PPOnNavyPill(text: "\(displayAudit.items.count) items", symbol: "cube.box")
                }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private var divider: some View {
        PPRowDivider()
    }

    private func summaryLine(_ label: String, _ value: String, symbol: String, family: PPFamily) -> some View {
        PPDetailRowLabel(title: label, value: value, symbol: symbol, family: family)
    }

    private func itemCard(index: Int, item: SiteAuditItem) -> some View {
        PPGroupedCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(index). \(item.title.isEmpty ? "Untitled" : item.title)")
                    .font(.body.weight(.semibold))
                if !item.location.isEmpty {
                    Label(item.location, systemImage: "mappin.and.ellipse")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !item.comments.isEmpty {
                    Text(item.comments).font(.subheadline)
                }
                if let url = item.imageURL, let imageURL = URL(string: url) {
                    Button { selectedImageURL = url } label: {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFill()
                            default: SiteAuditColors.primaryTint
                            }
                        }
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .accessibilityIdentifier("siteAuditDetail.itemCard")
                    .buttonStyle(.plain)
                    .fileReportContextMenu(photoReportTarget(url), presented: $reportTarget)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func shareAuditPDF() async {
        if pdfURL == nil {
            isPreparingSharePDF = true
            await buildPDFPreview()
            isPreparingSharePDF = false
        }
        guard pdfURL != nil else { return }
        showShare = true
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
        let orgAbbrev = firebaseBackend.currentOrganization?.documentAbbreviation
        let client = clientProject?.client.name
        let address = clientProject?.siteAddress
        let generated = await SiteAuditPDFBuilder.makePDFAsync(
            audit: audit,
            localItems: drafts,
            organizationName: orgName,
            organizationAbbreviation: orgAbbrev,
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

