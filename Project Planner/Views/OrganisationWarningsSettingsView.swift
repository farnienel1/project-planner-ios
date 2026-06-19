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
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var saveSucceeded = false
    @State private var userHasEdited = false
    @State private var excludedExpanded = false

    private var invoicingSettings: OrganizationInvoicingSettings {
        firebaseBackend.currentOrganization?.settings.invoicing ?? .default
    }

    private var invoicingPeriod: InvoicingPeriodInfo {
        InvoicingPeriodResolver.resolve(invoicing: invoicingSettings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerBar

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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Warnings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(exitsToHomeOnBack)
        .toolbar {
            if exitsToHomeOnBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onExitToHome?()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task { await save() }
                }
                .fontWeight(.semibold)
                .disabled(isSaving)
            }
        }
        .onAppear { syncDraftFromOrganization(force: true) }
        .onChange(of: firebaseBackend.currentOrganization?.firestoreDocumentId) { _, _ in
            syncDraftFromOrganization(force: false)
        }
        .onChange(of: firebaseBackend.currentOrganization?.settings.warningDetection) { _, newValue in
            guard !userHasEdited, let newValue else { return }
            draft = newValue
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Warnings")
                .font(.title2.bold())
            Text("Control how and when your team is alerted to scheduling issues")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Detection period

    private var detectionPeriodCard: some View {
        warningsCard {
            sectionHeader(icon: "clock.fill", title: "Detection period", subtitle: "How far ahead Project Planner scans for clashes, unbooked labour, and material cut-off dates. Warnings refresh automatically each day.")

            VStack(spacing: 10) {
                modeOption(.numberOfDays, label: "Set number of days", description: "Scan a fixed number of days from today — you control the window.")
                modeOption(.endOfInvoicingPeriod, label: "End of invoicing period", description: "Scan through the end of your current billing period. Automatically adjusts when each new period begins.")
                modeOption(.endOfWorkingWeek, label: "End of working week", description: "Scan through Friday of the current working week. Resets each Monday.")
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

            Text("Changing the look-ahead updates warnings immediately — extending the window surfaces new issues; reducing it removes warnings that fall outside the new end date.")
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
                        .strokeBorder(draft.clashLookaheadMode == mode ? ProjectWorksRevampColors.blue : Color(.systemGray4), lineWidth: 2)
                        .frame(width: 18, height: 18)
                    if draft.clashLookaheadMode == mode {
                        Circle()
                            .fill(ProjectWorksRevampColors.blue)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(draft.clashLookaheadMode == mode ? ProjectWorksRevampColors.blue : .primary)
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
                    .fill(draft.clashLookaheadMode == mode ? ProjectWorksRevampColors.blue.opacity(0.08) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(draft.clashLookaheadMode == mode ? ProjectWorksRevampColors.blue : Color.clear, lineWidth: 2)
            )
        }
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
                    Text("CURRENT INVOICING PERIOD")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                }
                Text(invoicingPeriod.currentPeriodLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.08, green: 0.33, blue: 0.18))
                Text("Warnings will scan through \(invoicingPeriod.currentPeriodEndLabel). This window resets automatically when the new period begins.")
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
            sectionHeader(icon: "person.2.fill", title: "Excluded users", subtitle: "Some staff (e.g. PAYE employees) don't need to appear in unbooked labour warnings. Users added here are silently skipped by the warnings engine.")

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
                            .background(ProjectWorksRevampColors.blue.opacity(0.15))
                            .foregroundStyle(ProjectWorksRevampColors.blue)
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
            .buttonStyle(.plain)

            NavigationLink {
                WarningExcludedUsersPickerView(
                    selectedUserIds: $draft.excludedUserIdsFromUnbookedWarnings,
                    onSave: saveExcludedUsers
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
                    .foregroundStyle(ProjectWorksRevampColors.blue)
            }
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
                subtitle: "Flags when an operative is double-booked on the same date across two or more projects. Clashes are always treated as high-urgency warnings.",
                isOn: $draft.detectClashes
            )

            Divider()

            toggleRow(
                title: "Include weekends in unbooked labour",
                subtitle: "When on, Saturday and Sunday are included when checking whether operatives have been booked for every day in the detection window. Enable only if your operatives regularly work weekends.",
                footnote: "Does not affect clash detection — clashes follow your working week unless a weekend booking exists.",
                isOn: $draft.includeWeekendsForUnbookedLabour
            )
        }
    }

    private var severityGuideCard: some View {
        warningsCard {
            sectionHeader(icon: "exclamationmark.triangle.fill", title: "Warning severity guide", subtitle: "For reference — severity levels are assigned automatically based on warning type.")

            severityRow(title: "High", description: "Operative clashes and unbooked labour — these directly affect project delivery and must be resolved promptly.", tint: .red)
            severityRow(title: "Medium", description: "Manager and admin overlaps — flagged for the weekly report but less time-critical to act on immediately.", tint: .orange)
            severityRow(title: "Low", description: "Materials not ordered by the required cut-off date — useful reminders that won't block site work immediately.", tint: .blue)
        }
    }

    // MARK: - Shared components

    private func warningsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(18)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 8, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5)
        )
    }

    private func sectionHeader(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ProjectWorksRevampColors.blue.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func infoBox(text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(ProjectWorksRevampColors.blue)
            Text(text)
                .font(.caption)
                .foregroundStyle(ProjectWorksRevampColors.blue)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(ProjectWorksRevampColors.blue.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ProjectWorksRevampColors.blue.opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stepButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 32, height: 32)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
        }
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
                .labelsHidden()
                .tint(ProjectWorksRevampColors.blue)
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

    private func syncDraftFromOrganization(force: Bool) {
        guard force || !userHasEdited else { return }
        guard let saved = firebaseBackend.currentOrganization?.settings.warningDetection else { return }
        draft = saved
        if force { userHasEdited = false }
    }

    private func markEdited() {
        userHasEdited = true
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
            await WarningsRefreshHelper.refreshSharedWarnings(
                operativeStore: operativeStore,
                bookingStore: bookingStore,
                projectStore: projectStore,
                userStore: userStore,
                managerScheduleStore: managerScheduleStore,
                holidayStore: holidayStore,
                firebaseBackend: firebaseBackend,
                appSettings: appSettings,
                force: true
            )
            userHasEdited = false
            if let onSaved {
                await MainActor.run { onSaved() }
            } else {
                saveSucceeded = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveExcludedUsers() async {
        markEdited()
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await firebaseBackend.updateOrganizationWarningDetectionSettings(draft)
            await WarningsRefreshHelper.refreshSharedWarnings(
                operativeStore: operativeStore,
                bookingStore: bookingStore,
                projectStore: projectStore,
                userStore: userStore,
                managerScheduleStore: managerScheduleStore,
                holidayStore: holidayStore,
                firebaseBackend: firebaseBackend,
                appSettings: appSettings,
                force: true
            )
            userHasEdited = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Excluded users picker

private struct WarningExcludedUsersPickerView: View {
    @Binding var selectedUserIds: [String]
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore

    @State private var searchText = ""
    @State private var isSaving = false
    @State private var saveSucceeded = false

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
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Excluded users")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search users")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task {
                        isSaving = true
                        saveSucceeded = false
                        await onSave()
                        isSaving = false
                        saveSucceeded = true
                    }
                }
                .fontWeight(.semibold)
                .disabled(isSaving)
            }
        }
        .overlay(alignment: .bottom) {
            if saveSucceeded {
                Text("Excluded users saved. Warnings updated.")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(ProjectWorksRevampColors.activeGreen)
                    .clipShape(Capsule())
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func toggle(_ userId: String) {
        if let idx = selectedUserIds.firstIndex(of: userId) {
            selectedUserIds.remove(at: idx)
        } else {
            selectedUserIds.append(userId)
        }
    }
}
