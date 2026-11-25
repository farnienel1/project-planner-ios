//
//  SubcontractorDocumentsSection.swift
//  Project Planner
//
//  RULEBOOK 1.80.0 §30 (owner decision 24 Nov, option (a)): a subcontractor's Insurance and RAMS documents on the
//  firm's page. Staff only (`canManageSubcontractors`, which already gates the Sub Contractors screens). Every rule —
//  the path, the lists, the expiry wording, who may delete the file — is the rulebook's; this view only shows it.
//

import SwiftUI
import UniformTypeIdentifiers

struct SubcontractorDocumentsSection: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.openURL) private var openURLAction
    let subcontractor: Subcontractor

    private static let allowedTypes: [UTType] = [.pdf, .jpeg, .png, .heic, .heif, .webP]

    @State private var importingKind: String?
    @State private var showingImporter = false
    /// Owner 25 Nov: the files just picked, waiting for the optional expiry date before they upload.
    @State private var pendingUpload: SubcontractorDocumentPendingUpload?
    /// The document whose expiry is being changed ("Edit expiry").
    @State private var editingExpiry: SubcontractorDocumentExpiryEdit?
    @State private var busyKind: String?
    @State private var message: String?

    private var organizationId: String { firebaseBackend.currentOrganization?.firestoreDocumentId ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(CanonicalBusinessEngine.subcontractorDocumentKinds, id: \.self) { kind in
                kindBlock(kind)
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
        .sheet(item: $pendingUpload) { pending in
            SubcontractorDocumentUploadSheet(pending: pending) { expiresOn in
                await upload(urls: pending.urls, kind: pending.kind, expiresOn: expiresOn)
            }
        }
        .sheet(item: $editingExpiry) { edit in
            SubcontractorDocumentExpirySheet(edit: edit) { expiresOn in
                await saveExpiry(edit, expiresOn: expiresOn)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: Self.allowedTypes, allowsMultipleSelection: true) { result in
            guard let kind = importingKind else { return }
            importingKind = nil
            switch result {
            case .success(let urls):
                // Owner 25 Nov: several certificates at once; the expiry is asked only now, for these files.
                guard !urls.isEmpty else { return }
                pendingUpload = SubcontractorDocumentPendingUpload(kind: kind, urls: urls)
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func kindBlock(_ kind: String) -> some View {
        let entries = subcontractor.documents?.entries(kind) ?? []
        let label = CanonicalBusinessEngine.subcontractorDocumentLabel(kind)
        HStack(alignment: .firstTextBaseline) {
            Text("\(label) · \(entries.count)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.horizontal, 4)
            Spacer()
            Button {
                message = nil
                importingKind = kind
                showingImporter = true
            } label: {
                if busyKind == kind {
                    ProgressView()
                } else {
                    Label("Upload", systemImage: "arrow.up.doc")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .tint(PPColor.brand)
            .disabled(busyKind != nil)
            .accessibilityIdentifier("subcontractorDocuments.upload.\(kind)")
        }
        .padding(.top, 12)
        PPGroupedCard {
            if entries.isEmpty {
                Text(CanonicalBusinessEngine.subcontractorDocumentsEmptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    documentRow(entry, kind: kind)
                    if index < entries.count - 1 { PPRowDivider() }
                }
            }
        }
    }

    private func documentRow(_ entry: RulebookSubcontractorDocument, kind: String) -> some View {
        let expiry = CanonicalBusinessEngine.subcontractorDocumentExpiryState(
            expiresOn: entry.expiresOn,
            timeZone: OrganizationRulebookContext.timeZoneIdentifier
        )
        return HStack(spacing: 12) {
            Image(systemName: entry.contentType == "application/pdf" ? "doc.richtext" : "photo")
                .foregroundStyle(PPColor.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .lineLimit(2)
                Text(expiry.label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(expiryColor(expiry.state))
            }
            Spacer(minLength: 8)
            Menu {
                Button("View") { Task { await open(entry) } }
                Button("Edit expiry") { editingExpiry = SubcontractorDocumentExpiryEdit(kind: kind, entry: entry) }
                Button("Remove", role: .destructive) { Task { await remove(entry, kind: kind) } }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .accessibilityLabel("Actions for \(entry.name)")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
    }

    private func expiryColor(_ state: String) -> Color {
        switch state {
        case "expired", "expiresToday": return .red
        case "expiringSoon": return .orange
        case "valid": return .green
        default: return .secondary
        }
    }

    /// Uploads the picked files one by one with the expiry chosen for them (nil = none). Returns nil when every file
    /// saved, else the message to show (the files that did save stay on the list).
    private func upload(urls: [URL], kind: String, expiresOn: String?) async -> String? {
        busyKind = kind
        defer { busyKind = nil }
        var failures: [String] = []
        for url in urls {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            do {
                // Read the file off the main thread (a large PDF from iCloud can take a while).
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                try await firebaseBackend.uploadSubcontractorDocument(
                    data: data,
                    fileName: url.lastPathComponent,
                    contentType: contentType,
                    organizationId: organizationId,
                    subcontractorId: subcontractor.documentId,
                    kind: kind,
                    expiresOn: expiresOn
                )
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let result = failures.isEmpty ? nil : "Not uploaded — " + failures.joined(separator: " · ")
        message = result
        return result
    }

    /// Nil when saved, else the message the sheet shows.
    private func saveExpiry(_ edit: SubcontractorDocumentExpiryEdit, expiresOn: String?) async -> String? {
        do {
            try await firebaseBackend.setSubcontractorDocumentExpiry(
                organizationId: organizationId,
                subcontractorId: subcontractor.documentId,
                kind: edit.kind,
                entryId: edit.entry.id,
                expiresOn: expiresOn
            )
            message = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func open(_ entry: RulebookSubcontractorDocument) async {
        do {
            // Staff-only Storage read (§24); opened only through `safeExternalUrl` (https).
            let url = try await firebaseBackend.subcontractorDocumentDownloadURL(path: entry.path)
            guard let safe = CanonicalBusinessEngine.safeExternalURL(url) else {
                message = "This file cannot be opened."
                return
            }
            openURLAction(safe)
        } catch {
            message = error.localizedDescription
        }
    }

    private func remove(_ entry: RulebookSubcontractorDocument, kind: String) async {
        let role = userStore.displayUser.map { UserStore.staffAccountRole(for: $0) }
            ?? CanonicalBusinessEngine.CanonicalStaffAccountRole(isSuperAdmin: false, isAdmin: false, isManager: false, isOperativeMode: false)
        do {
            let kept = try await firebaseBackend.removeSubcontractorDocument(
                organizationId: organizationId,
                subcontractorId: subcontractor.documentId,
                kind: kind,
                entry: entry,
                viewerRole: role
            )
            message = kept ? CanonicalBusinessEngine.fileKeptOnRemoveCopy : nil
        } catch {
            message = error.localizedDescription
        }
    }
}

/// One document whose expiry is being changed.
struct SubcontractorDocumentExpiryEdit: Identifiable {
    let kind: String
    let entry: RulebookSubcontractorDocument
    var id: String { "\(kind)|\(entry.id)" }
}

/// "Edit expiry": set, change or clear one document's expiry (`subcontractorDocumentExpiryWriteFields`).
private struct SubcontractorDocumentExpirySheet: View {
    @Environment(\.dismiss) private var dismiss
    let edit: SubcontractorDocumentExpiryEdit
    let save: (String?) async -> String?

    @State private var hasExpiry: Bool
    @State private var date: Date
    @State private var saving = false
    @State private var error: String?

    init(edit: SubcontractorDocumentExpiryEdit, save: @escaping (String?) async -> String?) {
        self.edit = edit
        self.save = save
        let stored = edit.entry.expiresOn.flatMap { OrganizationRulebookContext.date(fromDayKey: $0) }
        _hasExpiry = State(initialValue: stored != nil)
        _date = State(initialValue: stored ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(edit.entry.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Toggle(CanonicalBusinessEngine.subcontractorDocumentExpiryLabel, isOn: $hasExpiry)
                        .accessibilityIdentifier("subcontractorDocuments.editExpiry.toggle")
                    if hasExpiry {
                        DatePicker("Expiry date", selection: $date, displayedComponents: .date)
                            .closesCalendarOnDayPick(date)
                            .environment(\.timeZone, OrganizationRulebookContext.timeZone)
                    }
                }
                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit expiry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            error = await save(hasExpiry ? OrganizationRulebookContext.dayKey(date) : nil)
                            saving = false
                            if error == nil { dismiss() }
                        }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("subcontractorDocuments.editExpiry.save")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Files picked for one kind (Insurance or RAMS), waiting for the optional expiry date.
struct SubcontractorDocumentPendingUpload: Identifiable {
    let id = UUID()
    let kind: String
    let urls: [URL]
}

/// Owner 25 Nov: after choosing the files, an optional expiry date for them, then Upload. One date for the files
/// picked together; each document's date can be changed later with "Edit expiry".
private struct SubcontractorDocumentUploadSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pending: SubcontractorDocumentPendingUpload
    let upload: (String?) async -> String?

    @State private var hasExpiry = false
    @State private var date = Date()
    @State private var uploading = false

    var body: some View {
        NavigationStack {
            Form {
                Section(CanonicalBusinessEngine.subcontractorDocumentLabel(pending.kind)) {
                    ForEach(pending.urls, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "photo")
                            .font(.subheadline)
                            .lineLimit(2)
                    }
                }
                Section {
                    Toggle(CanonicalBusinessEngine.subcontractorDocumentExpiryLabel, isOn: $hasExpiry)
                        .accessibilityIdentifier("subcontractorDocuments.upload.expiryToggle")
                    if hasExpiry {
                        DatePicker("Expiry date", selection: $date, displayedComponents: .date)
                            .closesCalendarOnDayPick(date)
                            .environment(\.timeZone, OrganizationRulebookContext.timeZone)
                    }
                } footer: {
                    if pending.urls.count > 1 {
                        Text("The date applies to all \(pending.urls.count) files. Change one later with Edit expiry.")
                    }
                }
            }
            .navigationTitle(pending.urls.count == 1 ? "Upload document" : "Upload \(pending.urls.count) documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(uploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if uploading {
                        ProgressView()
                    } else {
                        Button("Upload") {
                            uploading = true
                            Task {
                                // Closes either way: files that saved are on the list, and any that did not are named
                                // under the section (retrying here would upload the saved ones a second time).
                                _ = await upload(hasExpiry ? OrganizationRulebookContext.dayKey(date) : nil)
                                uploading = false
                                dismiss()
                            }
                        }
                        .accessibilityIdentifier("subcontractorDocuments.upload.confirm")
                    }
                }
            }
        }
        .interactiveDismissDisabled(uploading)
        .presentationDetents([.medium, .large])
    }
}
