//
//  AddQualificationsCatalogView.swift
//  Project Planner
//
//  Pick organisation qualifications not yet on the operative profile; set expiry and attach certificates before saving.
//

import SwiftUI
import UniformTypeIdentifiers

struct AddQualificationsCatalogView: View {
    @Environment(\.dismiss) private var dismiss

    let catalog: [Qualification]
    @Binding var errorMessage: String?
    /// Merges selections into the profile and persists (uploads certificates). Return `true` if saved so the sheet can dismiss.
    let onCommit: (Set<Qualification>, [UUID: Date], [UUID: URL]) async -> Bool

    @State private var draftSelected: Set<Qualification> = []
    @State private var draftExpiry: [UUID: Date] = [:]
    @State private var draftPendingCerts: [UUID: URL] = [:]
    @State private var pickCertificateForId: UUID?
    @State private var isCommitting = false

    var body: some View {
        NavigationStack {
            Form {
                if catalog.isEmpty {
                    Section {
                        Text("All organisation qualifications are already on your profile.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Organisation qualifications") {
                        ForEach(catalog.sorted(by: { $0.name < $1.name })) { qualification in
                            draftRow(qualification)
                        }
                    }
                }
                if let msg = errorMessage, !msg.isEmpty {
                    Section {
                        Text(msg)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add qualifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCommitting ? "Saving…" : "Save") {
                        Task { @MainActor in
                            isCommitting = true
                            defer { isCommitting = false }
                            let ok = await onCommit(draftSelected, draftExpiry, draftPendingCerts)
                            if ok { dismiss() }
                        }
                    }
                    .disabled(draftSelected.isEmpty || isCommitting)
                    .fontWeight(.semibold)
                }
            }
            .fileImporter(
                isPresented: Binding(
                    get: { pickCertificateForId != nil },
                    set: { if !$0 { pickCertificateForId = nil } }
                ),
                allowedContentTypes: [.image, .pdf]
            ) { result in
                guard let qid = pickCertificateForId else { return }
                switch result {
                case .success(let url):
                    draftPendingCerts[qid] = url
                    errorMessage = nil
                case .failure(let error):
                    errorMessage = "Could not select file: \(error.localizedDescription)"
                }
                pickCertificateForId = nil
            }
        }
    }

    @ViewBuilder
    private func draftRow(_ qualification: Qualification) -> some View {
        let isOn = draftSelected.contains(qualification)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(qualification.name)
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.blue : Color.gray)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                toggleDraft(qualification)
            }

            if isOn {
                DatePicker(
                    "Expiry date",
                    selection: Binding(
                        get: { draftExpiry[qualification.id] ?? Date() },
                        set: { draftExpiry[qualification.id] = $0 }
                    ),
                    displayedComponents: .date
                )

                HStack {
                    Button("Remove expiry") {
                        draftExpiry.removeValue(forKey: qualification.id)
                    }
                    .disabled(draftExpiry[qualification.id] == nil)

                    Spacer()

                    Button("Upload certificate") {
                        pickCertificateForId = qualification.id
                    }
                }
                .font(.caption)

                if let pending = draftPendingCerts[qualification.id] {
                    Text("Pending upload: \(pending.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No certificate selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if draftPendingCerts[qualification.id] != nil {
                    Button("Remove certificate") {
                        draftPendingCerts.removeValue(forKey: qualification.id)
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func toggleDraft(_ qualification: Qualification) {
        if draftSelected.contains(qualification) {
            draftSelected.remove(qualification)
            draftExpiry.removeValue(forKey: qualification.id)
            draftPendingCerts.removeValue(forKey: qualification.id)
        } else {
            draftSelected.insert(qualification)
        }
    }
}
