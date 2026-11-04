//
//  PersonalSiteAuditViews.swift
//  Project Planner
//
//  RULEBOOK 1.30.0 §26: Site audits → Personal — the same flow as web `components/site-audit/PersonalSiteAudits.tsx`.
//  The signed-in person's own audits only (owner-only security rules); job number and job name are free text, not
//  linked to any job, and print on the audit. Rules and shapes are `personalSiteAudits.ts` through
//  `CanonicalBusinessEngine` (`personalSiteAuditValidationError`, `personalSiteAuditWriteFields`,
//  `parsePersonalSiteAuditDocument`, `personalSiteAuditsFor`, `personalSiteAuditTitle`, `personalSiteAuditImagePath`,
//  `personalSiteAuditPdfRows`); these views only show them. Online only.
//

import SwiftUI
import UIKit
import FirebaseStorage

/// The Personal list: Create Personal Site Audit, then the person's audits, newest first.
struct PersonalSiteAuditsView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss

    @State private var audits: [PersonalSiteAudit] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var creating = false
    @State private var open: PersonalSiteAudit?
    @State private var listener = OvertimeListeners()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(CanonicalBusinessEngine.payeClaimText("PERSONAL_SITE_AUDIT_PRIVATE_NOTE", fallback: "Only you can see your personal site audits."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        creating = true
                    } label: {
                        Text(CanonicalBusinessEngine.payeClaimText("PERSONAL_SITE_AUDIT_CREATE_LABEL", fallback: "Create Personal Site Audit"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .accessibilityIdentifier("personalSiteAudits.create")
                    if let loadError {
                        Text(loadError).foregroundStyle(.secondary)
                    } else if !loaded {
                        Text("Loading…").foregroundStyle(.secondary)
                    } else if audits.isEmpty {
                        Text("No personal site audits yet.").foregroundStyle(.secondary)
                    }
                    ForEach(audits) { audit in
                        Button {
                            open = audit
                        } label: {
                            OvertimeTile(
                                title: CanonicalBusinessEngine.personalSiteAuditTitle(audit),
                                subtitle: "\(audit.items.count) item\(audit.items.count == 1 ? "" : "s")"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle(CanonicalBusinessEngine.payeClaimText("PERSONAL_SITE_AUDIT_SECTION_LABEL", fallback: "Personal"))
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
            }
            .sheet(isPresented: $creating) {
                PersonalSiteAuditCreateView()
                    .environmentObject(firebaseBackend)
                    .environmentObject(userStore)
            }
            .sheet(item: $open) { audit in
                PersonalSiteAuditDetailView(audit: audit)
                    .environmentObject(firebaseBackend)
            }
        }
        .onAppear {
            listener.stop()
            if let registration = firebaseBackend.listenPersonalSiteAudits(
                onChange: { rows in
                    audits = rows
                    loaded = true
                },
                onError: { error in loadError = error.localizedDescription }
            ) {
                listener.add(registration)
            } else {
                loadError = "Sign in to see your personal site audits."
            }
        }
        .onDisappear { listener.stop() }
    }
}

/// One personal audit: its photos and Share PDF (the same frozen copy that is attached as evidence).
struct PersonalSiteAuditDetailView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss
    let audit: PersonalSiteAudit

    @State private var busy = false
    @State private var error: String?
    @State private var shareURL: URL?
    @State private var photos: [String: UIImage] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(CanonicalBusinessEngine.personalSiteAuditTitle(audit)).font(.headline)
                    Text("Job number \(audit.jobNumber.isEmpty ? "—" : audit.jobNumber) · Job name \(audit.jobName) · \(audit.authorName) · \(audit.items.count) item(s)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await share() }
                    } label: {
                        Text(busy ? "Making PDF…" : "Share PDF")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .disabled(busy)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    ForEach(Array(audit.items.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). \(item.title)").font(.subheadline.weight(.semibold))
                            if !item.location.isEmpty {
                                Text(item.location).font(.footnote).foregroundStyle(.secondary)
                            }
                            if !item.comments.isEmpty {
                                Text(item.comments).font(.footnote)
                            }
                            if let image = photos[item.imagePath] {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                    }
                }
                .padding(16)
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Personal site audit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: Binding(get: { shareURL.map(OvertimeShareItem.init) }, set: { shareURL = $0?.url })) { item in
                HSDocumentActivityView(activityItems: [item.url])
            }
            .task { await loadPhotos() }
        }
    }

    private func loadPhotos() async {
        for item in audit.items where !item.imagePath.isEmpty && photos[item.imagePath] == nil {
            if let data = try? await firebaseBackend.payeClaimStoredFileData(path: item.imagePath), let image = UIImage(data: data) {
                photos[item.imagePath] = image
            }
        }
    }

    private func share() async {
        busy = true
        error = nil
        defer { busy = false }
        let backend = firebaseBackend
        guard let data = await PersonalSiteAuditPDF.makeData(audit: audit, readFile: { path in
            try await backend.payeClaimStoredFileData(path: path)
        }) else {
            error = "The PDF could not be made."
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("personal-site-audit-\(audit.date.isEmpty ? "audit" : audit.date).pdf")
        do {
            try data.write(to: url, options: .atomic)
            shareURL = url
        } catch {
            self.error = "The PDF could not be saved."
        }
    }
}

/// A photo picked for a new audit, with its title and notes (uploaded on Save).
private struct PersonalSiteAuditDraftPhoto: Identifiable {
    let id = UUID().uuidString
    var title = ""
    var location = ""
    var comments = ""
    let jpeg: Data
    let preview: UIImage
    let takenAt: Date
}

/// Create Personal Site Audit: free-text job number and job name, type, date, then photos with a title each.
struct PersonalSiteAuditCreateView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss

    @State private var jobNumber = ""
    @State private var jobName = ""
    @State private var type = SiteAuditType.general.rawValue
    @State private var customTitle = ""
    @State private var date = Date()
    @State private var items: [PersonalSiteAuditDraftPhoto] = []
    @State private var error: String?
    @State private var saving: String?
    @State private var pickingPhoto: UIImagePickerController.SourceType?

    private var authorName: String {
        guard let user = userStore.displayUser else { return "" }
        return user.fullName.isEmpty ? user.email : user.fullName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(CanonicalBusinessEngine.payeClaimText("PERSONAL_SITE_AUDIT_PRIVATE_NOTE", fallback: "Only you can see your personal site audits.")) Not linked to any job.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("Job number", text: $jobNumber)
                    TextField("Job name", text: $jobName)
                        .accessibilityIdentifier("personalSiteAudits.jobName")
                    Picker("Audit type", selection: $type) {
                        ForEach(SiteAuditType.allCases) { value in
                            Text(value.rawValue).tag(value.rawValue)
                        }
                    }
                    TextField("Title (optional)", text: $customTitle)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .environment(\.timeZone, OrganizationRulebookContext.timeZone)
                }
                ForEach($items) { $item in
                    Section {
                        Image(uiImage: item.preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                        TextField("Title", text: $item.title)
                        TextField("Location", text: $item.location)
                        TextField("Notes", text: $item.comments, axis: .vertical)
                            .lineLimit(2...5)
                        Button("Remove", role: .destructive) {
                            let id = item.id
                            items.removeAll { $0.id == id }
                        }
                    } header: {
                        Text("Photo · taken \(takenText(item.takenAt))")
                    }
                }
                Section {
                    Button("Take photo") { pickingPhoto = .camera }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Button("Add from photo library") { pickingPhoto = .photoLibrary }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(saving ?? "Save audit")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(saving != nil)
                    .accessibilityIdentifier("personalSiteAudits.save")
                }
            }
            .navigationTitle(CanonicalBusinessEngine.payeClaimText("PERSONAL_SITE_AUDIT_CREATE_LABEL", fallback: "Create Personal Site Audit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving != nil)
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
        }
        .interactiveDismissDisabled(saving != nil)
    }

    private func takenText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = OrganizationRulebookContext.timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    private func addPhoto(_ image: UIImage) {
        do {
            let data = try StorageUploadPolicy.jpegDataFittingUploadLimit(
                image,
                maxBytes: StorageUploadPolicy.standardMaxBytes,
                initialQuality: 0.85,
                encodeFailedMessage: "This photo could not be read.",
                oversizedMessage: "This photo is too large to upload."
            )
            items.append(PersonalSiteAuditDraftPhoto(jpeg: data, preview: image, takenAt: Date()))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func draft(_ rows: [[String: Any]]) -> [String: Any] {
        [
            "jobNumber": jobNumber,
            "jobName": jobName,
            "type": type,
            "customTitle": customTitle,
            "date": OrganizationRulebookContext.dayKey(date),
            "authorName": authorName,
            "items": rows,
        ]
    }

    private func submit() async {
        guard saving == nil else { return }
        // The shape check before any upload (`personalSiteAuditValidationError` without the path context), as web does.
        let shape = draft(items.map { ["id": $0.id, "title": $0.title] })
        if let message = CanonicalBusinessEngine.personalSiteAuditValidationError(draft: shape, organizationId: nil, ownerUserId: nil) {
            error = message
            return
        }
        error = nil
        let auditId = UUID().uuidString
        var uploaded: [[String: Any]] = []
        do {
            for (index, item) in items.enumerated() {
                saving = "Uploading photo \(index + 1) of \(items.count)"
                let path = try await firebaseBackend.uploadPersonalSiteAuditPhoto(auditId: auditId, jpegData: item.jpeg)
                uploaded.append([
                    "id": item.id,
                    "title": item.title,
                    "location": item.location,
                    "comments": item.comments,
                    "imagePath": path,
                    "takenAtMs": (item.takenAt.timeIntervalSince1970 * 1000).rounded(),
                ])
            }
            saving = "Saving audit"
            try await firebaseBackend.savePersonalSiteAudit(auditId: auditId, draft: draft(uploaded))
            saving = nil
            dismiss()
        } catch {
            await firebaseBackend.discardPersonalSiteAuditPhotos(uploaded.compactMap { $0["imagePath"] as? String })
            saving = nil
            self.error = error.localizedDescription
        }
    }
}
