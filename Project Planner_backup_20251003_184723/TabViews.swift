//
//  TabViews.swift
//  Project Planner
//
//  Created by Farnie Nel on 29/09/2025.
//

import SwiftUI

// MARK: - Projects Tab
struct ProjectsTabView: View {
    @EnvironmentObject var appState: RestoredAppState
    @State private var showingAddProject = false
    
    var body: some View {
        NavigationView {
            VStack {
                if appState.projects.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "folder")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text("No Projects Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Tap + to create your first project")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(appState.projects) { project in
                            EnhancedProjectRowView(project: project)
                        }
                        .onDelete(perform: deleteProject)
                    }
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddProject = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddProject) {
                AddProjectView { newProject in
                    appState.addProject(newProject)
                }
            }
        }
    }
    
    private func deleteProject(at offsets: IndexSet) {
        for index in offsets {
            appState.deleteProject(appState.projects[index])
        }
    }
}

// MARK: - Operatives Tab
struct OperativesTabView: View {
    @EnvironmentObject var appState: RestoredAppState
    @State private var showingAddOperative = false
    
    var body: some View {
        NavigationView {
            VStack {
                if appState.operatives.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "person.2")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text("No Operatives Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Add your team members to get started")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(appState.operatives) { operative in
                            OperativeRowView(operative: operative)
                        }
                        .onDelete(perform: deleteOperative)
                    }
                }
            }
            .navigationTitle("Operatives")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAddOperative = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddOperative) {
                AddOperativeView { newOperative in
                    appState.addOperative(newOperative)
                }
            }
        }
    }
    
    private func deleteOperative(at offsets: IndexSet) {
        for index in offsets {
            appState.deleteOperative(appState.operatives[index])
        }
    }
}

struct OperativeRowView: View {
    let operative: ProjectOperative
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(operative.name)
                    .font(.headline)
                Spacer()
                Text(operative.status.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.2))
                    .foregroundColor(statusColor)
                    .cornerRadius(4)
            }
            
            Text(operative.trade)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text(operative.email)
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                Text("£\(String(format: "%.2f", operative.hourlyRate))/hr")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.green)
                Spacer()
                Text("Phone: \(operative.phone)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var statusColor: Color {
        switch operative.status {
        case .active: return .green
        case .inactive: return .gray
        case .onLeave: return .orange
        }
    }
}

// MARK: - Tasks Tab
struct TasksTabView: View {
    @State private var tasks: [Task] = [
        Task(title: "Review floor plans", isCompleted: false, priority: .high),
        Task(title: "Order materials", isCompleted: true, priority: .medium),
        Task(title: "Schedule inspections", isCompleted: false, priority: .high),
        Task(title: "Update client", isCompleted: false, priority: .low)
    ]
    @State private var showingAddTask = false
    
    var body: some View {
        NavigationView {
            VStack {
                if tasks.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "checklist")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text("No Tasks Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Tap + to create your first task")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(tasks) { task in
                            TaskRowView(task: task) {
                                if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                                    tasks[index].isCompleted.toggle()
                                }
                            }
                        }
                        .onDelete(perform: deleteTask)
                    }
                }
            }
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddTask = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddTask) {
                AddTaskView { newTask in
                    tasks.append(newTask)
                }
            }
        }
    }
    
    private func deleteTask(at offsets: IndexSet) {
        tasks.remove(atOffsets: offsets)
    }
}

// MARK: - Calendar Tab
struct CalendarTabView: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "calendar")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                
                Text("Calendar")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Your project schedule will appear here")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                VStack(spacing: 16) {
                    HStack {
                        Image(systemName: "clock")
                        Text("Upcoming deadlines")
                        Spacer()
                        Text("3")
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                    
                    HStack {
                        Image(systemName: "calendar.badge.plus")
                        Text("This week's tasks")
                        Spacer()
                        Text("12")
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .navigationTitle("Calendar")
            .padding()
        }
    }
}

