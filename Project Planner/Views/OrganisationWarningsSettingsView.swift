//
//  OrganisationWarningsSettingsView.swift
//  Project Planner
//
//  Company-wide warning detection defaults (org settings).
//

import SwiftUI

struct OrganisationWarningsSettingsView: View {
    var exitsToHomeOnBack: Bool = false
    var onExitToHome: (() -> Void)?
    var onSaved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var appSettings: AppSettingsStore

    @State private var draft = OrgWarningDetectionSettings.default
    @State private var baseline = OrgWarningDetectionSettings.default
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var saveSucceeded = false
    @State private var excludedExpanded = false
    @State private var showingLeaveConfirm = false

    private var isDirty: Bool { draft != baseline }

    private var invoicingSettings: OrganizationInvoicingSettings {
        firebaseBackend.currentOrganization?.settings.invoicing ?? .default
    }

    private var invoicingPeriod: InvoicingPeriodInfo {
        InvoicingPeriodResolver.resolve(invoicing: invoicingSettings)
    }

    /// Active payment-run segment used by Warnings “Invoicing period” mode (from Organisation Hub).
    private var warningsInvoicingScanLabel: String {
        InvoicingPeriodResolver.warningScanBounds(invoicing: invoicingSettings).label
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerBar

                VStack(alignment: .leading, spacing: 20) {
                    detectionPeriodCard
                    excludedUsersCard
                    warningTypesCard
                    severityGuideCard

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }

                    if saveSucceeded, onSaved == nil {
                        Text("Settings saved. Warnings have been updated.")
                            .font(.caption)
                            .foregroundStyle(ProjectWorksRevampColors.activeGreen)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.top, 18)
                .padding(.bottom, 12)
                .ppContentSheet()
            }
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("Warnings")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .navigationBarBackButtonHidden(true)
        .background(SettingsSwipeBackGuard(disabled: isDirty))
        .safeAreaInset(edge: .bottom) {
            SettingsStickySaveBar(isDirty: isDirty, isSaving: isSaving) {
                Task { await save() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    requestLeave()
                } label: {
                    if exitsToHomeOnBack {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Warnings")
                        }
                    } else {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .tint(.white)
                .accessibilityIdentifier("organisationWarningsSettings.back")
            }
        }
        .alert("Unsaved changes", isPresented: $showingLeaveConfirm) {
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("organisationWarningsSettings.cancel")
            Button("Continue") {
                draft = baseline
                leave()
            }
            .accessibilityIdentifier("organisationWarningsSettings.continue")
        } message: {
            Text("You have changes that have not been saved. Leave this page and discard them?")
        }
        .onAppear { syncDraftFromOrganization(force: true) }
        .task {
            await firebaseBackend.refreshWarningDetectionFromServer()
            syncDraftFromOrganization(force: false)
        }
        .onChange(of: firebaseBackend.currentOrganization?.firestoreDocumentId) { _, _ in
            syncDraftFromOrganization(force: false)
        }
        .onChange(of: firebaseBackend.currentOrganization?.settings.warningDetection) { _, newValue in
            guard !isDirty, let newValue else { return }
            draft = newValue
            baseline = newValue
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        PPNavyPageTitle(
            title: "Warnings",
            subtitle: "Control how and when your team is alerted to scheduling issues"
        )
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 16)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    // MARK: - Detection period

    private var detectionPeriodCard: some View {
        warningsCard {
            sectionHeader(icon: "clock.fill", title: "Detection period", subtitle: "How far ahead Project Planner scans for clashes, unbooked labour, and material cut-off dates. Warnings refresh automatically each day.")

            VStack(spacing: 10) {
                modeOption(.numberOfDays, label: "Set number of days", description: "Scan today through the next N calendar days (inclusive). Example: 7 days = today + the next 6 days.")
                modeOption(.endOfInvoicingPeriod, label: "Invoicing period", description: "Scan the active payment-run timeframe from Organisation Hub (e.g. 1–16 or 17–31) — every past, present, and future day inside that timeframe.")
                modeOption(.endOfWorkingWeek, label: "Full week", description: "This option will include any warnings for your current working week. To exclude weekends, please use the toggle below.")
            }

            if draft.clashLookaheadMode == .numberOfDays {
                daysStepperBox
            }

            if draft.clashLookaheadMode == .endOfInvoicingPeriod {
                invoicingPeriodPanel
            }

            if draft.clashLookaheadMode == .endOfWorkingWeek {
                infoBox(text: draft.detectionScanSummary(invoicing: invoicingSettings))
            }

            Text("Save updates the organisation setting. The Warnings list refreshes automatically when you leave settings; you can also tap Refresh anytime.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    private func modeOption(_ mode: WarningClashLookaheadMode, label: String, description: String) -> some View {
        Button {
            markEdited()
            draft.clashLookaheadMode = mode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(draft.clashLookaheadMode == mode ? PPColor.brand : Color(.systemGray4), lineWidth: 2)
                        .frame(width: 18, height: 18)
                    if draft.clashLookaheadMode == mode {
                        Circle()
                            .fill(PPColor.brand)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(draft.clashLookaheadMode == mode ? PPColor.brand : .primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(draft.clashLookaheadMode == mode ? PPColor.brand.opacity(0.08) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(draft.clashLookaheadMode == mode ? PPColor.brand : Color.clear, lineWidth: 2)
            )
        }
        .accessibilityIdentifier("organisationWarningsSettings.\(AccessibilityID.token(label))")
        .buttonStyle(.plain)
    }

    private var daysStepperBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Days ahead")
                        .font(.subheadline.weight(.semibold))
                    Text("Minimum 1 day · Maximum 365 days")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    stepButton(systemName: "minus") {
                        markEdited()
                        draft.clashLookaheadDays = max(1, draft.clashLookaheadDays - 1)
                    }
                    Text("\(draft.clashLookaheadDays)")
                        .font(.title3.bold())
                        .frame(width: 44)
                    stepButton(systemName: "plus") {
                        markEdited()
                        draft.clashLookaheadDays = min(365, draft.clashLookaheadDays + 1)
                    }
                }
            }
            infoBox(text: draft.detectionScanSummary(invoicing: invoicingSettings))
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, 8)
    }

    private var invoicingPeriodPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                HStack {
                    Text("YOUR INVOICING SCHEDULE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.tertiarySystemBackground))

                ForEach(Array(invoicingPeriod.scheduleRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    HStack {
                        Text(row.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(row.summary)
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    Text("ACTIVE PAYMENT-RUN PERIOD")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                }
                Text(warningsInvoicingScanLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.08, green: 0.33, blue: 0.18))
                Text("From Organisation Hub payment-run settings. While you are in this timeframe, warnings include every day from period start through period end — past, present, and future.")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.09, green: 0.40, blue: 0.20))
            }
            .padding(14)
            .background(Color(red: 0.94, green: 0.99, blue: 0.95))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.green.opacity(0.35), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            infoBox(text: draft.detectionScanSummary(invoicing: invoicingSettings))
        }
        .padding(.top, 8)
    }

