import SwiftUI
import Combine
import FirebaseAuth

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
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var smartCache: SmartCacheService

    @StateObject private var store = DLStore(items: [])
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var siteAudits: [SiteAudit] = []

    private var canManage: Bool { !userStore.isOperativeMode() }
    private var contextKind: String { project.jobType == .smallWorks ? "Small Work" : "Project" }
    private var authorName: String { userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown" }
    private var projectNotificationName: String {
        let site = project.siteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = project.jobNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if site.isEmpty { return job }
        if job.isEmpty { return site }
        return "\(site) · \(job)"
    }

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
                    siteAudits: siteAudits.map { WorkAccess.siteAuditRef($0) },
                    tradeOptions: ["General"] + StaffTradeType.pickerCases.map(\.rawValue),
                    onCommit: { deadline, fileURL in
                        Task { await commit(deadline, localFileURL: fileURL) }
                    },
                    onBack: { dismiss() },
                    project: project,
                    jobSiteAudits: siteAudits
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
                await persistDeadlines(items)
            } syncNotifications: { items in
                await syncDeadlineNotifications(items)
            }
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .offlineSyncDidComplete)) { _ in
            Task { await load(preferRemote: true) }
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

    private func load(preferRemote: Bool = false) async {
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
            let local = OfflineDeadlineLocalStore.shared.load(projectId: project.id, organizationId: orgId)
            if !preferRemote, smartCache.isOnline == false, let local {
                store.replaceAll(local.items)
                store.lastKnownUpdatedAt = local.updatedAt
            } else {
                let state = try await firebaseBackend.loadDeadlinesState(project: project, organizationId: orgId)
                if smartCache.isOnline == false, let local {
                    store.replaceAll(local.items)
                    store.lastKnownUpdatedAt = local.updatedAt ?? state.updatedAt
                } else {
                    store.replaceAll(state.items)
                    store.lastKnownUpdatedAt = state.updatedAt
                    OfflineDeadlineLocalStore.shared.save(
                        items: state.items,
                        projectId: project.id,
                        organizationId: orgId,
                        updatedAt: state.updatedAt
                    )
                }
            }
            store.restrictToAssigneeUserId = canManage ? nil : userStore.currentUser?.id
            store.now = Date()
            if smartCache.isOnline {
                siteAudits = (try? await firebaseBackend.loadSiteAudits(organizationId: orgId, projectId: project.id)) ?? siteAudits
            }
            await syncDeadlineNotifications(store.items)
        } catch {
            if let local = OfflineDeadlineLocalStore.shared.load(projectId: project.id, organizationId: orgId) {
                store.replaceAll(local.items)
                store.lastKnownUpdatedAt = local.updatedAt
                store.restrictToAssigneeUserId = canManage ? nil : userStore.currentUser?.id
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func persistDeadlines(_ items: [DLDeadline]) async {
        guard let orgId = organizationId() else { return }
        OfflineDeadlineLocalStore.shared.save(
            items: items,
            projectId: project.id,
            organizationId: orgId,
            updatedAt: store.lastKnownUpdatedAt
        )
        if OfflineWriteSupport.shouldQueue(isOnline: smartCache.isOnline) {
            OfflineOutboxStore.shared.enqueueSaveDeadlines(
                projectId: project.id,
                isSmallWorks: project.jobType == .smallWorks,
                items: items,
                baseUpdatedAt: store.lastKnownUpdatedAt,
                organizationId: orgId
            )
            return
        }
        do {
            let written = try await firebaseBackend.saveDeadlines(
                items,
                project: project,
                organizationId: orgId,
                baseUpdatedAt: store.lastKnownUpdatedAt
            )
            store.lastKnownUpdatedAt = Date()
            if written.map(\.id) != items.map(\.id) || written.count != items.count {
                store.replaceAll(written)
            }
            OfflineDeadlineLocalStore.shared.save(
                items: written,
                projectId: project.id,
                organizationId: orgId,
                updatedAt: store.lastKnownUpdatedAt
            )
        } catch {
            if OfflineWriteSupport.shouldQueue(error: error, isOnline: smartCache.isOnline) {
                OfflineOutboxStore.shared.enqueueSaveDeadlines(
                    projectId: project.id,
                    isSmallWorks: project.jobType == .smallWorks,
                    items: items,
                    baseUpdatedAt: store.lastKnownUpdatedAt,
                    organizationId: orgId
                )
            } else {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
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
            if OfflineWriteSupport.shouldQueue(isOnline: smartCache.isOnline) {
                errorMessage = "Deadline saved on this device. Attach the file again when you’re back online."
            } else {
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
        }
        if let auditId = item.siteAuditId,
           let audit = siteAudits.first(where: { $0.id == auditId }) {
            item.siteAuditTitle = WorkAccess.siteAuditRef(audit).title
        }
        let previous = store.items.first(where: { $0.id == item.id })
        store.upsert(item)
        await notifyNewAssignees(previous: previous, current: item)
        await syncDeadlineNotifications(store.items)
    }

    private func syncDeadlineNotifications(_ items: [DLDeadline]) async {
        await DeadlineLocalNotifications.sync(
            items: items,
            currentUserId: userStore.currentUser?.id,
            projectName: projectNotificationName
        )
        await notificationService.syncDeadlineInboxNotifications(
            items: items,
            projectName: projectNotificationName
        )
    }

    private func notifyNewAssignees(previous: DLDeadline?, current: DLDeadline) async {
        let oldIds = Set(previous?.assigneeUserIds ?? [])
        let added = current.assigneeUserIds.filter { !oldIds.contains($0) }
        guard !added.isEmpty else { return }
        await notificationService.notifyDeadlineAssigned(
            deadlineId: current.id,
            title: current.title,
            projectName: projectNotificationName,
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
