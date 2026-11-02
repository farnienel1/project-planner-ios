//
//  OrganisationCurrencyView.swift
//  Project Planner
//

import SwiftUI

struct OrganisationCurrencyView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject private var smartCache: SmartCacheService
    @Environment(\.dismiss) private var dismiss

    @State private var currencyCode = OrganizationCurrencyCatalog.defaultCode
    /// Last value read from the organisation; the draft follows the server only while it equals this.
    @State private var baselineCode = OrganizationCurrencyCatalog.defaultCode
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
                    .accessibilityIdentifier("organisationCurrency.currency")
                    .pickerStyle(.menu)
                    .font(.subheadline.weight(.medium))
                    .padding(.vertical, 12)
                    .tint(PPColor.brand)
                }
                SettingsHubChrome.footer("Used for rates, reports, and invoicing defaults. Country and address are set in Company details.")

                SettingsHubChrome.sectionTitle("Preview")
                SettingsHubChrome.card {
                    previewRow("Symbol", resolvedCurrency.symbol)
                    SettingsHubChrome.divider()
                    previewRow("Code", resolvedCurrency.code)
                    SettingsHubChrome.divider()
                    previewRow("Example", OrgMoney.format(1250, currencyCode: resolvedCurrency.code))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(PPColor.danger)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                }

                SettingsHubChrome.saveButton("Save currency", isSaving: isSaving) {
                    Task { await save() }
                }
                .onlineOnly(isOnline: smartCache.isOnline)
            }
            .padding(16)
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .onAppear {
            currencyCode = serverCurrencyCode
            baselineCode = currencyCode
        }
        .onChange(of: serverCurrencyCode) { _, server in
            // §4: keep an unsaved choice; follow the server only while the draft is unchanged.
            guard !isSaving, currencyCode == baselineCode else { return }
            currencyCode = server
            baselineCode = server
        }
    }

    /// `resolveOrganizationCurrency` (read into `settings.currencyCode`), else `defaultCurrencyForCountry`.
    private var serverCurrencyCode: String {
        let org = firebaseBackend.currentOrganization
        if let saved = org?.settings.currencyCode, !saved.isEmpty { return saved }
        return OrganizationCurrencyCatalog.defaultCode(forCountryCode: org?.countryCode ?? "GB")
    }

    private func previewRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
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
