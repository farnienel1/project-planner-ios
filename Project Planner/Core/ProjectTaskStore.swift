//
//  ProjectTaskStore.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import Foundation
import Combine

@MainActor
class ProjectTaskStore: ObservableObject {
    @Published private(set) var tasks: [ProjectTask] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private var firebaseBackend: FirebaseBackend?
    private var cancellables = Set<AnyCancellable>()
    
    func setFirebaseBackend(_ backend: FirebaseBackend) {
        self.firebaseBackend = backend
    }
    
    func loadData() async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            print("🔥🔥🔥 DEBUG: TaskStore - Organization not set. firebaseBackend: \(firebaseBackend != nil), organization: \(firebaseBackend?.currentOrganization?.firestoreDocumentId ?? "nil")")
            errorMessage = "Organization not set"
            isLoading = false
            return
        }
        
        print("🔥🔥🔥 DEBUG: TaskStore - Loading tasks for organization: \(organizationId)")
        isLoading = true
        errorMessage = nil
        
        do {
            let loadedTasks = try await firebaseBackend.loadProjectTasks(organizationId: organizationId)
            print("🔥🔥🔥 DEBUG: TaskStore - Loaded \(loadedTasks.count) tasks from Firebase")
            // Keep tasks that were just created locally but are not yet visible on the server read (avoids “disappearing” tasks).
            let loadedIds = Set(loadedTasks.map(\.id))
            let pendingLocal = tasks.filter { !loadedIds.contains($0.id) }
            tasks = (loadedTasks + pendingLocal).sorted { $0.createdAt > $1.createdAt }
            isLoading = false
        } catch {
            print("🔥🔥🔥 DEBUG: TaskStore - Error loading tasks: \(error.localizedDescription)")
            isLoading = false
            errorMessage = "Failed to load tasks: \(error.localizedDescription)"
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
        
        tasks.append(task)
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
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
            await save(task)
        }
    }
    
    func toggleTaskStatus(_ task: ProjectTask, to status: ProjectTask.Status) async {
        var updatedTask = task
        updatedTask.status = status
        updatedTask.updatedAt = Date()
        await updateTask(updatedTask)
    }
    
    func deleteTask(_ task: ProjectTask) async {
        tasks.removeAll { $0.id == task.id }
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            return
        }
        
        do {
            try await firebaseBackend.deleteProjectTask(taskId: task.id, organizationId: organizationId)
        } catch {
            print("🔥🔥🔥 DEBUG: Failed to delete task: \(error.localizedDescription)")
        }
    }
    
    private func save(_ task: ProjectTask) async {
        guard let firebaseBackend = firebaseBackend,
              let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            return
        }
        
        do {
            try await firebaseBackend.saveProjectTask(task, organizationId: organizationId)
        } catch {
            print("🔥🔥🔥 DEBUG: Failed to save task: \(error.localizedDescription)")
        }
    }
}





