//
//  CompanyDetailsEditView.swift
//  Project Planner
//

import SwiftUI
import CoreLocation
import PhotosUI

struct CompanyDetailsEditView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss
    
    @State private var organizationName = ""
    @State private var hasOfficeAddress = true
    @State private var officeAddressLine1 = ""
    @State private var officeCity = ""
    @State private var officePostcode = ""
    @State private var countryCode = "GB"
    @State private var selectedLogoItem: PhotosPickerItem?
    @State private var selectedLogoImage: UIImage?
    
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Organisation name", text: $organizationName)
                } header: {
                    Text("Company name")
                }
                
                Section {
                    Toggle("Organisation has an office address", isOn: $hasOfficeAddress)
                    
                    Picker("Country", selection: $countryCode) {
                        ForEach(CountryCapitalDirectory.supported, id: \.code) { country in
                            Text(country.name).tag(country.code)
                        }
                    }
                    
                    if hasOfficeAddress {
                        TextField("Office address line 1", text: $officeAddressLine1)
                        TextField("City / town", text: $officeCity)
                        TextField("Postcode (optional)", text: $officePostcode)
                    } else {
                        Text("Map default: \(CountryCapitalDirectory.fallbackDescription(for: countryCode))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Office & region")
                } footer: {
                    Text("Country is always required. If there is no office address, the site map centres on the capital (London for the UK).")
                }

                Section {
                    HStack(spacing: 12) {
                        Group {
                            if let selectedLogoImage {
                                Image(uiImage: selectedLogoImage)
                                    .resizable()
                                    .scaledToFit()
                            } else if let logoURL = firebaseBackend.currentOrganization?.companyLogoURL,
                                      let url = URL(string: logoURL) {
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    ProgressView()
                                }
                            } else {
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 72, height: 72)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $selectedLogoItem, matching: .images) {
                                Text("Upload logo (JPEG)")
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Remove logo", role: .destructive) {
                                selectedLogoImage = nil
                                selectedLogoItem = nil
                                Task {
                                    try? await firebaseBackend.updateOrganizationCompanyLogoURL(nil)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("Company logo")
                } footer: {
                    Text("Shown on Home and Site Audit report header.")
                }
                
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                if let successMessage {
                    Section {
                        Text(successMessage)
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Company details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .onAppear {
                applyOrganizationToForm()
            }
            .onChange(of: selectedLogoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            selectedLogoImage = resizedLogoImage(image)
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
    
    private func applyOrganizationToForm() {
        guard let org = firebaseBackend.currentOrganization else { return }
        organizationName = org.name
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
        guard canSave else { return }
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
                defaultLongitude: lon
            )
            if let selectedLogoImage,
               let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                let logoURL = try await firebaseBackend.uploadOrganizationLogo(selectedLogoImage, organizationId: orgId)
                try await firebaseBackend.updateOrganizationCompanyLogoURL(logoURL)
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
