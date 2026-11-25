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
    /// Expiry for the next upload, one per kind (Insurance and RAMS never share a date).
    @State private var setExpiry: [String: Bool] = [:]
    @State private var expiryDate: [String: Date] = [:]
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
        .sheet(item: $editingExpiry) { edit in
            SubcontractorDocumentExpirySheet(edit: edit) { expiresOn in
                await saveExpiry(edit, expiresOn: expiresOn)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: Self.allowedTypes, allowsMultipleSelection: false) { result in
            guard let kind = importingKind else { return }
            importingKind = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await upload(url: url, kind: kind) }
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
        Toggle(CanonicalBusinessEngine.subcontractorDocumentExpiryLabel, isOn: expiryToggle(kind))
            .font(.subheadline)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("subcontractorDocuments.setExpiry.\(kind)")
        if setExpiry[kind] == true {
            DatePicker("\(label) expiry date", selection: expiryDateBinding(kind), displayedComponents: .date)
                .closesCalendarOnDayPick(expiryDateBinding(kind).wrappedValue)
                .environment(\.timeZone, OrganizationRulebookContext.timeZone)
                .font(.subheadline)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("subcontractorDocuments.expiryDate.\(kind)")
        }
    }

    private func expiryToggle(_ kind: String) -> Binding<Bool> {
        Binding(get: { setExpiry[kind] ?? false }, set: { setExpiry[kind] = $0 })
    }

    private func expiryDateBinding(_ kind: String) -> Binding<Date> {
        Binding(get: { expiryDate[kind] ?? Date() }, set: { expiryDate[kind] = $0 })
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

    private func upload(url: URL, kind: String) async {
        busyKind = kind
        defer { busyKind = nil }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            // Read the file off the main thread (a large PDF from iCloud can take a while).
            data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        } catch {
            message = error.localizedDescription
            return
        }
        let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        let expiresOn = setExpiry[kind] == true ? OrganizationRulebookContext.dayKey(expiryDate[kind] ?? Date()) : nil
        do {
            try await firebaseBackend.uploadSubcontractorDocument(
                data: data,
                fileName: url.lastPathComponent,
                contentType: contentType,
                organizationId: organizationId,
                subcontractorId: subcontractor.documentId,
                kind: kind,
                expiresOn: expiresOn
            )
            setExpiry[kind] = false
            expiryDate[kind] = nil
            message = nil
        } catch {
            message = error.localizedDescription
        }
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
