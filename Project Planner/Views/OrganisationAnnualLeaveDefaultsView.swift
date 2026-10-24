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
    @State private var baselineDaysText = ""
    @State private var baselineStartMonth = AnnualLeavePolicy.defaultStartMonth
    @State private var baselineEndMonth = AnnualLeavePolicy.defaultEndMonth
    @State private var baselineCarriesOver = AnnualLeavePolicy.defaultCarriesOver
    @State private var baselineRegionId = BankHolidayRegionDirectory.defaultRegionId
    @State private var didLoad = false

    private var isDirty: Bool {
        daysText != baselineDaysText
            || startMonth != baselineStartMonth
            || endMonth != baselineEndMonth
            || carriesOver != baselineCarriesOver
            || bankHolidayRegionId != baselineRegionId
    }

    private let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    private var selectedRegionTitle: String {
        BankHolidayRegionDirectory.region(id: bankHolidayRegionId)?.title
            ?? BankHolidayRegionDirectory.defaultRegion(forCountryCode: "GB").title
    }

    private var leaveYearSummary: String {
        let start = monthNames.indices.contains(startMonth - 1) ? monthNames[startMonth - 1] : "—"
        let end = monthNames.indices.contains(endMonth - 1) ? monthNames[endMonth - 1] : "—"
        return "1 \(start) – end of \(end)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Applies to new users only")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    Text("These settings apply only when adding new manager/operative users. Existing users keep their current annual leave values unless an admin/manager edits their profile.")
                        .font(.system(size: 13))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ProjectWorksRevampColors.blueTint)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.bottom, 8)

                SettingsHubChrome.sectionTitle("Allowance", sentenceCase: true)
                SettingsHubChrome.footer("Applied when adding new manager / operative users.")
                SettingsHubChrome.card {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Days per year")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(ProjectWorksRevampColors.ink)
                            Text("Half days are allowed, e.g. 25.5")
                                .font(.system(size: 13))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 4) {
                            TextField("e.g. 25", text: $daysText)
                                .accessibilityIdentifier("organisationAnnualLeaveDefaults.daysPerYear")
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 72)
                                .disabled(isSaving)
                            Text("days")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                    }
                    .padding(.vertical, 12)
                }

                SettingsHubChrome.sectionTitle("Company leave year", sentenceCase: true)
                SettingsHubChrome.footer("Runs from the first day of the start month through the last day of the end month (e.g. April → March).")
                SettingsHubChrome.card {
                    HStack(alignment: .bottom, spacing: 10) {
                        monthMenu("Starts", selection: $startMonth)
                        Text("→")
                            .font(.system(size: 15))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .padding(.bottom, 10)
                        monthMenu("Ends", selection: $endMonth)
                    }
                    .padding(.top, 12)
                    Text("Leave year: \(leaveYearSummary)")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(ProjectWorksRevampColors.grayTint)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.vertical, 12)
                    Toggle(isOn: $carriesOver) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Carry unused days into next leave year")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Unused allowance from the previous leave year is added to this year’s balance (after booked and pending time in that year).")
                                .font(.system(size: 12))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                    }
                    .accessibilityIdentifier("organisationAnnualLeaveDefaults.carryUnusedDays")
                    .disabled(isSaving)
                    .padding(.bottom, 12)
                }

                SettingsHubChrome.sectionTitle("Bank holiday region", sentenceCase: true)
                SettingsHubChrome.footer("Bank holidays shown in annual leave and scheduling follow this region. It should match where your organisation is based.")
                SettingsHubChrome.card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Region")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .padding(.top, 12)
                        Text("Syncs with the web app and applies organisation-wide.")
                            .font(.system(size: 12))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                        Picker("Region", selection: $bankHolidayRegionId) {
                            ForEach(BankHolidayRegionDirectory.pickerRegions(), id: \.group) { group in
                                Section(group.group) {
                                    ForEach(group.regions) { region in
                                        Text(region.title).tag(region.id)
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("organisationAnnualLeaveDefaults.region")
                        .pickerStyle(.menu)
                        .font(.system(size: 13, weight: .medium))
                        .tint(ProjectWorksRevampColors.blue)
                        Text("Currently set to \(selectedRegionTitle)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(ProjectWorksRevampColors.grayTint)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.bottom, 12)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                }

            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Annual leave")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
        .safeAreaInset(edge: .bottom) {
            SettingsStickySaveBar(isDirty: isDirty, isSaving: isSaving) {
                Task { await save() }
            }
        }
        .settingsUnsavedLeave(isDirty: isDirty) {
            restoreBaseline()
            dismiss()
        }
        .onAppear {
            guard !didLoad else { return }
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
            captureBaseline()
            didLoad = true
        }
    }

    private func captureBaseline() {
        baselineDaysText = daysText
        baselineStartMonth = startMonth
        baselineEndMonth = endMonth
        baselineCarriesOver = carriesOver
        baselineRegionId = bankHolidayRegionId
    }

    private func restoreBaseline() {
        daysText = baselineDaysText
        startMonth = baselineStartMonth
        endMonth = baselineEndMonth
        carriesOver = baselineCarriesOver
        bankHolidayRegionId = baselineRegionId
    }

    private func monthMenu(_ title: String, selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            Picker(title, selection: selection) {
                ForEach(1...12, id: \.self) { month in
                    Text(monthNames[month - 1]).tag(month)
                }
            }
            .accessibilityIdentifier("organisationAnnualLeaveDefaults.\(AccessibilityID.token(title))")
            .pickerStyle(.menu)
            .disabled(isSaving)
            .tint(ProjectWorksRevampColors.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            captureBaseline()
            Task {
                BankHolidayService.shared.invalidateCache(for: region.id)
                await BankHolidayService.shared.ensureLoaded(region: region, forceRefresh: true)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
