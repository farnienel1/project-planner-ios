//
//  CreateSmallWorksView.swift
//  Project Planner
//
//  Created by Assistant on 23/10/2025.
//

import SwiftUI

struct CreateSmallWorksView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var projectJobNumber = ""
    @State private var projectSiteName = ""
    @State private var projectAddressLine1 = ""
    @State private var projectAddressLine2 = ""
    @State private var projectTownCity = ""
    @State private var projectPostcode = ""
    @State private var projectStartDate = Date()
    @State private var projectEndDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var projectDescription = ""
    @State private var selectedClient: Client?
    @State private var selectedManager: Manager?
    @State private var errorMessage: String?
    @State private var showingCreateClient = false
    @State private var showingCreateJobType = false
    @State private var showingCreateManager = false
    @State private var selectedJobType: String = ""

    @State private var isSaving = false
    
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
            // Custom job type - default to smallWorks for small works projects
            return .smallWorks
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                ScrollView {
                    VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 10) {
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.orange)
                        
                        Text("Create New Small Works")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Add a new small works project to your organisation.")
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
                                            selectedJobType = jobType
                                        }) {
                                            Text(jobType)
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(selectedJobType.isEmpty ? "Select Job Type" : selectedJobType)
                                            .foregroundColor(selectedJobType.isEmpty ? .secondary : .primary)
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
                                    ForEach(operativeStore.allManagers, id: \.id) { manager in
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
                    
                    // Create Button
                    Button("Create Small Works") {
                        Task {
                            await createSmallWorks()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || !isFormValid || selectedClient == nil)
                    .padding()
                    }
                }

                if isSaving {
                    ProgressView("Saving Small Works...")
                        .progressViewStyle(.circular)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }
            }
            .navigationTitle("New Small Works")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingCreateClient) {
                CreateClientView(onCreated: { client in
                    selectedClient = client
                })
                    .environmentObject(projectStore)
                    .environmentObject(notificationService)
                    .environmentObject(userStore)
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
            .onAppear {
                if selectedClient == nil {
                    selectedClient = projectStore.clients.first
                }
                // Don't set default job type - let user select it
            }
        }
    }
    
    private var isFormValid: Bool {
        !projectJobNumber.isEmpty &&
        !projectSiteName.isEmpty &&
        !projectAddressLine1.isEmpty &&
        !projectTownCity.isEmpty &&
        !projectPostcode.isEmpty
    }
    
    private func createSmallWorks() async {
        guard let client = selectedClient else {
            await MainActor.run {
                errorMessage = "Please select a client"
                isSaving = false
            }
            return
        }

        if projectJobNumber.trimmingCharacters(in: .whitespaces).isEmpty ||
            projectSiteName.trimmingCharacters(in: .whitespaces).isEmpty {
            await MainActor.run {
                errorMessage = "Job number and site name are required."
                isSaving = false
            }
            return
        }

        if projectStartDate > projectEndDate {
            await MainActor.run {
                errorMessage = "End date must be after start date."
                isSaving = false
            }
            return
        }

        await MainActor.run {
            isSaving = true
            errorMessage = nil
        }

        // jobType enum is always .smallWorks for small works items (determines collection)
        // customJobType is the user-selected job type for display
        let project = Project(
            jobNumber: projectJobNumber,
            siteName: projectSiteName,
            addressLine1: projectAddressLine1,
            addressLine2: projectAddressLine2.isEmpty ? nil : projectAddressLine2,
            townCity: projectTownCity,
            postcode: projectPostcode,
            client: client,
            startDate: projectStartDate,
            endDate: projectEndDate,
            jobType: .smallWorks, // Always .smallWorks for small works (determines collection)
            customJobType: selectedJobType.isEmpty ? nil : selectedJobType, // User-selected job type for display
            manager: selectedManager != nil ? .custom : .na,
            managerId: selectedManager?.id, // Save the actual manager ID
            isLive: true,
            description: projectDescription.isEmpty ? nil : projectDescription
        )

        do {
            try await projectStore.addSmallWorks(project)
            // Only dismiss if save was successful
            await MainActor.run {
                isSaving = false
                dismiss()
            }
        } catch {
            // Show error and keep view open
            await MainActor.run {
                isSaving = false
                let errorDesc = error.localizedDescription
                
                // Provide more helpful error messages
                var userFriendlyMessage = "Failed to save Small Works project."
                if errorDesc.contains("not linked to organization") || errorDesc.contains("Organization not found") {
                    userFriendlyMessage = "Unable to save: Your account is not linked to an organization. Please try 'Manually Link Organization' in Settings, or contact support."
                } else if errorDesc.contains("not authenticated") {
                    userFriendlyMessage = "Unable to save: You are not signed in. Please sign in and try again."
                } else if errorDesc.contains("Permission denied") {
                    userFriendlyMessage = "Unable to save: Permission denied. Please check your account access or try again."
                } else {
                    userFriendlyMessage = "Failed to save Small Works project: \(errorDesc). Please try again."
                }
                
                errorMessage = userFriendlyMessage
                print("🔥🔥🔥 DEBUG: ❌ Error saving Small Works: \(errorDesc)")
                print("🔥🔥🔥 DEBUG: Error type: \(type(of: error))")
            }
        }
    }
}

#Preview {
    CreateSmallWorksView()
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
}
