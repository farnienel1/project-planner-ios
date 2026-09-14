import SwiftUI

struct ProjectDeadlinesView: View {
    let project: Project

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var userStore: UserStore
    @EnvironmentObject private var firebaseBackend: FirebaseBackend
    @EnvironmentObject private var bookingStore: BookingStore
    @EnvironmentObject private var operativeStore: OperativeStore
    @EnvironmentObject private var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject private var taskStore: ProjectTaskStore
    @EnvironmentObject private var notificationService: NotificationService

    @StateObject private var store = DLStore(items: [])
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var siteAudits: [SiteAudit] = []

    private var canManage: Bool { !userStore.isOperativeMode() }
    private var contextKind: String { project.jobType == .smallWorks ? "Small Work" : "Project" }
    private var authorName: String { userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown" }

    var body: some View {
        Group {
            if isLoading && store.items.isEmpty {
                VStack(spacing: 0) {
                    HSNavBar(title: "Deadlines",
                             subtitle: "\(project.siteName) · \(project.jobNumber)",
                             onBack: { dismiss() }) { EmptyView() }
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .hsScreen()
            } else {
                DLDeadlinesScreen(
                    store: store,
                    contextName: project.siteName,
                    contextRef: project.jobNumber,
                    contextKind: contextKind,
                    canManage: canManage,
                    authorName: authorName,
                    people: people,
                    siteAudits: siteAudits.map(WorkAccess.siteAuditRef),
                    tradeOptions: ["General"] + StaffTradeType.pickerCases.map(\.rawValue),
                    onCommit: { deadline, fileURL in
                        Task { await commit(deadline, localFileURL: fileURL) }
                    },
                    onBack: { dismiss() }
                )
            }
        }
        .navigationBarHidden(true)
        .alert("Deadlines", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            store.bindPersistence { items in
                guard let orgId = organizationId() else { return }
                do {
                    try await firebaseBackend.saveDeadlines(items, project: project, organizationId: orgId)
                } catch {
                    await MainActor.run { errorMessage = error.localizedDescription }
                }
            } syncNotifications: { items in
                await DeadlineLocalNotifications.sync(items: items, currentUserId: userStore.currentUser?.id)
            }
            await load()
        }
        .onAppear {
            store.restrictToAssigneeUserId = canManage ? nil : userStore.currentUser?.id
            store.now = Date()
        }
    }

    private var people: [DLPerson] {
        WorkAccess.peopleForJob(
            projectId: project.id,
            userStore: userStore,
            bookingStore: bookingStore,
            operativeStore: operativeStore,
            managerScheduleStore: managerScheduleStore,
            taskStore: taskStore
        )
    }

    private func organizationId() -> String? {
        firebaseBackend.currentOrganization?.firestoreDocumentId ?? userStore.currentUser?.organizationId
    }

    private func load() async {
        guard let orgId = organizationId() else {
            errorMessage = "Organization is unavailable."
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            if userStore.organizationUsers.isEmpty {
                await userStore.loadOrganizationUsers()
            }
            let items = try await firebaseBackend.loadDeadlines(project: project, organizationId: orgId)
            store.replaceAll(items)
            store.restrictToAssigneeUserId = canManage ? nil : userStore.currentUser?.id
            store.now = Date()
            siteAudits = try await firebaseBackend.loadSiteAudits(organizationId: orgId, projectId: project.id)
            await DeadlineLocalNotifications.sync(items: items, currentUserId: userStore.currentUser?.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commit(_ draft: DLDeadline, localFileURL: URL?) async {
        guard let orgId = organizationId() else {
            errorMessage = "Cannot save without organization."
            return
        }
        var item = draft
        item.projectId = project.id
        item.contextKind = contextKind
        if item.createdByUserId.isEmpty {
            item.createdByUserId = userStore.currentUser?.id ?? firebaseBackend.currentUser?.uid ?? ""
        }
        if let localFileURL {
            do {
                let name = item.fileName ?? localFileURL.lastPathComponent
                let url = try await firebaseBackend.uploadHealthSafetyFile(
                    localFileURL,
                    organizationId: orgId,
                    projectId: project.id,
                    category: "deadlines",
                    fileName: name
                )
                item.fileURL = url
                item.fileName = name
                item.history.insert(DLChange(at: Date(), author: authorName, kind: .fileAttached(name: name)), at: 0)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        if let auditId = item.siteAuditId,
           let audit = siteAudits.first(where: { $0.id == auditId }) {
            item.siteAuditTitle = WorkAccess.siteAuditRef(audit).title
        }
        let previous = store.items.first(where: { $0.id == item.id })
        store.upsert(item)
        await notifyNewAssignees(previous: previous, current: item)
        await DeadlineLocalNotifications.sync(items: store.items, currentUserId: userStore.currentUser?.id)
    }

    private func notifyNewAssignees(previous: DLDeadline?, current: DLDeadline) async {
        let oldIds = Set(previous?.assigneeUserIds ?? [])
        let added = current.assigneeUserIds.filter { !oldIds.contains($0) }
        guard !added.isEmpty else { return }
        await notificationService.notifyDeadlineAssigned(
            deadlineId: current.id,
            title: current.title,
            projectName: project.siteName,
            assignedUserIds: added,
            createdBy: authorName
        )
    }
}

extension DLStore {
    /// Persistence hook used by the live Deadlines tab after in-sheet mutations (progress / complete / reschedule).
    func bindPersistence(
        persist: @escaping ([DLDeadline]) async -> Void,
        syncNotifications: @escaping ([DLDeadline]) async -> Void
    ) {
        onItemsChanged = { items in
            Task {
                await persist(items)
                await syncNotifications(items)
            }
        }
    }
}
