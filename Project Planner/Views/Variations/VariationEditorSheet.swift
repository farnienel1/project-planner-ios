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
    @State private var showingTradePicker = false
    @State private var tradePickerRowID: String?
    @State private var suggestionNames: [String]

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
        _suggestionNames = State(initialValue: materialNames)
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
                    fieldBlock(title: "VO number") {
                        TextField("VO-001", text: $voNumber)
                            .disabled(trackerOn)
                            .textInputAutocapitalization(.characters)
                        if trackerOn {
                            Text("Numbered by the tracker · next free number is \(store.nextVoNumber())")
                                .font(.caption)
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        } else if store.voNumberIsDuplicate(voNumber, excludingId: variationId) {
                            Text("This VO number is already used on this job.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    fieldBlock(title: "Heading") {
                        TextField("Short heading", text: $heading)
                    }
                    fieldBlock(title: "Description") {
                        TextField("What changed on site", text: $descriptionText, axis: .vertical)
                            .lineLimit(3...8)
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
            .sheet(isPresented: $showingTradePicker) {
                VariationTradePickerSheet(
                    options: VariationTrades.mergedPickerOptions(custom: store.customTrades),
                    onSelect: { trade in
                        if let id = tradePickerRowID, let idx = labour.firstIndex(where: { $0.id == id }) {
                            labour[idx].trade = trade
                        } else if labour.isEmpty {
                            labour.append(VariationLabourLine(id: UUID().uuidString, trade: trade, hours: 0))
                        }
                        showingTradePicker = false
                    },
                    onCustom: {
                        showingTradePicker = false
                        showingCustomTrade = true
                    }
                )
            }
        }
    }

    private var labourSection: some View {
        fieldBlock(title: "Labour · \(formatHours(labourHours)) hrs") {
            ForEach($labour) { $row in
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        tradePickerRowID = row.id
                        showingTradePicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(row.trade.isEmpty ? "Select trade" : row.trade)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .foregroundStyle(row.trade.isEmpty ? ProjectWorksRevampColors.placeholderInk : ProjectWorksRevampColors.ink)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    TextField("Hrs", value: $row.hours, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Button(role: .destructive) {
                        labour.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                }
            }
            HStack {
                ForEach([0.5, 1, 4, 8], id: \.self) { hours in
                    Button(hours == 0.5 ? "+30 min" : "+\(Int(hours)) hr\(hours == 1 ? "" : "s")") {
                        addHours(hours)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(ProjectWorksRevampColors.blue.opacity(0.1))
                    .clipShape(Capsule())
                }
            }
            Button("Add labour row") {
                labour.append(VariationLabourLine(id: UUID().uuidString, trade: "", hours: 0))
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private var materialsSection: some View {
        fieldBlock(title: "Materials · \(materials.count)") {
            ForEach($materials) { $row in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Material name", text: $row.name)
                    HStack {
                        TextField("Qty / length", text: $row.quantity)
                        ForEach(["m", "no", "box", "kg"], id: \.self) { unit in
                            Button(unit) {
                                appendUnit(unit, to: $row)
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                        }
                        Button(role: .destructive) {
                            materials.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                    }
                    if !suggestionNames.isEmpty {
                        ForEach(suggestionNames.filter { name in
                            let q = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            return !q.isEmpty && name.localizedCaseInsensitiveContains(q) && name.localizedCaseInsensitiveCompare(row.name) != .orderedSame
                        }.prefix(3), id: \.self) { suggestion in
                            Button(suggestion) { row.name = suggestion }
                                .font(.caption)
                        }
                    }
                }
            }
            Button("Add material row") {
                materials.append(VariationMaterialLine(id: UUID().uuidString, name: "", quantity: ""))
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private var evidenceSection: some View {
        fieldBlock(title: "Evidence") {
            Text("Please upload any supporting evidence here")
                .font(.subheadline)
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Menu {
                Button("Camera") { showingCamera = true }
                Button("Photo library") { showingLibrary = true }
                Button("Files") { showingFileImporter = true }
            } label: {
                Label("Add evidence", systemImage: "paperclip")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(ProjectWorksRevampColors.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            ForEach(evidence) { item in
                HStack {
                    Text(typeBadge(item))
                        .font(.caption2.weight(.bold))
                        .padding(4)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading) {
                        Text(item.fileName).font(.subheadline)
                        Text(item.isPending ? "Uploading…" : byteString(item.sizeBytes))
                            .font(.caption)
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        Task { await removeEvidence(item) }
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fieldBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ProjectWorksRevampColors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func addHours(_ hours: Double) {
        if labour.isEmpty {
            labour.append(VariationLabourLine(id: UUID().uuidString, trade: "", hours: hours))
        } else {
            labour[labour.count - 1].hours += hours
        }
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
        if let id = tradePickerRowID, let idx = labour.firstIndex(where: { $0.id == id }) {
            labour[idx].trade = trimmed
        } else if labour.isEmpty {
            labour.append(VariationLabourLine(id: UUID().uuidString, trade: trimmed, hours: 0))
        } else {
            labour[labour.count - 1].trade = trimmed
        }
        store.customTrades.append(trimmed)
        if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
            Task { await firebaseBackend.addCustomVariationTrade(trimmed, organizationId: orgId) }
        }
        customTradeDraft = ""
        tradePickerRowID = nil
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
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
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
        guard canSave, let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        if !trackerOn, store.voNumberIsDuplicate(voNumber, excludingId: variationId) {
            errorMessage = "This VO number is already used on this job."
            return
        }
        isSaving = true
        while inFlightUploads > 0 {
            try? await Task.sleep(nanoseconds: 200_000_000)
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

private struct VariationTradePickerSheet: View {
    let options: [String]
    var onSelect: (String) -> Void
    var onCustom: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(options, id: \.self) { trade in
                        Button(trade) {
                            onSelect(trade)
                            dismiss()
                        }
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    }
                }
                Section {
                    Button(VariationTrades.customPickerTitle) {
                        onCustom()
                    }
                }
            }
            .navigationTitle("Labour trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
