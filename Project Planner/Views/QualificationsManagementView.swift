//
//  QualificationsManagementView.swift
//  Project Planner
//
//  Created by Assistant on 23/10/2025.
//

import SwiftUI

private enum QualificationsHubMode: String, CaseIterable, Identifiable {
    case organisation
    case mine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .organisation: return "Organisation Qualifications"
        case .mine: return "My Qualifications"
        }
    }
}

struct QualificationsManagementView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService
    @Environment(\.dismiss) private var dismiss

    @State private var mode: QualificationsHubMode = .organisation
    @State private var showingAddQualification = false
    @State private var qualificationToEdit: Qualification?
    @State private var myOperative: Operative?
    @State private var isResolvingMyProfile = false
    @State private var myProfileError: String?

    private var canManageOrganisation: Bool {
        // UI-only gate. Org catalogue + My Qualifications data are independent of this flag.
        userStore.canManageOrganisationQualifications()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if canManageOrganisation {
                    Picker("Qualifications", selection: $mode) {
                        ForEach(QualificationsHubMode.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }

                Group {
                    if canManageOrganisation && mode == .organisation {
                        organisationQualificationsContent
                    } else {
                        myQualificationsContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Qualifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.blue)
                    }
                }

                if canManageOrganisation && mode == .organisation {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Add") {
                            showingAddQualification = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddQualification) {
                NavigationStack {
                    AddQualificationView()
                        .environmentObject(operativeStore)
                }
            }
            .sheet(item: $qualificationToEdit) { qualification in
                NavigationStack {
                    EditOrganisationQualificationView(qualification: qualification)
                        .environmentObject(operativeStore)
                }
            }
            .task {
                if !canManageOrganisation {
                    mode = .mine
                }
                await resolveMyOperativeIfNeeded()
            }
            .onChange(of: mode) { _, newMode in
                if newMode == .mine {
                    Task { await resolveMyOperativeIfNeeded() }
                }
            }
        }
    }

    @ViewBuilder
    private var organisationQualificationsContent: some View {
        if operativeStore.qualifications.isEmpty {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.gray)

                Text("No Qualifications Added Yet")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Add organisation qualification templates. Staff can then assign them on My Qualifications, with their own expiry dates and certificates.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("Create New Qualification") {
                    showingAddQualification = true
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
        } else {
            List {
                ForEach(operativeStore.qualifications.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { qualification in
                    Button {
                        qualificationToEdit = qualification
                    } label: {
                        QualificationRowView(qualification: qualification)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteQualifications)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var myQualificationsContent: some View {
        if let myOperative {
            OperativeQualificationsEditorView(
                operative: myOperative,
                title: "My Qualifications",
                canEditAssignments: true,
                presentation: .myQualifications,
                usesOwnNavigationStack: false
            )
            .environmentObject(operativeStore)
            .environmentObject(firebaseBackend)
            .environmentObject(notificationService)
        } else if isResolvingMyProfile {
            ProgressView("Loading your qualifications…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Profile not linked",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text(myProfileError ?? "Could not find a staff profile for your account. Ask an admin to check your email matches your operative record.")
            )
        }
    }

    private func deleteQualifications(offsets: IndexSet) {
        let sorted = operativeStore.qualifications.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        for index in offsets {
            let qualification = sorted[index]
            Task {
                await operativeStore.deleteQualification(qualification)
            }
        }
    }

    @MainActor
    private func resolveMyOperativeIfNeeded() async {
        guard myOperative == nil, !isResolvingMyProfile else { return }
        guard let user = userStore.currentUser else {
            myProfileError = "You are not signed in."
            return
        }
        isResolvingMyProfile = true
        defer { isResolvingMyProfile = false }

        if let existing = operativeMatching(email: user.email) {
            myOperative = existing
            return
        }

        if let created = await userStore.ensureOperativeProfileForAppUser(user, operativeStore: operativeStore) {
            myOperative = created
        } else {
            myProfileError = "Could not create a linked profile for your qualifications. Check your account email and try again."
        }
    }

    private func operativeMatching(email: String) -> Operative? {
        let e = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return operativeStore.allOperatives.first {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == e
        }
    }
}

struct QualificationRowView: View {
    let qualification: Qualification

    var body: some View {
        HStack {
            Text(qualification.name)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct AddQualificationView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss

    @State private var qualificationName = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Qualification Details") {
                TextField("Qualification Name", text: $qualificationName)
                    .textInputAutocapitalization(.words)

                Text("Expiration dates and certificates are set when someone assigns this qualification on My Qualifications.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let errorMessage = errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Add Qualification")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    saveQualification()
                }
                .disabled(!isFormValid || isLoading)
                .foregroundStyle(isFormValid && !isLoading ? Color.blue : Color.secondary)
            }
        }
    }

    private var isFormValid: Bool {
        !qualificationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveQualification() {
        guard isFormValid, !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let trimmedName = qualificationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if operativeStore.qualifications.contains(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedName) == .orderedSame
        }) {
            errorMessage = "A qualification with this name already exists."
            isLoading = false
            return
        }

        let qualification = Qualification(
            name: trimmedName,
            hasEndDate: false,
            endDate: nil
        )

        Task { @MainActor in
            await operativeStore.addQualification(qualification)
            isLoading = false
            dismiss()
        }
    }
}

struct EditOrganisationQualificationView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss

    let qualification: Qualification

    @State private var qualificationName: String
    @State private var isLoading = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var showingDeleteConfirm = false

    init(qualification: Qualification) {
        self.qualification = qualification
        _qualificationName = State(initialValue: qualification.name)
    }

    private var trimmedName: String {
        qualificationName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedName.caseInsensitiveCompare(qualification.name.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
            || trimmedName != qualification.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && hasChanges && !isLoading && !isDeleting
    }

    var body: some View {
        Form {
            Section("Qualification") {
                TextField("Name", text: $qualificationName)
                    .textInputAutocapitalization(.words)
            }

            Section {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Text("Delete Qualification")
                    }
                }
                .disabled(isLoading || isDeleting)
            } footer: {
                Text("Deleting removes this template from the organisation list. Existing assignments on staff profiles are not automatically removed.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Edit Qualification")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isLoading ? "Saving…" : "Save") {
                    Task { await saveChanges() }
                }
                .disabled(!canSave)
                .foregroundStyle(canSave ? Color.blue : Color.secondary)
                .fontWeight(canSave ? .semibold : .regular)
            }
        }
        .confirmationDialog(
            "Delete “\(qualification.name)”?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await deleteQualification() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    @MainActor
    private func saveChanges() async {
        guard canSave else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        if operativeStore.qualifications.contains(where: {
            $0.id != qualification.id
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedName) == .orderedSame
        }) {
            errorMessage = "A qualification with this name already exists."
            return
        }

        var updated = qualification
        updated.name = trimmedName
        updated.updatedAt = Date()
        await operativeStore.updateQualification(updated)
        dismiss()
    }

    @MainActor
    private func deleteQualification() async {
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        await operativeStore.deleteQualification(qualification)
        dismiss()
    }
}

#Preview {
    QualificationsManagementView()
        .environmentObject(OperativeStore())
        .environmentObject(UserStore())
        .environmentObject(FirebaseBackend())
        .environmentObject(NotificationService())
}
