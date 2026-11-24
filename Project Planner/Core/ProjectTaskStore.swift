//
//  ProjectTaskStore.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore

@MainActor
class ProjectTaskStore: ObservableObject {
    @Published private(set) var tasks: [ProjectTask] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// RULEBOOK 1.89.0 §34: the last task save or delete the server refused, shown to the person (before 1.89.0 it
    /// was only printed, so a refused delete or edit looked like it had worked until the next reload).
    @Published var lastWriteError: String?
    
    private var firebaseBackend: FirebaseBackend?
    private var cancellables = Set<AnyCancellable>()
    private var pendingReloadAfterCurrentLoad = false
    
    func setFirebaseBackend(_ backend: FirebaseBackend) {
        self.firebaseBackend = backend
    }

    /// Live `tasks` for the organisation (one listener), read through `projectTask(documentId:data:)`
    /// (`parseTaskDocument`). A server snapshot replaces the list, except tasks this device still has queued
    /// in the outbox ("Pending sync", RULEBOOK §2). Cached copy first; offline keeps the last copy.
    func startLiveUpdates(organizationId: String) {
        guard let firebaseBackend else { return }
        firebaseBackend.listenOrganizationQuery(
            key: "tasks",
            organizationId: organizationId,
            retryOnFailure: true,
            query: { $0.collection("tasks") }
        ) { [weak self] rows, fromCache in
            guard let self else { return }
            let incoming = rows.compactMap { FirebaseBackend.projectTask(documentId: $0.id, data: $0.data) }
            guard var next = LiveSnapshotMerge.apply(existing: self.tasks, incoming: incoming, fromCache: fromCache, rowCount: LiveSnapshotMerge.readableRowCount(rows), collection: "tasks") else { return }
            let incomingIds = Set(next.map(\.id))
            let queued = self.tasks.filter {
                !incomingIds.contains($0.id) && OfflineOutboxStore.shared.hasPendingSync(entityId: $0.id.uuidString)
            }
            next = (next + queued).sorted { $0.createdAt > $1.createdAt }
            guard next != self.tasks else { return }
            self.tasks = next
            OfflineTaskLocalStore.shared.save(next, organizationId: organizationId)
        }
    }

    func discardInMemoryForOrganizationSwitch() {
        tasks = []
        isLoading = false
        pendingReloadAfterCurrentLoad = false
        errorMessage = nil
    }

    func loadData() async {
        if isLoading {
            if firebaseBackend?.isBootstrappingOrgDataLoad == true {
                print("🔥🔥🔥 DEBUG: TaskStore loadData ignored (already loading during bootstrap); not queueing follow-up")
                return
            }
            pendingReloadAfterCurrentLoad = true
            print("🔥🔥🔥 DEBUG: TaskStore loadData ignored (already loading); queued one follow-up reload")
            return
        }

        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            print("🔥🔥🔥 DEBUG: TaskStore - Organization not set. firebaseBackend: \(firebaseBackend != nil), organization: \(firebaseBackend?.currentOrganization?.firestoreDocumentId ?? "nil")")
            errorMessage = "Organization not set"
            isLoading = false
            return
        }
        
        if tasks.isEmpty {
            let cached = OfflineTaskLocalStore.shared.load(organizationId: organizationId)
            if !cached.isEmpty {
                tasks = cached
            }
        }

        print("🔥🔥🔥 DEBUG: TaskStore - Loading tasks for organization: \(organizationId)")
        isLoading = true
        errorMessage = nil
        
        defer {
            isLoading = false
            if pendingReloadAfterCurrentLoad,
               self.firebaseBackend?.isBootstrappingOrgDataLoad != true {
                pendingReloadAfterCurrentLoad = false
                Task { @MainActor in
                    await self.loadData()
                }
            } else {
                pendingReloadAfterCurrentLoad = false
            }
        }

