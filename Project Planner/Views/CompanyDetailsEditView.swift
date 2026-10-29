//
//  CompanyDetailsEditView.swift
//  Project Planner
//

import SwiftUI
import CoreLocation
import PhotosUI
import UniformTypeIdentifiers

struct CompanyDetailsEditView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss
    
    @State private var organizationName = ""
    @State private var documentAbbreviation = ""
    @State private var showAbbreviationLimitToast = false
    @State private var hasOfficeAddress = true
    @State private var officeAddressLine1 = ""
    @State private var officeCity = ""
    @State private var officePostcode = ""
    @State private var countryCode = "GB"
    @State private var selectedLogoItem: PhotosPickerItem?
    @State private var selectedLogoImage: UIImage?
    @State private var selectedLogoPDFData: Data?
    @State private var showingLogoPDFPicker = false
    
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var logoRemoved = false
    @State private var showingLeaveConfirm = false
    @State private var baselineName = ""
    @State private var baselineAbbreviation = ""
    @State private var baselineHasOffice = true
    @State private var baselineLine1 = ""
    @State private var baselineCity = ""
    @State private var baselinePostcode = ""
    @State private var baselineCountry = "GB"
    @State private var didLoad = false

    private var isDirty: Bool {
        organizationName != baselineName
            || documentAbbreviation != baselineAbbreviation
            || hasOfficeAddress != baselineHasOffice
            || officeAddressLine1 != baselineLine1
            || officeCity != baselineCity
            || officePostcode != baselinePostcode
            || countryCode != baselineCountry
            || logoRemoved
            || selectedLogoImage != nil
            || selectedLogoPDFData != nil
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsHubChrome.sectionTitle("Company name")
                    SettingsHubChrome.card {
                        TextField("Organisation name", text: $organizationName)
                            .accessibilityIdentifier("companyDetailsEdit.organisationName")
                            .font(.subheadline.weight(.medium))
                            .padding(.vertical, 12)
                    }

                    SettingsHubChrome.sectionTitle("Abbreviation for site audits and toolbox talks")
                    SettingsHubChrome.card {
                        TextField("e.g. RM", text: $documentAbbreviation)
                            .accessibilityIdentifier("companyDetailsEdit.eGRM")
                            .font(.subheadline.weight(.medium))
                            .textInputAutocapitalization(.characters)
                            .disableAutocorrection(true)
                            .padding(.vertical, 12)
                            .onChange(of: documentAbbreviation) { _, newValue in
                                handleAbbreviationTyping(newValue)
                            }
                    }
                    SettingsHubChrome.footer("Shown on site audit and toolbox talk headers. Maximum 3 characters.")

                    SettingsHubChrome.sectionTitle("Office & country")
                    SettingsHubChrome.card {
                        Toggle("Organisation has an office address", isOn: $hasOfficeAddress)
                            .accessibilityIdentifier("companyDetailsEdit.organisationHasAnOfficeAddress")
                            .font(.subheadline.weight(.medium))
                            .tint(PPColor.brand)
                            .padding(.vertical, 11)
                        SettingsHubChrome.divider()
                        Picker("Country", selection: $countryCode) {
                            ForEach(CountryCapitalDirectory.supported, id: \.code) { country in
                                Text(country.name).tag(country.code)
                            }
                        }
                        .accessibilityIdentifier("companyDetailsEdit.country")
                        .font(.subheadline.weight(.medium))
                        .tint(PPColor.brand)
                        .padding(.vertical, 11)
                        if hasOfficeAddress {
                            SettingsHubChrome.divider()
                            TextField("Office address line 1", text: $officeAddressLine1)
                                .accessibilityIdentifier("companyDetailsEdit.officeAddressLine1")
                                .font(.subheadline.weight(.medium))
                                .padding(.vertical, 11)
                            SettingsHubChrome.divider()
                            TextField("City / town", text: $officeCity)
                                .accessibilityIdentifier("companyDetailsEdit.cityTown")
                                .font(.subheadline.weight(.medium))
                                .padding(.vertical, 11)
                            SettingsHubChrome.divider()
                            TextField("Postcode (optional)", text: $officePostcode)
                                .accessibilityIdentifier("companyDetailsEdit.postcodeOptional")
                                .font(.subheadline.weight(.medium))
                                .padding(.vertical, 11)
                        } else {
                            SettingsHubChrome.divider()
                            Text("Map default: \(CountryCapitalDirectory.fallbackDescription(for: countryCode))")
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                                .padding(.vertical, 11)
                        }
                    }
                    SettingsHubChrome.footer("Country is always required. Bank holidays for annual leave are set separately under Organisation → Annual leave. If there is no office address, the site map centres on the capital (London for the UK).")

                    SettingsHubChrome.sectionTitle("Company logo")
                    SettingsHubChrome.card {
                        HStack(spacing: 12) {
                            Group {
                                if let selectedLogoImage {
                                    Image(uiImage: selectedLogoImage)
                                        .resizable()
                                        .scaledToFit()
                                } else if selectedLogoPDFData != nil {
                                    Image(systemName: "doc.fill")
                                        .font(.title2)
                                        .foregroundStyle(PPColor.brand)
                                } else if !logoRemoved,
                                          let logoURL = firebaseBackend.currentOrganization?.companyLogoURL,
                                          let url = URL(string: logoURL) {
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: {
                                        ProgressView()
                                    }
                                } else {
                                    Image(systemName: "photo")
                                        .font(.title2)
                                        .foregroundStyle(Color.secondary)
                                }
                            }
                            .frame(width: 72, height: 72)
                            .background(PPColor.page)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            VStack(alignment: .leading, spacing: 8) {
                                PhotosPicker(selection: $selectedLogoItem, matching: .images) {
                                    Text("Upload logo (JPEG)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(PPColor.brand)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                    .accessibilityIdentifier("companyDetailsEdit.uploadLogoJPEG")
                                Button("Upload PDF") {
                                    showingLogoPDFPicker = true
                                }
                                .accessibilityIdentifier("companyDetailsEdit.uploadLogoPDF")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PPColor.brand)
                                Button("Remove logo", role: .destructive) {
                                    selectedLogoImage = nil
                                    selectedLogoItem = nil
                                    selectedLogoPDFData = nil
                                    logoRemoved = true
                                }
                                .accessibilityIdentifier("companyDetailsEdit.removeLogo")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(PPColor.danger)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    SettingsHubChrome.footer("Image or PDF, up to 5 MB. Shown on Home and Site Audit report header.")

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(PPColor.danger)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 8)
                    }
                    if let successMessage {
                        Text(successMessage)
                            .font(.footnote)
                            .foregroundStyle(ProjectWorksRevampColors.activeGreen)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 8)
                    }
                }
                .padding(16)
            }
            .background(PPColor.page.ignoresSafeArea())
            .overlay(alignment: .top) {
                if showAbbreviationLimitToast {
                    Text("Only 3 characters for the abbreviation")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(PPColor.navy.opacity(0.94))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: showAbbreviationLimitToast)
            .navigationTitle("Company details")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .interactiveDismissDisabled(isDirty)
            .safeAreaInset(edge: .bottom) {
                SettingsStickySaveBar(isDirty: isDirty, isSaving: isSaving) {
                    Task { await save() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { requestLeave() }
                        .accessibilityIdentifier("companyDetailsEdit.cancel")
                        .font(.body.weight(.semibold))
                        .tint(.white)
                }
            }
            .alert("Unsaved changes", isPresented: $showingLeaveConfirm) {
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("companyDetailsEdit.stay")
                Button("Continue") {
                    applyOrganizationToForm()
                    dismiss()
                }
                .accessibilityIdentifier("companyDetailsEdit.continue")
            } message: {
                Text("You have changes that have not been saved. Leave this page and discard them?")
            }
            .onAppear {
                guard !didLoad else { return }
                applyOrganizationToForm()
                didLoad = true
            }
            .fileImporter(
                isPresented: $showingLogoPDFPicker,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    errorMessage = "Could not read that PDF."
                    return
                }
                if let message = StorageUploadPolicy.refusal(
                    family: .companyLogo,
                    fileExtension: "pdf",
                    contentType: "application/pdf",
                    byteCount: data.count
                ) {
                    errorMessage = message
                    return
                }
                selectedLogoPDFData = data
                selectedLogoImage = nil
                selectedLogoItem = nil
                logoRemoved = false
            }
            .onChange(of: selectedLogoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            selectedLogoImage = resizedLogoImage(image)
                            selectedLogoPDFData = nil
                            logoRemoved = false
                        }
                    }
                }
            }
        }
    }
    
    private var canSave: Bool {
        let nameOk = !organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let countryOk = !countryCode.isEmpty
        if hasOfficeAddress {
            let lineOk = !officeAddressLine1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let cityOk = !officeCity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return nameOk && countryOk && lineOk && cityOk
        }
        return nameOk && countryOk
    }
    
    private func requestLeave() {
        if isDirty {
            showingLeaveConfirm = true
        } else {
            dismiss()
        }
    }

    private func applyOrganizationToForm() {
        guard let org = firebaseBackend.currentOrganization else { return }
        organizationName = firebaseBackend.organizationNameForEditing(org)
        documentAbbreviation = org.documentAbbreviation
            ?? OrganizationDocumentAbbreviation.display(abbreviation: nil, organizationName: org.name)
        countryCode = org.countryCode.uppercased()
        if let line1 = org.officeAddressLine1, !line1.isEmpty,
           let city = org.officeCity, !city.isEmpty {
            hasOfficeAddress = true
            officeAddressLine1 = line1
            officeCity = city
            officePostcode = org.officePostcode ?? ""
        } else {
            hasOfficeAddress = false
            officeAddressLine1 = ""
            officeCity = ""
            officePostcode = org.officePostcode ?? ""
        }
        selectedLogoImage = nil
        selectedLogoItem = nil
        selectedLogoPDFData = nil
        logoRemoved = false
        captureBaseline()
    }

    private func captureBaseline() {
        baselineName = organizationName
        baselineAbbreviation = documentAbbreviation
        baselineHasOffice = hasOfficeAddress
        baselineLine1 = officeAddressLine1
        baselineCity = officeCity
        baselinePostcode = officePostcode
        baselineCountry = countryCode
    }
    
    private func resolveMapCenter() async -> (Double, Double) {
        if hasOfficeAddress {
            let parts = [
                officeAddressLine1.trimmingCharacters(in: .whitespacesAndNewlines),
                officeCity.trimmingCharacters(in: .whitespacesAndNewlines),
                officePostcode.trimmingCharacters(in: .whitespacesAndNewlines)
            ].filter { !$0.isEmpty }
            let query = parts.joined(separator: ", ")
            if !query.isEmpty, let coord = await GeocodingCacheService.shared.coordinate(for: query) {
                return (coord.latitude, coord.longitude)
            }
        }
        if countryCode.uppercased() == "GB" {
            return (51.5074, -0.1278)
        }
        if let c = CountryCapitalDirectory.option(for: countryCode) {
            return (c.latitude, c.longitude)
        }
        return (51.5074, -0.1278)
    }
    
    private func save() async {
        guard canSave else {
            errorMessage = hasOfficeAddress
                ? "Name, country, address line 1 and town are required."
                : "Organisation name and country are required."
            return
        }
        isSaving = true
        errorMessage = nil
        successMessage = nil
        let (lat, lon) = await resolveMapCenter()
        do {
            try await firebaseBackend.updateOrganizationCompanyDetails(
                name: organizationName,
                hasOfficeAddress: hasOfficeAddress,
                officeAddressLine1: hasOfficeAddress ? officeAddressLine1 : nil,
                officeCity: hasOfficeAddress ? officeCity : nil,
                officePostcode: hasOfficeAddress ? officePostcode : nil,
                countryCode: countryCode,
                defaultLatitude: lat,
                defaultLongitude: lon,
                documentAbbreviation: documentAbbreviation
            )
            if logoRemoved, selectedLogoImage == nil, selectedLogoPDFData == nil {
                try await firebaseBackend.updateOrganizationCompanyLogoURL(nil)
            }
            if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                if let selectedLogoPDFData {
                    let logoURL = try await firebaseBackend.uploadOrganizationLogoFile(
                        selectedLogoPDFData,
                        fileName: "logo.pdf",
                        organizationId: orgId
                    )
                    try await firebaseBackend.updateOrganizationCompanyLogoURL(logoURL)
                } else if let selectedLogoImage {
                    let logoURL = try await firebaseBackend.uploadOrganizationLogo(selectedLogoImage, organizationId: orgId)
                    try await firebaseBackend.updateOrganizationCompanyLogoURL(logoURL)
                }
            }
            await MainActor.run {
                isSaving = false
                successMessage = "Saved."
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    dismiss()
                }
            }
        } catch {
            await MainActor.run {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleAbbreviationTyping(_ newValue: String) {
        let cleaned = OrganizationDocumentAbbreviation.normalizeForTyping(newValue)
        if cleaned.count > OrganizationDocumentAbbreviation.maxLength {
            documentAbbreviation = String(cleaned.prefix(OrganizationDocumentAbbreviation.maxLength))
            showAbbreviationLimitToast = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                showAbbreviationLimitToast = false
            }
        } else if cleaned != newValue {
            documentAbbreviation = cleaned
        }
    }

    private func resizedLogoImage(_ image: UIImage) -> UIImage {
        let targetWidth: CGFloat = 900
        guard image.size.width > targetWidth else { return image }
        let scale = targetWidth / image.size.width
        let newSize = CGSize(width: targetWidth, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
