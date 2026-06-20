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
        Form {
            Section("Annual Leave / Bank Holiday Region") {
                Picker("Region", selection: $bankHolidayRegionId) {
                    ForEach(BankHolidayRegionDirectory.groupedRegions(), id: \.group) { group in
                        Section(group.group) {
                            ForEach(group.regions) { region in
                                Text(region.title).tag(region.id)
                            }
                        }
                    }
                }
                Text("Bank holidays are shown on annual leave calendars for all users. Weekends are always blocked. Data is cached offline for this year and the next two years.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Default annual leave for new users") {
                AnnualLeaveEntitlementEditor(
                    daysText: $daysText,
                    startMonth: $startMonth,
                    endMonth: $endMonth,
                    carriesOver: $carriesOver,
                    isEnabled: !isSaving
                )
            }

            Section {
                Text("These settings apply only when adding new manager/operative users. Existing users keep their current annual leave values unless an admin/manager edits their profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                            Text("Save settings")
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
        .navigationTitle("Annual leave")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let defaults = firebaseBackend.currentOrganization?.settings.annualLeaveDefaults ?? .default
            daysText = defaults.daysPerYear.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(defaults.daysPerYear))
                : String(format: "%.1f", defaults.daysPerYear)
            startMonth = defaults.startMonth
            endMonth = defaults.endMonth
            carriesOver = defaults.carriesOver
            bankHolidayRegionId = firebaseBackend.currentOrganization?.settings.bankHolidayRegionId
                ?? BankHolidayRegionDirectory.defaultRegionId
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
            try await firebaseBackend.updateOrganizationAnnualLeaveDefaults(defaults)
            try await firebaseBackend.updateOrganizationBankHolidayRegion(bankHolidayRegionId)
            let region = BankHolidayRegionDirectory.region(id: bankHolidayRegionId, fallbackCountryCode: "GB")
            await BankHolidayService.shared.ensureLoaded(region: region)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
