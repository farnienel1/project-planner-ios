//
//  VariationEditorSheet.swift
//  Project Planner
//
//  New variation form. Visual and behaviour spec: new-variation-redesign.html.
//  Saved documents stay labour[{trade, hours}] and materials[{name, quantity}].
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import FirebaseAuth

private enum VariationFormColors {
    static let bg = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.949, 0.961, 0.980),
        dark: AppAdaptiveColor.rgb(0.043, 0.071, 0.125)
    )
    static let card = AppAdaptiveColor.dynamic(
        light: .white,
        dark: AppAdaptiveColor.rgb(0.075, 0.110, 0.180)
    )
    static let soft = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.933, 0.953, 0.976),
        dark: AppAdaptiveColor.rgb(0.090, 0.133, 0.220)
    )
    static let soft2 = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.890, 0.918, 0.957),
        dark: AppAdaptiveColor.rgb(0.118, 0.165, 0.267)
    )
    static let line = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.886, 0.910, 0.949),
        dark: AppAdaptiveColor.rgb(0.141, 0.192, 0.294)
    )
    static let line2 = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.788, 0.831, 0.894),
        dark: AppAdaptiveColor.rgb(0.216, 0.275, 0.416)
    )
    static let ink = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.055, 0.090, 0.149),
        dark: AppAdaptiveColor.rgb(0.918, 0.941, 0.973)
    )
    static let ink2 = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.275, 0.333, 0.420),
        dark: AppAdaptiveColor.rgb(0.686, 0.733, 0.808)
    )
    static let ink3 = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.478, 0.529, 0.608),
        dark: AppAdaptiveColor.rgb(0.494, 0.549, 0.647)
    )
    static let blue = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.145, 0.388, 0.788),
        dark: AppAdaptiveColor.rgb(0.298, 0.545, 0.902)
    )
    static let blueTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.902, 0.937, 0.988),
        dark: AppAdaptiveColor.rgb(0.090, 0.173, 0.302)
    )
    static let proj = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.055, 0.663, 0.486),
        dark: AppAdaptiveColor.rgb(0.231, 0.796, 0.596)
    )
    static let projTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.882, 0.969, 0.937),
        dark: AppAdaptiveColor.rgb(0.067, 0.196, 0.165)
    )
    static let amber = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.788, 0.518, 0.000),
        dark: AppAdaptiveColor.rgb(0.961, 0.725, 0.227)
    )
    static let amberTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.988, 0.953, 0.855),
        dark: AppAdaptiveColor.rgb(0.227, 0.173, 0.047)
    )
    static let red = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.827, 0.271, 0.247),
        dark: AppAdaptiveColor.rgb(1.000, 0.420, 0.420)
    )
    static let redTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.984, 0.910, 0.906),
        dark: AppAdaptiveColor.rgb(0.239, 0.090, 0.090)
    )
    static let violet = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.478, 0.357, 0.941),
        dark: AppAdaptiveColor.rgb(0.655, 0.545, 1.000)
    )
    static let violetTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.933, 0.918, 0.996),
        dark: AppAdaptiveColor.rgb(0.141, 0.110, 0.290)
    )
}

private struct LabourDraft: Identifiable, Equatable {
    var id: String
    var trade: String
    var operatives: Int
    var hoursEach: Double

    var lineHours: Double { Double(max(operatives, 1)) * hoursEach }
}

private struct MaterialDraft: Identifiable, Equatable {
    var id: String
    var name: String
    var quantity: String
    var unit: String

    var storedQuantity: String {
        let qty = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = qty.isEmpty ? "1" : qty
        // "no" is the untyped count, so the saved string stays "9". m/box/kg become "9m".
        if unit == "no" || unit.isEmpty { return amount }
        return amount + unit
    }
}

private struct LabourComposerState: Equatable {
    var isOpen = false
    var trade = ""
    var operatives = 1
    var hoursEach = 8.0
    var editId: String?
    var duplicateOf: String?

    var total: Double { Double(max(operatives, 1)) * hoursEach }
    var canCommit: Bool {
        !trade.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && operatives >= 1 && hoursEach > 0
    }
}

private struct MaterialComposerState: Equatable {
    var name = ""
    var quantity = ""
    var unit = "no"
    var editId: String?
}

private struct VariationUndoNotice: Equatable {
    var message: String
    var token: UUID
    var canUndo: Bool
}

