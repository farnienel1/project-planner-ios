//
//  OrganisationWarningsSettingsView.swift
//  Project Planner
//
//  Company-wide warning detection defaults (org settings).
//

import SwiftUI

struct OrganisationWarningsSettingsView: View {
    /// When true, the leading control dismisses warnings and returns to Home (opened from Warnings detail).
    var exitsToHomeOnBack: Bool = false
    var onExitToHome: (() -> Void)?
    /// When set (e.g. from Warnings detail), Save pops back to the warnings list after a successful save.
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

    var body: some View {
        Form {
            Section {
                Text("How far ahead should clashes, missed bookings and material lists be detected. It is set to End of the working week by default.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Warning detection")
            }

            Section {
                Picker("Look ahead", selection: $draft.clashLookaheadMode) {
                    ForEach(WarningClashLookaheadMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if draft.clashLookaheadMode == .numberOfDays {
                    Stepper(
                        "Days ahead: \(draft.clashLookaheadDays)",
                        value: $draft.clashLookaheadDays,
                        in: 1...366
                    )
                }

                if draft.clashLookaheadMode == .endOfInvoicingPeriod {
                    Text("When invoicing periods are configured, warnings will use your billing period end date. Until then, the end of the calendar month is used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Warnings scan \(draft.detectionHorizonDayCount()) day\(draft.detectionHorizonDayCount() == 1 ? "" : "s") from today through \(draft.detectionHorizonEndLabel()). Unbooked labour uses this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Detection period")
            } footer: {
                Text("Applies to clashes, unbooked labour, and material cut-off checks. Changing the look-ahead updates warnings immediately — extending shows more future days; reducing removes warnings beyond the new end date.")
            }

            Section {
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
                } label: {
                    HStack {
                        Text("Excluded users")
                        Spacer()
                        Text("\(draft.excludedUserIdsFromUnbookedWarnings.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Exclude users from the warnings")
            } footer: {
                Text("Use this feature to remove certain users such as PAYE staff from the warnings page so they will not show up when not booked in. It shouldn't be used for users/sub-contractors/operatives that are working elsewhere temporarily. They should be marked as inactive via Manage Users.")
            }

            Section {
                Toggle("Clashes", isOn: $draft.detectClashes)
                    .tint(ProjectWorksRevampColors.blue)
            } header: {
                Text("Clashes")
            }

            Section {
                Toggle("Include weekends for unbooked labour detection", isOn: $draft.includeWeekendsForUnbookedLabour)
                    .tint(ProjectWorksRevampColors.blue)
            } footer: {
                Text("Only affects unbooked labour warnings. Clash and materials detection follow your working week unless weekends are booked.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            if saveSucceeded, onSaved == nil {
                Section {
                    Text("Settings saved. Warnings have been updated.")
                        .font(.caption)
                        .foregroundStyle(ProjectWorksRevampColors.activeGreen)
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
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(isSaving)
                .listRowBackground(ProjectWorksRevampColors.blue)
                .foregroundStyle(.white)
            }
        }
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
        .onAppear {
            draft = firebaseBackend.currentOrganization?.settings.warningDetection ?? .default
        }
        .onChange(of: draft.clashLookaheadDays) { _, newValue in
            if newValue > 0, draft.clashLookaheadMode != .numberOfDays {
                draft.clashLookaheadMode = .numberOfDays
            }
        }
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
            if let onSaved {
                await MainActor.run {
                    onSaved()
                }
            } else {
                saveSucceeded = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveExcludedUsers() async {
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

