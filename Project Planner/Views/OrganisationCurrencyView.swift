//
//  OrganisationCurrencyView.swift
//  Project Planner
//

import SwiftUI

struct OrganisationCurrencyView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss

    @State private var currencyCode = OrganizationCurrencyCatalog.defaultCode
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var resolvedCurrency: OrganizationCurrencyOption {
        OrganizationCurrencyCatalog.option(for: currencyCode)
    }

    var body: some View {
        Form {
            Section("Organisation currency") {
                Picker("Currency", selection: $currencyCode) {
                    ForEach(OrganizationCurrencyCatalog.all) { option in
                        Text("\(option.symbol) \(option.code) — \(option.title)")
                            .tag(option.code)
                    }
                }
                Text("Used for rates, reports, and invoicing defaults. Country and address are set in Company details.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                LabeledContent("Symbol", value: resolvedCurrency.symbol)
                LabeledContent("Code", value: resolvedCurrency.code)
                LabeledContent("Example", value: "\(resolvedCurrency.symbol)1,250.00")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Save currency")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .listRowBackground(Color.blue)
                .foregroundStyle(.white)
                .disabled(isSaving)
            }
        }
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let org = firebaseBackend.currentOrganization
            let saved = org?.settings.currencyCode
            currencyCode = saved?.isEmpty == false
                ? saved!
                : OrganizationCurrencyCatalog.defaultCode(forCountryCode: org?.countryCode ?? "GB")
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await firebaseBackend.updateOrganizationCurrencyCode(currencyCode)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
