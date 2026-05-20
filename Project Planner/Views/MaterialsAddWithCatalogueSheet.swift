//
//  MaterialsAddWithCatalogueSheet.swift
//  Project Planner
//

import SwiftUI
import FirebaseAuth

private struct MaterialAutocompleteSuggestion: Identifiable {
    enum Source { case catalogue, recent }

    let id: String
    let source: Source
    let name: String
    let brand: String
    let productCode: String?
    let unit: MaterialUnit
    let sizeOrLength: String?
    let category: String?
    let catalogueItem: MaterialCatalogItem?
}

struct MaterialsAddWithCatalogueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    let project: Project
    let initialDate: Date
    var existingMaterial: MaterialItem?
    var canSendQuoteOrOrder: Bool = true

    @StateObject private var catalogueStore = MaterialCatalogStore()

    @State private var query = ""
    @State private var selectedCatalogue: MaterialCatalogItem?
    @State private var quantity = 1
    @State private var unit: MaterialUnit = .number
    @State private var neededDate: Date
    @State private var notes = ""
    @State private var customItemName = ""
    @State private var customBrand = ""
    @State private var customProductCode = ""
    @State private var sizeOrLength = ""
    @State private var customCategory = "Other"
    @State private var websiteURL = ""
    @State private var showingDuplicateAlert = false
    @State private var duplicateExisting: MaterialCatalogItem?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var recentMaterials: [MaterialItem] = []
    @State private var prefersCustomEntry = false

    private var categorySuggestions: [String] {
        let typed = customCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        var all: [String] = catalogueStore.items.compactMap { $0.category?.trimmingCharacters(in: .whitespacesAndNewlines) }
        all += recentMaterials.compactMap { $0.category?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let unique = Array(Set(all.filter { !$0.isEmpty })).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        guard !typed.isEmpty else { return Array(unique.prefix(6)) }
        return unique.filter {
            $0.localizedCaseInsensitiveContains(typed) && $0.caseInsensitiveCompare(typed) != .orderedSame
        }
        .prefix(6)
        .map { $0 }
    }

    init(project: Project, date: Date, existingMaterial: MaterialItem? = nil, canSendQuoteOrOrder: Bool = true) {
        self.project = project
        self.initialDate = date
        self.existingMaterial = existingMaterial
        self.canSendQuoteOrOrder = canSendQuoteOrOrder
        _neededDate = State(initialValue: date)
    }

    private var suggestions: [MaterialAutocompleteSuggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        var merged: [MaterialAutocompleteSuggestion] = []
        var seen = Set<String>()
        let catalogMatches = catalogueStore.search(query: q, limit: 8)
        for item in catalogMatches {
            let key = "\(MaterialCatalogDuplicateDetection.normalizeName(item.name))|\(MaterialCatalogDuplicateDetection.normalizeCode(item.productCode))"
            if seen.insert(key).inserted {
                merged.append(MaterialAutocompleteSuggestion(
                    id: "cat:\(item.id.uuidString)",
                    source: .catalogue,
                    name: item.name,
                    brand: item.brand,
                    productCode: item.productCode,
                    unit: item.defaultUnit,
                    sizeOrLength: item.sizeOrLength,
                    category: item.category,
                    catalogueItem: item
                ))
            }
        }

        let normalizedQuery = MaterialCatalogDuplicateDetection.normalizeName(q)
        let recentMatches = recentMaterials
            .filter {
                MaterialCatalogDuplicateDetection.normalizeName($0.material).contains(normalizedQuery)
                    || MaterialCatalogDuplicateDetection.normalizeName($0.brand ?? "").contains(normalizedQuery)
                    || MaterialCatalogDuplicateDetection.normalizeCode($0.productCode).contains(normalizedQuery)
            }
            .prefix(8)
        for item in recentMatches {
            let key = "\(MaterialCatalogDuplicateDetection.normalizeName(item.material))|\(MaterialCatalogDuplicateDetection.normalizeCode(item.productCode))"
            if seen.insert(key).inserted {
                merged.append(MaterialAutocompleteSuggestion(
                    id: "recent:\(item.id.uuidString)",
                    source: .recent,
                    name: item.material,
                    brand: item.brand ?? "Custom",
                    productCode: item.productCode,
                    unit: item.unit,
                    sizeOrLength: item.sizeOrLength,
                    category: item.category,
                    catalogueItem: nil
                ))
            }
        }
        return Array(merged.prefix(10))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    materialSection
                    if selectedCatalogue == nil,
                       !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !prefersCustomEntry {
                        suggestionsList
                    }
                    if selectedCatalogue == nil {
                        customHint
                    }
                    if selectedCatalogue == nil {
                        customDetailsSection
                    }
                    quantityUnitRow
                    dateRow
                    notesRow
                }
                .padding(16)
            }
            .background(MaterialsOrderingTheme.pageBackground)
            .navigationTitle(existingMaterial == nil ? "Add material" : "Edit material")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
            }
            .task {
                catalogueStore.setFirebaseBackend(firebaseBackend)
                await catalogueStore.load()
                if let existing = existingMaterial {
                    query = existing.material
                    customItemName = existing.material
                    quantity = existing.quantity
                    unit = existing.unit
                    neededDate = existing.date
                    notes = existing.notes ?? ""
                    customBrand = existing.brand ?? ""
                    customProductCode = existing.productCode ?? ""
                    sizeOrLength = existing.sizeOrLength ?? ""
                    let existingCategory = existing.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    customCategory = existingCategory.isEmpty ? "Other" : existingCategory
                    websiteURL = existing.websiteURL ?? ""
                    if let cid = existing.catalogueItemId,
                       let match = catalogueStore.items.first(where: { $0.id == cid }) {
                        selectedCatalogue = match
                        prefersCustomEntry = false
                    }
                    if existing.catalogueItemId == nil { prefersCustomEntry = true }
                } else {
                    neededDate = initialDate
                }
                if let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId {
                    recentMaterials = (try? await firebaseBackend.loadMaterialItems(
                        organizationId: organizationId,
                        projectId: project.id
                    )) ?? []
                }
            }
            .alert("Duplicate material", isPresented: $showingDuplicateAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Add anyway") { Task { await save(force: true) } }
            } message: {
                if let duplicateExisting {
                    Text("“\(duplicateExisting.name)” is already in your organisation catalogue. Add this line anyway?")
                }
            }
            .alert("Could not save", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
            .onChange(of: query) { _, newValue in
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    prefersCustomEntry = false
                }
            }
        }
    }

    private var canSave: Bool {
        !resolvedName.isEmpty && quantity > 0
    }

    private var resolvedName: String {
        if let selectedCatalogue { return selectedCatalogue.name }
        return customItemName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedCategory: String {
        if let selectedCatalogue {
            let cat = selectedCatalogue.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return cat.isEmpty ? "Other" : cat
        }
        let custom = customCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? "Other" : custom
    }

    @ViewBuilder
    private var materialSection: some View {
        Text("MATERIAL")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MaterialsOrderingTheme.muted)
        if let item = selectedCatalogue {
            matchedCard(item)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(MaterialsOrderingTheme.primary)
                TextField("Search catalogue or type custom", text: $query)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(10)
            .background(MaterialsOrderingTheme.cardBackground)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MaterialsOrderingTheme.primary, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func matchedCard(_ item: MaterialCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(MaterialsOrderingTheme.success)
                    }
                    Text(item.brand)
                        .font(.system(size: 11))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                    if let code = item.productCode {
                        Text("Code: \(code)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(MaterialsOrderingTheme.primary)
                    }
                    if let sizeOrLength = item.sizeOrLengthLabel {
                        Text("Size/Length: \(sizeOrLength)")
                            .font(.system(size: 10))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                    }
                }
                Spacer()
                Button {
                    selectedCatalogue = nil
                    query = item.name
                    customItemName = item.name
                    unit = item.defaultUnit
                    prefersCustomEntry = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                        .padding(6)
                        .background(MaterialsOrderingTheme.pageBackground)
                        .clipShape(Circle())
                }
            }
            Text("Matched from organisation catalogue · auto-filled")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(MaterialsOrderingTheme.success)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MaterialsOrderingTheme.successTint)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .background(MaterialsOrderingTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var suggestionsList: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button {
                    applySuggestion(suggestion)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.source == .catalogue ? "shippingbox.fill" : "clock.arrow.circlepath")
                            .font(.system(size: 13))
                            .foregroundStyle(MaterialsOrderingTheme.primary)
                            .frame(width: 26, height: 26)
                            .background(MaterialsOrderingTheme.primaryTint)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(highlighted(suggestion.name))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(MaterialsOrderingTheme.ink)
                            Text("\(suggestion.brand) · \(suggestion.productCode ?? "—") · \(suggestion.unit.rawValue)\(suggestion.sizeOrLength?.isEmpty == false ? " · \(suggestion.sizeOrLength!)" : "")")
                                .font(.system(size: 10))
                                .foregroundStyle(MaterialsOrderingTheme.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(suggestion.source == .catalogue ? "In catalogue" : "Previously used")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MaterialsOrderingTheme.primary)
                    }
                    .padding(9)
                    .background(MaterialsOrderingTheme.primaryTint.opacity(0.35))
                }
                .buttonStyle(.plain)
                if suggestion.id != suggestions.last?.id {
                    Divider()
                }
            }
            Button {
                selectedCatalogue = nil
                query = query.trimmingCharacters(in: .whitespacesAndNewlines)
                customItemName = query
                prefersCustomEntry = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 26)
                        .background(Color(red: 0.949, green: 0.953, blue: 0.961))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use “\(query)” as custom item")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MaterialsOrderingTheme.primary)
                        Text("Not in catalogue · add details below")
                            .font(.system(size: 10))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                    }
                    Spacer()
                }
                .padding(9)
            }
            .buttonStyle(.plain)
        }
        .background(MaterialsOrderingTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.08), radius: 10, y: 4)
    }

    private var customHint: some View {
        HStack(spacing: 7) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 12))
                .foregroundStyle(MaterialsOrderingTheme.primary)
            Text("Predictions use your catalogue and previously used materials (name · brand · code · unit · size/length).")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(MaterialsOrderingTheme.primary)
        }
        .padding(8)
        .background(MaterialsOrderingTheme.primaryTint)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var customDetailsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ITEM DETAILS")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MaterialsOrderingTheme.muted)
            HStack(spacing: 4) {
                Text("Item name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
                Text("*")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MaterialsOrderingTheme.danger)
            }
            TextField("Item name *", text: $customItemName)
                .padding(10)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 4) {
                Text("Category")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
                Text("*")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MaterialsOrderingTheme.danger)
            }
            TextField("Category *", text: $customCategory)
                .padding(10)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if !categorySuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(categorySuggestions, id: \.self) { suggestion in
                            Button {
                                customCategory = suggestion
                            } label: {
                                Text(suggestion)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(MaterialsOrderingTheme.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(MaterialsOrderingTheme.primaryTint)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            TextField("Manufacturer (Optional)", text: $customBrand)
                .padding(10)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            TextField("Code (Optional)", text: $customProductCode)
                .padding(10)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            TextField("Size/Length (optional)", text: $sizeOrLength)
                .padding(10)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            TextField("Product website URL (Optional)", text: $websiteURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .padding(10)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var quantityUnitRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("QUANTITY")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
                TextField("1", value: $quantity, format: .number)
                    .keyboardType(.numberPad)
                    .font(.system(size: 14, weight: .medium))
                    .padding(10)
                    .background(MaterialsOrderingTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("UNIT")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
                Picker("Unit", selection: $unit) {
                    ForEach(MaterialUnit.allCases, id: \.self) { u in
                        Text(u.rawValue).tag(u)
                    }
                }
                .pickerStyle(.menu)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 11))
            }
        }
    }

    private var dateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DATE NEEDED")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MaterialsOrderingTheme.muted)
            DatePicker("", selection: $neededDate, displayedComponents: .date)
                .labelsHidden()
                .padding(10)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 11))
        }
    }

    private var notesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOTES · OPTIONAL")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MaterialsOrderingTheme.muted)
            TextField("e.g. for Level 3 plant room", text: $notes, axis: .vertical)
                .lineLimit(2...4)
                .padding(10)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 11))
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let range = attributed.range(of: q, options: .caseInsensitive) else {
            return attributed
        }
        attributed[range].backgroundColor = MaterialsOrderingTheme.warnTint
        return attributed
    }

    private func applySuggestion(_ suggestion: MaterialAutocompleteSuggestion) {
        if let item = suggestion.catalogueItem {
            selectedCatalogue = item
            prefersCustomEntry = false
        } else {
            selectedCatalogue = nil
            prefersCustomEntry = true
        }
        query = suggestion.name
        customItemName = suggestion.name
        customBrand = suggestion.brand
        customProductCode = suggestion.productCode ?? ""
        sizeOrLength = suggestion.sizeOrLength ?? ""
        customCategory = suggestion.category ?? "Other"
        unit = suggestion.unit
        quantity = 1
    }

    private func save(force: Bool = false) async {
        let name = resolvedName
        let code = selectedCatalogue?.productCode
        let trimmedCustomBrand = customBrand.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCustomCode = customProductCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSizeOrLength = sizeOrLength.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWebsiteURL = websiteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !force, existingMaterial == nil,
           let match = MaterialCatalogDuplicateDetection.findCatalogueMatch(
            name: name,
            productCode: code,
            in: catalogueStore.items
           ), selectedCatalogue == nil {
            duplicateExisting = match
            showingDuplicateAlert = true
            return
        }

        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        isSaving = true
        defer { isSaving = false }

        let addedBy = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown"
        let ownerUid = firebaseBackend.currentUser?.uid ?? Auth.auth().currentUser?.uid
        let cal = Calendar.current
        var item = existingMaterial ?? MaterialItem(
            quantity: quantity,
            unit: unit,
            material: name,
            addedBy: addedBy,
            addedByUserId: ownerUid,
            projectId: project.id,
            date: cal.startOfDay(for: neededDate),
            status: .draft,
            catalogueItemId: selectedCatalogue?.id,
            brand: selectedCatalogue?.brand ?? (trimmedCustomBrand.isEmpty ? nil : trimmedCustomBrand),
            productCode: selectedCatalogue?.productCode ?? (trimmedCustomCode.isEmpty ? nil : trimmedCustomCode),
            sizeOrLength: selectedCatalogue?.sizeOrLength ?? (trimmedSizeOrLength.isEmpty ? nil : trimmedSizeOrLength),
            category: resolvedCategory,
            websiteURL: trimmedWebsiteURL.isEmpty ? nil : trimmedWebsiteURL,
            notes: notes.isEmpty ? nil : notes
        )
        item.quantity = quantity
        item.unit = unit
        item.material = name
        item.date = cal.startOfDay(for: neededDate)
        item.catalogueItemId = selectedCatalogue?.id
        item.brand = selectedCatalogue?.brand ?? (trimmedCustomBrand.isEmpty ? nil : trimmedCustomBrand)
        item.productCode = selectedCatalogue?.productCode ?? (trimmedCustomCode.isEmpty ? nil : trimmedCustomCode)
        item.sizeOrLength = selectedCatalogue?.sizeOrLength ?? (trimmedSizeOrLength.isEmpty ? nil : trimmedSizeOrLength)
        item.category = resolvedCategory
        item.websiteURL = trimmedWebsiteURL.isEmpty ? nil : trimmedWebsiteURL
        item.notes = notes.isEmpty ? nil : notes
        if existingMaterial != nil {
            item.editedBy = addedBy
            item.editedByUserId = ownerUid
            item.editedAt = Date()
        }

        do {
            try await firebaseBackend.saveMaterialItem(item, organizationId: organizationId)
            NotificationCenter.default.post(
                name: NSNotification.Name("reloadMaterials"),
                object: nil,
                userInfo: ["materialBookingDayIntervals": [item.date.timeIntervalSince1970]]
            )
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
