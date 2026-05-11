import SwiftUI
import UniformTypeIdentifiers

struct OperativeQualificationsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let operative: Operative
    let title: String
    let canEditAssignments: Bool
    
    @State private var selectedQualifications: Set<Qualification>
    @State private var selectedSkills: Set<String>
    @State private var qualificationExpiryDates: [UUID: Date]
    @State private var qualificationCertificateURLs: [UUID: String]
    @State private var certificateUploadTargets: [UUID: URL] = [:]
    @State private var selectedUploadQualificationId: UUID?
    @State private var isSaving = false
    @State private var errorMessage: String?
    
    init(
        operative: Operative,
        title: String = "Skills & Qualifications",
        canEditAssignments: Bool
    ) {
        self.operative = operative
        self.title = title
        self.canEditAssignments = canEditAssignments
        _selectedQualifications = State(initialValue: operative.qualifications)
        _selectedSkills = State(initialValue: operative.skills)
        _qualificationExpiryDates = State(initialValue: operative.qualificationExpiryDates)
        _qualificationCertificateURLs = State(initialValue: operative.qualificationCertificateURLs)
    }
    
    var body: some View {
        NavigationStack {
            Form {
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        Task { await saveChanges() }
                    }
                    .disabled(isSaving || !canEditAssignments)
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
        }
    }
    
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
    
    @MainActor
    private func saveChanges() async {
        guard canEditAssignments else { return }
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            errorMessage = "No organization loaded. Please retry."
            return
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
                return
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
        dismiss()
    }
}

