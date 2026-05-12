//
//  EditProjectView.swift
//  Project Planner
//
//  Edit project or small works with redesigned layout, address vs map pin (mutually exclusive).
//

import SwiftUI
import MapKit

private enum EditLocationMode: String, CaseIterable, Identifiable {
    case addressFields = "Address"
    case mapPin = "Map pin"
    var id: String { rawValue }
}

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

    @State private var locationMode: EditLocationMode
    @State private var pinLatitude: Double?
    @State private var pinLongitude: Double?
    @State private var showingMapPinPicker = false
    @State private var showingQuickAddressForm = false

    // Backup so we can restore address when the user toggles to "Map pin"
    // but never actually drops a pin.
    @State private var addressBackupLine1: String = ""
    @State private var addressBackupLine2: String = ""
    @State private var addressBackupTownCity: String = ""
    @State private var addressBackupPostcode: String = ""

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingCreateClient = false
    @State private var showingCreateJobType = false
    @State private var showingCreateManager = false

    private var screenTitle: String {
        project.jobType == .smallWorks ? "Edit small work" : "Edit project"
    }

    private var heroGradient: LinearGradient {
        LinearGradient(
            colors: [
                ProjectWorksRevampColors.blue,
                ProjectWorksRevampColors.blueLight
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    init(project: Project) {
        self.project = project
        _projectJobNumber = State(initialValue: project.jobNumber)
        _projectSiteName = State(initialValue: project.siteName)
        _projectAddressLine1 = State(initialValue: project.addressLine1)
        _projectAddressLine2 = State(initialValue: project.addressLine2 ?? "")
        _projectTownCity = State(initialValue: project.townCity)
        _projectPostcode = State(initialValue: project.postcode)
        _addressBackupLine1 = State(initialValue: project.addressLine1)
        _addressBackupLine2 = State(initialValue: project.addressLine2 ?? "")
        _addressBackupTownCity = State(initialValue: project.townCity)
        _addressBackupPostcode = State(initialValue: project.postcode)
        _projectStartDate = State(initialValue: project.startDate)
        _projectEndDate = State(initialValue: project.endDate)
        _projectDescription = State(initialValue: project.description ?? "")
        _selectedClient = State(initialValue: project.client)
        _locationMode = State(initialValue: project.usesMapPinForLocation ? .mapPin : .addressFields)
        _pinLatitude = State(initialValue: project.latitude)
        _pinLongitude = State(initialValue: project.longitude)

        let worksType: String = project.customJobType ?? {
            switch project.jobType {
            case .smallWorks: return "Small Works"
            case .maintenance: return "Maintenance"
            case .catA: return "CAT A"
            case .catB: return "CAT B"
            }
        }()
        _projectWorksType = State(initialValue: worksType)
        _selectedManager = State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroHeader

                    sectionLabel("Project")
                    projectFieldsCard

                    sectionLabel("Location")
                    Picker("", selection: $locationMode) {
                        ForEach(EditLocationMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: locationMode) { _, newValue in
                        applyMutualExclusion(for: newValue)
                    }

                    if locationMode == .addressFields {
                        addressFieldsCard
                    } else {
                        mapPinLocationCard
                    }

                    sectionLabel("Timeline")
                    timelineCard

                    durationBanner

                    sectionLabel("Classification")
                    classificationCard

                    sectionLabel("Team")
                    teamCard

                    sectionLabel("Description · Optional")
                    TextEditor(text: $projectDescription)
                        .frame(minHeight: 100)
                        .padding(12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                        )
                        .overlay(alignment: .topLeading) {
                            if projectDescription.isEmpty {
                                Text("Add notes, scope, key contacts…")
                                    .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 18)
                                    .allowsHitTesting(false)
                            }
                        }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationTitle(screenTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.white)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(ProjectWorksRevampColors.searchBorder, lineWidth: 0.5))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveProject() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(ProjectWorksRevampColors.blue)
                        .clipShape(Capsule())
                        .disabled(isLoading || !isFormValid)
                }
            }
            .onAppear {
                if let managerId = project.managerId,
                   let manager = operativeStore.allManagers.first(where: { $0.id == managerId }) {
                    selectedManager = manager
                }
            }
            .sheet(isPresented: $showingCreateClient) {
                CreateClientView()
                    .environmentObject(projectStore)
                    .onDisappear { projectStore.loadData() }
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
                    initialCoordinate: defaultMapCoordinate,
                    selectedLatitude: $pinLatitude,
                    selectedLongitude: $pinLongitude,
                    onConfirm: { _ in }
                )
            }
            .sheet(isPresented: $showingQuickAddressForm) {
                quickAddressFormSheet
            }
        }
    }

    private var defaultMapCoordinate: CLLocationCoordinate2D {
        if let la = pinLatitude, let lo = pinLongitude {
            return CLLocationCoordinate2D(latitude: la, longitude: lo)
        }
        return CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
    }

    private func applyMutualExclusion(for mode: EditLocationMode) {
        let hadPin = pinLatitude != nil && pinLongitude != nil

        switch mode {
        case .addressFields:
            // If the user never actually set a pin, restore the address they had typed.
            // If a pin was set, address should remain cleared to avoid ambiguity.
            pinLatitude = nil
            pinLongitude = nil

            if !hadPin {
                projectAddressLine1 = addressBackupLine1
                projectAddressLine2 = addressBackupLine2
                projectTownCity = addressBackupTownCity
                projectPostcode = addressBackupPostcode
            }
        case .mapPin:
            // Backup typed address before clearing it (in case they back out without selecting a pin).
            addressBackupLine1 = projectAddressLine1
            addressBackupLine2 = projectAddressLine2
            addressBackupTownCity = projectTownCity
            addressBackupPostcode = projectPostcode

            projectAddressLine1 = ""
            projectAddressLine2 = ""
            projectTownCity = ""
            projectPostcode = ""
        }
    }

    private var heroHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(heroGradient)
                    .frame(width: 64, height: 64)
                Image(systemName: project.jobType == .smallWorks ? "hammer.fill" : "folder.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
            }
            HStack(spacing: 8) {
                Text(projectJobNumber)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                if !projectWorksType.isEmpty {
                    Text(projectWorksType.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.jobTypePillInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ProjectWorksRevampColors.jobTypePillBg)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            Text("Update details, dates and team")
                .font(.system(size: 13))
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .tracking(0.4)
            .padding(.leading, 4)
    }

    private var projectFieldsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project reference")
                .font(.system(size: 11))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            TextField("Project reference", text: $projectJobNumber)
                .font(.system(size: 13, weight: .medium))
            Divider().overlay(ProjectWorksRevampColors.border)
            Text("Project name")
                .font(.system(size: 11))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            TextField("Project name", text: $projectSiteName)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var addressFieldsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Address line 1", text: $projectAddressLine1)
            TextField("Address line 2 (optional)", text: $projectAddressLine2)
            TextField("Town / City", text: $projectTownCity)
            TextField("Postcode", text: $projectPostcode)
                .textInputAutocapitalization(.characters)
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var mapPinLocationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let la = pinLatitude, let lo = pinLongitude {
                Text(String(format: "Pinned at %.5f, %.5f", la, lo))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
            } else {
                Text("No pin set yet")
                    .font(.system(size: 13))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Button {
                showingMapPinPicker = true
            } label: {
                HStack {
                    Image(systemName: "map")
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    Text("Set pin on map")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            Divider().overlay(ProjectWorksRevampColors.border)
            Button {
                showingQuickAddressForm = true
            } label: {
                HStack {
                    Image(systemName: "text.justify.left")
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                    Text("Set address")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var timelineCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Start date")
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Spacer()
                DatePicker("", selection: $projectStartDate, displayedComponents: .date)
                    .labelsHidden()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            Divider().overlay(ProjectWorksRevampColors.border)
            HStack {
                Text("End date")
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Spacer()
                DatePicker("", selection: $projectEndDate, displayedComponents: .date)
                    .labelsHidden()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var durationBanner: some View {
        let comps = Calendar.current.dateComponents([.month, .day], from: projectStartDate, to: projectEndDate)
        let months = comps.month ?? 0
        let days = comps.day ?? 0
        return HStack(spacing: 8) {
            Image(systemName: "clock")
                .foregroundStyle(ProjectWorksRevampColors.blue)
            Text("Project duration: \(months) months, \(days) days")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.blue)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.902, green: 0.945, blue: 0.984))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var classificationCard: some View {
        VStack(spacing: 0) {
            clientMenuRow
            Divider().overlay(ProjectWorksRevampColors.border)
            jobTypeMenuRow
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var clientMenuRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.98, green: 0.933, blue: 0.855))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "building.2.fill").foregroundStyle(ProjectWorksRevampColors.upcomingAmber))
            VStack(alignment: .leading, spacing: 2) {
                Text("Client")
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Text(selectedClient?.name ?? "Select client")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
            }
            Spacer()
            Menu {
                ForEach(projectStore.clients, id: \.id) { c in
                    Button(c.name) { selectedClient = c }
                }
                Button("Create client…") { showingCreateClient = true }
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    private var jobTypeMenuRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ProjectWorksRevampColors.jobTypePillBg)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "square.grid.2x2.fill").foregroundStyle(Color(red: 0.325, green: 0.29, blue: 0.718)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Job type")
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Text(projectWorksType.isEmpty ? "Select type" : projectWorksType)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
            }
            Spacer()
            Menu {
                ForEach(projectStore.jobTypes.sorted(), id: \.self) { jt in
                    Button(jt) { projectWorksType = jt }
                }
                Button("Manage job types…") { showingCreateJobType = true }
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    private var teamCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.325, green: 0.29, blue: 0.718), Color(red: 0.5, green: 0.47, blue: 0.87)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 34, height: 34)
                .overlay(
                    Text(managerInitials)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Manager")
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Text(selectedManager.map { "\($0.firstName) \($0.lastName)" } ?? "Select manager")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
            }
            Spacer()
            Menu {
                ForEach(operativeStore.allManagers, id: \.id) { m in
                    Button("\(m.firstName) \(m.lastName)") { selectedManager = m }
                }
                Button("Create manager…") { showingCreateManager = true }
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var managerInitials: String {
        guard let m = selectedManager else { return "?" }
        let f = m.firstName.prefix(1)
        let l = m.lastName.prefix(1)
        return "\(f)\(l)".uppercased()
    }

    private var quickAddressFormSheet: some View {
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
                    Button("Save") { showingQuickAddressForm = false }
                }
            }
        }
    }

    private func jobTypeFromString(_ type: String) -> JobType {
        switch type.lowercased() {
        case "small works", "smallworks": return .smallWorks
        case "maintenance": return .maintenance
        case "cat a", "cata": return .catA
        case "cat b", "catb": return .catB
        default:
            if projectStore.jobTypes.contains(type) { return .catA }
            return .catA
        }
    }

    private var isFormValid: Bool {
        guard !projectJobNumber.isEmpty, !projectSiteName.isEmpty, selectedClient != nil else { return false }
        if locationMode == .mapPin {
            return pinLatitude != nil && pinLongitude != nil
        }
        return !projectAddressLine1.isEmpty && !projectTownCity.isEmpty && !projectPostcode.isEmpty
    }

    private func saveProject() {
        guard let client = selectedClient else {
            errorMessage = "Please select a client"
            return
        }
        isLoading = true
        errorMessage = nil

        let usesPin = locationMode == .mapPin
        let finalLat = usesPin ? pinLatitude : nil
        let finalLon = usesPin ? pinLongitude : nil

        let mappedWorksType = jobTypeFromString(projectWorksType)
        let finalJobType: JobType = {
            if project.jobType == .smallWorks { return .smallWorks }
            if projectWorksType.isEmpty { return .catA }
            return mappedWorksType == .smallWorks ? .catA : mappedWorksType
        }()

        var updatedProject = Project(
            id: project.id,
            jobNumber: projectJobNumber,
            siteName: projectSiteName,
            addressLine1: usesPin ? (projectAddressLine1.isEmpty ? "" : projectAddressLine1) : projectAddressLine1,
            addressLine2: projectAddressLine2.isEmpty ? nil : projectAddressLine2,
            townCity: projectTownCity,
            postcode: projectPostcode,
            client: client,
            startDate: projectStartDate,
            endDate: projectEndDate,
            jobType: finalJobType,
            customJobType: projectWorksType.isEmpty ? nil : projectWorksType,
            manager: selectedManager != nil ? .custom : project.manager,
            managerId: selectedManager?.id,
            isLive: project.isLive,
            description: projectDescription.isEmpty ? nil : projectDescription,
            notes: project.notes,
            hiddenManagerUserIds: project.hiddenManagerUserIds,
            hiddenOperativeUserIds: project.hiddenOperativeUserIds,
            usesMapPinForLocation: usesPin,
            latitude: finalLat,
            longitude: finalLon
        )
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
