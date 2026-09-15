//
//  OrganisationAnnualLeaveDefaultsView.swift
//  Project Planner
//

import SwiftUI

struct OrganisationAnnualLeaveDefaultsView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss

    @State private var daysText: String = ""
    @State private var startMonth: Int = AnnualLeavePolicy.defaultStartMonth
    @State private var endMonth: Int = AnnualLeavePolicy.defaultEndMonth
    @State private var carriesOver: Bool = AnnualLeavePolicy.defaultCarriesOver
    @State private var bankHolidayRegionId: String = BankHolidayRegionDirectory.defaultRegionId
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHubChrome.sectionTitle("Bank holiday region")
                SettingsHubChrome.card {
                    Picker("Region", selection: $bankHolidayRegionId) {
                        ForEach(BankHolidayRegionDirectory.pickerRegions(), id: \.group) { group in
                            Section(group.group) {
                                ForEach(group.regions) { region in
                                    Text(region.title).tag(region.id)
                                }
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.vertical, 12)
                    .tint(ProjectWorksRevampColors.blue)
                }
                SettingsHubChrome.footer("Bank holidays on annual leave calendars use this region only — not the company country in Company details. Choose England & Wales, Scotland, Northern Ireland, or another supported region. Data is cached offline.")

                SettingsHubChrome.sectionTitle("Default annual leave for new users")
                SettingsHubChrome.card {
                    AnnualLeaveEntitlementEditor(
                        daysText: $daysText,
                        startMonth: $startMonth,
                        endMonth: $endMonth,
                        carriesOver: $carriesOver,
                        isEnabled: !isSaving
                    )
                    .padding(.vertical, 12)
                }
                SettingsHubChrome.footer("These settings apply only when adding new manager/operative users. Existing users keep their current annual leave values unless an admin/manager edits their profile.")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                }

                SettingsHubChrome.saveButton("Save settings", isSaving: isSaving) {
                    Task { await save() }
                }
            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Annual leave")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
        .onAppear {
            let defaults = firebaseBackend.currentOrganization?.settings.annualLeaveDefaults ?? .default
            daysText = defaults.daysPerYear.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(defaults.daysPerYear))
                : String(format: "%.1f", defaults.daysPerYear)
            startMonth = defaults.startMonth
            endMonth = defaults.endMonth
            carriesOver = defaults.carriesOver
            bankHolidayRegionId = BankHolidayRegionDirectory.pickerSelection(
                forStoredRegionId: firebaseBackend.currentOrganization?.settings.bankHolidayRegionId
                    ?? BankHolidayRegionDirectory.defaultRegion(
                        forCountryCode: firebaseBackend.currentOrganization?.countryCode ?? "GB"
                    ).id
            )
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let normalized = daysText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedDays = Double(normalized), parsedDays > 0 else {
            errorMessage = "Enter a valid annual leave allowance (a positive number of days)."
            return
        }

        let defaults = OrganizationAnnualLeaveDefaults(
            daysPerYear: parsedDays,
            startMonth: startMonth,
            endMonth: endMonth,
            carriesOver: carriesOver
        )
        do {
            try await firebaseBackend.updateOrganizationAnnualLeaveSettings(
                defaults: defaults,
                bankHolidayRegionId: bankHolidayRegionId
            )
            let region = BankHolidayRegionDirectory.region(id: bankHolidayRegionId) ?? BankHolidayRegionDirectory.defaultRegion(forCountryCode: "GB")
            dismiss()
            Task {
                BankHolidayService.shared.invalidateCache(for: region.id)
                await BankHolidayService.shared.ensureLoaded(region: region, forceRefresh: true)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
