//
//  CompanyDetailsEditView.swift
//  Project Planner
//

import SwiftUI
import CoreLocation

struct CompanyDetailsEditView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss
    
    @State private var organizationName = ""
    @State private var hasOfficeAddress = true
    @State private var officeAddressLine1 = ""
    @State private var officeCity = ""
    @State private var officePostcode = ""
    @State private var countryCode = "GB"
    
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
}
