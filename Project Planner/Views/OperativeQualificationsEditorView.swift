import SwiftUI
import UniformTypeIdentifiers

/// How the qualifications editor is presented: full catalog (manage users) vs. my profile flow.
enum OperativeQualificationsPresentation: Equatable {
    /// Admin/manager editing a staff member's assigned qualifications.
    case manageQualifications
    /// Only assigned qualifications on the main screen; add via catalog sheet ("My Qualifications").
    case myQualifications
}

struct OperativeQualificationsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService

    let operative: Operative
    let title: String
    let canEditAssignments: Bool
    var presentation: OperativeQualificationsPresentation = .manageQualifications
    /// When false, content is embedded in a parent `NavigationStack` (Qualifications hub).
    var usesOwnNavigationStack: Bool = true

    @State private var selectedQualifications: Set<Qualification>
    @State private var qualificationExpiryDates: [UUID: Date]
    @State private var qualificationCertificateURLs: [UUID: String]
    /// Local temp copies of security-scoped picks, ready to upload on Save.
    @State private var certificateUploadTargets: [UUID: URL] = [:]
    @State private var selectedUploadQualificationId: UUID?
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var baselineQualifications: Set<Qualification>
    @State private var baselineExpiry: [UUID: Date]
    @State private var baselineCerts: [UUID: String]

    @State private var showingAssignQualificationsPicker = false
    @State private var showingListFilters = false
    @State private var qualificationSearchText = ""

    init(
        operative: Operative,
        title: String = "Qualifications",
        canEditAssignments: Bool,
        presentation: OperativeQualificationsPresentation = .manageQualifications,
        usesOwnNavigationStack: Bool = true
    ) {
        self.operative = operative
        self.title = title
        self.canEditAssignments = canEditAssignments
        self.presentation = presentation
        self.usesOwnNavigationStack = usesOwnNavigationStack
        _selectedQualifications = State(initialValue: operative.qualifications)
        _qualificationExpiryDates = State(initialValue: operative.qualificationExpiryDates)
        _qualificationCertificateURLs = State(initialValue: operative.qualificationCertificateURLs)
        _baselineQualifications = State(initialValue: operative.qualifications)
        _baselineExpiry = State(initialValue: operative.qualificationExpiryDates)
        _baselineCerts = State(initialValue: operative.qualificationCertificateURLs)
    }

    private var isMyQualifications: Bool {
        presentation == .myQualifications
    }

    private var hasUnsavedChanges: Bool {
        if !certificateUploadTargets.isEmpty { return true }
        if selectedQualifications != baselineQualifications { return true }
        if qualificationExpiryDates != baselineExpiry { return true }
        if qualificationCertificateURLs != baselineCerts { return true }
        return false
    }

    private var qualificationFilterTrimmed: String {
        qualificationSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredSelectedQualifications: [Qualification] {
        let base = sortedSelectedQualifications
        let q = qualificationFilterTrimmed
        if q.isEmpty { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Group {
            if usesOwnNavigationStack {
                NavigationStack {
                    editorForm
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { editorToolbar }
                }
            } else {
                editorForm
                    .toolbar { editorToolbar }
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
                do {
                    let localCopy = try Self.copySecurityScopedFileToTemp(url)
                    certificateUploadTargets[qualificationId] = localCopy
                    errorMessage = nil
                } catch {
                    errorMessage = "Could not read selected file: \(error.localizedDescription)"
                }
            case .failure(let error):
                errorMessage = "Could not select file: \(error.localizedDescription)"
            }
            selectedUploadQualificationId = nil
        }
        .sheet(isPresented: $showingAssignQualificationsPicker) {
            AssignQualificationsPickerView(selectedQualifications: $selectedQualifications)
                .environmentObject(operativeStore)
        }
        .sheet(isPresented: $showingListFilters) {
            NavigationStack {
                Form {
                    Section("Qualifications") {
                        TextField("Search qualifications", text: $qualificationSearchText)
                            .textInputAutocapitalization(.never)
                    }
                }
                .navigationTitle("Filter list")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingListFilters = false }
                    }
                }
            }
        }
        .onChange(of: operative.updatedAt) { _, _ in
            guard isMyQualifications, !hasUnsavedChanges else { return }
            applyOperativeSnapshot(operative)
        }
    }

    private var editorForm: some View {
        Form {
            if isMyQualifications {
                myQualificationsQualSection
            } else {
                manageQualificationsSections
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundColor(.red)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showingListFilters = true
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
        }
        if isMyQualifications {
            if usesOwnNavigationStack {
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
            } else if hasUnsavedChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        revertToBaseline()
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
                .disabled(isSaving || !canEditAssignments || !hasUnsavedChanges)
                .foregroundColor(
                    hasUnsavedChanges && canEditAssignments && !isSaving ? .blue : .gray
                )
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var manageQualificationsSections: some View {
        Section {
            if operativeStore.qualifications.isEmpty {
                Text("No qualifications available yet. Ask an admin to add organisation qualification templates first.")
                    .foregroundStyle(.secondary)
            } else if filteredSelectedQualifications.isEmpty {
                Text(qualificationFilterTrimmed.isEmpty ? "No qualifications assigned yet." : "No qualifications match this filter.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredSelectedQualifications) { qualification in
                    qualificationRow(qualification)
                }
            }

            Button {
                showingAssignQualificationsPicker = true
            } label: {
                Label("Add qualifications", systemImage: "plus.circle.fill")
            }
            .disabled(!canEditAssignments)
        } header: {
            Text("Current qualifications")
        }
    }

    @ViewBuilder
    private var myQualificationsQualSection: some View {
        Section {
            if operativeStore.qualifications.isEmpty {
                Text("No qualifications have been set up for your organisation yet. Ask a manager or admin to add qualification templates.")
                    .foregroundStyle(.secondary)
            } else if selectedQualifications.isEmpty {
                Text("You have not added any qualifications yet. Tap Add qualifications to pick from your organisation list, then set expiry dates and certificates below.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredSelectedQualifications) { qualification in
                    qualificationRow(qualification)
                }
            }

            Button {
                showingAssignQualificationsPicker = true
            } label: {
                Label("Add qualifications", systemImage: "plus.circle.fill")
            }
            .disabled(!canEditAssignments || operativeStore.qualifications.isEmpty)
        } header: {
            Text("My qualifications")
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
                    Text("Ready to upload: \(pendingFile.lastPathComponent)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Tap Save to store this certificate on your qualifications.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if let existingURLString = qualificationCertificateURLs[qualification.id],
                          !existingURLString.isEmpty {
                    HStack(spacing: 12) {
                        Text("Certificate uploaded")
                            .font(.caption)
                            .foregroundColor(.green)
                        if let url = URL(string: existingURLString) {
                            Button("View certificate") {
                                openURL(url)
                            }
                            .font(.caption)
                        }
                    }
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
        selectedQualifications = baselineQualifications
        qualificationExpiryDates = baselineExpiry
        qualificationCertificateURLs = baselineCerts
        certificateUploadTargets = [:]
        errorMessage = nil
    }

    private func syncBaselineFromWorkingState() {
        baselineQualifications = selectedQualifications
        baselineExpiry = qualificationExpiryDates
        baselineCerts = qualificationCertificateURLs
    }

    private func applyOperativeSnapshot(_ op: Operative) {
        selectedQualifications = op.qualifications
        qualificationExpiryDates = op.qualificationExpiryDates
        qualificationCertificateURLs = op.qualificationCertificateURLs
        certificateUploadTargets = [:]
        syncBaselineFromWorkingState()
    }

    /// FileImporter URLs are security-scoped; copy immediately so Save can still read the bytes.
    private static func copySecurityScopedFileToTemp(_ url: URL) throws -> URL {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? Int64, size > 10 * 1024 * 1024 {
            throw NSError(
                domain: "OperativeQualificationsEditor",
                code: 413,
                userInfo: [NSLocalizedDescriptionKey: "File is too large. Please choose a file smaller than 10MB."]
            )
        }

        let fileName = url.lastPathComponent
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qual-cert-\(UUID().uuidString)-\(fileName)")
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }
        try FileManager.default.copyItem(at: url, to: tempURL)
        return tempURL
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

        var updatedOperative = operativeStore.allOperatives.first(where: { $0.id == operative.id }) ?? operative
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

        // Reschedule local expiry reminders (3m / 1m / 1w / 1d) for this user and line managers.
        await notificationService.refreshQualificationExpiryReminders()

        if dismissAfterSave {
            dismiss()
        }
        return true
    }
}
