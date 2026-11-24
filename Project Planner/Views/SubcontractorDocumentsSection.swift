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
    @State private var setExpiry = false
    @State private var expiryDate = Date()
    @State private var busyKind: String?
    @State private var message: String?

    private var organizationId: String { firebaseBackend.currentOrganization?.firestoreDocumentId ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(CanonicalBusinessEngine.subcontractorDocumentKinds, id: \.self) { kind in
                kindBlock(kind)
            }
            Toggle(CanonicalBusinessEngine.subcontractorDocumentExpiryLabel, isOn: $setExpiry)
                .font(.subheadline)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("subcontractorDocuments.setExpiry")
            if setExpiry {
                DatePicker("Expiry date", selection: $expiryDate, displayedComponents: .date)
                    .environment(\.timeZone, OrganizationRulebookContext.timeZone)
                    .font(.subheadline)
                    .padding(.horizontal, 4)
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
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
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            message = error.localizedDescription
            return
        }
        busyKind = kind
        defer { busyKind = nil }
        let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        do {
            try await firebaseBackend.uploadSubcontractorDocument(
                data: data,
                fileName: url.lastPathComponent,
                contentType: contentType,
                organizationId: organizationId,
                subcontractorId: subcontractor.documentId,
                kind: kind,
                expiresOn: setExpiry ? OrganizationRulebookContext.dayKey(expiryDate) : nil
            )
            setExpiry = false
            message = nil
        } catch {
            message = error.localizedDescription
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
