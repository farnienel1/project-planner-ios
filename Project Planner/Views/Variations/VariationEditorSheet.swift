//
//  VariationEditorSheet.swift
//  Project Planner
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import FirebaseAuth

struct VariationEditorSheet: View {
    let project: Project
    let existing: Variation?
    @ObservedObject var store: VariationStore
    let materialNames: [String]

    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var notificationService: NotificationService
    @Environment(\.dismiss) private var dismiss

    @State private var variationId: String
    @State private var voNumber: String
    @State private var heading: String
    @State private var descriptionText: String
    @State private var labour: [VariationLabourLine]
    @State private var materials: [VariationMaterialLine]
    @State private var evidence: [VariationEvidenceItem]
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var showingCamera = false
    @State private var showingLibrary = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var customTradeDraft = ""
    @State private var showingCustomTrade = false
    @State private var inFlightUploads = 0
    @State private var tradePickerLineId: String?
    @State private var tradeSearch = ""

    init(project: Project, existing: Variation?, store: VariationStore, materialNames: [String]) {
        self.project = project
        self.existing = existing
        self.store = store
        self.materialNames = materialNames
        let id = existing?.id ?? UUID().uuidString
        _variationId = State(initialValue: id)
        _voNumber = State(initialValue: existing?.voNumber ?? store.nextVoNumber())
        _heading = State(initialValue: existing?.heading ?? "")
        _descriptionText = State(initialValue: existing?.description ?? "")
        _labour = State(initialValue: existing?.labour ?? [])
        _materials = State(initialValue: existing?.materials ?? [])
        _evidence = State(initialValue: existing?.evidence ?? [])
    }

