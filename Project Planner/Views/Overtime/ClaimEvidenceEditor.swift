//
//  ClaimEvidenceEditor.swift
//  Project Planner
//
//  RULEBOOK 1.45.0 (owner decision 14 Nov): the one iOS attach control for claim evidence — timesheet price work and
//  expense entries (§8) and PAYE Add / Edit Price Work and Expense (§26). Take photo, Choose photo, Add site audit (a
//  frozen PDF copy of one of the person's personal site audits) and Add file, laid out with the app design kit
//  (`PayeClaimEvidenceSourceButton`). Every label is the rulebook's (`claimEvidence.ts`); this file only picks files,
//  uploads them into the person's own claim folder on save (`uploadPayeClaimEvidence`, `payeClaimEvidencePath`) and
//  shows them. Nothing is decided here.
//

import FirebaseStorage
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The evidence card: saved files (`existing`, kept as they are) and picked ones (`pending`, uploaded on save).
struct ClaimEvidenceEditor: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Binding var existing: [PayeClaimEvidence]
    @Binding var pending: [PendingPayeClaimEvidence]
    /// A photo or file that could not be added, or the rulebook's evidence message for this card.
    @Binding var message: String?
    /// Expenses: at least one; price work: optional (`EXPENSE_EVIDENCE_REQUIRED_MESSAGE`).
    let required: Bool
    let identifier: String

    @State private var pickingPhoto: UIImagePickerController.SourceType?
    @State private var pickingFile = false
    @State private var pickingAudit = false
    @State private var viewing: IdentifiableURL?

    private var count: Int { existing.count + pending.count }

    var body: some View {
        let canPickMore = count < CanonicalBusinessEngine.payeClaimEvidenceMax
        let well = RoundedRectangle(cornerRadius: 14, style: .continuous)
        PayeClaimFormCard(
            title: "\(CanonicalBusinessEngine.claimEvidenceHeading) \(required ? "(at least one)" : "(optional)")",
            symbol: "paperclip",
            family: .trade,
            note: CanonicalBusinessEngine.claimEvidenceHelpText,
            message: message,
            identifier: identifier
        ) {
            if count > 0 {
                VStack(spacing: 0) {
                    ForEach(Array(existing.enumerated()), id: \.element.path) { index, entry in
                        if index > 0 { Divider().padding(.leading, 58) }
                        ClaimSavedEvidenceRow(entry: entry, onOpen: { Task { await open(entry) } }) {
                            existing.removeAll { $0.path == entry.path }
                        }
                    }
                    ForEach(Array(pending.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 || !existing.isEmpty { Divider().padding(.leading, 58) }
                        PayeClaimAttachedEvidenceRow(entry: entry) {
                            pending.removeAll { $0.id == entry.id }
                        }
                    }
                }
                .background(PPColor.well, in: well)
            }
            if canPickMore {
                VStack(spacing: 0) {
                    PayeClaimEvidenceSourceButton(
                        title: CanonicalBusinessEngine.claimEvidenceTakePhotoLabel,
                        symbol: "camera",
                        family: .sites,
                        isEnabled: UIImagePickerController.isSourceTypeAvailable(.camera),
                        identifier: "\(identifier).camera"
                    ) { pickingPhoto = .camera }
                    PPRowDivider()
                    PayeClaimEvidenceSourceButton(
                        title: CanonicalBusinessEngine.claimEvidenceChoosePhotoLabel,
                        symbol: "photo.on.rectangle",
                        family: .people,
                        identifier: "\(identifier).library"
                    ) { pickingPhoto = .photoLibrary }
                    PPRowDivider()
                    PayeClaimEvidenceSourceButton(
                        title: CanonicalBusinessEngine.claimEvidenceAddSiteAuditLabel,
                        symbol: "checklist",
                        family: .trade,
                        identifier: "\(identifier).audit"
                    ) { pickingAudit = true }
                    PPRowDivider()
                    PayeClaimEvidenceSourceButton(
                        title: CanonicalBusinessEngine.claimEvidenceAddFileLabel,
                        symbol: "doc",
                        family: .plan,
                        identifier: "\(identifier).file"
                    ) { pickingFile = true }
                }
                .background(PPColor.well, in: well)
                .clipShape(well)
            } else {
                Text(CanonicalBusinessEngine.payeClaimText("PAYE_CLAIM_EVIDENCE_LIMIT_MESSAGE", fallback: "Up to 20 pieces of evidence."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: Binding(
            get: { pickingPhoto.map(PayeClaimPickerSource.init) },
            set: { pickingPhoto = $0?.sourceType }
        )) { source in
            PayeClaimImagePicker(sourceType: source.sourceType) { image in
                addPhoto(image)
            }
        }
        .sheet(isPresented: $pickingFile) {
            PayeClaimDocumentPicker { url in
                addFile(url)
            }
        }
        .sheet(isPresented: $pickingAudit) {
            PersonalSiteAuditPickerSheet { audit in
                pending.append(PendingPayeClaimEvidence(
                    label: CanonicalBusinessEngine.personalSiteAuditTitle(audit),
                    source: .audit(audit)
                ))
                message = nil
            }
            .environmentObject(firebaseBackend)
        }
        .sheet(item: $viewing) { target in
            InAppRemoteDocumentViewer(remoteURL: target.url, title: "Evidence", noun: "evidence")
        }
    }

    private func open(_ entry: PayeClaimEvidence) async {
        do {
            let url = try await Storage.storage().reference(withPath: entry.path).downloadURL()
            viewing = IdentifiableURL(url)
        } catch {
            message = "\(entry.name) could not be opened."
        }
    }

    /// Every photo becomes a JPEG (`jpegDataFittingUploadLimit`) so the report and invoice can draw it full size.
    private func addPhoto(_ image: UIImage) {
        do {
            let data = try StorageUploadPolicy.jpegDataFittingUploadLimit(
                image,
                maxBytes: StorageUploadPolicy.standardMaxBytes,
                initialQuality: 0.85,
                encodeFailedMessage: "This photo could not be read.",
                oversizedMessage: "This photo is too large to upload."
            )
            pending.append(PendingPayeClaimEvidence(
                label: "Photo \(count + 1)",
                source: .file(data: data, contentType: "image/jpeg", kind: "photo")
            ))
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// A PDF is kept as a PDF; an image becomes a JPEG; anything else (SVG included) is refused.
    private func addFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            message = "This file could not be read."
            return
        }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true {
            guard data.count <= StorageUploadPolicy.standardMaxBytes else {
                message = "This file is larger than 10 MB."
                return
            }
            pending.append(PendingPayeClaimEvidence(
                label: url.lastPathComponent,
                source: .file(data: data, contentType: "application/pdf", kind: "file")
            ))
            message = nil
        } else if type?.conforms(to: .image) == true, type?.conforms(to: .svg) != true, let image = UIImage(data: data) {
            addPhoto(image)
        } else {
            message = "Evidence must be a photo or a PDF."
        }
    }
}

/// A saved piece of evidence: its name (opens the file), its kind and a remove button.
struct ClaimSavedEvidenceRow: View {
    let entry: PayeClaimEvidence
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PPIconTile(
                symbol: entry.kind == "personalSiteAudit" ? "checklist" : (entry.kind == "photo" ? "photo" : "doc.richtext"),
                family: entry.kind == "personalSiteAudit" ? .trade : (entry.kind == "photo" ? .people : .plan),
                size: 34
            )
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(entry.kind == "personalSiteAudit" ? "Personal site audit copy · saved" : "Saved · tap to open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("claimEvidence.saved.open")
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(PPColor.danger)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(entry.name)")
            .accessibilityIdentifier("claimEvidence.saved.remove")
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.vertical, 6)
    }
}

/// Read-only evidence links for review lists and list rows: each file opens in the app (the Storage rules decide who
/// may); an older entry with only a receipt name says so (`CLAIM_EVIDENCE_LEGACY_RECEIPT_NOTE`).
struct ClaimEvidenceLinks: View {
    let evidence: [PayeClaimEvidence]
    var legacyReceiptName: String? = nil

    @State private var viewing: IdentifiableURL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(evidence, id: \.path) { entry in
                Button {
                    Task { await open(entry) }
                } label: {
                    Label(
                        entry.name + (entry.kind == "personalSiteAudit" ? " (personal site audit copy)" : ""),
                        systemImage: "paperclip"
                    )
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.brand)
                .accessibilityIdentifier("claimEvidence.link")
            }
            if evidence.isEmpty, let legacyReceiptName, !legacyReceiptName.isEmpty {
                Text(CanonicalBusinessEngine.claimEvidenceLegacyReceiptNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("claimEvidence.legacyReceipt")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(PPColor.danger)
            }
        }
        .sheet(item: $viewing) { target in
            InAppRemoteDocumentViewer(remoteURL: target.url, title: "Evidence", noun: "evidence")
        }
    }

    private func open(_ entry: PayeClaimEvidence) async {
        do {
            let url = try await Storage.storage().reference(withPath: entry.path).downloadURL()
            viewing = IdentifiableURL(url)
        } catch {
            self.error = "\(entry.name) could not be opened."
        }
    }
}

/// Uploads picked evidence into the signed-in person's own claim folder, in order. Frozen site audit copies are built
/// (and size-checked) first, so a copy over the 10 MB limit is refused before anything is uploaded. If any upload fails
/// the files already uploaded are discarded (`payeClaimEvidenceToDelete`, §24) and the error is thrown.
@MainActor
enum ClaimEvidenceUpload {
    static func upload(
        _ pending: [PendingPayeClaimEvidence],
        firebaseBackend: FirebaseBackend,
        progress: (String) -> Void
    ) async throws -> [PayeClaimEvidence] {
        var auditCopies: [UUID: Data] = [:]
        for entry in pending {
            guard case .audit(let audit) = entry.source else { continue }
            progress("Making the personal site audit copy")
            let backend = firebaseBackend
            guard let pdf = await PersonalSiteAuditPDF.makeData(audit: audit, readFile: { path in
                try await backend.payeClaimStoredFileData(path: path)
            }) else {
                throw PayeClaimRefused(message: "The personal site audit copy could not be made.")
            }
            if let refusal = PersonalSiteAuditPDF.attachRefusal(byteCount: pdf.count) {
                throw PayeClaimRefused(message: refusal)
            }
            auditCopies[entry.id] = pdf
        }
        var uploaded: [PayeClaimEvidence] = []
        do {
            for (index, entry) in pending.enumerated() {
                progress("Uploading evidence \(index + 1) of \(pending.count)")
                switch entry.source {
                case .file(let data, let contentType, let kind):
                    uploaded.append(try await firebaseBackend.uploadPayeClaimEvidence(
                        data: data,
                        name: entry.label,
                        contentType: contentType,
                        kind: kind
                    ))
                case .audit(let audit):
                    guard let pdf = auditCopies[entry.id] else {
                        throw PayeClaimRefused(message: "The personal site audit copy could not be made.")
                    }
                    uploaded.append(try await firebaseBackend.attachPersonalSiteAuditCopy(audit, pdfData: pdf))
                }
            }
        } catch {
            await firebaseBackend.discardPayeClaimEvidence(uploaded)
            throw error
        }
        return uploaded
    }
}