    // MARK: - Excluded users

    private var excludedUsersCard: some View {
        warningsCard {
            sectionHeader(icon: "person.2.fill", title: "Excluded users", subtitle: "Some staff (e.g. PAYE employees) don't need to appear in unbooked labour warnings. Users added here are silently skipped. Pending users who have not finished sign-up are never unbooked-labour warnings.")

            Button {
                withAnimation { excludedExpanded.toggle() }
            } label: {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.systemBackground))
                            .frame(width: 30, height: 30)
                        Image(systemName: "person.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Manage excluded users")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if !draft.excludedUserIdsFromUnbookedWarnings.isEmpty {
                        Text("\(draft.excludedUserIdsFromUnbookedWarnings.count)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(PPColor.brand.opacity(0.15))
                            .foregroundStyle(PPColor.brand)
                            .clipShape(Capsule())
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(excludedExpanded ? 90 : 0))
                }
                .padding(14)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityIdentifier("organisationWarningsSettings.person2")
            .buttonStyle(.plain)

            NavigationLink {
                WarningExcludedUsersPickerView(
                    selectedUserIds: $draft.excludedUserIdsFromUnbookedWarnings
                )
                .environmentObject(userStore)
                .environmentObject(operativeStore)
                .environmentObject(firebaseBackend)
                .environmentObject(bookingStore)
                .environmentObject(projectStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(holidayStore)
                .environmentObject(appSettings)
                .onDisappear { markEdited() }
            } label: {
                Text("Open full exclusion list")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PPColor.brand)
            }
            .accessibilityIdentifier("organisationWarningsSettings.openFullExclusionList")
            .padding(.top, 4)

            if excludedExpanded {
                excludedUsersPreview
            }

            Text("Only exclude users who are permanently not bookable (e.g. office-based PAYE staff). For operatives working elsewhere temporarily, use the inactive flag in Manage Users instead.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var excludedUsersPreview: some View {
        let users = draft.excludedUserIdsFromUnbookedWarnings.compactMap { id in
            userStore.organizationUsers.first(where: { $0.id == id })
        }
        if users.isEmpty {
            Text("No users excluded — all operatives will appear in warnings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 8) {
                ForEach(users, id: \.id) { user in
                    HStack {
                        Circle()
                            .fill(Color(.systemGray4))
                            .frame(width: 28, height: 28)
                            .overlay {
                                Text(String((user.fullName.isEmpty ? user.email : user.fullName).prefix(1)).uppercased())
                                    .font(.caption2.weight(.semibold))
                            }
                        Text(user.fullName.isEmpty ? user.email : user.fullName)
                            .font(.subheadline)
                        Spacer()
                        Button {
                            markEdited()
                            draft.excludedUserIdsFromUnbookedWarnings.removeAll { $0 == user.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.red)
                                .padding(6)
                                .background(Color.red.opacity(0.12))
                                .clipShape(Circle())
                        }
                        .accessibilityIdentifier("organisationWarningsSettings.row.\(user.id).close")
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Warning types

    private var warningTypesCard: some View {
        warningsCard {
            sectionHeader(icon: "shield.fill", title: "Warning types", subtitle: "Choose which categories of issue Project Planner actively monitors and flags.")

            toggleRow(
                title: "Booking clashes",
                subtitle: "Flags when a person is double-booked on the same date. Operative, manager, and admin clashes are high-urgency; each can be approved for the weekly report.",
                isOn: $draft.detectClashes
            )

            Divider()

            toggleRow(
                title: "Include weekends in unbooked labour",
                subtitle: "When on, Saturday and Sunday are checked for unbooked labour inside the detection window (including Full week). Turn off to exclude weekends.",
                footnote: "Clash warnings still appear if someone has overlapping weekend bookings.",
                isOn: $draft.includeWeekendsForUnbookedLabour
            )
        }
    }

    private var materialCutOffSeverityDescription: String {
        let clock = OrgMaterialCutOff.resolve(
            stored: firebaseBackend.currentOrganization?.settings.materialCutOff,
            organizationLoaded: firebaseBackend.currentOrganization != nil
        )
        if let label = clock.flatMap({ CanonicalBusinessEngine.formatMaterialCutOffClock($0) }) {
            return "Materials not ordered by the \(label) cut-off, qualification expiry (including already expired), and unverified accounts."
        }
        return "Materials not ordered by the daily cut-off, qualification expiry (including already expired), and unverified accounts."
    }

    private var severityGuideCard: some View {
        warningsCard {
            sectionHeader(icon: "exclamationmark.triangle.fill", title: "Warning severity guide", subtitle: "For reference — severity levels are assigned automatically based on warning type.")

            severityRow(title: "High", description: "Operative booking clashes and unbooked labour. Approve a clash to note it on the weekly report.", tint: .red)
            severityRow(title: "Medium", description: "Manager and admin booking overlaps. Approve if intentional so they appear on the weekly report.", tint: .orange)
            severityRow(title: "Low", description: materialCutOffSeverityDescription, tint: .blue)
        }
    }

    // MARK: - Shared components

    private func warningsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(18)
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private func sectionHeader(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            PPIconTile(symbol: icon, family: sectionFamily(for: icon), size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionFamily(for icon: String) -> PPFamily {
        switch icon {
        case "clock.fill": return .plan
        case "person.2.fill": return .people
        case "exclamationmark.triangle.fill": return .alert
        default: return .system
        }
    }

    private func infoBox(text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(PPColor.brand)
            Text(text)
                .font(.caption)
                .foregroundStyle(PPColor.brand)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(PPColor.brand.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PPColor.brand.opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stepButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.footnote.weight(.bold))
                .frame(width: 32, height: 32)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
        }
        .accessibilityIdentifier("organisationWarningsSettings.step")
        .buttonStyle(.plain)
    }

    private func toggleRow(title: String, subtitle: String, footnote: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let footnote {
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("", isOn: isOn)
                .accessibilityIdentifier("organisationWarningsSettings.\(AccessibilityID.token(title))")
                .labelsHidden()
                .tint(PPColor.brand)
                .onChange(of: isOn.wrappedValue) { _, _ in markEdited() }
        }
        .padding(.vertical, 4)
    }

    private func severityRow(title: String, description: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint.opacity(0.85))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(tint.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Persistence

    private func requestLeave() {
        if isDirty {
            showingLeaveConfirm = true
        } else {
            leave()
        }
    }

    private func leave() {
        if exitsToHomeOnBack {
            onExitToHome?()
        } else {
            dismiss()
        }
    }

    private func syncDraftFromOrganization(force: Bool) {
        guard force || !isDirty else { return }
        guard let saved = firebaseBackend.currentOrganization?.settings.warningDetection else { return }
        draft = saved
        baseline = saved
    }

    private func markEdited() {
        saveSucceeded = false
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        saveSucceeded = false
        defer { isSaving = false }
        do {
            try await firebaseBackend.updateOrganizationWarningDetectionSettings(draft)
            let didRefresh = await WarningsRefreshHelper.refreshSharedWarnings(
                operativeStore: operativeStore,
                bookingStore: bookingStore,
                projectStore: projectStore,
                userStore: userStore,
                managerScheduleStore: managerScheduleStore,
                holidayStore: holidayStore,
                firebaseBackend: firebaseBackend,
                appSettings: appSettings,
                force: true,
                manualUserInitiated: true
            )
            if !didRefresh {
                errorMessage = "Settings saved, but warnings could not refresh yet. Go back and tap Refresh."
            }
            baseline = draft
            if let onSaved {
                await MainActor.run { onSaved() }
            } else {
                saveSucceeded = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

// MARK: - Excluded users picker

private struct WarningExcludedUsersPickerView: View {
    @Binding var selectedUserIds: [String]

    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore

    @State private var searchText = ""

    private var eligibleUsers: [AppUser] {
        userStore.organizationUsers
            .filter(\.isActive)
            .sorted { lhs, rhs in
                lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName) == .orderedAscending
            }
    }

    private var filteredUsers: [AppUser] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return eligibleUsers }
        return eligibleUsers.filter {
            $0.fullName.localizedCaseInsensitiveContains(q) ||
            $0.email.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List {
            if eligibleUsers.isEmpty {
                Text("No active manager or admin users to exclude.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredUsers) { user in
                    Button {
                        toggle(user.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.fullName.isEmpty ? user.email : user.fullName)
                                    .foregroundStyle(.primary)
                                Text(user.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedUserIds.contains(user.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(ProjectWorksRevampColors.activeGreen)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(Color(.systemGray3))
                            }
                        }
                    }
                    .accessibilityIdentifier("warningExcludedUsersPicker.row.\(user.id).done")
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("Excluded users")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .searchable(text: $searchText, prompt: "Search users")
    }

    private func toggle(_ userId: String) {
        if let idx = selectedUserIds.firstIndex(of: userId) {
            selectedUserIds.remove(at: idx)
        } else {
            selectedUserIds.append(userId)
        }
    }
}
