import SwiftUI
import UniformTypeIdentifiers

/// How the qualifications editor is presented: full catalog (manage users) vs. my profile flow.
enum OperativeQualificationsPresentation: Equatable {
    /// Lists every organisation qualification and skills (admin/manager editing an operative).
    case manageSkillsAndQualifications
    /// Only assigned qualifications on the main screen; add via catalog sheet (operative "My Qualifications").
    case myQualifications
}

struct OperativeQualificationsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    let operative: Operative
    let title: String
    let canEditAssignments: Bool
    var presentation: OperativeQualificationsPresentation = .manageSkillsAndQualifications

    @State private var selectedQualifications: Set<Qualification>
    @State private var selectedSkills: Set<String>
    @State private var qualificationExpiryDates: [UUID: Date]
    @State private var qualificationCertificateURLs: [UUID: String]
    @State private var certificateUploadTargets: [UUID: URL] = [:]
    @State private var selectedUploadQualificationId: UUID?
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var baselineSkills: Set<String>
    @State private var baselineQualifications: Set<Qualification>
    @State private var baselineExpiry: [UUID: Date]
    @State private var baselineCerts: [UUID: String]

    @State private var showingAddQualifications = false

    init(
        operative: Operative,
        title: String = "Skills & Qualifications",
        canEditAssignments: Bool,
        presentation: OperativeQualificationsPresentation = .manageSkillsAndQualifications
    ) {
        self.operative = operative
        self.title = title
        self.canEditAssignments = canEditAssignments
        self.presentation = presentation
        _selectedQualifications = State(initialValue: operative.qualifications)
        _selectedSkills = State(initialValue: operative.skills)
        _qualificationExpiryDates = State(initialValue: operative.qualificationExpiryDates)
        _qualificationCertificateURLs = State(initialValue: operative.qualificationCertificateURLs)
        _baselineSkills = State(initialValue: operative.skills)
        _baselineQualifications = State(initialValue: operative.qualifications)
        _baselineExpiry = State(initialValue: operative.qualificationExpiryDates)
        _baselineCerts = State(initialValue: operative.qualificationCertificateURLs)
    }

    private var isMyQualifications: Bool {
        presentation == .myQualifications
    }

    private var hasUnsavedChanges: Bool {
        if !certificateUploadTargets.isEmpty { return true }
        if selectedSkills != baselineSkills { return true }
        if selectedQualifications != baselineQualifications { return true }
        if qualificationExpiryDates != baselineExpiry { return true }
        if qualificationCertificateURLs != baselineCerts { return true }
        return false
    }

    /// Qualifications in the organisation catalogue not yet on this profile (for Add flow).
    private var addCatalogQualifications: [Qualification] {
        operativeStore.qualifications.filter { q in
            !selectedQualifications.contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isMyQualifications {
                    myQualificationsQualSection
                } else {
                    manageQualificationsCatalogSection
                }

                if !operativeStore.skills.isEmpty {
                    Section("Available Skills") {
                        ForEach(Array(operativeStore.skills).sorted(), id: \.self) { skill in
                            HStack {
                                Text(skill)
                                Spacer()
                                Image(systemName: selectedSkills.contains(skill) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedSkills.contains(skill) ? .blue : .gray)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard canEditAssignments else { return }
                                if selectedSkills.contains(skill) {
                                    selectedSkills.remove(skill)
                                } else {
                                    selectedSkills.insert(skill)
                                }
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isMyQualifications {
                    ToolbarItem(placement: .cancellationAction) {
                        if hasUnsavedChanges {
                            Button("Cancel") {
                                revertToBaseline()
                            }
                        } else {
                            Button("Done") {
                                dismiss()
                            }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Saving…" : "Save") {
                            Task { await saveChanges(dismissAfterSave: false, mergeAdditions: nil) }
                        }
                        .disabled(isSaving || !canEditAssignments || !hasUnsavedChanges)
                        .foregroundColor(
                            hasUnsavedChanges && canEditAssignments && !isSaving ? .blue : .gray
                        )
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Saving…" : "Save") {
                            Task { _ = await saveChanges(dismissAfterSave: true, mergeAdditions: nil) }
                        }
                        .disabled(isSaving || !canEditAssignments)
                    }
                }
            }
            .fileImporter(
                isPresented: Binding(
                    get: { selectedUploadQualificationId != nil },
                    set: { if !$0 { selectedUploadQualificationId = nil } }
                ),
                allowedContentTypes: [.image, .pdf]
            ) { result in
                guard let qualificationId = selectedUploadQualificationId else { return }
                switch result {
                case .success(let url):
                    certificateUploadTargets[qualificationId] = url
                    errorMessage = nil
                case .failure(let error):
                    errorMessage = "Could not select file: \(error.localizedDescription)"
                }
                selectedUploadQualificationId = nil
            }
            .sheet(isPresented: $showingAddQualifications) {
                AddQualificationsCatalogView(
                    catalog: addCatalogQualifications,
                    errorMessage: $errorMessage,
                    onCommit: { added, newExpiries, newPending in
                        await saveChanges(
                            dismissAfterSave: false,
                            mergeAdditions: (added, newExpiries, newPending)
                        )
                    }
                )
            }
            .onChange(of: operative.updatedAt) { _, _ in
                guard isMyQualifications, !hasUnsavedChanges else { return }
                applyOperativeSnapshot(operative)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var myQualificationsQualSection: some View {
        Section {
            if operativeStore.qualifications.isEmpty {
                Text("No qualifications have been set up for your organisation yet. Ask a manager or admin to add qualification templates.")
                    .foregroundStyle(.secondary)
            } else if selectedQualifications.isEmpty {
                Text("You have not added any qualifications yet. Tap Add qualifications to choose from your organisation’s list, set expiry dates, and attach certificates.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedSelectedQualifications) { qualification in
                    qualificationRow(qualification)
                }
            }

            Button {
                showingAddQualifications = true
            } label: {
                Label("Add qualifications", systemImage: "plus.circle.fill")
            }
            .disabled(!canEditAssignments || operativeStore.qualifications.isEmpty)
        } header: {
            Text("My qualifications")
        }
    }

    @ViewBuilder
    private var manageQualificationsCatalogSection: some View {
        if operativeStore.qualifications.isEmpty {
            Section {
                Text("No qualifications available yet. Ask a manager or admin to create qualification templates.")
                    .foregroundColor(.secondary)
            }
        } else {
            Section("Available Qualifications") {
                ForEach(operativeStore.qualifications.sorted(by: { $0.name < $1.name })) { qualification in
                    qualificationRow(qualification)
                }
            }
        }
    }

    private var sortedSelectedQualifications: [Qualification] {
        selectedQualifications.sorted(by: { $0.name < $1.name })
    }

    // MARK: - Row

    @ViewBuilder
    private func qualificationRow(_ qualification: Qualification) -> some View {
        let isSelected = selectedQualifications.contains(qualification)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(qualification.name)
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .gray)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard canEditAssignments else { return }
                toggleQualification(qualification)
            }

            if isSelected {
                DatePicker(
                    "Expiry Date",
                    selection: Binding(
                        get: { qualificationExpiryDates[qualification.id] ?? Date() },
                        set: { qualificationExpiryDates[qualification.id] = $0 }
                    ),
                    displayedComponents: .date
                )
                .disabled(!canEditAssignments)

                HStack {
                    Button("Remove Expiry") {
                        qualificationExpiryDates.removeValue(forKey: qualification.id)
                    }
                    .disabled(!canEditAssignments || qualificationExpiryDates[qualification.id] == nil)

                    Spacer()

                    Button("Upload Certificate") {
                        selectedUploadQualificationId = qualification.id
                    }
                    .disabled(!canEditAssignments)
                }
                .font(.caption)

                if let pendingFile = certificateUploadTargets[qualification.id] {
                    Text("Pending upload: \(pendingFile.lastPathComponent)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if let existingURL = qualificationCertificateURLs[qualification.id], !existingURL.isEmpty {
                    Text("Certificate uploaded")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text("No certificate uploaded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if qualificationCertificateURLs[qualification.id] != nil || certificateUploadTargets[qualification.id] != nil {
                    Button("Remove Certificate") {
                        qualificationCertificateURLs.removeValue(forKey: qualification.id)
                        certificateUploadTargets.removeValue(forKey: qualification.id)
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                    .disabled(!canEditAssignments)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func toggleQualification(_ qualification: Qualification) {
        if selectedQualifications.contains(qualification) {
            selectedQualifications.remove(qualification)
            qualificationExpiryDates.removeValue(forKey: qualification.id)
            qualificationCertificateURLs.removeValue(forKey: qualification.id)
            certificateUploadTargets.removeValue(forKey: qualification.id)
        } else {
            selectedQualifications.insert(qualification)
        }
    }

    private func revertToBaseline() {
        selectedSkills = baselineSkills
        selectedQualifications = baselineQualifications
        qualificationExpiryDates = baselineExpiry
        qualificationCertificateURLs = baselineCerts
        certificateUploadTargets = [:]
        errorMessage = nil
    }

    private func syncBaselineFromWorkingState() {
        baselineSkills = selectedSkills
        baselineQualifications = selectedQualifications
        baselineExpiry = qualificationExpiryDates
        baselineCerts = qualificationCertificateURLs
    }

    private func applyOperativeSnapshot(_ op: Operative) {
        selectedQualifications = op.qualifications
        selectedSkills = op.skills
        qualificationExpiryDates = op.qualificationExpiryDates
        qualificationCertificateURLs = op.qualificationCertificateURLs
        certificateUploadTargets = [:]
        syncBaselineFromWorkingState()
    }

    @MainActor
    @discardableResult
    private func saveChanges(
        dismissAfterSave: Bool,
        mergeAdditions: (Set<Qualification>, [UUID: Date], [UUID: URL])?
    ) async -> Bool {
        guard canEditAssignments else { return false }
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            errorMessage = "No organization loaded. Please retry."
            return false
        }

        let mergeRollback: (
            quals: Set<Qualification>,
            expiry: [UUID: Date],
            pending: [UUID: URL]
        )?
        if let mergeAdditions {
            let (added, newExpiries, newPending) = mergeAdditions
            mergeRollback = (selectedQualifications, qualificationExpiryDates, certificateUploadTargets)
            selectedQualifications.formUnion(added)
            for (id, date) in newExpiries {
                qualificationExpiryDates[id] = date
            }
            for (id, url) in newPending {
                certificateUploadTargets[id] = url
            }
        } else {
            mergeRollback = nil
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        var updatedCertificateURLs = qualificationCertificateURLs

        for (qualificationId, fileURL) in certificateUploadTargets {
            do {
                let data = try Data(contentsOf: fileURL)
                let contentType: String
                if fileURL.pathExtension.lowercased() == "pdf" {
                    contentType = "application/pdf"
                } else {
                    contentType = "image/jpeg"
                }

                let uploadedURL = try await firebaseBackend.uploadQualificationDocument(
                    data: data,
                    organizationId: organizationId,
                    operativeId: operative.id,
                    qualificationId: qualificationId,
                    fileName: fileURL.lastPathComponent,
                    contentType: contentType
                )
                updatedCertificateURLs[qualificationId] = uploadedURL
            } catch {
                errorMessage = "Upload failed for one of the certificates: \(error.localizedDescription)"
                if let mergeRollback {
                    selectedQualifications = mergeRollback.quals
                    qualificationExpiryDates = mergeRollback.expiry
                    certificateUploadTargets = mergeRollback.pending
                }
                return false
            }
        }

        var updatedOperative = operative
        updatedOperative.skills = selectedSkills
        updatedOperative.qualifications = selectedQualifications
        updatedOperative.qualificationExpiryDates = qualificationExpiryDates.filter { entry in
            selectedQualifications.contains(where: { $0.id == entry.key })
        }
        updatedOperative.qualificationCertificateURLs = updatedCertificateURLs.filter { entry in
            selectedQualifications.contains(where: { $0.id == entry.key })
        }
        updatedOperative.updatedAt = Date()

        await operativeStore.updateOperative(updatedOperative)

        qualificationCertificateURLs = updatedOperative.qualificationCertificateURLs
        certificateUploadTargets = [:]
        syncBaselineFromWorkingState()

        if dismissAfterSave {
            dismiss()
        }
        return true
    }
}
