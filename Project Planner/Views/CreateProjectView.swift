//
//  CreateProjectView.swift
//  Project Planner
//
//  Created by Assistant on 23/10/2025.
//

import SwiftUI
import MapKit

private enum CreateProjectLocationMode: String, CaseIterable, Identifiable {
    case addressFields = "Address"
    case mapPin = "Map pin"
    var id: String { rawValue }
}

struct CreateProjectView: View {
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
    @State private var projectEndDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var projectWorksType: String = ""
    @State private var projectDescription = ""
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
            // Custom job type - default to catA for now
            return .catA
        }
    }
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingCreateClient = false
    @State private var showingCreateJobType = false
    @State private var showingCreateManager = false

    @State private var locationMode: CreateProjectLocationMode = .addressFields
    @State private var pinLatitude: Double?
    @State private var pinLongitude: Double?
    @State private var showingMapPinPicker = false
    @State private var showingQuickAddressForm = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 10) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        
                        Text("Create New Project")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Add a new project to your organisation.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)
                    
                    // Form
                    VStack(spacing: 15) {
                        TextField("Project reference *", text: $projectJobNumber)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Site Name *", text: $projectSiteName)
                            .textFieldStyle(.roundedBorder)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Location")
                                .font(.headline)
                            Picker("", selection: $locationMode) {
                                ForEach(CreateProjectLocationMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: locationMode) { _, newValue in
                                switch newValue {
                                case .addressFields:
                                    pinLatitude = nil
                                    pinLongitude = nil
                                case .mapPin:
                                    projectAddressLine1 = ""
                                    projectAddressLine2 = ""
                                    projectTownCity = ""
                                    projectPostcode = ""
                                }
                            }
                            if locationMode == .addressFields {
                                TextField("Address Line 1 *", text: $projectAddressLine1)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Address Line 2 (Optional)", text: $projectAddressLine2)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Town/City *", text: $projectTownCity)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Postcode *", text: $projectPostcode)
                                    .textFieldStyle(.roundedBorder)
                                    .textInputAutocapitalization(.characters)
                            } else {
                                createMapPinLocationBlock
                            }
                        }
                        
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
                                        Text(selectedClient?.name ?? "Choose Client")
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
                                        Text(selectedManager != nil ? "\(selectedManager!.firstName) \(selectedManager!.lastName)" : "Create Manager")
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
                    Button("Create Project") {
                        createProject()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || !isFormValid)
                    .padding()
                }
            }
            .navigationTitle("New Project")
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
            .sheet(isPresented: $showingMapPinPicker) {
                MapPinPickerView(
                    initialCoordinate: defaultCreateMapCoordinate,
                    selectedLatitude: $pinLatitude,
                    selectedLongitude: $pinLongitude,
                    onConfirm: { _ in }
                )
            }
            .sheet(isPresented: $showingQuickAddressForm) {
                createQuickAddressSheet
            }
        }
    }

    private var defaultCreateMapCoordinate: CLLocationCoordinate2D {
        if let la = pinLatitude, let lo = pinLongitude {
            return CLLocationCoordinate2D(latitude: la, longitude: lo)
        }
        return CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
    }

    private var createMapPinLocationBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let la = pinLatitude, let lo = pinLongitude {
                Text(String(format: "Pinned at %.5f, %.5f", la, lo))
                    .font(.subheadline)
            } else {
                Text("Optional: set a pin for the site, then add postal address if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Set pin on map") { showingMapPinPicker = true }
                .buttonStyle(.bordered)
            Button("Set address") { showingQuickAddressForm = true }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var createQuickAddressSheet: some View {
        NavigationStack {
            Form {
                TextField("Address line 1", text: $projectAddressLine1)
                TextField("Address line 2 (optional)", text: $projectAddressLine2)
                TextField("Town / City", text: $projectTownCity)
                TextField("Postcode", text: $projectPostcode)
                    .textInputAutocapitalization(.characters)
            }
            .navigationTitle("Set address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingQuickAddressForm = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingQuickAddressForm = false }
                }
            }
        }
    }
    
    private var isFormValid: Bool {
        let locationOK: Bool = {
            if locationMode == .mapPin {
                return pinLatitude != nil && pinLongitude != nil
            }
            return !projectAddressLine1.isEmpty && !projectTownCity.isEmpty && !projectPostcode.isEmpty
        }()
        return !projectJobNumber.isEmpty &&
        !projectSiteName.isEmpty &&
        locationOK
    }
    
    private func createProject() {
        guard let client = selectedClient else {
            errorMessage = "Please select a client"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        // For projects, jobType enum should NOT be .smallWorks (that's only for small works collection)
        // Map job type string to JobType enum, but default to .catA if empty (not .smallWorks)
        let jobTypeEnum = projectWorksType.isEmpty ? .catA : jobTypeFromString(projectWorksType)
        // Ensure projects never have .smallWorks jobType (that's only for small works collection)
        let finalJobType = jobTypeEnum == .smallWorks ? .catA : jobTypeEnum

        let usesPin = locationMode == .mapPin
        
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
            jobType: finalJobType, // Used for determining collection (projects vs smallWorks)
            customJobType: projectWorksType.isEmpty ? nil : projectWorksType, // User-selected job type for display
            manager: selectedManager != nil ? .custom : .na,
            managerId: selectedManager?.id, // Save the actual manager ID
            isLive: true,
            description: projectDescription.isEmpty ? nil : projectDescription,
            usesMapPinForLocation: usesPin,
            latitude: usesPin ? pinLatitude : nil,
            longitude: usesPin ? pinLongitude : nil
        )
        
        Task {
            do {
                try await projectStore.addProject(project)
                await MainActor.run {
                    isLoading = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "Failed to save project: \(error.localizedDescription). Please try again."
                }
            }
        }
    }
}

#Preview {
    CreateProjectView()
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
}
