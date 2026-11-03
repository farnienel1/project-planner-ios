//
//  OrganisationAnnualLeaveDefaultsView.swift
//  Project Planner
//

import SwiftUI

struct OrganisationAnnualLeaveDefaultsView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject private var smartCache: SmartCacheService
    @Environment(\.dismiss) private var dismiss

    @State private var daysText: String = ""
    @State private var startMonth: Int = AnnualLeavePolicy.defaultStartMonth
    @State private var endMonth: Int = AnnualLeavePolicy.defaultEndMonth
    @State private var carriesOver: Bool = AnnualLeavePolicy.defaultCarriesOver
    /// RULEBOOK 1.13.0 §4.4 `annualLeaveDefaults.maxCarryOverDays` as typed; blank = no cap (`parseMaxCarryOverDays`).
    @State private var maxCarryText: String = ""
    @State private var baselineMaxCarryText = ""
    @State private var bankHolidayRegionId: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var baselineDaysText = ""
    @State private var baselineStartMonth = AnnualLeavePolicy.defaultStartMonth
    @State private var baselineEndMonth = AnnualLeavePolicy.defaultEndMonth
    @State private var baselineCarriesOver = AnnualLeavePolicy.defaultCarriesOver
    @State private var baselineRegionId = ""
    @State private var didLoad = false

    private var isDirty: Bool {
        daysText != baselineDaysText
            || startMonth != baselineStartMonth
            || endMonth != baselineEndMonth
            || carriesOver != baselineCarriesOver
            || maxCarryText != baselineMaxCarryText
            || bankHolidayRegionId != baselineRegionId
    }

    private let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// `bankHolidayRegionLabel` (the listed title, or the stored id when it is not listed).
    private var selectedRegionTitle: String {
        CanonicalBusinessEngine.bankHolidayRegionLabel(bankHolidayRegionId)
    }

    /// Only the company country's regions (`bankHolidayRegionsForCountry`, rulebook §4.4). The country is set in
    /// Company details.
    private var regionChoices: [BankHolidayRegion] {
        CanonicalBusinessEngine.bankHolidayRegionsForCountry(firebaseBackend.currentOrganization?.countryCode ?? "GB")
    }

    /// The saved region when it is not one of this country's choices, so the picker still shows it.
    private var selectionIsListed: Bool {
        regionChoices.contains { $0.id == bankHolidayRegionId }
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
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text("These settings apply only when adding new manager/operative users. Existing users keep their current annual leave values unless an admin/manager edits their profile.")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PPColor.brand.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                .padding(.bottom, 8)

                SettingsHubChrome.sectionTitle("Allowance", sentenceCase: true)
                SettingsHubChrome.footer("Applied when adding new manager / operative users.")
                SettingsHubChrome.card {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Days per year")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.primary)
                            Text("Half days are allowed, e.g. 25.5")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 4) {
                            TextField("e.g. 25", text: $daysText)
                                .accessibilityIdentifier("organisationAnnualLeaveDefaults.daysPerYear")
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(.body.weight(.bold))
                                .frame(width: 72)
                                .disabled(isSaving)
                            Text("days")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .padding(.vertical, 12)
                }

                SettingsHubChrome.sectionTitle("Company leave year", sentenceCase: true)
                SettingsHubChrome.footer("Runs from the first day of the start month through the last day of the end month (e.g. April → March).")
                SettingsHubChrome.card {
                    HStack(alignment: .bottom, spacing: 10) {
                        monthMenu("Starts", selection: startSelection)
                        Text("→")
                            .font(.body)
                            .foregroundStyle(Color.secondary)
                            .padding(.bottom, 10)
                        monthMenu("Ends", selection: endSelection)
                    }
                    .padding(.top, 12)
                    Text("Leave year: \(leaveYearSummary)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(PPColor.well)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.vertical, 12)
                    Toggle(isOn: $carriesOver) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Carry unused days into next leave year")
                                .font(.body.weight(.semibold))
                            Text("Unused allowance from the previous leave year is added to this year’s balance (after booked and pending time in that year).")
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .accessibilityIdentifier("organisationAnnualLeaveDefaults.carryUnusedDays")
                    .disabled(isSaving)
                    .padding(.bottom, 12)
                    if carriesOver {
                        // RULEBOOK 1.13.0 §4.4: the suggested cap is shown, never saved.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Most days carried over")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.secondary)
                            TextField(suggestedMaxCarryText, text: $maxCarryText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isSaving)
                                .accessibilityIdentifier("organisationAnnualLeaveDefaults.maxCarryOverDays")
                            Text("Leave blank for no limit. \(suggestedMaxCarryText) is a common limit.")
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                        }
                        .padding(.bottom, 12)
                    }
                }

                SettingsHubChrome.sectionTitle("Bank holiday region", sentenceCase: true)
                SettingsHubChrome.footer("Bank holidays shown in annual leave and scheduling follow this region. It should match where your organisation is based.")
                SettingsHubChrome.card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Region")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.secondary)
                            .padding(.top, 12)
                        Text("Syncs with the web app and applies organisation-wide.")
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                        if regionChoices.isEmpty {
                            Text("No bank-holiday calendar is listed for this country.")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                                .padding(.vertical, 6)
                        } else {
                            Picker("Region", selection: $bankHolidayRegionId) {
                                if !selectionIsListed {
                                    Text(bankHolidayRegionId.isEmpty ? "Choose…" : selectedRegionTitle)
                                        .tag(bankHolidayRegionId)
                                }
                                ForEach(regionChoices) { region in
                                    Text(region.title).tag(region.id)
                                }
                            }
                            .accessibilityIdentifier("organisationAnnualLeaveDefaults.region")
                            .pickerStyle(.menu)
                            .font(.subheadline.weight(.medium))
                            .tint(PPColor.brand)
                        }
                        Text("Currently set to \(selectedRegionTitle)")
                            .font(.footnote)
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(PPColor.well)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.bottom, 12)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(PPColor.danger)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                }

            }
            .padding(16)
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("Annual leave")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .safeAreaInset(edge: .bottom) {
            SettingsStickySaveBar(isDirty: isDirty, isSaving: isSaving, isOnline: smartCache.isOnline) {
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
            maxCarryText = defaults.maxCarryOverDays.map(Self.daysText) ?? ""
            // The saved region (already `parseCompanyDetails`), aliases resolved; else the country's default.
            let storedRegion = firebaseBackend.currentOrganization?.settings.bankHolidayRegionId
            bankHolidayRegionId = CanonicalBusinessEngine.normalizeBankHolidayRegionId(storedRegion)
                ?? storedRegion
                ?? CanonicalBusinessEngine.defaultBankHolidayRegionForCountry(
                    firebaseBackend.currentOrganization?.countryCode ?? "GB"
                )
                ?? ""
            captureBaseline()
            didLoad = true
        }
    }

    private var suggestedMaxCarryText: String { Self.daysText(CanonicalBusinessEngine.suggestedMaxCarryOverDays) }

    private static func daysText(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func captureBaseline() {
        baselineDaysText = daysText
        baselineStartMonth = startMonth
        baselineEndMonth = endMonth
        baselineCarriesOver = carriesOver
        baselineMaxCarryText = maxCarryText
        baselineRegionId = bankHolidayRegionId
    }

    private func restoreBaseline() {
        daysText = baselineDaysText
        startMonth = baselineStartMonth
        endMonth = baselineEndMonth
        carriesOver = baselineCarriesOver
        maxCarryText = baselineMaxCarryText
        bankHolidayRegionId = baselineRegionId
    }

    /// RULEBOOK 1.12.0 §4.4: a leave year is 12 months, so the end follows the start (`leaveYearEndMonth`).
    private var startSelection: Binding<Int> {
        Binding(
            get: { startMonth },
            set: { next in
                startMonth = next
                if let end = CanonicalBusinessEngine.leaveYearEndMonth(startMonth: next) { endMonth = end }
            }
        )
    }

    /// Picking the end month moves the start to the month whose `leaveYearEndMonth` it is (12 months either way).
    private var endSelection: Binding<Int> {
        Binding(
            get: { endMonth },
            set: { next in
                endMonth = next
                if let start = CanonicalBusinessEngine.leaveYearStartMonth(endingIn: next) { startMonth = start }
            }
        )
    }

    private func monthMenu(_ title: String, selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.secondary)
            Picker(title, selection: selection) {
                ForEach(1...12, id: \.self) { month in
                    Text(monthNames[month - 1]).tag(month)
                }
            }
            .accessibilityIdentifier("organisationAnnualLeaveDefaults.\(AccessibilityID.token(title))")
            .pickerStyle(.menu)
            .disabled(isSaving)
            .tint(PPColor.brand)
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

        // RULEBOOK 1.12.0 §4.4 `validateAnnualLeaveDefaults`: a leave year that is not 12 months is refused.
        if let leaveYearError = CanonicalBusinessEngine.annualLeaveDefaultsError(startMonth: startMonth, endMonth: endMonth) {
            errorMessage = leaveYearError
            return
        }

        let defaults = OrganizationAnnualLeaveDefaults(
            daysPerYear: parsedDays,
            startMonth: startMonth,
            endMonth: endMonth,
            carriesOver: carriesOver,
            // Web: the cap applies only with carry-over on; blank = no cap. The whole map is written.
            maxCarryOverDays: carriesOver
                ? CanonicalBusinessEngine.parseMaxCarryOverDays(maxCarryText.replacingOccurrences(of: ",", with: "."))
                : nil
        )
        do {
            try await firebaseBackend.updateOrganizationAnnualLeaveSettings(
                defaults: defaults,
                bankHolidayRegionId: bankHolidayRegionId
            )
            let region = CanonicalBusinessEngine.bankHolidayRegion(id: bankHolidayRegionId)
            captureBaseline()
            if let region {
                Task {
                    BankHolidayService.shared.invalidateCache(for: region.id)
                    await BankHolidayService.shared.ensureLoaded(region: region, forceRefresh: true)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