struct VariationEditorSheet: View {
    static let maxEvidence = 10
    private static let units = ["no", "m", "box", "kg"]

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
    @State private var descriptionExpanded = false
    @State private var labour: [LabourDraft]
    @State private var materials: [MaterialDraft]
    @State private var evidence: [VariationEvidenceItem]
    @State private var labourComposer: LabourComposerState
    @State private var materialComposer = MaterialComposerState()
    @State private var extraTrades: [String] = []
    @State private var catalogue: [MaterialCatalogItem] = []
    @State private var catalogueRecords: [CanonicalBusinessEngine.CanonicalMaterialRecord] = []
    @State private var catalogueSearchGeneration = 0
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var showingCamera = false
    @State private var showingLibrary = false
    @State private var showingFileImporter = false
    @State private var showingEvidenceChoices = false
    @State private var showingTrades = false
    @State private var showingVOEdit = false
    @State private var voDraft = ""
    @State private var customTradeOpen = false
    @State private var customTradeDraft = ""
    @State private var tradeQuery = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var inFlightUploads = 0
    @State private var pendingEvidenceBytes: [String: Data] = [:]
    @State private var persistedVariation: Variation?
    @State private var preparingEvidence = 0
    @State private var undoNotice: VariationUndoNotice?
    @State private var undoRestore: (() -> Void)?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case hours
        case materialName
        case materialQuantity
        case customTrade
    }

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
        _labour = State(initialValue: (existing?.labour ?? []).map {
            LabourDraft(id: $0.id, trade: $0.trade, operatives: 1, hoursEach: $0.hours)
        })
        _materials = State(initialValue: (existing?.materials ?? []).map { line in
            let parsed = Self.parseQuantity(line.quantity)
            return MaterialDraft(id: line.id, name: line.name, quantity: parsed.quantity, unit: parsed.unit)
        })
        _evidence = State(initialValue: existing?.evidence ?? [])
        var composer = LabourComposerState()
        composer.hoursEach = 8
        _labourComposer = State(initialValue: composer)
    }

    private var trackerOn: Bool { store.tracker.enabled }
    private var parentName: String {
        VariationNumbering.parentName(jobNumber: project.jobNumber, siteName: project.siteName)
    }
    private var totalHours: Double { labour.reduce(0) { $0 + $1.lineHours } }
    private var canSave: Bool {
        !heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }
    private var hourPresets: [(label: String, hours: Double)] {
        let day = firebaseBackend.currentOrganization?.settings.payrollTimePolicy.standardPaidHours ?? 0
        let full = day > 0 ? day : 8
        return [("Half day", full / 2), ("Full day", full), ("Day + 2", full + 2)]
    }
    private var tradeChips: [String] {
        let base = Array(VariationTrades.mergedPickerOptions(custom: store.customTrades).prefix(5))
        var seen = Set<String>()
        var chips: [String] = []
        for trade in extraTrades + base {
            let key = trade.lowercased()
            guard seen.insert(key).inserted else { continue }
            chips.append(trade)
            if chips.count == 6 { break }
        }
        return chips
    }
    private var materialSuggestions: [(name: String, unit: String)] {
        let query = materialComposer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        if !catalogue.isEmpty {
            let hits = CanonicalBusinessEngine.rankMaterialRecords(
                query: query,
                records: catalogueRecords,
                limit: 80,
                cacheIdentity: catalogueSearchGeneration
            ) ?? []
            return hits.compactMap { hit in
                catalogue.indices.contains(hit.index) ? catalogue[hit.index] : nil
            }
            .map { ($0.name, Self.formUnit(for: $0.defaultUnit)) }
        }
        let names = materialNames.map { name in
            (name: name, unit: "no")
        }
        return CanonicalBusinessEngine.rankedItems(names, query: query, limit: 80) { row in
            CanonicalBusinessEngine.CanonicalMaterialRecord(name: row.name)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    detailsCard
                    labourCard
                    materialsCard
                    evidenceCard
                    if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(VariationFormColors.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(VariationFormColors.bg.ignoresSafeArea())
            .navigationTitle(existing == nil ? "New variation" : "Edit variation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(VariationFormColors.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("variationEditor.cancel")
                        .fontWeight(.semibold)
                        .foregroundStyle(VariationFormColors.blue)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .accessibilityIdentifier("variationEditor.save")
                        .fontWeight(.semibold)
                        .foregroundStyle(VariationFormColors.blue)
                        .disabled(!canSave)
                        .opacity(canSave ? 1 : 0.42)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if (focusedField == .hours && labourComposer.duplicateOf == nil) || focusedField == .materialQuantity {
                        Spacer()
                        Button(focusedField == .hours ? addLabourTitle : (materialComposer.editId == nil ? "Add material" : "Update line item")) {
                            if focusedField == .hours {
                                commitLabour(.new)
                            } else {
                                commitMaterial()
                            }
                        }
                        .accessibilityIdentifier("variationEditor.addMaterial")
                        .fontWeight(.bold)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
            .overlay(alignment: .bottom) { undoToast }
            .sheet(isPresented: $showingTrades) { tradeSheet }
            .sheet(isPresented: $showingCamera) {
                VariationCameraPicker { image in
                    preparingEvidence += 1
                    Task {
                        await addImage(image, fileName: "photo.jpg")
                        preparingEvidence = max(0, preparingEvidence - 1)
                    }
                }
            }
            .photosPicker(
                isPresented: $showingLibrary,
                selection: $photoItems,
                maxSelectionCount: max(1, Self.maxEvidence - evidence.count),
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                let batch = items
                photoItems = []
                preparingEvidence += 1
                Task {
                    await importPhotos(batch)
                    preparingEvidence = max(0, preparingEvidence - 1)
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    preparingEvidence += 1
                    Task {
                        await importFiles(urls)
                        preparingEvidence = max(0, preparingEvidence - 1)
                    }
                } else if case .failure(let error) = result {
                    errorMessage = error.localizedDescription
                }
            }
            .confirmationDialog("Evidence", isPresented: $showingEvidenceChoices, titleVisibility: .visible) {
                Button("Take photo") { showingCamera = true }
                    .accessibilityIdentifier("variationEditor.takePhoto")
                Button("Photo library") { showingLibrary = true }
                    .accessibilityIdentifier("variationEditor.photoLibrary")
                Button("Choose files") { showingFileImporter = true }
                    .accessibilityIdentifier("variationEditor.chooseFiles")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("variationEditor.cancel2")
            }
            .alert("VO number", isPresented: $showingVOEdit) {
                TextField("VO number", text: $voDraft)
                    .accessibilityIdentifier("variationEditor.voNumber")
                Button("Save") {
                    let trimmed = voDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { voNumber = trimmed }
                }
                    .accessibilityIdentifier("variationEditor.save2")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("variationEditor.cancel3")
            }
            .task(id: firebaseBackend.currentOrganization?.firestoreDocumentId) {
                await loadCatalogue()
            }
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !trackerOn else { return }
                voDraft = voNumber
                showingVOEdit = true
            } label: {
                Text("\(voNumber) · \(trackerOn ? "from tracker" : "auto")")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(VariationFormColors.violet)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(VariationFormColors.violetTint)
                    .clipShape(Capsule())
            }
            .accessibilityIdentifier("variationEditor.voNumber2")
            .buttonStyle(.plain)
            .disabled(trackerOn)
            .accessibilityLabel("VO number \(voNumber)")

            TextField("Heading", text: $heading)
                .accessibilityIdentifier("variationEditor.heading")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(VariationFormColors.ink)
                .padding(.top, 10)
                .padding(.bottom, 4)

            TextField("What changed, who asked for it, and where.", text: $descriptionText, axis: .vertical)
                .accessibilityIdentifier("variationEditor.whatChangedWhoAskedForIt")
                .font(.system(size: 15))
                .foregroundStyle(VariationFormColors.ink2)
                .lineLimit(descriptionExpanded ? 8 : 3, reservesSpace: true)

            Button(descriptionExpanded ? "Less" : "More detail") {
                descriptionExpanded.toggle()
            }
            .accessibilityIdentifier("variationEditor.less")
            .font(.system(size: 13.5, weight: .bold))
            .foregroundStyle(VariationFormColors.blue)
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .formCard()
    }

    private var labourCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Labour", pill: formatHours(totalHours) + " hrs", active: totalHours > 0)
            VStack(alignment: .leading, spacing: 0) {
                if labour.isEmpty {
                    Text("No labour added yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(VariationFormColors.ink3)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
                ForEach(labour) { line in
                    labourRow(line)
                }
                if labourComposer.isOpen {
                    labourComposerView
                } else {
                    Button {
                        openLabourComposer()
                    } label: {
                        Text("+ Add labour item")
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(VariationFormColors.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(VariationFormColors.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(VariationFormColors.line2, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .accessibilityIdentifier("variationEditor.addLabourItem")
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .formCard()
    }

    private func labourRow(_ line: LabourDraft) -> some View {
        let editing = labourComposer.editId == line.id
        let isLast = labour.last?.id == line.id
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(line.trade)
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(VariationFormColors.ink)
                    .lineLimit(1)
                if line.operatives > 1 {
                    Text("\(line.operatives) operatives × \(formatHours(line.hoursEach)) hrs each")
                        .font(.system(size: 12.5))
                        .foregroundStyle(VariationFormColors.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(formatHours(line.lineHours)) hrs")
                .font(.system(size: 15.5, weight: .heavy))
                .foregroundStyle(VariationFormColors.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(VariationFormColors.soft)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            iconButton(systemImage: "gearshape", label: "Edit \(line.trade)", destructive: false) {
                editLabour(line)
            }
            iconButton(systemImage: "xmark", label: "Remove \(line.trade)", destructive: true) {
                removeLabour(line)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, editing ? 10 : 0)
        .background(editing ? VariationFormColors.blueTint : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottom) {
            if !editing && !isLast {
                Rectangle().fill(VariationFormColors.line).frame(height: 1)
            }
        }
    }

    private var labourComposerView: some View {
        let editing = labourComposer.editId != nil
        return VStack(alignment: .leading, spacing: 0) {
            Text(editing ? "Editing line item" : "New labour item")
                .formMicroLabel()
            Button { showingTrades = true } label: {
                HStack {
                    Text(labourComposer.trade.isEmpty ? "Choose a trade" : labourComposer.trade)
                        .font(.system(size: 16, weight: labourComposer.trade.isEmpty ? .regular : .semibold))
                        .foregroundStyle(labourComposer.trade.isEmpty ? VariationFormColors.ink3 : VariationFormColors.ink)
                    Spacer()
                    Text("Change ›")
                        .font(.system(size: 13))
                        .foregroundStyle(VariationFormColors.ink3)
                }
                .padding(13)
                .background(VariationFormColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            }
            .accessibilityIdentifier("variationEditor.chooseATrade")
            .buttonStyle(.plain)
            .accessibilityLabel(labourComposer.trade.isEmpty ? "Choose a trade" : "Change \(labourComposer.trade)")

            if labourComposer.trade.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(tradeChips, id: \.self) { trade in
                            Button(trade) { chooseTrade(trade) }
                                .accessibilityIdentifier("variationEditor.row.\(trade).\(AccessibilityID.token(trade))")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(VariationFormColors.ink)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background(VariationFormColors.card)
                                .overlay(Capsule().stroke(VariationFormColors.line, lineWidth: 1))
                                .clipShape(Capsule())
                        }
                        Button("All trades") { showingTrades = true }
                            .accessibilityIdentifier("variationEditor.allTrades")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(VariationFormColors.blue)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(VariationFormColors.card)
                            .overlay(Capsule().stroke(VariationFormColors.line, lineWidth: 1))
                            .clipShape(Capsule())
                    }
                }
                .padding(.top, 9)
                .scrollClipDisabled()
            }

            VStack(spacing: 10) {
                stepperBox(title: "Operatives") {
                    stepper(
                        valueText: "\(labourComposer.operatives)",
                        decrementLabel: "Fewer operatives",
                        incrementLabel: "More operatives",
                        decrementDisabled: labourComposer.operatives <= 1,
                        onDecrement: { labourComposer.operatives = max(1, labourComposer.operatives - 1) },
                        onIncrement: { labourComposer.operatives += 1 }
                    ) {
                        TextField("1", value: $labourComposer.operatives, format: .number)
                            .accessibilityIdentifier("variationEditor.numberOfOperatives")
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 17, weight: .heavy))
                            .onChange(of: labourComposer.operatives) { _, value in
                                if value < 1 { labourComposer.operatives = 1 }
                            }
                            .accessibilityLabel("Number of operatives")
                    }
                }
                stepperBox(title: "Hours each") {
                    stepper(
                        valueText: formatHours(labourComposer.hoursEach),
                        decrementLabel: "Fewer hours",
                        incrementLabel: "More hours",
                        decrementDisabled: labourComposer.hoursEach <= 0,
                        onDecrement: { bumpHours(-0.5) },
                        onIncrement: { bumpHours(0.5) }
                    ) {
                        TextField("0", value: $labourComposer.hoursEach, format: .number)
                            .accessibilityIdentifier("variationEditor.hoursPerOperative")
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 17, weight: .heavy))
                            .focused($focusedField, equals: .hours)
                            .onChange(of: labourComposer.hoursEach) { _, value in
                                if value < 0 { labourComposer.hoursEach = 0 }
                            }
                            .accessibilityLabel("Hours per operative")
                    }
                }
            }
            .padding(.top, 11)

            HStack(spacing: 6) {
                ForEach(hourPresets, id: \.label) { preset in
                    Button(preset.label) { labourComposer.hoursEach = preset.hours }
                        .accessibilityIdentifier("variationEditor.row.\(preset.label)")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(VariationFormColors.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(VariationFormColors.card)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                }
            }
            .padding(.top, 10)

            if let duplicateId = labourComposer.duplicateOf,
               let existingLine = labour.first(where: { $0.id == duplicateId }) {
                HStack(alignment: .top, spacing: 9) {
                    Text("⚠")
                        .font(.system(size: 13))
                        .foregroundStyle(VariationFormColors.amber)
                    (
                        Text(labourComposer.trade).fontWeight(.bold).foregroundColor(VariationFormColors.amber)
                        + Text(" is already on this variation")
                            .fontWeight(.bold)
                            .foregroundColor(VariationFormColors.amber)
                        + Text(" at \(formatHours(existingLine.hoursEach)) hrs each. Merge them into one line, or add a second line if this was a separate visit.")
                            .foregroundColor(VariationFormColors.ink2)
                    )
                    .font(.system(size: 12.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VariationFormColors.amberTint)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .padding(.top, 11)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }

            HStack(spacing: 8) {
                if labourComposer.duplicateOf != nil {
                    composerButton("Add separate", primary: false) { commitLabour(.separate) }
                    composerButton("Merge", primary: true) { commitLabour(.merge) }
                } else {
                    if editing || !labourComposer.trade.isEmpty {
                        composerButton("Cancel", primary: false) {
                            labourComposer = freshComposer(open: false)
                        }
                    }
                    composerButton(addLabourTitle, primary: true) { commitLabour(.new) }
                        .disabled(!labourComposer.canCommit)
                        .opacity(labourComposer.canCommit ? 1 : 0.4)
                }
            }
            .padding(.top, 11)
        }
        .padding(12)
        .background(editing ? VariationFormColors.blueTint : VariationFormColors.soft)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(editing ? VariationFormColors.blue.opacity(0.3) : VariationFormColors.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 4)
    }

    private var addLabourTitle: String {
        if labourComposer.editId != nil { return "Update line item" }
        if labourComposer.total > 0 { return "Add · \(formatHours(labourComposer.total)) hrs" }
        return "Add"
    }

    private var materialsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                "Materials",
                pill: "\(materials.count) line\(materials.count == 1 ? "" : "s")",
                active: !materials.isEmpty
            )
            VStack(alignment: .leading, spacing: 0) {
                if materials.isEmpty {
                    Text("No materials added yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(VariationFormColors.ink3)
                        .padding(.bottom, 2)
                }
                ForEach(materials) { line in
                    materialRow(line)
                }
                materialComposerView
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .formCard()
    }

    private func materialRow(_ line: MaterialDraft) -> some View {
        let editing = materialComposer.editId == line.id
        let isLast = materials.last?.id == line.id
        return HStack(spacing: 8) {
            Text(line.name)
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(VariationFormColors.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(line.quantity) \(line.unit)")
                .font(.system(size: 15.5, weight: .heavy))
                .foregroundStyle(VariationFormColors.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(VariationFormColors.soft)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            iconButton(systemImage: "gearshape", label: "Edit \(line.name)", destructive: false) {
                editMaterial(line)
            }
            iconButton(systemImage: "xmark", label: "Remove \(line.name)", destructive: true) {
                removeMaterial(line)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, editing ? 10 : 0)
        .background(editing ? VariationFormColors.blueTint : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottom) {
            if !editing && !isLast {
                Rectangle().fill(VariationFormColors.line).frame(height: 1)
            }
        }
    }

    private var materialComposerView: some View {
        let editing = materialComposer.editId != nil
        return VStack(alignment: .leading, spacing: 0) {
            Text(editing ? "Editing line item" : "New material")
                .formMicroLabel()
            HStack(spacing: 8) {
                TextField("Material name", text: $materialComposer.name)
                    .accessibilityIdentifier("variationEditor.materialName")
                    .font(.system(size: 16))
                    .focused($focusedField, equals: .materialName)
                    .submitLabel(.done)
                    .onSubmit { commitMaterial() }
                    .padding(13)
                    .background(VariationFormColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                    .accessibilityLabel("Material name")
                TextField("Qty", text: $materialComposer.quantity)
                    .accessibilityIdentifier("variationEditor.quantityOrLength")
                    .font(.system(size: 16, weight: .bold))
                    .focused($focusedField, equals: .materialQuantity)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .submitLabel(.done)
                    .onSubmit { commitMaterial() }
                    .frame(width: 80)
                    .padding(.vertical, 13)
                    .background(VariationFormColors.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                    .accessibilityLabel("Quantity or length")
            }
            HStack(spacing: 3) {
                ForEach(Self.units, id: \.self) { unit in
                    Button(unit) { materialComposer.unit = unit }
                        .accessibilityIdentifier("variationEditor.row.\(unit).unit")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(materialComposer.unit == unit ? Color.white : VariationFormColors.ink2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(materialComposer.unit == unit ? VariationFormColors.blue : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel("Unit \(unit)")
                        .accessibilityAddTraits(materialComposer.unit == unit ? .isSelected : [])
                }
            }
            .padding(3)
            .background(VariationFormColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .padding(.top, 9)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Unit")

            if !materialSuggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(materialSuggestions, id: \.name) { suggestion in
                        Button {
                            materialComposer.name = suggestion.name
                            materialComposer.unit = suggestion.unit
                            focusedField = .materialQuantity
                        } label: {
                            HStack {
                                Text(suggestion.name)
                                    .font(.system(size: 14.5))
                                    .foregroundStyle(VariationFormColors.ink)
                                Spacer()
                                Text(suggestion.unit)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(VariationFormColors.ink3)
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 12)
                        }
                        .accessibilityIdentifier("variationEditor.row.\(suggestion.name)")
                        .buttonStyle(.plain)
                        Divider().overlay(VariationFormColors.line)
                    }
                }
                .background(VariationFormColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 9)
            }

            HStack(spacing: 8) {
                if editing {
                    composerButton("Cancel", primary: false) {
                        materialComposer = MaterialComposerState(unit: materialComposer.unit)
                    }
                }
                composerButton(editing ? "Update line item" : "Add material", primary: true) {
                    commitMaterial()
                }
                .disabled(materialComposer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(materialComposer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            }
            .padding(.top, 11)
        }
        .padding(12)
        .background(editing ? VariationFormColors.blueTint : VariationFormColors.soft)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(editing ? VariationFormColors.blue.opacity(0.3) : VariationFormColors.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 10)
    }

    private var evidenceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                "Evidence",
                pill: "\(evidence.count) file\(evidence.count == 1 ? "" : "s")",
                active: !evidence.isEmpty
            )
            VStack(alignment: .leading, spacing: 0) {
                if evidence.isEmpty {
                    VStack(spacing: 10) {
                        Text("Please upload any supporting evidence here")
                            .font(.system(size: 13.5))
                            .foregroundStyle(VariationFormColors.ink2)
                            .multilineTextAlignment(.center)
                        Button("Take photos or choose files") { presentEvidencePicker() }
                            .accessibilityIdentifier("variationEditor.takePhotosOrChooseFiles")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(VariationFormColors.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(VariationFormColors.soft2)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Text("Add as many as you need — up to \(Self.maxEvidence) photos, videos, or files per variation. Each file must be 20 MB or smaller.")
                            .font(.system(size: 12))
                            .foregroundStyle(VariationFormColors.ink3)
                            .multilineTextAlignment(.center)
                    }
                    .padding(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(VariationFormColors.line2, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    )
                } else {
                    VStack(spacing: 7) {
                        ForEach(evidence) { item in
                            HStack(spacing: 10) {
                                Text(typeBadge(item))
                                    .font(.system(size: 10.5, weight: .heavy))
                                    .foregroundStyle(VariationFormColors.blue)
                                    .frame(width: 30, height: 30)
                                    .background(VariationFormColors.blueTint)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                Text(item.isPending ? "\(item.fileName) — queued" : item.fileName)
                                    .font(.system(size: 13.5))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                iconButton(systemImage: "xmark", label: "Remove \(item.fileName)", destructive: true) {
                                    Task { await removeEvidence(item) }
                                }
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .background(VariationFormColors.soft)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                    }
                    Button("+ Add more evidence") { presentEvidencePicker() }
                        .accessibilityIdentifier("variationEditor.addMoreEvidence")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(VariationFormColors.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(VariationFormColors.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(VariationFormColors.line2, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .disabled(evidence.count >= Self.maxEvidence)
                        .opacity(evidence.count >= Self.maxEvidence ? 0.45 : 1)
                        .padding(.top, 10)
                    Text(evidenceLimitCopy)
                        .font(.system(size: 12))
                        .foregroundStyle(VariationFormColors.ink3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 9)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .formCard()
    }

    private var evidenceLimitCopy: String {
        if evidence.count >= Self.maxEvidence {
            return "\(evidence.count) of \(Self.maxEvidence) added — that is the limit"
        }
        return "\(evidence.count) of \(Self.maxEvidence) added. Photos, videos, PDFs, and other files."
    }

    private var footer: some View {
        VStack(spacing: 9) {
            HStack(spacing: 6) {
                footerPill("\(formatHours(totalHours)) hrs", on: totalHours > 0)
                footerPill("\(materials.count) material\(materials.count == 1 ? "" : "s")", on: !materials.isEmpty)
                footerPill("\(evidence.count) evidence file\(evidence.count == 1 ? "" : "s")", on: !evidence.isEmpty)
            }
            Button {
                Task { await save() }
            } label: {
                Text(isSaving ? "Saving…" : "Save variation")
                    .font(.system(size: 16.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(VariationFormColors.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: canSave ? VariationFormColors.blue.opacity(0.32) : .clear, radius: 12, y: 8)
            }
            .accessibilityIdentifier("variationEditor.saving")
            .buttonStyle(.plain)
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.42)
            Text("Saves as Open on \(parentName) and notifies every admin")
                .font(.system(size: 12))
                .foregroundStyle(VariationFormColors.ink3)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(VariationFormColors.bg.opacity(0.92))
        .overlay(alignment: .top) { Rectangle().fill(VariationFormColors.line).frame(height: 1) }
    }

    @ViewBuilder
    private var undoToast: some View {
        if let undoNotice {
            HStack(spacing: 12) {
                Text(undoNotice.message)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                if undoNotice.canUndo {
                    Button("Undo") { performUndo() }
                        .accessibilityIdentifier("variationEditor.undo")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(red: 0.498, green: 0.690, blue: 1))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Color(red: 0.055, green: 0.090, blue: 0.149))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.bottom, 96)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityLabel(undoNotice.message)
        }
    }

    private var tradeSheet: some View {
        NavigationStack {
            List {
                ForEach(filteredTrades, id: \.self) { trade in
                    Button(trade) {
                        chooseTrade(trade)
                        showingTrades = false
                    }
                    .accessibilityIdentifier("variationEditor.row.\(trade).\(AccessibilityID.token(trade))2")
                    .font(.system(size: 15.5))
                    .foregroundStyle(VariationFormColors.ink)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(VariationFormColors.bg)
            .searchable(text: $tradeQuery, prompt: "Search trades")
            .navigationTitle("All trades")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { customTradeFooter }
            .onAppear { tradeQuery = "" }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(VariationFormColors.bg)
    }
    private var filteredTrades: [String] {
        let all = extraTrades + VariationTrades.mergedPickerOptions(custom: store.customTrades)
        var seen = Set<String>()
        let unique = all.filter { seen.insert($0.lowercased()).inserted }
        let query = tradeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return unique }
        return unique.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var customTradeFooter: some View {
        VStack(spacing: 8) {
            if customTradeOpen {
                HStack(spacing: 8) {
                    TextField("Trade name", text: $customTradeDraft)
                        .accessibilityIdentifier("variationEditor.customTradeName")
                        .focused($focusedField, equals: .customTrade)
                        .submitLabel(.done)
                        .onSubmit { commitCustomTrade() }
                        .padding(13)
                        .background(VariationFormColors.soft)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VariationFormColors.line))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityLabel("Custom trade name")
                    Button("Add") { commitCustomTrade() }
                        .accessibilityIdentifier("variationEditor.add")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .background(VariationFormColors.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .disabled(customTradeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(customTradeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                }
                Text("Saved to your organisation’s trade list for next time.")
                    .font(.system(size: 12))
                    .foregroundStyle(VariationFormColors.ink3)
            } else {
                Button("+ Custom trade") {
                    customTradeOpen = true
                    focusedField = .customTrade
                }
                .accessibilityIdentifier("variationEditor.customTrade")
                .font(.system(size: 14.5, weight: .bold))
                .foregroundStyle(VariationFormColors.blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(VariationFormColors.line2, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(VariationFormColors.card)
    }

    private func sectionHeader(_ title: String, pill: String, active: Bool) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(VariationFormColors.ink)
            Spacer()
            Text(pill)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(active ? VariationFormColors.proj : VariationFormColors.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(active ? VariationFormColors.projTint : VariationFormColors.soft)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func footerPill(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(on ? VariationFormColors.proj : VariationFormColors.ink2)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(on ? VariationFormColors.projTint : VariationFormColors.card)
            .overlay(Capsule().stroke(on ? Color.clear : VariationFormColors.line, lineWidth: 1))
            .clipShape(Capsule())
    }

    private func iconButton(systemImage: String, label: String, destructive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(destructive ? VariationFormColors.red : VariationFormColors.ink2)
                .frame(width: 34, height: 34)
                .background(destructive ? VariationFormColors.redTint : VariationFormColors.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(destructive ? VariationFormColors.red.opacity(0.26) : VariationFormColors.line, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .accessibilityIdentifier("variationEditor.icon")
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func stepperBox<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .formMicroLabel()
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VariationFormColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
    }

    private func stepper<Field: View>(
        valueText: String,
        decrementLabel: String,
        incrementLabel: String,
        decrementDisabled: Bool,
        onDecrement: @escaping () -> Void,
        onIncrement: @escaping () -> Void,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(spacing: 2) {
            Button("−", action: onDecrement)
                .accessibilityIdentifier("variationEditor.stepper")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(VariationFormColors.blue)
                .frame(width: 36, height: 36)
                .background(VariationFormColors.soft)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .disabled(decrementDisabled)
                .opacity(decrementDisabled ? 0.3 : 1)
                .accessibilityLabel(decrementLabel)
            field()
                .frame(maxWidth: .infinity)
            Button("+", action: onIncrement)
                .accessibilityIdentifier("variationEditor.stepper2")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(VariationFormColors.blue)
                .frame(width: 36, height: 36)
                .background(VariationFormColors.soft)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityLabel(incrementLabel)
        }
        .accessibilityHint(valueText)
    }

    private func composerButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14.5, weight: .bold))
                .foregroundStyle(primary ? Color.white : VariationFormColors.ink2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(primary ? VariationFormColors.blue : VariationFormColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: primary ? .clear : .black.opacity(0.06), radius: 1, y: 1)
        }
        .accessibilityIdentifier("variationEditor.\(AccessibilityID.token(title))")
        .buttonStyle(.plain)
    }

    private func freshComposer(open: Bool) -> LabourComposerState {
        var composer = LabourComposerState()
        composer.isOpen = open
        composer.hoursEach = hourPresets.first(where: { $0.label == "Full day" })?.hours ?? 8
        return composer
    }

    private func openLabourComposer() {
        labourComposer = freshComposer(open: true)
    }

    private func chooseTrade(_ trade: String) {
        labourComposer.isOpen = true
        labourComposer.trade = trade
        labourComposer.duplicateOf = nil
        showingTrades = false
        customTradeOpen = false
        focusedField = .hours
    }

    private func bumpHours(_ delta: Double) {
        labourComposer.hoursEach = max(0, (labourComposer.hoursEach + delta * 2).rounded() / 2)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private enum LabourCommit { case new, merge, separate }

    private func commitLabour(_ mode: LabourCommit) {
        guard labourComposer.canCommit else { return }
        if mode == .merge, let targetId = labourComposer.duplicateOf,
           let index = labour.firstIndex(where: { $0.id == targetId }) {
            let merged = labour[index].lineHours + labourComposer.total
            labour[index].operatives = 1
            labour[index].hoursEach = merged
            showUndo("\(labour[index].trade) merged — \(formatHours(merged)) hrs", restore: nil)
            labourComposer = freshComposer(open: false)
            return
        }
        if let editId = labourComposer.editId, let index = labour.firstIndex(where: { $0.id == editId }) {
            labour[index].trade = labourComposer.trade
            labour[index].operatives = labourComposer.operatives
            labour[index].hoursEach = labourComposer.hoursEach
            showUndo("\(labourComposer.trade) updated", restore: nil)
            labourComposer = freshComposer(open: false)
            return
        }
        if mode == .new, let dupe = labour.first(where: { $0.trade == labourComposer.trade }) {
            labourComposer.duplicateOf = dupe.id
            return
        }
        labour.append(LabourDraft(
            id: UUID().uuidString,
            trade: labourComposer.trade,
            operatives: labourComposer.operatives,
            hoursEach: labourComposer.hoursEach
        ))
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        labourComposer = freshComposer(open: true)
    }

    private func editLabour(_ line: LabourDraft) {
        labourComposer = LabourComposerState(
            isOpen: true,
            trade: line.trade,
            operatives: line.operatives,
            hoursEach: line.hoursEach,
            editId: line.id,
            duplicateOf: nil
        )
        focusedField = .hours
    }

    private func removeLabour(_ line: LabourDraft) {
        guard let index = labour.firstIndex(where: { $0.id == line.id }) else { return }
        let removed = labour[index]
        labour.remove(at: index)
        if labourComposer.editId == removed.id {
            labourComposer = freshComposer(open: false)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        showUndo("\(removed.trade) removed") {
            labour.insert(removed, at: min(index, labour.count))
        }
    }

    private func commitMaterial() {
        let name = materialComposer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let quantity = materialComposer.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = quantity.isEmpty ? "1" : quantity
        if let editId = materialComposer.editId, let index = materials.firstIndex(where: { $0.id == editId }) {
            materials[index].name = name
            materials[index].quantity = amount
            materials[index].unit = materialComposer.unit
            showUndo("\(name) updated", restore: nil)
        } else {
            materials.append(MaterialDraft(id: UUID().uuidString, name: name, quantity: amount, unit: materialComposer.unit))
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        let unit = materialComposer.unit
        materialComposer = MaterialComposerState(unit: unit)
        focusedField = .materialName
    }

    private func editMaterial(_ line: MaterialDraft) {
        materialComposer = MaterialComposerState(name: line.name, quantity: line.quantity, unit: line.unit, editId: line.id)
        focusedField = .materialName
    }

    private func removeMaterial(_ line: MaterialDraft) {
        guard let index = materials.firstIndex(where: { $0.id == line.id }) else { return }
        let removed = materials[index]
        materials.remove(at: index)
        if materialComposer.editId == removed.id {
            materialComposer = MaterialComposerState(unit: materialComposer.unit)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        showUndo("\(removed.name) removed") {
            materials.insert(removed, at: min(index, materials.count))
        }
    }

    private func commitCustomTrade() {
        let name = customTradeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let known = (extraTrades + VariationTrades.mergedPickerOptions(custom: store.customTrades))
            .contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        if !known {
            extraTrades.insert(name, at: 0)
            if !store.customTrades.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                store.customTrades.append(name)
            }
            if let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                Task { await firebaseBackend.addCustomVariationTrade(name, organizationId: orgId) }
            }
        }
        customTradeDraft = ""
        customTradeOpen = false
        chooseTrade(name)
    }

    private func presentEvidencePicker() {
        let room = Self.maxEvidence - evidence.count
        guard room > 0 else {
            showUndo("Up to \(Self.maxEvidence) files per variation", restore: nil)
            return
        }
        showingEvidenceChoices = true
    }

    private func showUndo(_ message: String, restore: (() -> Void)? = nil) {
        let token = UUID()
        undoRestore = restore
        undoNotice = VariationUndoNotice(message: message, token: token, canUndo: restore != nil)
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if undoNotice?.token == token {
                undoNotice = nil
                undoRestore = nil
            }
        }
    }

    private func performUndo() {
        undoRestore?()
        undoRestore = nil
        undoNotice = nil
    }

    private func loadCatalogue() async {
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        catalogue = (try? await firebaseBackend.loadMaterialCatalogue(organizationId: orgId)) ?? []
        catalogueRecords = catalogue.map(\.canonicalSearchRecord)
        catalogueSearchGeneration = CanonicalBusinessEngine.makeMaterialSearchCacheIdentity()
        CanonicalBusinessEngine.installMaterialSearchRecords(catalogueRecords, cacheIdentity: catalogueSearchGeneration)
    }

    private static func formUnit(for unit: MaterialUnit) -> String {
        switch unit {
        case .box: return "box"
        case .length: return "m"
        default: return "no"
        }
    }

    private static func parseQuantity(_ raw: String) -> (quantity: String, unit: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let units = ["box", "kg", "no", "m"]
        let lower = trimmed.lowercased()
        for unit in units {
            if lower.hasSuffix(" " + unit) {
                let qty = String(trimmed.dropLast(unit.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                return (qty.isEmpty ? "1" : qty, unit)
            }
            if lower.hasSuffix(unit), trimmed.count > unit.count {
                let prefix = trimmed.dropLast(unit.count)
                if prefix.last?.isNumber == true || prefix.last == "." || prefix.last == " " {
                    let qty = String(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
                    return (qty.isEmpty ? "1" : qty, unit)
                }
            }
        }
        return (trimmed.isEmpty ? "1" : trimmed, "no")
    }

    private func formatHours(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.05 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    @MainActor
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        let room = Self.maxEvidence - evidence.count
        if room <= 0 {
            showUndo("Up to \(Self.maxEvidence) files per variation", restore: nil)
            return
        }
        if items.count > room {
            showUndo("Only \(room) more file\(room == 1 ? "" : "s") fit on this variation", restore: nil)
        }
        for item in items.prefix(room) {
            await importPhotoItem(item)
        }
    }

    @MainActor
    private func importPhotoItem(_ item: PhotosPickerItem) async {
        do {
            if let picked = try await item.loadTransferable(type: PickedEvidenceFile.self) {
                let name = picked.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
                let fileName = name.isEmpty ? suggestedFileName(for: item) : name
                await uploadPickedPayload(picked.data, fileName: fileName, contentType: mime(for: fileName))
                return
            }
            if let data = try await item.loadTransferable(type: Data.self) {
                let fileName = suggestedFileName(for: item)
                await uploadPickedPayload(data, fileName: fileName, contentType: mime(for: fileName))
                return
            }
            errorMessage = "Could not read that item. Try Choose files."
        } catch {
            errorMessage = "Could not read that item. Try Choose files."
        }
    }

    private func suggestedFileName(for item: PhotosPickerItem) -> String {
        let type = item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? "bin"
        if type?.conforms(to: .image) == true { return "photo.\(ext)" }
        if type?.conforms(to: .movie) == true { return "video.\(ext)" }
        return "evidence.\(ext)"
    }

    private func uploadPickedPayload(_ data: Data, fileName: String, contentType: String) async {
        let type = contentType.lowercased()
        if type.hasPrefix("image/") || UTType(mimeType: contentType)?.conforms(to: .image) == true,
           let image = UIImage(data: data),
           let jpeg = VariationEvidenceProcessor.preparedImageData(image) {
            let jpegName = (fileName as NSString).pathExtension.lowercased() == "jpg" || (fileName as NSString).pathExtension.lowercased() == "jpeg"
                ? fileName
                : "photo.jpg"
            await uploadData(jpeg, fileName: jpegName, contentType: "image/jpeg")
            return
        }
        await uploadData(data, fileName: fileName, contentType: contentType.isEmpty ? mime(for: fileName) : contentType)
    }

    @MainActor
    private func importFiles(_ urls: [URL]) async {
        let room = Self.maxEvidence - evidence.count
        if room <= 0 {
            showUndo("Up to \(Self.maxEvidence) files per variation", restore: nil)
            return
        }
        if urls.count > room {
            showUndo("Only \(room) more file\(room == 1 ? "" : "s") fit on this variation", restore: nil)
        }
        for url in urls.prefix(room) {
            await importFile(url)
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
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true, let image = UIImage(data: data) {
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
        guard VariationEvidenceProcessor.isAllowed(fileName: fileName, contentType: contentType, byteCount: data.count) else {
            errorMessage = data.count > VariationEvidenceProcessor.maxBytes
                ? "That file is too large. Evidence must be 20 MB or smaller."
                : "That file could not be added."
            return
        }
        guard evidence.count < Self.maxEvidence else {
            showUndo("Up to \(Self.maxEvidence) files per variation", restore: nil)
            return
        }
        let evidenceId = UUID().uuidString
        pendingEvidenceBytes[evidenceId] = data
        evidence.append(
            VariationEvidenceItem(
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
        )
    }

    private func removeEvidence(_ item: VariationEvidenceItem) async {
        evidence.removeAll { $0.id == item.id }
        pendingEvidenceBytes[item.id] = nil
        if !item.storagePath.isEmpty {
            await firebaseBackend.deleteVariationEvidenceFile(storagePath: item.storagePath)
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        let orgId = (await firebaseBackend.resolveOrganizationIdForFirebaseWrites(
            preferredFallback: firebaseBackend.currentOrganization?.firestoreDocumentId
        )) ?? ""
        guard !orgId.isEmpty else {
            errorMessage = "Organization ID is missing. Open Settings → Force Reload Data, then retry."
            isSaving = false
            return
        }
        if !trackerOn, store.voNumberIsDuplicate(voNumber, excludingId: variationId) {
            errorMessage = "This VO number is already used on this job."
            isSaving = false
            return
        }
        let savedLabour = labour
            .filter { $0.hoursEach > 0 && !$0.trade.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { VariationLabourLine(id: $0.id, trade: $0.trade, hours: $0.lineHours) }
        let savedMaterials = materials
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { VariationMaterialLine(id: $0.id, name: $0.name, quantity: $0.storedQuantity) }
        let user = userStore.displayUser
        let uid = user?.id ?? firebaseBackend.currentUser?.uid ?? ""
        let name = (user?.fullName.isEmpty == false ? user?.fullName : user?.email) ?? "Unknown"
        let parentType: VariationParentType = project.jobType == .smallWorks ? .smallWork : .project
        let now = Date()
        let baseline = persistedVariation ?? existing
        let creating = baseline == nil
        var variation: Variation
        if var baseline {
            baseline.voNumber = trackerOn ? baseline.voNumber : voNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            baseline.heading = heading.trimmingCharacters(in: .whitespacesAndNewlines)
            baseline.description = descriptionText
            baseline.labour = savedLabour
            baseline.materials = savedMaterials
            baseline.evidence = evidence.filter { !$0.isPending }
            baseline.updatedByUid = uid
            baseline.updatedAt = now
            baseline.recomputeCounts()
            variation = baseline
        } else {
            variation = Variation(
                id: variationId,
                orgId: orgId,
                parentType: parentType,
                parentId: project.id.uuidString,
                parentName: parentName,
                origin: .app,
                voNumber: voNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                sequence: (store.variations.map(\.sequence).max() ?? 0) + 1,
                voNumberLocked: false,
                numberHistory: [],
                heading: heading.trimmingCharacters(in: .whitespacesAndNewlines),
                description: descriptionText,
                status: .open,
                labour: savedLabour,
                materials: savedMaterials,
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
            persistedVariation = variation
            store.upsert(variation)
            if creating {
                await notificationService.notifyVariationAdded(
                    parentId: project.id,
                    parentName: variation.parentName,
                    isSmallWorks: project.jobType == .smallWorks,
                    createdByUserId: uid
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
            return
        }
        let uploadError = await uploadQueuedEvidence(orgId: orgId)
        let attached = evidence.filter { !$0.isPending }
        if attached.map(\.id) != variation.evidence.map(\.id) {
            variation.evidence = attached
            variation.recomputeCounts()
            do {
                try await firebaseBackend.saveVariation(variation, organizationId: orgId)
                persistedVariation = variation
                store.upsert(variation)
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
                return
            }
        }
        if let uploadError {
            errorMessage = uploadError
            isSaving = false
            return
        }
        dismiss()
    }

    /// Uploads files queued on this variation. A storage failure leaves the saved variation in place.
    private func uploadQueuedEvidence(orgId: String) async -> String? {
        let queued = evidence.filter(\.isPending)
        var failed = 0
        for item in queued {
            guard let data = pendingEvidenceBytes[item.id] else { continue }
            inFlightUploads += 1
            do {
                let uploaded = try await firebaseBackend.uploadVariationEvidence(
                    data: data,
                    fileName: item.fileName,
                    contentType: item.contentType,
                    organizationId: orgId,
                    parentId: project.id.uuidString,
                    variationId: variationId,
                    evidenceId: item.id
                )
                if let idx = evidence.firstIndex(where: { $0.id == item.id }) {
                    evidence[idx].storagePath = uploaded.storagePath
                    evidence[idx].downloadURL = uploaded.downloadURL
                    evidence[idx].isPending = false
                }
                pendingEvidenceBytes[item.id] = nil
            } catch {
                failed += 1
            }
            inFlightUploads = max(0, inFlightUploads - 1)
        }
        if failed == 0 { return nil }
        return failed == 1
            ? "The variation was saved. One file did not upload."
            : "The variation was saved. \(failed) files did not upload."
    }

    private func mime(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private func typeBadge(_ item: VariationEvidenceItem) -> String {
        let ext = (item.fileName as NSString).pathExtension.uppercased()
        let badge = ext.isEmpty ? "FILE" : String(ext.prefix(4))
        return badge
    }
}

private extension View {
    func formCard() -> some View {
        self
            .background(VariationFormColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(VariationFormColors.line, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
            .shadow(color: Color.black.opacity(0.06), radius: 11, y: 8)
    }
}

private extension Text {
    func formMicroLabel() -> some View {
        self
            .font(.system(size: 11.5, weight: .heavy))
            .foregroundStyle(VariationFormColors.ink3)
            .tracking(0.35)
            .textCase(.uppercase)
    }
}

private struct PickedEvidenceFile: Transferable {
    let data: Data
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            PickedEvidenceFile(data: data, fileName: "")
        }
        DataRepresentation(importedContentType: .movie) { data in
            PickedEvidenceFile(data: data, fileName: "")
        }
        DataRepresentation(importedContentType: .pdf) { data in
            PickedEvidenceFile(data: data, fileName: "document.pdf")
        }
        DataRepresentation(importedContentType: .data) { data in
            PickedEvidenceFile(data: data, fileName: "")
        }
        FileRepresentation(importedContentType: .item) { received in
            let data = try Data(contentsOf: received.file)
            let name = received.file.lastPathComponent
            return PickedEvidenceFile(data: data, fileName: name)
        }
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
