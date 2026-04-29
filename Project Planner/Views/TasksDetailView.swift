//
//  TasksDetailView.swift
//  Project Planner
//
//  Created by Assistant on 26/11/2025.
//

import SwiftUI

struct TasksDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    
    @State private var sortOrder: TaskSortOrder = .newest
    
    enum TaskSortOrder: String, CaseIterable {
        case newest = "Newest"
        case oldest = "Oldest"
    }
    
    private var qualificationExpiryBannerItems: [(id: String, title: String, subtitle: String)] {
        guard userStore.isOperativeMode(),
              let email = userStore.currentUser?.email else { return [] }
        let em = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let op = operativeStore.allOperatives.first(where: {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == em
        }) else { return [] }
        let today = Calendar.current.startOfDay(for: Date())
        guard let horizon = Calendar.current.date(byAdding: .day, value: 30, to: today) else { return [] }
        var rows: [(String, String, String)] = []
        for (qid, exp) in op.qualificationExpiryDates {
            guard exp >= today && exp <= horizon,
                  let q = op.qualifications.first(where: { $0.id == qid }) else { continue }
            let days = Calendar.current.dateComponents([.day], from: today, to: exp).day ?? 0
            rows.append((
                id: qid.uuidString,
                title: "Qualification expiring: \(q.name)",
                subtitle: days <= 0 ? "Renew today — tell your manager when complete." : "\(days) day(s) remaining. Tell your manager when you have renewed it."
            ))
        }
        return rows.sorted(by: { $0.1 < $1.1 })
    }
    
    private var hasListContent: Bool {
        !qualificationExpiryBannerItems.isEmpty || !filteredTasks.isEmpty
    }
    
    var body: some View {
        NavigationView {
            Group {
                if !hasListContent {
                    emptyStateView
                } else {
                    VStack(spacing: 0) {
                        // Sort Filter
                        HStack {
                            Text("Sort by:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Picker("Sort", selection: $sortOrder) {
                                ForEach(TaskSortOrder.allCases, id: \.self) { order in
                                    Text(order.rawValue).tag(order)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                            Spacer()
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        
                        tasksList
                    }
                }
            }
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                print("🔥🔥🔥 DEBUG: TasksDetailView - Loading tasks")
                await taskStore.loadData()
                print("🔥🔥🔥 DEBUG: TasksDetailView - Tasks loaded: \(taskStore.tasks.count), Filtered: \(filteredTasks.count)")
            }
            .refreshable {
                await taskStore.loadData()
            }
        }
    }
    
    private var filteredTasks: [ProjectTask] {
        var tasks: [ProjectTask]
        
        if userStore.isOperativeMode() {
            // For operative mode, only show tasks assigned to this operative
            if let currentUserEmail = userStore.currentUser?.email,
               let operative = operativeStore.allOperatives.first(where: {
                   $0.email.lowercased() == currentUserEmail.lowercased()
               }) {
                tasks = taskStore.tasks.filter { task in
                    !task.isCompleted && task.allAssignedOperativeIds.contains(operative.id)
                }
            } else {
                return []
            }
        } else {
            // For regular users: Super Admin and Admins see all tasks, others see assigned tasks
            if userStore.canManageUsers() {
                // Super Admin or Admin - see all active tasks
                tasks = taskStore.tasks.filter { !$0.isCompleted }
            } else {
                // Regular users - show all active tasks (can be refined based on assignment)
                tasks = taskStore.tasks.filter { !$0.isCompleted }
            }
        }
        
        // Apply sort order
        switch sortOrder {
        case .newest:
            return tasks.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return tasks.sorted { $0.createdAt < $1.createdAt }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            if taskStore.isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Loading tasks...")
                    .font(.body)
                    .foregroundColor(.secondary)
            } else if let errorMessage = taskStore.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.orange)
                
                Text("Error Loading Tasks")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(errorMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button("Retry") {
                    Task {
                        await taskStore.loadData()
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)
                
                Text("No Tasks")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(qualificationExpiryBannerItems.isEmpty
                     ? "You have no assigned tasks at the moment."
                     : "No project tasks right now. See qualification reminders above when you open Tasks from Home.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                if taskStore.tasks.isEmpty {
                    Text("Total tasks in store: 0")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Total tasks: \(taskStore.tasks.count) (filtered out)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var tasksList: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !qualificationExpiryBannerItems.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Qualification reminders")
                            .font(.headline)
                            .foregroundStyle(.red)
                        ForEach(qualificationExpiryBannerItems, id: \.id) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)
                                Text(item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal)
                }
                
                ForEach(filteredTasks) { task in
                    TaskTileView(task: task)
                        .environmentObject(projectStore)
                        .environmentObject(operativeStore)
                        .environmentObject(taskStore)
                        .environmentObject(userStore)
                }
            }
            .padding()
        }
    }
}

struct TaskTileView: View {
    let task: ProjectTask
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    @State private var showingCompletionPopup = false
    
    var body: some View {
        Button(action: {
            if !task.isCompleted {
                showingCompletionPopup = true
            }
        }) {
        VStack(alignment: .leading, spacing: 12) {
            // Project/Small Works Info
            if let project = projectStore.projects.first(where: { $0.id == task.projectId }) {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.blue)
                    Text("\(project.jobNumber) - \(project.siteName)")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                }
            } else if let smallWork = projectStore.smallWorks.first(where: { $0.id == task.projectId }) {
                HStack {
                    Image(systemName: "hammer.fill")
                        .foregroundColor(.orange)
                    Text("\(smallWork.jobNumber) - \(smallWork.siteName)")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                }
            }
            
            Divider()
            
            // Task Title
            Text(task.title)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            // Task Details
            if let details = task.details, !details.isEmpty {
                Text(details)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            
            // Assigned To
            if !task.allAssignedOperativeIds.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(operativeNames(for: task.allAssignedOperativeIds).joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if !task.allAssignedManagerIds.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.text.rectangle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(managerNames(for: task.allAssignedManagerIds).joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Due Date
            if let dueDate = task.dueDate {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Due: \(dueDate, style: .date)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Created By
            HStack(spacing: 4) {
                Image(systemName: "person.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Created by \(task.createdBy)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Status Badge
            HStack {
                Spacer()
                Text(task.status.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.1))
                    .foregroundColor(statusColor)
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
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
            .environmentObject(taskStore)
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
    }
    
    private func operativeNames(for ids: [UUID]) -> [String] {
        ids.compactMap { id in
            operativeStore.allOperatives.first(where: { $0.id == id })?.name
        }
    }
    
    private func managerNames(for ids: [UUID]) -> [String] {
        ids.compactMap { id in
            operativeStore.allManagers.first(where: { $0.id == id })?.fullName
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

#Preview {
    TasksDetailView()
        .environmentObject(ProjectTaskStore())
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
        .environmentObject(UserStore())
}