// MARK: - Profile Tab
struct ProfileTabView: View {
    let currentUser: String
    let onSignOut: () -> Void
    @State private var showingSignOutAlert = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 32) {
                // Profile Header
                VStack(spacing: 16) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                    
                    VStack(spacing: 4) {
                        Text(currentUser)
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Project Manager")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 40)
                
                // Profile Options
                VStack(spacing: 16) {
                    ProfileOptionRow(icon: "person.circle", title: "Edit Profile") {
                        // TODO: Implement edit profile
                    }
                    
                    ProfileOptionRow(icon: "bell", title: "Notifications") {
                        // TODO: Implement notifications
                    }
                    
                    ProfileOptionRow(icon: "gear", title: "Settings") {
                        // TODO: Implement settings
                    }
                    
                    ProfileOptionRow(icon: "questionmark.circle", title: "Help & Support") {
                        // TODO: Implement help
                    }
                }
                .padding(.horizontal, 24)
                
                Spacer()
                
                // Sign Out Button
                Button(action: { showingSignOutAlert = true }) {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Sign Out")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .alert("Sign Out", isPresented: $showingSignOutAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Sign Out", role: .destructive) {
                    onSignOut()
                }
            } message: {
                Text("Are you sure you want to sign out?")
            }
        }
    }
}

// MARK: - Supporting Views
struct ProjectRowView: View {
    let project: Project
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(project.jobNumber)
                    .font(.headline)
                Spacer()
                Text(project.isLive ? "Live" : "Planning")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.2))
                    .foregroundColor(statusColor)
                    .cornerRadius(4)
            }
            
            Text(project.siteName)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("Manager: \(project.manager.rawValue) | Type: \(project.jobType.rawValue)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
    
    private var statusColor: Color {
        return project.isLive ? .blue : .orange
    }
}

struct TaskRowView: View {
    let task: Task
    let onToggle: () -> Void
    
    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(task.isCompleted ? .green : .gray)
                    .font(.title2)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .strikethrough(task.isCompleted)
                    .foregroundColor(task.isCompleted ? .secondary : .primary)
                
                Text(task.priority.rawValue.capitalized)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(priorityColor.opacity(0.2))
                    .foregroundColor(priorityColor)
                    .cornerRadius(4)
            }
            
            Spacer()
        }
    }
    
    private var priorityColor: Color {
        switch task.priority {
        case .high: return .red
        case .medium: return .orange
        case .low: return .green
        }
    }
}

struct ProfileOptionRow: View {
    let icon: String
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 30)
                
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(10)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Enhanced Project Row View
struct EnhancedProjectRowView: View {
    let project: EnhancedProject
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(project.jobNumber)
                    .font(.headline)
                    .foregroundColor(.blue)
                Spacer()
                Text(project.status.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.2))
                    .foregroundColor(statusColor)
                    .cornerRadius(4)
            }
            
            Text(project.clientName)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text(project.description)
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                Text("Manager: \(project.projectManager)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Type: \(project.projectType.rawValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Progress bar based on actual vs estimated hours
            if project.estimatedHours > 0 {
                HStack {
                    Text("Progress:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ProgressView(value: progressPercentage)
                        .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    Text("\(Int(progressPercentage * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Cost information
            HStack {
                Text("£\(Int(project.totalCost))")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.green)
                Spacer()
                Text("\(project.actualHours)/\(project.estimatedHours)h")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var statusColor: Color {
        switch project.status {
        case .completed: return .green
        case .live: return .blue
        case .planning: return .orange
        case .onHold: return .red
        }
    }
    
    private var progressPercentage: Double {
        guard project.estimatedHours > 0 else { return 0 }
        return min(Double(project.actualHours) / Double(project.estimatedHours), 1.0)
    }
}

struct AddOperativeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var trade = ""
    @State private var hourlyRate = ""
    @State private var status = OperativeStatus.active
    @State private var notes = ""
    let onAdd: (ProjectOperative) -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section("Personal Details") {
                    TextField("Name", text: $name)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                }
                
                Section("Work Details") {
                    TextField("Trade", text: $trade)
                    TextField("Hourly Rate", text: $hourlyRate)
                        .keyboardType(.decimalPad)
                    Picker("Status", selection: $status) {
                        ForEach(OperativeStatus.allCases) { stat in
                            Text(stat.rawValue).tag(stat)
                        }
                    }
                }
                
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("New Operative")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        let hourlyRateValue = Double(hourlyRate) ?? 0
                        let newOperative = ProjectOperative(
                            name: name,
                            email: email,
                            phone: phone,
                            trade: trade,
                            hourlyRate: hourlyRateValue,
                            startDate: Date(),
                            status: status,
                            notes: notes
                        )
                        onAdd(newOperative)
                        dismiss()
                    }
                    .disabled(name.isEmpty || trade.isEmpty)
                }
            }
        }
    }
}

