import SwiftUI
import FirebaseFirestore
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
    /// The deadlines as last loaded from (or written to) the server: what this person's changes are compared with, so
    /// only their own changes are saved (`saveDeadlineChanges`).
    @State private var serverBaseItems: [DLDeadline] = []
    /// The same list as stored, read by the rulebook reader (`loadDeadlinesState` / the last save); nil when the list
    /// came from this device's cache.
    @State private var serverBaseRows: RulebookJSONBox?
    /// Saves run one after another, so each compares with the list the previous save wrote (two quick edits are never
    /// read as a conflict with each other).
    @State private var persistTask: Task<Void, Never>?

    private var canManage: Bool { !userStore.isOperativeMode() }
    private var contextKind: String { project.isSmallWorksDocument ? "Small Work" : "Project" }
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
                    VStack(alignment: .leading, spacing: 0) {
                        HSNavBar(title: "Deadlines",
                                 subtitle: "\(project.siteName) · \(project.jobNumber)",
                                 onBack: { dismiss() }) { EmptyView() }

                        DeadlinesLoadingNavyHeader(
                            contextName: project.siteName,
                            contextRef: project.jobNumber,
                            contextKind: contextKind
                        )
                    }
                    .padding(.bottom, PPMetrics.headerBottomPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ppNavyHeader()

                    VStack(spacing: 0) {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .modifier(DeadlinesLoadingContentSheet())
                }
                .background(PPColor.page.ignoresSafeArea())
            } else {
                DLDeadlinesScreen(
                    store: store,
                    contextName: project.siteName,
                    contextRef: project.jobNumber,
                    contextKind: contextKind,
                    // RULEBOOK §2: deadline changes are online only — the add and edit controls are off offline.
                    canManage: canManage && OfflinePolicy.isEnabled(.saveDeadlines, isOnline: smartCache.isOnline),
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
                .accessibilityIdentifier("projectDeadlines.ok")
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: firebaseBackend.currentOrganization?.firestoreDocumentId ?? "") {
            let orgReady = organizationId() != nil
            guard orgReady else { return }
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
        .listensWhileOpen("deadlines", key: "deadlines", targetSuffix: project.documentId,
                          firebaseBackend: firebaseBackend,
                          query: { org in
                              let isSmallWorks = project.isSmallWorksDocument
                              let docId = CanonicalBusinessEngine.deadlinesDocumentId(projectId: project.documentId, isSmallWorks: isSmallWorks)
                                  ?? "deadlines_\(isSmallWorks ? "smallWorks" : "projects")_\(project.documentId.uppercased())"
                              return org.collection("settings").whereField(FieldPath.documentID(), in: [docId, "deadlineAssignments"])
                          }) {
            await load(preferRemote: true)
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

    /// AGENTS rule 2: the open organisation only, never the person's home company (`users/{uid}.organizationId`).
    private func organizationId() -> String? {
        FirebaseBackend.openOrganizationIdForWrites(
            requested: nil,
            openOrganizationId: firebaseBackend.currentOrganization?.firestoreDocumentId
        )
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
                serverBaseItems = local.items
                serverBaseRows = nil
            } else {
                let state = try await firebaseBackend.loadDeadlinesState(project: project, organizationId: orgId)
                if smartCache.isOnline == false, let local {
                    store.replaceAll(local.items)
                    store.lastKnownUpdatedAt = local.updatedAt ?? state.updatedAt
                    serverBaseItems = local.items
                    serverBaseRows = nil
                } else {
                    store.replaceAll(state.items)
                    store.lastKnownUpdatedAt = state.updatedAt
                    serverBaseItems = state.items
                    serverBaseRows = state.storedRows
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
                serverBaseItems = local.items
                serverBaseRows = nil
                store.restrictToAssigneeUserId = canManage ? nil : userStore.currentUser?.id
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// RULEBOOK §2: deadlines are not in `OFFLINE_ACTIONS`, so a change is online only — offline it is put back and
    /// the person is told; nothing is queued. Online, only this person's changes are laid over the stored list
    /// (`saveDeadlineChanges`); a deadline someone else changed meanwhile is not overwritten, and the person is told
    /// which of their changes did not apply.
    private func persistDeadlines(_ items: [DLDeadline]) async {
        let previous = persistTask
        let task = Task { @MainActor in
            await previous?.value
            await saveDeadlineChanges(items)
        }
        persistTask = task
        await task.value
    }

    private func saveDeadlineChanges(_ items: [DLDeadline]) async {
        guard let orgId = organizationId() else { return }
        guard OfflinePolicy.isEnabled(.saveDeadlines, isOnline: smartCache.isOnline) else {
            store.replaceAll(DeadlineScreenMerge.screenAfterSave(sent: items, saved: serverBaseItems, onScreen: store.items))
            errorMessage = OnlineOnlyActionError(actionId: UnlistedOfflineAction.saveDeadlines.rawValue).localizedDescription
            return
        }
        do {
            let result = try await firebaseBackend.saveDeadlineChanges(
                base: serverBaseItems,
                baseStoredRows: serverBaseRows,
                next: items,
                projectId: project.id,
                projectKey: project.documentId,
                isSmallWorks: project.isSmallWorksDocument,
                organizationId: orgId,
                baseUpdatedAt: store.lastKnownUpdatedAt
            )
            // The new base is the list as stored, read back through the rulebook reader (never this device's own
            // copies, whose dates are more precise than the stored ones — review of #242).
            serverBaseItems = result.items
            serverBaseRows = result.storedRows
            store.lastKnownUpdatedAt = Date()
            // Review of #242: only the deadlines the person has not changed since this save was sent take the saved
            // copy; a newer edit still waiting to be saved stays on screen.
            let screen = DeadlineScreenMerge.screenAfterSave(sent: items, saved: result.items, onScreen: store.items)
            if screen != store.items {
                store.replaceAll(screen)
            }
            OfflineDeadlineLocalStore.shared.save(
                items: result.items,
                projectId: project.id,
                organizationId: orgId,
                updatedAt: store.lastKnownUpdatedAt
            )
            if !result.notApplied.isEmpty {
                let titles = result.notApplied.map(\.title).joined(separator: ", ")
                errorMessage = "Not saved — changed or deleted on another device: \(titles). Check it and try again."
            }
        } catch {
            // Puts back only what this save sent; a newer edit made since stays (its own save follows).
            store.replaceAll(DeadlineScreenMerge.screenAfterSave(sent: items, saved: serverBaseItems, onScreen: store.items))
            errorMessage = error.localizedDescription
        }
    }

    private func commit(_ draft: DLDeadline, localFileURL: URL?) async {
        guard let orgId = organizationId() else {
            errorMessage = "Cannot save without organization."
            return
        }
        // RULEBOOK §2: deadlines are online only (not in `OFFLINE_ACTIONS`); nothing is saved on the device.
        guard OfflinePolicy.isEnabled(.saveDeadlines, isOnline: smartCache.isOnline) else {
            errorMessage = OnlineOnlyActionError(actionId: UnlistedOfflineAction.saveDeadlines.rawValue).localizedDescription
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

/// Loading-state copy of the Deadlines page's navy header (same title block, stat
/// row and progress track) so the page doesn't jump when the list arrives.
/// Counts are not known yet, so the stat row and caption are shown as placeholders.
private struct DeadlinesLoadingNavyHeader: View {
    let contextName: String
    let contextRef: String
    let contextKind: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                PPNavyPageTitle(
                    eyebrow: "\(contextRef) · \(contextKind)",
                    title: contextName
                )
                Spacer(minLength: 8)
                PPIconTile(symbol: "calendar.badge.clock", family: .plan, size: 40)
            }

            HStack(alignment: .top, spacing: 14) {
                PPStat(value: "0", label: "Deadlines")
                PPStatDivider()
                PPStat(value: "0", label: "Met")
                PPStatDivider()
                PPStat(value: "0", label: "Overdue")
            }
            .fixedSize(horizontal: false, vertical: true)
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                PPOnNavyProgressBar(fraction: 0)
                Text("0 of 0 deadlines met")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(PPColor.onNavySecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .redacted(reason: .placeholder)
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 4)
    }
}

/// Same light rounded sheet the loaded Deadlines page uses. Visual only.
private struct DeadlinesLoadingContentSheet: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(PPColor.page)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: PPMetrics.contentCornerRadius,
                    topTrailingRadius: PPMetrics.contentCornerRadius,
                    style: .continuous
                )
            )
            .padding(.top, -PPMetrics.contentOverlap)
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

/// What the Deadlines screen shows when a save finishes (review of #242). Saves run one after another, and the person
/// may edit again while one is in flight. A deadline still exactly as this save sent it takes `saved` (the stored copy,
/// or the base when the save failed); one changed, added or deleted on screen since stays as it is; a deadline the
/// stored list has that this save neither sent nor shows (added on another device) is added. Screen plumbing only.
enum DeadlineScreenMerge {
    static func screenAfterSave(sent: [DLDeadline], saved: [DLDeadline], onScreen: [DLDeadline]) -> [DLDeadline] {
        let sentById = Dictionary(sent.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let savedById = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [DLDeadline] = []
        for item in onScreen {
            if let was = sentById[item.id], was == item {
                if let fresh = savedById[item.id] { out.append(fresh) }
            } else {
                out.append(item)
            }
        }
        let shown = Set(onScreen.map(\.id))
        let sentIds = Set(sent.map(\.id))
        for fresh in saved where !shown.contains(fresh.id) && !sentIds.contains(fresh.id) {
            out.append(fresh)
        }
        return out
    }
}