    private var trackerOn: Bool { store.tracker.enabled }
    private var labourHours: Double { labour.reduce(0) { $0 + $1.hours } }
    private var canSave: Bool {
        !heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    jobBanner

                    fieldBlock(title: "VO number", systemImage: "number", tint: ProjectWorksRevampColors.blue) {
                        TextField("VO-001", text: $voNumber)
                            .font(.system(size: 17, weight: .semibold))
                            .disabled(trackerOn)
                            .textInputAutocapitalization(.characters)
                        if trackerOn {
                            Text("Numbered by the tracker · next free number is \(store.nextVoNumber())")
                                .font(.caption)
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        } else if store.voNumberIsDuplicate(voNumber, excludingId: variationId) {
                            Text("This VO number is already used on this job.")
                                .font(.caption)
                                .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                        }
                    }

                    fieldBlock(title: "Heading", systemImage: "text.alignleft", tint: ProjectWorksRevampColors.jobTypePillInk) {
                        TextField("What changed on site?", text: $heading)
                    }
                    fieldBlock(title: "Description", systemImage: "doc.text", tint: ProjectWorksRevampColors.activeGreen) {
                        TextEditor(text: $descriptionText)
                            .frame(minHeight: 110)
                            .scrollContentBackground(.hidden)
                    }

                    labourSection
                    materialsSection
                    evidenceSection

                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                    Color.clear.frame(height: 72)
                }
                .padding(16)
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationTitle(existing == nil ? "New variation" : "Edit variation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Text("Saves as Open and notifies every admin")
                        .font(.caption)
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    Button {
                        Task { await save() }
                    } label: {
                        Text(isSaving ? "Saving…" : "Save")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(canSave ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.placeholderInk)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(!canSave)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(ProjectWorksRevampColors.canvas.ignoresSafeArea(edges: .bottom))
            }
            .sheet(isPresented: $showingCamera) {
                VariationCameraPicker { image in
                    Task { await addImage(image, fileName: "photo.jpg") }
                }
            }
            .photosPicker(isPresented: $showingLibrary, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await importPhoto(item) }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.jpeg, .png, .pdf, UTType("public.heic") ?? .image],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await importFile(url) }
                }
            }
            .alert("Custom trade", isPresented: $showingCustomTrade) {
                TextField("Trade name", text: $customTradeDraft)
                Button("Add") { addCustomTrade() }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: Binding(
                get: { tradePickerLineId != nil },
                set: { if !$0 { tradePickerLineId = nil; tradeSearch = "" } }
            )) {
                tradePickerSheet
            }
        }
    }

    private var jobBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ProjectWorksRevampColors.blue.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: project.jobType == .smallWorks ? "wrench.and.screwdriver.fill" : "building.2.fill")
                    .foregroundStyle(ProjectWorksRevampColors.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(project.jobNumber.isEmpty ? "Job" : project.jobNumber)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(project.siteName.isEmpty ? "Variation" : project.siteName)
                    .font(.system(size: 12))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Spacer()
            Text(project.jobType == .smallWorks ? "Small works" : "Project")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.jobTypePillInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(ProjectWorksRevampColors.jobTypePillBg)
                .clipShape(Capsule())
        }
        .padding(14)
        .appChromeCardContainer(cornerRadius: 16)
    }

    private var labourSection: some View {
        fieldBlock(title: "Labour", systemImage: "person.2.fill", tint: ProjectWorksRevampColors.blue, trailing: formatHours(labourHours) + " hrs") {
            if labour.isEmpty {
                Text("Add a trade, then set the hours with the stepper or a preset.")
                    .font(.system(size: 13))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            ForEach($labour) { $row in
                labourCard(row: $row)
            }
            Button {
                let line = VariationLabourLine(id: UUID().uuidString, trade: "", hours: 1)
                labour.append(line)
                tradeSearch = ""
                tradePickerLineId = line.id
            } label: {
                Label("Add trade", systemImage: "plus.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(ProjectWorksRevampColors.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func labourCard(row: Binding<VariationLabourLine>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    tradeSearch = ""
                    tradePickerLineId = row.wrappedValue.id
                } label: {
                    HStack {
                        Text(row.wrappedValue.trade.isEmpty ? "Choose trade" : row.wrappedValue.trade)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(row.wrappedValue.trade.isEmpty ? ProjectWorksRevampColors.placeholderInk : ProjectWorksRevampColors.ink)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.blue)
                    }
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    labour.removeAll { $0.id == row.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                        .frame(width: 32, height: 32)
                        .background(ProjectWorksRevampColors.requiredPillBg)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                Button {
                    row.wrappedValue.hours = max(0, row.wrappedValue.hours - 0.5)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                        .frame(width: 40, height: 40)
                        .background(ProjectWorksRevampColors.blue.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                VStack(spacing: 0) {
                    Text(formatHours(row.wrappedValue.hours))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .monospacedDigit()
                    Text("hours")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }
                .frame(minWidth: 72)
                Button {
                    row.wrappedValue.hours += 0.5
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(ProjectWorksRevampColors.blue)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([0.5, 1, 2, 4, 8], id: \.self) { hours in
                        let selected = abs(row.wrappedValue.hours - hours) < 0.01
                        Button(hours == 0.5 ? "30 min" : "\(Int(hours)) hr\(hours == 1 ? "" : "s")") {
                            row.wrappedValue.hours = hours
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? .white : ProjectWorksRevampColors.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(selected ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.blue.opacity(0.1))
                        .clipShape(Capsule())
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(ProjectWorksRevampColors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var tradePickerSheet: some View {
        let options = VariationTrades.mergedPickerOptions(custom: store.customTrades).filter { trade in
            let query = tradeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty || trade.localizedCaseInsensitiveContains(query)
        }
        return NavigationStack {
            List {
                Section {
                    TextField("Search trades", text: $tradeSearch)
                }
                Section("Trades") {
                    ForEach(options, id: \.self) { trade in
                        Button(trade) {
                            assignTrade(trade)
                        }
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    }
                }
                Section("Not in the list?") {
                    TextField("Custom trade", text: $customTradeDraft)
                    Button("Add custom trade") { addCustomTrade() }
                        .disabled(customTradeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Choose trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        tradePickerLineId = nil
                        tradeSearch = ""
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var materialsSection: some View {
        fieldBlock(title: "Materials", systemImage: "shippingbox.fill", tint: ProjectWorksRevampColors.upcomingAmber, trailing: "\(materials.count)") {
            if materials.isEmpty {
                Text("Add materials with a quantity, then tap a unit if you need one.")
                    .font(.system(size: 13))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            ForEach($materials) { $row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Material name", text: $row.name)
                            .font(.system(size: 15, weight: .semibold))
                        Button(role: .destructive) {
                            materials.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                        }
                        .buttonStyle(.plain)
                    }
                    TextField("Quantity", text: $row.quantity)
                        .font(.system(size: 15))
                    HStack(spacing: 6) {
                        ForEach(["m", "no", "box", "kg"], id: \.self) { unit in
                            Button(unit) { appendUnit(unit, to: $row) }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(ProjectWorksRevampColors.upcomingAmber.opacity(0.14))
                                .clipShape(Capsule())
                                .buttonStyle(.plain)
                        }
                    }
                    let suggestions = materialNames.filter { name in
                        let q = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        return !q.isEmpty && name.localizedCaseInsensitiveContains(q) && name.localizedCaseInsensitiveCompare(row.name) != .orderedSame
                    }.prefix(3)
                    if !suggestions.isEmpty {
                        ForEach(Array(suggestions), id: \.self) { suggestion in
                            Button {
                                row.name = suggestion
                            } label: {
                                Text(suggestion)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(ProjectWorksRevampColors.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(12)
                .background(ProjectWorksRevampColors.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Button {
                materials.append(VariationMaterialLine(id: UUID().uuidString, name: "", quantity: ""))
            } label: {
                Label("Add material", systemImage: "plus.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(ProjectWorksRevampColors.upcomingAmber.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var evidenceSection: some View {
        fieldBlock(title: "Evidence", systemImage: "paperclip", tint: ProjectWorksRevampColors.activeGreen, trailing: "\(evidence.count)") {
            Text("Please upload any supporting evidence here")
                .font(.system(size: 13))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            HStack(spacing: 8) {
                evidenceAddButton("Camera", systemImage: "camera.fill") { showingCamera = true }
                evidenceAddButton("Library", systemImage: "photo.fill") { showingLibrary = true }
                evidenceAddButton("Files", systemImage: "folder.fill") { showingFileImporter = true }
            }
            ForEach(evidence) { item in
                HStack(spacing: 10) {
                    Text(typeBadge(item))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(ProjectWorksRevampColors.activeGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(ProjectWorksRevampColors.activeGreen.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.fileName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                        Text(item.isPending ? "Uploading…" : byteString(item.sizeBytes))
                            .font(.caption)
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        Task { await removeEvidence(item) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(ProjectWorksRevampColors.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func evidenceAddButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(ProjectWorksRevampColors.activeGreen)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(ProjectWorksRevampColors.activeGreen.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func fieldBlock<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        trailing: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appChromeCardContainer(cornerRadius: 16)
    }

    private func assignTrade(_ trade: String) {
        guard let id = tradePickerLineId, let index = labour.firstIndex(where: { $0.id == id }) else { return }
        labour[index].trade = trade
        tradePickerLineId = nil
        tradeSearch = ""
    }

    private func appendUnit(_ unit: String, to row: Binding<VariationMaterialLine>) {
        let current = row.wrappedValue.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            row.wrappedValue.quantity = unit
        } else if current.lowercased().hasSuffix(unit) {
            return
        } else {
            row.wrappedValue.quantity = current + unit
        }
    }

    private func addCustomTrade() {
        let trimmed = customTradeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if tradePickerLineId == nil {
            let line = VariationLabourLine(id: UUID().uuidString, trade: trimmed, hours: 1)
            labour.append(line)
            tradePickerLineId = line.id
        }
        assignTrade(trimmed)
        if !store.customTrades.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            store.customTrades.append(trimmed)
        }
        if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            Task { await firebaseBackend.addCustomVariationTrade(trimmed, organizationId: orgId) }
        }
        customTradeDraft = ""
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
            await addImage(image, fileName: "library.jpg")
        }
    }

    private func importFile(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.lastPathComponent
        if data.count > VariationEvidenceProcessor.maxBytes {
            errorMessage = "That file is too large. Evidence must be 20 MB or smaller."
            return
        }
        if let image = UIImage(data: data) {
            await addImage(image, fileName: name)
            return
        }
        await uploadData(data, fileName: name, contentType: mime(for: name))
    }

    private func addImage(_ image: UIImage, fileName: String) async {
        guard let data = VariationEvidenceProcessor.preparedImageData(image) else { return }
        await uploadData(data, fileName: fileName.hasSuffix(".pdf") ? "photo.jpg" : fileName, contentType: "image/jpeg")
    }

    private func uploadData(_ data: Data, fileName: String, contentType: String) async {
        guard VariationEvidenceProcessor.isAllowed(fileName: fileName, contentType: contentType) else {
            errorMessage = "Use a JPG, PNG, HEIC or PDF file."
            return
        }
        guard evidence.count < 10 else {
            errorMessage = "You can attach up to 10 files."
            return
        }
        let orgId = (await firebaseBackend.resolveOrganizationIdForFirebaseWrites(
            preferredFallback: firebaseBackend.currentOrganization?.firestoreDocumentId
        )) ?? ""
        guard !orgId.isEmpty else {
            errorMessage = "Organization ID is missing. Open Settings → Force Reload Data, then retry."
            return
        }
        let evidenceId = UUID().uuidString
        let pending = VariationEvidenceItem(
            id: evidenceId,
            fileName: fileName,
            contentType: contentType,
            sizeBytes: data.count,
            storagePath: "",
            downloadURL: "",
            uploadedByUid: firebaseBackend.currentUser?.uid ?? "",
            uploadedAt: Date(),
            isPending: true
        )
        evidence.append(pending)
        inFlightUploads += 1
        do {
            let uploaded = try await firebaseBackend.uploadVariationEvidence(
                data: data,
                fileName: fileName,
                contentType: contentType,
                organizationId: orgId,
                parentId: project.id.uuidString,
                variationId: variationId,
                evidenceId: evidenceId
            )
            if let idx = evidence.firstIndex(where: { $0.id == evidenceId }) {
                evidence[idx].storagePath = uploaded.storagePath
                evidence[idx].downloadURL = uploaded.downloadURL
                evidence[idx].isPending = false
            }
        } catch {
            evidence.removeAll { $0.id == evidenceId }
            errorMessage = error.localizedDescription
        }
        inFlightUploads = max(0, inFlightUploads - 1)
    }

    private func removeEvidence(_ item: VariationEvidenceItem) async {
        evidence.removeAll { $0.id == item.id }
        if !item.storagePath.isEmpty {
            await firebaseBackend.deleteVariationEvidenceFile(storagePath: item.storagePath)
        }
    }

    private func save() async {
        guard canSave else { return }
        let orgId = (await firebaseBackend.resolveOrganizationIdForFirebaseWrites(
            preferredFallback: firebaseBackend.currentOrganization?.firestoreDocumentId
        )) ?? ""
        guard !orgId.isEmpty else {
            errorMessage = "Organization ID is missing. Open Settings → Force Reload Data, then retry."
            return
        }
        if !trackerOn, store.voNumberIsDuplicate(voNumber, excludingId: variationId) {
            errorMessage = "This VO number is already used on this job."
            return
        }
        isSaving = true
        errorMessage = nil
        let waitDeadline = Date().addingTimeInterval(20)
        while inFlightUploads > 0 && Date() < waitDeadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if inFlightUploads > 0 {
            errorMessage = "Evidence is still uploading. Wait a moment and tap Save again."
            isSaving = false
            return
        }
        let user = userStore.displayUser
        let uid = user?.id ?? firebaseBackend.currentUser?.uid ?? ""
        let name = (user?.fullName.isEmpty == false ? user?.fullName : user?.email) ?? "Unknown"
        let parentType: VariationParentType = project.jobType == .smallWorks ? .smallWork : .project
        let now = Date()
        var variation: Variation
        if var existing {
            existing.voNumber = trackerOn ? existing.voNumber : voNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.heading = heading.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.description = descriptionText
            existing.labour = labour.filter { !$0.trade.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.hours > 0 }
            existing.materials = materials.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            existing.evidence = evidence.filter { !$0.isPending }
            existing.updatedByUid = uid
            existing.updatedAt = now
            existing.recomputeCounts()
            variation = existing
        } else {
            variation = Variation(
                id: variationId,
                orgId: orgId,
                parentType: parentType,
                parentId: project.id.uuidString,
                parentName: VariationNumbering.parentName(jobNumber: project.jobNumber, siteName: project.siteName),
                origin: .app,
                voNumber: voNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                sequence: (store.variations.map(\.sequence).max() ?? 0) + 1,
                voNumberLocked: false,
                numberHistory: [],
                heading: heading.trimmingCharacters(in: .whitespacesAndNewlines),
                description: descriptionText,
                status: .open,
                labour: labour.filter { !$0.trade.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.hours > 0 },
                materials: materials.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                evidence: evidence.filter { !$0.isPending },
                totalLabourHours: 0,
                materialLineCount: 0,
                evidenceCount: 0,
                createdByUid: uid,
                createdByName: name,
                createdAt: now,
                updatedByUid: uid,
                updatedAt: now,
                statusHistory: [VariationStatusHistoryEntry(status: VariationStatus.open.rawValue, byUid: uid, byName: name, at: now)],
                submittedAt: nil,
                closedAt: nil,
                isDeleted: false
            )
            variation.recomputeCounts()
        }
        do {
            try await firebaseBackend.saveVariation(variation, organizationId: orgId)
            store.upsert(variation)
            if existing == nil {
                await notificationService.notifyVariationAdded(
                    parentId: project.id,
                    parentName: variation.parentName,
                    isSmallWorks: project.jobType == .smallWorks,
                    createdByUserId: uid
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }

    private func mime(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "pdf": return "application/pdf"
        case "heic": return "image/heic"
        default: return "image/jpeg"
        }
    }

    private func typeBadge(_ item: VariationEvidenceItem) -> String {
        let ext = (item.fileName as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : ext
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func formatHours(_ value: Double) -> String {
        String(format: abs(value - value.rounded()) < 0.05 ? "%.0f" : "%.1f", value)
    }
}

private struct VariationCameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: VariationCameraPicker
        init(parent: VariationCameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
