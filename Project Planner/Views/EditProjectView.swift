//
//  EditProjectView.swift
//  Project Planner
//
//  Created by Assistant on 27/10/2025.
//

import SwiftUI

struct EditProjectView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss
    
    let project: Project
    
    @State private var projectJobNumber: String
    @State private var projectSiteName: String
    @State private var projectAddressLine1: String
    @State private var projectAddressLine2: String
    @State private var projectTownCity: String
    @State private var projectPostcode: String
    @State private var projectStartDate: Date
    @State private var projectEndDate: Date
    @State private var projectWorksType: String
    @State private var projectDescription: String
    @State private var selectedClient: Client?
    @State private var selectedManager: Manager?
    
    // Job type mapping helper
    private func jobTypeFromString(_ type: String) -> JobType {
        switch type.lowercased() {
        case "small works", "smallworks":
            return .smallWorks
        case "maintenance":
            return .maintenance
        case "cat a", "cata":
            return .catA
        case "cat b", "catb":
            return .catB
        default:
            // Try to match from jobTypes
            if projectStore.jobTypes.contains(type) {
                // Map custom job type - for now default to catA
                return .catA
            }
            return .catA // Default
        }
    }
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingCreateClient = false
    @State private var showingCreateJobType = false
    @State private var showingCreateManager = false
    
    init(project: Project) {
        self.project = project
        _projectJobNumber = State(initialValue: project.jobNumber)
        _projectSiteName = State(initialValue: project.siteName)
        _projectAddressLine1 = State(initialValue: project.addressLine1)
        _projectAddressLine2 = State(initialValue: project.addressLine2 ?? "")
        _projectTownCity = State(initialValue: project.townCity)
        _projectPostcode = State(initialValue: project.postcode)
        _projectStartDate = State(initialValue: project.startDate)
        _projectEndDate = State(initialValue: project.endDate)
        _projectDescription = State(initialValue: project.description ?? "")
        _selectedClient = State(initialValue: project.client)
        
        // Initialize projectWorksType from customJobType if available, otherwise from jobType enum
        let worksType: String = project.customJobType ?? {
            // Fallback to jobType enum if customJobType is nil
            switch project.jobType {
            case .smallWorks:
                return "Small Works"
            case .maintenance:
                return "Maintenance"
            case .catA:
                return "CAT A"
            case .catB:
                return "CAT B"
            }
        }()
        _projectWorksType = State(initialValue: worksType)
        
        // Manager will need to be resolved from project.manager
        // For now, set to nil and handle in onAppear
        _selectedManager = State(initialValue: nil)
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 10) {
                        Image(systemName: "folder.badge.gear")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        
                        Text("Edit Project")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Update project details.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)
                    
                    // Form
                    VStack(spacing: 15) {
                        TextField("Job Number *", text: $projectJobNumber)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Site Name *", text: $projectSiteName)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Address Line 1 *", text: $projectAddressLine1)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Address Line 2 (Optional)", text: $projectAddressLine2)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Town/City *", text: $projectTownCity)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Postcode *", text: $projectPostcode)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.characters)
                        
                        DatePicker("Start Date", selection: $projectStartDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                        
                        DatePicker("End Date", selection: $projectEndDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                        
                        // Client Selection
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Client")
                                .font(.headline)
                            
                            if projectStore.clients.isEmpty {
                                Button(action: {
                                    showingCreateClient = true
                                }) {
                                    HStack {
                                        Spacer()
                                        Text("Create New Client")
                                            .foregroundColor(.primary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.gray.opacity(0.3))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(PlainButtonStyle())
                            } else {
                                Menu {
                                    ForEach(projectStore.clients, id: \.id) { client in
                                        Button(action: {
                                            selectedClient = client
                                        }) {
                                            Text(client.name)
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(selectedClient?.name ?? "Select Client")
                                            .foregroundColor(selectedClient == nil ? .secondary : .primary)
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(8)
                                }
                            }
                        }
                        
                        // Job Type Selection
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Job Type")
                                .font(.headline)
                            
                            if projectStore.jobTypes.isEmpty {
                                Button(action: {
                                    showingCreateJobType = true
                                }) {
                                    HStack {
                                        Spacer()
                                        Text("Create Job Type")
                                            .foregroundColor(.primary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.gray.opacity(0.3))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(PlainButtonStyle())
                            } else {
                                Menu {
                                    ForEach(projectStore.jobTypes.sorted(), id: \.self) { jobType in
                                        Button(action: {
                                            projectWorksType = jobType
                                        }) {
                                            Text(jobType)
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(projectWorksType.isEmpty ? "Select Job Type" : projectWorksType)
                                            .foregroundColor(projectWorksType.isEmpty ? .secondary : .primary)
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(8)
                                }
                            }
                        }
                        
                        // Manager Selection
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Manager")
                                .font(.headline)
                            
                            if operativeStore.allManagers.isEmpty {
                                Button(action: {
                                    showingCreateManager = true
                                }) {
                                    HStack {
                                        Spacer()
                                        Text("Create New Manager")
                                            .foregroundColor(.primary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.gray.opacity(0.3))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(PlainButtonStyle())
                            } else {
                                Menu {
                                    ForEach(operativeStore.allManagers) { manager in
                                        Button(action: {
                                            selectedManager = manager
                                        }) {
                                            Text("\(manager.firstName) \(manager.lastName)")
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(selectedManager != nil ? "\(selectedManager!.firstName) \(selectedManager!.lastName)" : "Select Manager")
                                            .foregroundColor(selectedManager == nil ? .secondary : .primary)
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(8)
                                }
                            }
                        }
                        
                        TextField("Description (Optional)", text: $projectDescription, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                    }
                    .padding(.horizontal)
                    
                    // Error Message
                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }
                    
                    // Save Button
                    Button("Save Changes") {
                        saveProject()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || !isFormValid)
                    .padding()
                }
            }
            .navigationTitle("Edit Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Initialize selectedManager from project's managerId if available
                if let managerId = project.managerId,
                   let manager = operativeStore.allManagers.first(where: { $0.id == managerId }) {
                    selectedManager = manager
                }
            }
            .sheet(isPresented: $showingCreateClient) {
                CreateClientView()
                    .environmentObject(projectStore)
                    .onDisappear {
                        projectStore.loadData()
                    }
            }
            .sheet(isPresented: $showingCreateJobType) {
                JobTypesManagementView()
                    .environmentObject(projectStore)
            }
            .sheet(isPresented: $showingCreateManager) {
                CreateManagerView()
                    .environmentObject(operativeStore)
            }
        }
    }
    
    private var isFormValid: Bool {
        !projectJobNumber.isEmpty &&
        !projectSiteName.isEmpty &&
        !projectAddressLine1.isEmpty &&
        !projectTownCity.isEmpty &&
        !projectPostcode.isEmpty &&
        selectedClient != nil
    }
    
    private func saveProject() {
        guard let client = selectedClient else {
            errorMessage = "Please select a client"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        // Keep the original jobType enum (don't change it - it determines which collection the project is in)
        // Only update customJobType for display purposes
        var updatedProject = Project(
            id: project.id,
            jobNumber: projectJobNumber,
            siteName: projectSiteName,
            addressLine1: projectAddressLine1,
            addressLine2: projectAddressLine2.isEmpty ? nil : projectAddressLine2,
            townCity: projectTownCity,
            postcode: projectPostcode,
            client: client,
            startDate: projectStartDate,
            endDate: projectEndDate,
            jobType: project.jobType, // Keep original jobType (determines collection)
            customJobType: projectWorksType.isEmpty ? nil : projectWorksType, // Update customJobType for display
            manager: selectedManager != nil ? .custom : project.manager, // Use selected manager if available
            managerId: selectedManager?.id, // Save the actual manager ID
            isLive: project.isLive,
            description: projectDescription.isEmpty ? nil : projectDescription,
            notes: project.notes
        )
        
        // Preserve original createdAt, update updatedAt
        updatedProject.createdAt = project.createdAt
        updatedProject.updatedAt = Date()
        
        Task {
            await projectStore.updateProject(updatedProject)
            await MainActor.run {
                isLoading = false
                dismiss()
            }
        }
    }
}