        do {
            let loadedTasks = try await firebaseBackend.loadProjectTasks(organizationId: organizationId)
            guard firebaseBackend.currentOrganization?.firestoreDocumentId == organizationId else { return }
            print("🔥🔥🔥 DEBUG: TaskStore - Loaded \(loadedTasks.count) tasks from Firebase")
            // Keep tasks that were just created locally but are not yet visible on the server read (avoids “disappearing” tasks).
            let loadedIds = Set(loadedTasks.map(\.id))
            let pendingLocal = firebaseBackend.suppressStaleOrganizationCache
                ? []
                : tasks.filter { !loadedIds.contains($0.id) }
            tasks = (loadedTasks + pendingLocal).sorted { $0.createdAt > $1.createdAt }
            OfflineTaskLocalStore.shared.save(tasks, organizationId: organizationId)
        } catch {
            print("🔥🔥🔥 DEBUG: TaskStore - Error loading tasks: \(error.localizedDescription)")
            let cached = OfflineTaskLocalStore.shared.load(organizationId: organizationId)
            if !cached.isEmpty {
                let cachedIds = Set(cached.map(\.id))
                let pendingLocal = tasks.filter { !cachedIds.contains($0.id) }
                tasks = (cached + pendingLocal).sorted { $0.createdAt > $1.createdAt }
                errorMessage = nil
            } else if tasks.isEmpty {
                errorMessage = "Failed to load tasks: \(error.localizedDescription)"
            } else {
                errorMessage = nil
            }
        }
    }
    
    func tasks(for projectId: UUID, includeCompleted: Bool = true) -> [ProjectTask] {
        tasks.filter { task in
            guard task.projectId == projectId else { return false }
            if includeCompleted {
                return true
            }
            return !task.isCompleted
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
    
    func addTask(_ task: ProjectTask) async throws {
        // Check task limit (500 per project)
        let projectTaskCount = tasks(for: task.projectId, includeCompleted: true).count
        if projectTaskCount >= 500 {
            throw TaskLimitError.taskLimitReached
        }
        
        // RULEBOOK 1.10.0 §13: a new task stores who created it (`createdByUserId`, the signed-in account).
        var task = task
        if (task.createdByUserId ?? "").isEmpty { task.createdByUserId = firebaseBackend?.currentUser?.uid }
        tasks.append(task)
        if let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId {
            OfflineTaskLocalStore.shared.upsert(task, organizationId: organizationId)
        }
        await save(task)
    }
    
    enum TaskLimitError: LocalizedError {
        case taskLimitReached
        
        var errorDescription: String? {
            switch self {
            case .taskLimitReached:
                return "Task limit reached. Please delete the first 50 completed tasks to clear some space."
            }
        }
    }
    
    func taskCount(for projectId: UUID) -> Int {
        tasks(for: projectId, includeCompleted: true).count
    }
    
    func completedTaskCount(for projectId: UUID) -> Int {
        tasks(for: projectId, includeCompleted: true).filter { $0.isCompleted }.count
    }
    
    func updateTask(_ task: ProjectTask) async {
        _ = await updateTaskReportingError(task)
    }

    /// Saves an edited task and says whether the server accepted it. On a refusal the row on screen goes back to the
    /// stored copy and `lastWriteError` says why.
    @discardableResult
    func updateTaskReportingError(_ task: ProjectTask) async -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return false }
        let previous = tasks[index]
        tasks[index] = task
        if let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId {
            OfflineTaskLocalStore.shared.upsert(task, organizationId: organizationId)
        }
        let ok = await save(task)
        if !ok, let back = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[back] = previous
            if let organizationId = firebaseBackend?.currentOrganization?.firestoreDocumentId {
                OfflineTaskLocalStore.shared.upsert(previous, organizationId: organizationId)
            }
        }
        return ok
    }
    
    func deleteTask(_ task: ProjectTask) async {
        _ = await deleteTaskReportingError(task)
    }

    /// Deletes a task and says whether the server accepted it (RULEBOOK 1.89.0 §34: only admins delete; the security
    /// rules refuse anyone else). On a refusal the task comes back and `lastWriteError` says why.
    @discardableResult
    func deleteTaskReportingError(_ task: ProjectTask) async -> Bool {
        lastWriteError = nil
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            lastWriteError = "Couldn't delete the task. Try again."
            return false
        }
        let original = tasks.first(where: { $0.id == task.id }) ?? task
        tasks.removeAll { $0.id == task.id }
        OfflineTaskLocalStore.shared.remove(taskId: task.id, organizationId: organizationId)

        do {
            try await firebaseBackend.deleteProjectTask(taskId: task.id, organizationId: organizationId)
            return true
        } catch {
            if !tasks.contains(where: { $0.id == original.id }) { tasks.append(original) }
            OfflineTaskLocalStore.shared.upsert(original, organizationId: organizationId)
            lastWriteError = Self.writeErrorText(error, deleting: true)
            return false
        }
    }

    @discardableResult
    private func save(_ task: ProjectTask) async -> Bool {
        lastWriteError = nil
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            lastWriteError = "Couldn't save the task. Try again."
            return false
        }

        do {
            try await firebaseBackend.saveProjectTask(task, organizationId: organizationId)
            return true
        } catch {
            lastWriteError = Self.writeErrorText(error, deleting: false)
            return false
        }
    }

    /// The words a refused write shows (`TASK_COPY.errors`, the same words as web).
    private static func writeErrorText(_ error: Error, deleting: Bool) -> String {
        let code = (error as NSError).code
        // FirestoreErrorCode.permissionDenied == 7
        if (error as NSError).domain == "FIRFirestoreErrorDomain", code == 7 {
            return deleting
                ? TaskRulebook.copy("errors", "deleteRefused", fallback: "Only an admin can delete a task.")
                : TaskRulebook.copy("errors", "noAccess", fallback: "You don't have access to this task.")
        }
        return deleting
            ? "Couldn't delete the task. Check your connection and try again."
            : TaskRulebook.copy("errors", "saveFailed", fallback: "The task wasn't saved. Check your connection and try again.")
    }
}