struct Task: Identifiable {
    let id = UUID()
    let title: String
    var isCompleted: Bool
    let priority: Priority
}

enum Priority: String, CaseIterable {
    case high = "high"
    case medium = "medium"
    case low = "low"
}

// MARK: - Add Views
struct AddProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var jobNumber = ""
    @State private var clientName = ""
    @State private var siteAddress = ""
    @State private var description = ""
    @State private var projectType = ProjectType.project
    @State private var status = ProjectStatus.planning
    @State private var projectManager = ""
    @State private var estimatedHours = ""
    @State private var materialsCost = ""
    @State private var labourCost = ""
    let onAdd: (EnhancedProject) -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section("Project Details") {
                    TextField("Job Number", text: $jobNumber)
                    TextField("Client Name", text: $clientName)
                    TextField("Site Address", text: $siteAddress)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    
                    Picker("Project Type", selection: $projectType) {
                        ForEach(ProjectType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    
                    Picker("Status", selection: $status) {
                        ForEach(ProjectStatus.allCases) { stat in
                            Text(stat.rawValue).tag(stat)
                        }
                    }
                    
                    TextField("Project Manager", text: $projectManager)
                }
                
                Section("Costs & Hours") {
                    TextField("Estimated Hours", text: $estimatedHours)
                        .keyboardType(.numberPad)
                    TextField("Materials Cost", text: $materialsCost)
                        .keyboardType(.decimalPad)
                    TextField("Labour Cost", text: $labourCost)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        let materialsCostValue = Double(materialsCost) ?? 0
                        let labourCostValue = Double(labourCost) ?? 0
                        let estimatedHoursValue = Int(estimatedHours) ?? 0
                        let totalCostValue = materialsCostValue + labourCostValue
                        let profitMargin = totalCostValue > 0 ? (totalCostValue - labourCostValue) / totalCostValue : 0
                        
                        let newProject = EnhancedProject(
                            jobNumber: jobNumber,
                            clientName: clientName,
                            siteAddress: siteAddress,
                            projectType: projectType,
                            status: status,
                            startDate: Date(),
                            endDate: Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date(),
                            description: description,
                            projectManager: projectManager,
                            estimatedHours: estimatedHoursValue,
                            actualHours: 0,
                            materialsCost: materialsCostValue,
                            labourCost: labourCostValue,
                            totalCost: totalCostValue,
                            profitMargin: profitMargin,
                            notes: ""
                        )
                        onAdd(newProject)
                        dismiss()
                    }
                    .disabled(jobNumber.isEmpty || clientName.isEmpty)
                }
            }
        }
    }
}

struct AddTaskView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var priority = Priority.medium
    let onAdd: (Task) -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section("Task Details") {
                    TextField("Task Title", text: $title)
                    Picker("Priority", selection: $priority) {
                        ForEach(Priority.allCases, id: \.self) { priority in
                            Text(priority.rawValue.capitalized).tag(priority)
                        }
                    }
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        onAdd(Task(title: title, isCompleted: false, priority: priority))
                        dismiss()
                    }
                    .disabled(title.isEmpty)
                }
            }
        }
    }
}
