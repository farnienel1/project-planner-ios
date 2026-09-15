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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHubChrome.sectionTitle("Organisation currency")
                SettingsHubChrome.card {
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(OrganizationCurrencyCatalog.all) { option in
                            Text("\(option.symbol) \(option.code) — \(option.title)")
                                .tag(option.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.vertical, 12)
                    .tint(ProjectWorksRevampColors.blue)
                }
                SettingsHubChrome.footer("Used for rates, reports, and invoicing defaults. Country and address are set in Company details.")

                SettingsHubChrome.sectionTitle("Preview")
                SettingsHubChrome.card {
                    previewRow("Symbol", resolvedCurrency.symbol)
                    SettingsHubChrome.divider()
                    previewRow("Code", resolvedCurrency.code)
                    SettingsHubChrome.divider()
                    previewRow("Example", "\(resolvedCurrency.symbol)1,250.00")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                }

                SettingsHubChrome.saveButton("Save currency", isSaving: isSaving) {
                    Task { await save() }
                }
            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
        .onAppear {
            let org = firebaseBackend.currentOrganization
            let saved = org?.settings.currencyCode
            currencyCode = saved?.isEmpty == false
                ? saved!
                : OrganizationCurrencyCatalog.defaultCode(forCountryCode: org?.countryCode ?? "GB")
        }
    }

    private func previewRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
        .padding(.vertical, 12)
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
