//
//  CreateProjectView.swift
//  Project Planner
//
//  New project flow (layout aligned with design reference).
//

import SwiftUI
import MapKit
import CoreLocation

struct CreateProjectView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
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

    @State private var pinLatitude: Double?
    @State private var pinLongitude: Double?
    @State private var showingMapPinPicker = false
    @State private var addressFieldsExpanded = true
    @State private var officeBaseCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)

    private var hasMapPin: Bool {
        pinLatitude != nil && pinLongitude != nil
    }

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingCreateClient = false
    @State private var showingCreateJobType = false
    @State private var showingCreateManager = false
    @State private var hiddenManagerUserIds: Set<String> = []

    @FocusState private var focusedFieldKey: String?

    private let requiredFieldTotal = 7

    private func jobTypeFromString(_ type: String) -> JobType {
        switch type.lowercased() {
        case "small works", "smallworks": return .smallWorks
        case "maintenance": return .maintenance
        case "cat a", "cata": return .catA
        case "cat b", "catb": return .catB
        default: return .catA
        }
    }

    private var requiredFilledCount: Int {
        var n = 0
        if !projectJobNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { n += 1 }
        if !projectSiteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { n += 1 }
        if hasMapPin {
            n += 3
        } else {
            if !projectAddressLine1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { n += 1 }
            if !projectTownCity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { n += 1 }
            if !projectPostcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { n += 1 }
        }
        if selectedClient != nil { n += 1 }
        if selectedManager != nil { n += 1 }
        return n
    }

    private var progressFraction: CGFloat {
        CGFloat(requiredFilledCount) / CGFloat(requiredFieldTotal)
    }

    private var isFormValid: Bool {
        requiredFilledCount == requiredFieldTotal && projectStartDate <= projectEndDate
    }

    private var durationSummary: String {
        let days = Calendar.current.dateComponents([.day], from: projectStartDate, to: projectEndDate).day ?? 0
        return "\(max(0, days)) days"
    }

    private var defaultMapCoordinate: CLLocationCoordinate2D {
        if let la = pinLatitude, let lo = pinLongitude {
            return CLLocationCoordinate2D(latitude: la, longitude: lo)
        }
        return officeBaseCoordinate
    }

    private func resolveOfficeBaseCoordinate() async {
        let london = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        guard let org = firebaseBackend.currentOrganization else {
            officeBaseCoordinate = london
            return
        }
        if let lat = org.defaultLatitude, let lon = org.defaultLongitude {
            officeBaseCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            return
        }

        let parts: [String] = [
            org.officeAddressLine1,
            org.officeCity,
            org.officePostcode
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else {
            officeBaseCoordinate = london
            return
        }

        let address = parts.joined(separator: ", ")
        if let coord = await GeocodingCacheService.shared.coordinate(for: address) {
            officeBaseCoordinate = coord
        } else {
            officeBaseCoordinate = london
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ProjectWorksRevampColors.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        heroCard
                        requiredProgressCard

                        sectionHeader("Basics", showRequiredBadge: true)
                        basicsCard

                        addressSectionHeader
                        if addressFieldsExpanded || !hasMapPin {
                            addressCard
                        } else {
                            expandAddressFieldsRow
                        }
                        setPinOnMapRow

                        sectionHeader("Timeline", showRequiredBadge: true)
                        timelineCard
                        durationBanner

                        sectionHeader("Classification", showRequiredBadge: false)
                        classificationCard

                        sectionHeader("Team", showRequiredBadge: true)
                        teamCard

                        sectionHeader("View", showRequiredBadge: false)
                        CreateWorkVisibilitySection(
                            hiddenManagerUserIds: $hiddenManagerUserIds,
                            workKindNoun: "project",
                            palette: .projects
                        )
                        .environmentObject(userStore)

                        sectionHeader("Description", subtitle: "Optional")
                        descriptionCard

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 120)
                }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomCreateBar
            }
            .sheet(isPresented: $showingCreateClient) {
                CreateClientView(onCreated: { client in
                    selectedClient = client
                })
                .environmentObject(projectStore)
                .environmentObject(notificationService)
                .environmentObject(userStore)
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
            .onAppear {
                Task { await resolveOfficeBaseCoordinate() }
            }
            .onChange(of: pinLatitude) { _, _ in
                if hasMapPin { addressFieldsExpanded = false }
            }
            .onChange(of: pinLongitude) { _, _ in
                if hasMapPin { addressFieldsExpanded = false }
            }
            .overlay {
                if isLoading {
                    ProgressView("Saving…")
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                Image(systemName: "folder.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ProjectWorksRevampColors.blue)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(ProjectWorksRevampColors.canvas))
                    .overlay(Circle().stroke(ProjectWorksRevampColors.canvas, lineWidth: 2))
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Create a new project")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text("Fill in the essentials, add the rest later")
                    .font(.system(size: 12))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ProjectWorksRevampColors.border, lineWidth: 0.5))
    }

    private var requiredProgressCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Required fields")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Spacer()
                Text("\(requiredFilledCount) of \(requiredFieldTotal)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ProjectWorksRevampColors.border)
                    Capsule()
                        .fill(ProjectWorksRevampColors.blue)
                        .frame(width: max(8, geo.size.width * progressFraction))
                }
            }
            .frame(height: 4)
        }
        .padding(10)
        .padding(.horizontal, 4)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ProjectWorksRevampColors.border, lineWidth: 0.5))
    }

    private func sectionHeader(_ title: String, subtitle: String? = nil, showRequiredBadge: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .tracking(0.4)
            if showRequiredBadge {
                Text("REQUIRED")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(ProjectWorksRevampColors.requiredPillBg)
                    .clipShape(Capsule())
            }
            if let subtitle {
                Text("· \(subtitle)")
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
    }

    private var addressSectionHeader: some View {
        HStack {
            HStack(spacing: 8) {
                Text("ADDRESS")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .tracking(0.4)
                if hasMapPin {
                    Text("MAP PIN SET")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.activeGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(red: 0.882, green: 0.961, blue: 0.933))
                        .clipShape(Capsule())
                } else {
                    Text("REQUIRED")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(ProjectWorksRevampColors.requiredPillBg)
                        .clipShape(Capsule())
                }
            }
            Spacer()
        }
        .padding(.leading, 4)
    }

    private var basicsCard: some View {
        VStack(spacing: 0) {
            createFieldRow(
                icon: "number",
                iconBg: Color(red: 0.902, green: 0.945, blue: 0.984),
                iconTint: ProjectWorksRevampColors.blue,
                label: "Project reference",
                prompt: "e.g. C646",
                text: $projectJobNumber,
                fieldKey: "jobNumber",
                required: true
            )
            Divider().overlay(ProjectWorksRevampColors.border)
            createFieldRow(
                icon: "textformat",
                iconBg: ProjectWorksRevampColors.jobTypePillBg,
                iconTint: ProjectWorksRevampColors.jobTypePillInk,
                label: "Site name",
                prompt: "e.g. Lancelot Place",
                text: $projectSiteName,
                fieldKey: "siteName",
                required: true
            )
        }
        .padding(.horizontal, 14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ProjectWorksRevampColors.border, lineWidth: 0.5))
    }

    private var expandAddressFieldsRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                addressFieldsExpanded = true
            }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.97, green: 0.973, blue: 0.98))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Address fields hidden")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    Text("Tap to show address line 1–2, town / city, and postcode")
                        .font(.system(size: 11))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ProjectWorksRevampColors.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var addressCard: some View {
        VStack(spacing: 0) {
            createFieldRow(
                icon: "mappin.and.ellipse",
                iconBg: ProjectWorksRevampColors.pinRoseBg,
                iconTint: ProjectWorksRevampColors.pinRoseFg,
                label: "Address line 1",
                prompt: "Building number and street",
                text: $projectAddressLine1,
                fieldKey: "address1",
                required: true
            )
            Divider().overlay(ProjectWorksRevampColors.border)
            createFieldRow(
                icon: "square.dashed",
                iconBg: Color(red: 0.97, green: 0.973, blue: 0.98),
                iconTint: ProjectWorksRevampColors.muted,
                label: "Address line 2 · Optional",
                prompt: "Flat, unit, floor",
                text: $projectAddressLine2,
                fieldKey: "address2",
                required: false
            )
            Divider().overlay(ProjectWorksRevampColors.border)
            createFieldRow(
                icon: "building.2",
                iconBg: Color(red: 0.97, green: 0.973, blue: 0.98),
                iconTint: ProjectWorksRevampColors.muted,
                label: "Town / City",
                prompt: "e.g. London",
                text: $projectTownCity,
                fieldKey: "town",
                required: true
            )
            Divider().overlay(ProjectWorksRevampColors.border)
            createFieldRow(
                icon: "envelope",
                iconBg: Color(red: 0.97, green: 0.973, blue: 0.98),
                iconTint: ProjectWorksRevampColors.muted,
                label: "Postcode",
                prompt: "e.g. SW7 1DR",
                text: $projectPostcode,
                fieldKey: "postcode",
                required: true,
                autocapitalization: .characters
            )
        }
        .padding(.horizontal, 14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ProjectWorksRevampColors.border, lineWidth: 0.5))
    }

    private var setPinOnMapRow: some View {
        Button {
            showingMapPinPicker = true
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.902, green: 0.945, blue: 0.984))
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "map").font(.system(size: 15, weight: .medium)).foregroundStyle(ProjectWorksRevampColors.blue))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set pin on map")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    Text(hasMapPin ? "Map Pin has been set." : "Place exact site location · Optional")
                        .font(.system(size: 11))
                        .foregroundStyle(hasMapPin ? ProjectWorksRevampColors.activeGreen : ProjectWorksRevampColors.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
            }
            .padding(12)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ProjectWorksRevampColors.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var timelineCard: some View {
        VStack(spacing: 0) {
            dateRow(icon: "calendar", iconBg: Color(red: 0.882, green: 0.961, blue: 0.933), iconTint: ProjectWorksRevampColors.activeGreen, label: "Start date", date: $projectStartDate)
            Divider().overlay(ProjectWorksRevampColors.border)
            dateRow(icon: "flag.fill", iconBg: ProjectWorksRevampColors.endDateBg, iconTint: ProjectWorksRevampColors.endDateFg, label: "End date", date: $projectEndDate)
        }
        .padding(.horizontal, 14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ProjectWorksRevampColors.border, lineWidth: 0.5))
    }

    private func dateRow(icon: String, iconBg: Color, iconTint: Color, label: String, date: Binding<Date>) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconBg)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(iconTint))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Text(date.wrappedValue, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
            }
            Spacer()
            DatePicker("", selection: date, displayedComponents: .date)
                .labelsHidden()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
                .allowsHitTesting(false)
        }
        .frame(minHeight: 48, alignment: .center)
        .contentShape(Rectangle())
    }

    private var durationBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 13))
                .foregroundStyle(ProjectWorksRevampColors.blue)
            Text("Duration: \(durationSummary)")
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
        .padding(.horizontal, 14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ProjectWorksRevampColors.border, lineWidth: 0.5))
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
                Text(selectedClient?.name ?? "Choose a client")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selectedClient == nil ? ProjectWorksRevampColors.placeholderInk : ProjectWorksRevampColors.ink)
            }
            Spacer()
            Image(systemName: "asterisk")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
            Menu {
                ForEach(projectStore.clients, id: \.id) { c in
                    Button(c.name) { selectedClient = c }
                }
                Button("Create client…") { showingCreateClient = true }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
        }
        .padding(.vertical, 10)
    }

    private var jobTypeMenuRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ProjectWorksRevampColors.jobTypePillBg)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "square.grid.2x2.fill").foregroundStyle(ProjectWorksRevampColors.jobTypePillInk))
            VStack(alignment: .leading, spacing: 2) {
                Text("Job type · Optional")
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Text(projectWorksType.isEmpty ? "Select job type" : projectWorksType)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(projectWorksType.isEmpty ? ProjectWorksRevampColors.placeholderInk : ProjectWorksRevampColors.ink)
            }
            Spacer()
            if projectStore.jobTypes.isEmpty {
                Button("Manage…") { showingCreateJobType = true }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.blue)
            } else {
                Menu {
                    ForEach(projectStore.jobTypes.sorted(), id: \.self) { jt in
                        Button(jt) { projectWorksType = jt }
                    }
                    Button("Manage job types…") { showingCreateJobType = true }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var teamCard: some View {
        HStack(spacing: 12) {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "person.badge.plus").font(.system(size: 14)).foregroundStyle(ProjectWorksRevampColors.muted))
            VStack(alignment: .leading, spacing: 2) {
                Text("Manager")
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Text(selectedManager.map { "\($0.firstName) \($0.lastName)" } ?? "Assign a manager")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selectedManager == nil ? ProjectWorksRevampColors.placeholderInk : ProjectWorksRevampColors.ink)
            }
            Spacer()
            if operativeStore.allManagers.isEmpty {
                Button("Create…") { showingCreateManager = true }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.blue)
            } else {
                Menu {
                    ForEach(operativeStore.allManagers, id: \.id) { m in
                        Button("\(m.firstName) \(m.lastName)") { selectedManager = m }
                    }
                    Button("Create manager…") { showingCreateManager = true }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ProjectWorksRevampColors.border, lineWidth: 0.5))
    }

    private var descriptionCard: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $projectDescription)
                .font(.system(size: 12))
                .frame(minHeight: 88)
                .scrollContentBackground(.hidden)
                .padding(10)
            if projectDescription.isEmpty {
                Text("Add notes, scope, key contacts or anything else the team should know about this project…")
                    .font(.system(size: 12))
                    .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ProjectWorksRevampColors.border, lineWidth: 0.5))
    }

    private var bottomCreateBar: some View {
        VStack(spacing: 8) {
            Button {
                createProject()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                    Text("Create project")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(isFormValid && !isLoading ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.placeholderInk)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(!isFormValid || isLoading)
            Text(isFormValid ? " " : "Fill the \(requiredFieldTotal) required fields to continue")
                .font(.system(size: 10))
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            Color.white
                .shadow(color: .black.opacity(0.06), radius: 10, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func createFieldRow(
        icon: String,
        iconBg: Color,
        iconTint: Color,
        label: String,
        prompt: String,
        text: Binding<String>,
        fieldKey: String,
        required: Bool,
        autocapitalization: TextInputAutocapitalization = .never
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(iconBg)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(iconTint))
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedFieldKey = fieldKey }
                TextField("", text: text, prompt: Text(prompt).foregroundStyle(ProjectWorksRevampColors.placeholderInk))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .textInputAutocapitalization(autocapitalization)
                    .focused($focusedFieldKey, equals: fieldKey)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            if required {
                Image(systemName: hasMapPin && ["address1", "town", "postcode"].contains(fieldKey) ? "checkmark.circle.fill" : "asterisk")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(
                        hasMapPin && ["address1", "town", "postcode"].contains(fieldKey)
                            ? ProjectWorksRevampColors.activeGreen
                            : ProjectWorksRevampColors.requiredPillFg
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { focusedFieldKey = fieldKey }
    }

    private func createProject() {
        guard let client = selectedClient else {
            errorMessage = "Please select a client"
            return
        }
        guard selectedManager != nil else {
            errorMessage = "Please assign a manager"
            return
        }
        guard projectStartDate <= projectEndDate else {
            errorMessage = "End date must be on or after start date."
            return
        }
        isLoading = true
        errorMessage = nil

        let jobTypeEnum = projectWorksType.isEmpty ? .catA : jobTypeFromString(projectWorksType)
        let finalJobType = jobTypeEnum == .smallWorks ? .catA : jobTypeEnum
        let hasPin = pinLatitude != nil && pinLongitude != nil
        let sanitizedHidden = Set(hiddenManagerUserIds.filter { uid in
            guard let u = userStore.organizationUsers.first(where: { $0.id == uid }) else { return false }
            return !u.isExcludedFromManagerVisibilityHiding
        })

        let project = Project(
            jobNumber: projectJobNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            siteName: projectSiteName.trimmingCharacters(in: .whitespacesAndNewlines),
            addressLine1: projectAddressLine1.trimmingCharacters(in: .whitespacesAndNewlines),
            addressLine2: projectAddressLine2.isEmpty ? nil : projectAddressLine2,
            townCity: projectTownCity.trimmingCharacters(in: .whitespacesAndNewlines),
            postcode: projectPostcode.trimmingCharacters(in: .whitespacesAndNewlines),
            client: client,
            startDate: projectStartDate,
            endDate: projectEndDate,
            jobType: finalJobType,
            customJobType: projectWorksType.isEmpty ? nil : projectWorksType,
            manager: .custom,
            managerId: selectedManager?.id,
            isLive: true,
            description: projectDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : projectDescription,
            hiddenManagerUserIds: sanitizedHidden,
            usesMapPinForLocation: hasPin,
            latitude: hasPin ? pinLatitude : nil,
            longitude: hasPin ? pinLongitude : nil
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
        .environmentObject(NotificationService())
        .environmentObject(UserStore())
}
