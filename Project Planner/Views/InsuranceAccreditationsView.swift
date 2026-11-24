//
//  InsuranceAccreditationsView.swift
//  Project Planner
//
//  RULEBOOK 1.83.0 §31 (owner decisions 24 Nov: lean; admins only; 30-day recovery): Settings › Organisation ›
//  Compliance › Insurance & accreditations. Sections, types, labels, checks, status, order and counts are the
//  rulebook's (`Rulebook+OrgCompliance.swift`); this view only shows them.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct InsuranceAccreditationsView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @ObservedObject var store: OrgComplianceStore
    @Environment(\.openURL) private var openURLAction

    @State private var form: OrgComplianceFormMode?
    @State private var removing: RulebookOrgComplianceEntry?
    @State private var message: String?
    /// Ticked documents (`section:id`), for the zip and share links (owner decision 24 Nov).
    @State private var selected: Set<String> = []
    @State private var working = false
    @State private var shareFile: IdentifiableURL?
    @State private var lastZip: URL?
    @State private var createdLink: OrgComplianceCreatedShareLink?
    @State private var links: [OrgComplianceShareLinkRow] = []
    @State private var linksError: String?

    private var organizationId: String { firebaseBackend.currentOrganization?.firestoreDocumentId ?? "" }
    private var todayKey: String { CanonicalBusinessEngine.orgComplianceTodayKey() }
    private var allowed: Bool {
        userStore.displayUser.map { CanonicalBusinessEngine.canManageOrganizationCompliance($0.permissionSubject) } ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !allowed {
                    Text("Only an admin can open insurance & accreditations.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    Text(CanonicalBusinessEngine.orgCompliancePageSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    statsRow
                    if let error = store.loadError ?? message {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                            .padding(.top, 8)
                    }
                    if let documents = store.documents {
                        shareAndZipBar(documents)
                        ForEach(CanonicalBusinessEngine.orgComplianceSections) { section in
                            sectionBlock(section, entries: CanonicalBusinessEngine.orgComplianceSortedEntries(documents.entries(section.key), todayKey: todayKey))
                        }
                        linksBlock
                    } else if store.loadError == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(PPColor.page)
        .navigationTitle(CanonicalBusinessEngine.orgCompliancePageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if allowed, !organizationId.isEmpty { store.start(organizationId: organizationId, db: firebaseBackend.db) }
        }
        .task(id: organizationId) {
            if allowed, !organizationId.isEmpty { await loadLinks() }
        }
        .sheet(item: $shareFile, onDismiss: {
            // The zip is only for sharing: its temporary folder goes when the share sheet closes.
            if let url = lastZip { OrgComplianceZipFiles.remove(containing: url) }
            lastZip = nil
        }) { item in
            HSDocumentActivityView(activityItems: [item.url])
        }
        .sheet(item: $form) { mode in
            OrgComplianceDocumentForm(mode: mode, todayKey: todayKey) { details, file in
                await save(mode: mode, details: details, file: file)
            }
        }
        .confirmationDialog(
            removing?.title ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { entry in
            Button(CanonicalBusinessEngine.orgComplianceLabel("remove", fallback: "Remove"), role: .destructive) {
                Task { await remove(entry) }
            }
        } message: { _ in
            Text(CanonicalBusinessEngine.orgComplianceLabel("removeConfirm", fallback: "Remove this document?"))
        }
    }

    private var statsRow: some View {
        let counts = CanonicalBusinessEngine.orgComplianceCounts(store.documents, todayKey: todayKey)
        return HStack(spacing: 8) {
            statChip("\(counts.total)", "Documents", .green)
            statChip("\(counts.expiringSoon)", "Expiring soon", .orange)
            statChip("\(counts.expired)", "Expired", .red)
        }
        .padding(.top, 12)
    }

    private func statChip(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.bold)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sectionBlock(_ section: RulebookOrgComplianceSection, entries: [RulebookOrgComplianceEntry]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                PPGroupLabel(text: "\(section.title) · \(entries.count)")
                Text(section.helper).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            Spacer()
            Button {
                message = nil
                form = .add(section)
            } label: {
                Label(CanonicalBusinessEngine.orgComplianceLabel("upload", fallback: "Upload"), systemImage: "arrow.up.doc")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(PPColor.brand)
            .accessibilityIdentifier("orgCompliance.upload.\(section.key)")
        }
        .padding(.top, 12)
        PPGroupedCard {
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.emptyTitle).font(.subheadline.weight(.semibold))
                    Text(section.emptyBody).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry, section: section)
                    if index < entries.count - 1 { PPRowDivider() }
                }
            }
        }
    }

    private func row(_ entry: RulebookOrgComplianceEntry, section: RulebookOrgComplianceSection) -> some View {
        let status = CanonicalBusinessEngine.orgComplianceExpiryStatus(expiresOn: entry.expiresOn, todayKey: todayKey)
        let detail = [
            entry.issuer.isEmpty ? nil : entry.issuer,
            entry.reference.isEmpty ? nil : entry.reference,
            entry.coverAmount.map { CanonicalBusinessEngine.orgComplianceCoverText($0) },
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let key = orgComplianceRefKey(section: section.key, id: entry.id)
        let ticked = selected.contains(key)
        return HStack(spacing: 12) {
            Button {
                if ticked { selected.remove(key) } else { selected.insert(key) }
            } label: {
                Image(systemName: ticked ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(ticked ? PPColor.brand : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select \(entry.title)")
            .accessibilityAddTraits(ticked ? .isSelected : [])
            Image(systemName: entry.contentType == "application/pdf" ? "doc.richtext" : "photo")
                .foregroundStyle(PPColor.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.body).lineLimit(2)
                if !detail.isEmpty {
                    Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(status.label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(toneColor(status.tone))
            }
            Spacer(minLength: 8)
            Menu {
                Button(CanonicalBusinessEngine.orgComplianceLabel("view", fallback: "View")) { Task { await open(entry) } }
                Button(CanonicalBusinessEngine.orgComplianceLabel("edit", fallback: "Edit details")) { form = .edit(section, entry) }
                Button(CanonicalBusinessEngine.orgComplianceLabel("replace", fallback: "Replace file")) { form = .replace(section, entry) }
                Button(CanonicalBusinessEngine.orgComplianceLabel("remove", fallback: "Remove"), role: .destructive) { removing = entry }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityLabel("Actions for \(entry.title)")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
    }

    private func toneColor(_ tone: String) -> Color {
        switch tone {
        case "red": return .red
        case "amber": return .orange
        case "green": return .green
        default: return .secondary
        }
    }

    /// The ticked documents that still exist, in page order.
    private func selectedDocuments(_ documents: RulebookOrgComplianceDocuments) -> [OrgComplianceSelectedDocument] {
        CanonicalBusinessEngine.orgComplianceSections.flatMap { section in
            documents.entries(section.key)
                .map { OrgComplianceSelectedDocument(section: section.key, entry: $0) }
                .filter { selected.contains($0.key) }
        }
    }

    @ViewBuilder
    private func shareAndZipBar(_ documents: RulebookOrgComplianceDocuments) -> some View {
        let chosen = selectedDocuments(documents)
        VStack(alignment: .leading, spacing: 8) {
            Text(chosen.isEmpty ? "Tick documents to download them as a zip or share them with a 7-day link." : "\(chosen.count) selected")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    Task { await downloadZip(chosen) }
                } label: {
                    Label("Download zip", systemImage: "doc.zipper")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(chosen.isEmpty || working)
                Button {
                    Task { await createLink(documents: documents, chosen: chosen) }
                } label: {
                    Label("Create share link", systemImage: "link")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(PPColor.brand)
                .disabled(chosen.isEmpty || working)
                if working { ProgressView() }
            }
            if let createdLink {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Share link (works for 7 days, read only)").font(.footnote.weight(.semibold))
                    Text(createdLink.url).font(.footnote.monospaced()).textSelection(.enabled).lineLimit(3)
                    HStack(spacing: 10) {
                        Button("Copy link") { UIPasteboard.general.string = createdLink.url }
                        if let url = URL(string: createdLink.url) {
                            ShareLink(item: url) { Text("Share") }
                        }
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PPColor.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var linksBlock: some View {
        let active = links.filter { $0.state == "active" }
        if !active.isEmpty || linksError != nil {
            PPGroupLabel(text: "Active share links · \(active.count)").padding(.top, 16)
            if let linksError {
                Text(linksError).font(.footnote).foregroundStyle(.red).padding(.horizontal, 4)
            }
            PPGroupedCard {
                ForEach(Array(active.enumerated()), id: \.element.id) { index, link in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(link.documents.count) document\(link.documents.count == 1 ? "" : "s")").font(.body)
                            Text(linkDetail(link)).font(.footnote).foregroundStyle(.secondary)
                            if let status = link.statusText {
                                Text(status).font(.footnote.weight(.semibold)).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        Button("Turn off", role: .destructive) { Task { await revoke(link) } }
                            .font(.subheadline.weight(.semibold))
                            .disabled(working)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 56)
                    if index < active.count - 1 { PPRowDivider() }
                }
            }
        }
    }

    private func linkDetail(_ link: OrgComplianceShareLinkRow) -> String {
        let expires = link.expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        let formatter = DateFormatter()
        formatter.timeZone = OrganizationRulebookContext.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        let expiresText = expires.map { "Expires \(formatter.string(from: $0))" } ?? ""
        let opens = "Opened \(link.openCount) time\(link.openCount == 1 ? "" : "s")"
        return [expiresText, opens].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func downloadZip(_ chosen: [OrgComplianceSelectedDocument]) async {
        working = true
        defer { working = false }
        do {
            let url = try await firebaseBackend.orgComplianceZip(entries: chosen.map(\.entry), todayKey: todayKey)
            message = nil
            lastZip = url
            shareFile = IdentifiableURL(url)
        } catch {
            message = error.localizedDescription
        }
    }

    private func createLink(documents: RulebookOrgComplianceDocuments, chosen: [OrgComplianceSelectedDocument]) async {
        let selection = CanonicalBusinessEngine.orgComplianceShareSelection(documents, refs: chosen.map(\.key))
        if let error = selection.error {
            message = error
            return
        }
        working = true
        defer { working = false }
        do {
            createdLink = try await OrgComplianceShareClient.create(organizationId: organizationId, documents: selection.refs)
            message = nil
            await loadLinks()
        } catch {
            message = error.localizedDescription
        }
    }

    private func revoke(_ link: OrgComplianceShareLinkRow) async {
        working = true
        defer { working = false }
        do {
            try await OrgComplianceShareClient.revoke(organizationId: organizationId, id: link.id)
            if createdLink?.id == link.id { createdLink = nil }
            await loadLinks()
        } catch {
            linksError = error.localizedDescription
        }
    }

    private func loadLinks() async {
        let org = organizationId
        do {
            let rows = try await OrgComplianceShareClient.list(organizationId: org)
            guard org == organizationId else { return }
            links = rows
            linksError = nil
        } catch {
            guard org == organizationId else { return }
            linksError = error.localizedDescription
        }
    }

    /// Nil when saved, else the message the form shows.
    private func save(mode: OrgComplianceFormMode, details: OrgComplianceDetailsInput, file: OrgCompliancePickedFile?) async -> String? {
        do {
            switch mode {
            case .add(let section):
                guard let file else { return "Choose a file." }
                try await firebaseBackend.addOrgComplianceDocument(
                    data: file.data, fileName: file.name, contentType: file.contentType, organizationId: organizationId,
                    section: section.key, details: details, todayKey: todayKey
                )
            case .replace(let section, let entry):
                guard let file else { return "Choose a file." }
                try await firebaseBackend.replaceOrgComplianceFile(
                    data: file.data, fileName: file.name, contentType: file.contentType, organizationId: organizationId,
                    section: section.key, entryId: entry.id, details: details, todayKey: todayKey
                )
            case .edit(let section, let entry):
                try await firebaseBackend.updateOrgComplianceDocument(
                    organizationId: organizationId, section: section.key, entryId: entry.id, details: details, todayKey: todayKey
                )
            }
            message = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func remove(_ entry: RulebookOrgComplianceEntry) async {
        do {
            try await firebaseBackend.removeOrgComplianceDocument(organizationId: organizationId, section: entry.section, entryId: entry.id)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func open(_ entry: RulebookOrgComplianceEntry) async {
        do {
            // Admin-only Storage read (§24); opened only through `safeExternalUrl` (https).
            let url = try await firebaseBackend.orgComplianceDownloadURL(path: entry.path)
            guard let safe = CanonicalBusinessEngine.safeExternalURL(url) else {
                message = "This file cannot be opened."
                return
            }
            openURLAction(safe)
        } catch {
            message = error.localizedDescription
        }
    }
}

/// What the form is doing.
enum OrgComplianceFormMode: Identifiable {
    case add(RulebookOrgComplianceSection)
    case edit(RulebookOrgComplianceSection, RulebookOrgComplianceEntry)
    case replace(RulebookOrgComplianceSection, RulebookOrgComplianceEntry)

    var id: String {
        switch self {
        case .add(let s): return "add|\(s.key)"
        case .edit(let s, let e): return "edit|\(s.key)|\(e.id)"
        case .replace(let s, let e): return "replace|\(s.key)|\(e.id)"
        }
    }

    var section: RulebookOrgComplianceSection {
        switch self {
        case .add(let s), .edit(let s, _), .replace(let s, _): return s
        }
    }

    var entry: RulebookOrgComplianceEntry? {
        switch self {
        case .add: return nil
        case .edit(_, let e), .replace(_, let e): return e
        }
    }
}

struct OrgCompliancePickedFile: Sendable {
    let data: Data
    let name: String
    let contentType: String?
}

/// Add / Edit details / Replace file. Checks with `orgComplianceDetailsError` before saving.
private struct OrgComplianceDocumentForm: View {
    @Environment(\.dismiss) private var dismiss
    let mode: OrgComplianceFormMode
    let todayKey: String
    let save: (OrgComplianceDetailsInput, OrgCompliancePickedFile?) async -> String?

    private static let allowedTypes: [UTType] = [.pdf, .jpeg, .png, .heic, .heif, .webP]

    @State private var docType: String
    @State private var title: String
    @State private var titleTouched: Bool
    @State private var issuer: String
    @State private var reference: String
    @State private var cover: String
    @State private var hasExpiry: Bool
    @State private var expiry: Date
    @State private var file: OrgCompliancePickedFile?
    @State private var showingImporter = false
    @State private var saving = false
    @State private var error: String?

    init(mode: OrgComplianceFormMode, todayKey: String, save: @escaping (OrgComplianceDetailsInput, OrgCompliancePickedFile?) async -> String?) {
        self.mode = mode
        self.todayKey = todayKey
        self.save = save
        let entry = mode.entry
        let first = mode.section.documentTypes.first
        _docType = State(initialValue: entry?.docType ?? first?.key ?? "")
        _title = State(initialValue: entry?.title ?? first?.label ?? "")
        _titleTouched = State(initialValue: entry != nil)
        _issuer = State(initialValue: entry?.issuer ?? "")
        _reference = State(initialValue: entry?.reference ?? "")
        _cover = State(initialValue: entry?.coverAmount.map { String(Int($0)) } ?? "")
        let stored = entry?.expiresOn.flatMap { OrganizationRulebookContext.date(fromDayKey: $0) }
        _hasExpiry = State(initialValue: stored != nil)
        _expiry = State(initialValue: stored ?? Date())
    }

    private var needsFile: Bool {
        if case .edit = mode { return false }
        return true
    }

    private var heading: String {
        switch mode {
        case .add(let s): return "Add to \(s.title)"
        case .edit: return CanonicalBusinessEngine.orgComplianceLabel("edit", fallback: "Edit details")
        case .replace: return CanonicalBusinessEngine.orgComplianceLabel("replace", fallback: "Replace file")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if needsFile {
                    Section {
                        Button(file == nil ? "Choose a file" : "Change file") { showingImporter = true }
                            .accessibilityIdentifier("orgCompliance.form.chooseFile")
                        if let file { Text(file.name).font(.footnote).foregroundStyle(.secondary) }
                    } footer: {
                        if case .replace = mode {
                            Text(CanonicalBusinessEngine.orgComplianceLabel("replaceHelper", fallback: ""))
                        }
                    }
                }
                Section {
                    Picker(CanonicalBusinessEngine.orgComplianceLabel("docType", fallback: "Document type"), selection: $docType) {
                        ForEach(mode.section.documentTypes, id: \.key) { type in
                            Text(type.label).tag(type.key)
                        }
                        if let entry = mode.entry, !mode.section.documentTypes.contains(where: { $0.key == entry.docType }) {
                            Text(entry.docType).tag(entry.docType)
                        }
                    }
                    .onChange(of: docType) { _, newValue in
                        if !titleTouched, let type = mode.section.documentTypes.first(where: { $0.key == newValue }) { title = type.label }
                    }
                    TextField(CanonicalBusinessEngine.orgComplianceLabel("title", fallback: "Name"), text: Binding(
                        get: { title },
                        set: { title = $0; titleTouched = true }
                    ))
                    Toggle(CanonicalBusinessEngine.orgComplianceLabel("expiryToggle", fallback: "Has an expiry date"), isOn: $hasExpiry)
                        .accessibilityIdentifier("orgCompliance.form.hasExpiry")
                    if hasExpiry {
                        DatePicker(CanonicalBusinessEngine.orgComplianceLabel("expiry", fallback: "Expiry date"), selection: $expiry, displayedComponents: .date)
                            .environment(\.timeZone, OrganizationRulebookContext.timeZone)
                    }
                } footer: {
                    if hasExpiry { Text(CanonicalBusinessEngine.orgComplianceLabel("expiryHelper", fallback: "")) }
                }
                Section {
                    TextField("\(mode.section.issuerLabel) (optional)", text: $issuer)
                    TextField("\(mode.section.referenceLabel) (optional)", text: $reference)
                    if let coverLabel = mode.section.coverLabel {
                        TextField("\(coverLabel) (optional)", text: $cover).keyboardType(.numberPad)
                    }
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: Self.allowedTypes, allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await read(url) }
                case .failure(let failure):
                    error = failure.localizedDescription
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(CanonicalBusinessEngine.orgComplianceLabel("cancel", fallback: "Cancel")) { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(CanonicalBusinessEngine.orgComplianceLabel("save", fallback: "Save")) { Task { await submit() } }
                            .accessibilityIdentifier("orgCompliance.form.save")
                    }
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func read(_ url: URL) async {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
            file = OrgCompliancePickedFile(data: data, name: url.lastPathComponent, contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func submit() async {
        let details = OrgComplianceDetailsInput(
            docType: docType, title: title, issuer: issuer, reference: reference, coverAmount: cover,
            expiresOn: hasExpiry ? OrganizationRulebookContext.dayKey(expiry) : nil
        )
        if let problem = CanonicalBusinessEngine.orgComplianceDetailsError(section: mode.section.key, details: details, todayKey: todayKey) {
            error = problem
            return
        }
        if needsFile && file == nil {
            error = "Choose a file."
            return
        }
        saving = true
        let result = await save(details, file)
        saving = false
        if let result {
            error = result
        } else {
            dismiss()
        }
    }
}
