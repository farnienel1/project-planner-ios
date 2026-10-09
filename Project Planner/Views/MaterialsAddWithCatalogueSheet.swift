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
    let size: String?
    let length: String?
    let lengthUnit: MaterialLengthUnit?
    let category: String?
    let catalogueItem: MaterialCatalogItem?
}

struct MaterialsAddWithCatalogueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var smartCache: SmartCacheService
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var operativeStore: OperativeStore

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
    @State private var sizeValue = ""
    @State private var lengthValue = ""
    @State private var lengthUnit: MaterialLengthUnit?
    @State private var customCategory = "Other"
    @State private var websiteURL = ""
    @State private var showingDuplicateAlert = false
    @State private var duplicateExisting: MaterialCatalogItem?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var recentMaterials: [MaterialItem] = []
    @State private var prefersCustomEntry = false
    @State private var editMatchedLineItemDetails = false
    @State private var suggestionPool: [MaterialAutocompleteSuggestion] = []
    @State private var suggestionRecords: [CanonicalBusinessEngine.CanonicalMaterialRecord] = []
    @State private var suggestionGeneration = 0
    @State private var rankedSuggestions: [MaterialAutocompleteSuggestion] = []

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

    private var suggestions: [MaterialAutocompleteSuggestion] { rankedSuggestions }

    private func rebuildSuggestionPool() {
        var merged: [MaterialAutocompleteSuggestion] = []
        var records: [CanonicalBusinessEngine.CanonicalMaterialRecord] = []
        var seen = Set<String>()
        merged.reserveCapacity(catalogueStore.items.count)
        records.reserveCapacity(catalogueStore.items.count)
        for item in catalogueStore.items {
            let key = "\(MaterialCatalogDuplicateDetection.normalizeName(item.name))|\(MaterialCatalogDuplicateDetection.normalizeCode(item.productCode))"
            if seen.insert(key).inserted {
                merged.append(MaterialAutocompleteSuggestion(
                    id: "cat:\(item.id.uuidString)",
                    source: .catalogue,
                    name: item.name,
                    brand: item.brand,
                    productCode: item.productCode,
                    unit: item.defaultUnit,
                    size: item.size,
                    length: item.length ?? item.sizeOrLength,
                    lengthUnit: item.lengthUnit,
                    category: item.category,
                    catalogueItem: item
                ))
                records.append(item.canonicalSearchRecord)
            }
        }
        for item in recentMaterials {
            let key = "\(MaterialCatalogDuplicateDetection.normalizeName(item.material))|\(MaterialCatalogDuplicateDetection.normalizeCode(item.productCode))"
            if seen.insert(key).inserted {
                let suggestion = MaterialAutocompleteSuggestion(
                    id: "recent:\(item.id.uuidString)",
                    source: .recent,
                    name: item.material,
                    brand: item.brand ?? "Custom",
                    productCode: item.productCode,
                    unit: item.unit,
                    size: item.size,
                    length: item.length ?? item.sizeOrLength,
                    lengthUnit: item.lengthUnit,
                    category: item.category,
                    catalogueItem: nil
                )
                merged.append(suggestion)
                records.append(CanonicalBusinessEngine.CanonicalMaterialRecord(
                    name: suggestion.name,
                    brand: suggestion.brand,
                    productCode: suggestion.productCode ?? "",
                    category: suggestion.category ?? "",
                    size: suggestion.size ?? "",
                    length: suggestion.length ?? ""
                ))
            }
        }
        suggestionPool = merged
        suggestionRecords = records
        suggestionGeneration = CanonicalBusinessEngine.makeMaterialSearchCacheIdentity()
        CanonicalBusinessEngine.installMaterialSearchRecords(records, cacheIdentity: suggestionGeneration)
        rankSuggestionPool()
    }

    private func rankSuggestionPool() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            rankedSuggestions = []
            return
        }
        let hits = CanonicalBusinessEngine.rankMaterialRecords(
            query: q,
            records: suggestionRecords,
            limit: 80,
            cacheIdentity: suggestionGeneration
        ) ?? []
        rankedSuggestions = hits.compactMap { suggestionPool.indices.contains($0.index) ? suggestionPool[$0.index] : nil }
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
                    if selectedCatalogue == nil || editMatchedLineItemDetails {
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
                        .accessibilityIdentifier("materialsAddWithCatalogue.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .accessibilityIdentifier("materialsAddWithCatalogue.save")
                        .disabled(!canSave || isSaving)
                }
            }
            .task(id: firebaseBackend.currentOrganization?.firestoreDocumentId ?? "") {
                guard !(firebaseBackend.currentOrganization?.firestoreDocumentId ?? "").isEmpty else { return }
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
                    sizeValue = existing.size ?? ""
                    lengthValue = existing.length ?? existing.sizeOrLength ?? ""
                    lengthUnit = existing.lengthUnit
                    let existingCategory = existing.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    customCategory = existingCategory.isEmpty ? "Other" : existingCategory
                    websiteURL = existing.websiteURL ?? ""
                    if let cid = existing.catalogueItemId,
                       let match = catalogueStore.items.first(where: { $0.id == cid }) {
                        selectedCatalogue = match
                        prefersCustomEntry = false
                        editMatchedLineItemDetails = true
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
                rebuildSuggestionPool()
            }
            .onChange(of: query) { _, _ in
                rankSuggestionPool()
            }
            .onChange(of: catalogueStore.searchGeneration) { _, _ in
                rebuildSuggestionPool()
            }
            .alert("Duplicate material", isPresented: $showingDuplicateAlert) {
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("materialsAddWithCatalogue.cancel2")
                Button("Add anyway") { Task { await save(force: true) } }
                    .accessibilityIdentifier("materialsAddWithCatalogue.addAnyway")
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
                    .accessibilityIdentifier("materialsAddWithCatalogue.ok")
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
            if editMatchedLineItemDetails {
                let custom = customCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                return custom.isEmpty ? "Other" : custom
            }
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
                TextField("Try 2.5mm LS or a product code", text: $query)
                    .accessibilityIdentifier("materialsAddWithCatalogue.searchCatalogueOrTypeCustom")
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
                        Text(sizeOrLength)
                            .font(.system(size: 10))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        editMatchedLineItemDetails.toggle()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(MaterialsOrderingTheme.primary)
                            .padding(6)
                            .background(MaterialsOrderingTheme.primaryTint)
                            .clipShape(Circle())
                    }
                        .accessibilityIdentifier("materialsAddWithCatalogue.settings")
                    Button {
                        selectedCatalogue = nil
                        query = item.name
                        customItemName = item.name
                        unit = item.defaultUnit
                        prefersCustomEntry = true
                        editMatchedLineItemDetails = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                            .padding(6)
                            .background(MaterialsOrderingTheme.pageBackground)
                            .clipShape(Circle())
                    }
                        .accessibilityIdentifier("materialsAddWithCatalogue.close")
                }
            }
            Text(editMatchedLineItemDetails
                 ? "Matched from organisation catalogue · line-item detail edit enabled"
                 : "Matched from organisation catalogue · auto-filled")
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
            Text(suggestions.isEmpty ? "No items match" : "\(suggestions.count) matches")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MaterialsOrderingTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(suggestions) { suggestion in
                        suggestionRow(suggestion)
                        if suggestion.id != suggestions.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 420)
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
            .accessibilityIdentifier("materialsAddWithCatalogue.add")
            .buttonStyle(.plain)
        }
        .background(MaterialsOrderingTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.08), radius: 10, y: 4)
    }

    private func suggestionRow(_ suggestion: MaterialAutocompleteSuggestion) -> some View {
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
                    Text(autocompleteSubtitle(for: suggestion))
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
        .accessibilityIdentifier("materialsAddWithCatalogue.row.\(suggestion.id).shippingboxFill")
        .buttonStyle(.plain)
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
            if selectedCatalogue == nil {
                HStack(spacing: 4) {
                    Text("Item name")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                    Text("*")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MaterialsOrderingTheme.danger)
                }
                TextField("Item name *", text: $customItemName)
                    .accessibilityIdentifier("materialsAddWithCatalogue.itemName")
                    .padding(10)
                    .background(MaterialsOrderingTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 4) {
                Text("Category")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
                Text("*")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MaterialsOrderingTheme.danger)
            }
            TextField("Category *", text: $customCategory)
                .accessibilityIdentifier("materialsAddWithCatalogue.category")
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
                            .accessibilityIdentifier("materialsAddWithCatalogue.row.\(suggestion).\(AccessibilityID.token(suggestion))")
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            TextField("Manufacturer (Optional)", text: $customBrand)
                .accessibilityIdentifier("materialsAddWithCatalogue.manufacturerOptional")
                .padding(10)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            TextField("Code (Optional)", text: $customProductCode)
                .accessibilityIdentifier("materialsAddWithCatalogue.codeOptional")
                .padding(10)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            TextField("Size (Optional)", text: $sizeValue)
                .accessibilityIdentifier("materialsAddWithCatalogue.sizeOptional")
                .padding(10)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            MaterialsLengthInputRow(lengthValue: $lengthValue, lengthUnit: $lengthUnit)
            TextField("Product website URL (Optional)", text: $websiteURL)
                .accessibilityIdentifier("materialsAddWithCatalogue.productWebsiteURLOptional")
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .padding(10)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var quantityUnitRow: some View {
        MaterialsQuantityTypeRow(quantity: $quantity, unit: $unit)
    }

    private func autocompleteSubtitle(for suggestion: MaterialAutocompleteSuggestion) -> String {
        let lengthSpec = MaterialLengthSpecification.format(value: suggestion.length, unit: suggestion.lengthUnit)
        var parts = [
            suggestion.brand,
            suggestion.productCode ?? "—",
            suggestion.unit.rawValue
        ]
        if let size = suggestion.size, !size.isEmpty { parts.append("Size: \(size)") }
        if !lengthSpec.isEmpty { parts.append("Length: \(lengthSpec)") }
        return parts.joined(separator: " · ")
    }

    private var dateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DATE NEEDED")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MaterialsOrderingTheme.muted)
            DatePicker("", selection: $neededDate, displayedComponents: .date)
                .accessibilityIdentifier("materialsAddWithCatalogue.datePicker")
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
                .accessibilityIdentifier("materialsAddWithCatalogue.eGForLevel3Plant")
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
            editMatchedLineItemDetails = false
        } else {
            selectedCatalogue = nil
            prefersCustomEntry = true
            editMatchedLineItemDetails = false
        }
        query = suggestion.name
        customItemName = suggestion.name
        customBrand = suggestion.brand
        customProductCode = suggestion.productCode ?? ""
        sizeValue = suggestion.size ?? ""
        lengthValue = suggestion.length ?? ""
        lengthUnit = suggestion.lengthUnit
        customCategory = suggestion.category ?? "Other"
        unit = suggestion.unit
        quantity = 1
    }

    private func save(force: Bool = false) async {
        let name = resolvedName
        let code = selectedCatalogue?.productCode
        let trimmedCustomBrand = customBrand.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCustomCode = customProductCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSize = sizeValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLength = lengthValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLengthUnit: MaterialLengthUnit? = trimmedLength.isEmpty ? nil : lengthUnit
        let trimmedWebsiteURL = websiteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldOverrideMatched = selectedCatalogue != nil && editMatchedLineItemDetails
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

        guard let organizationId = MaterialOfflineService.resolvedOrganizationId(firebaseBackend: firebaseBackend) else { return }
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
            brand: shouldOverrideMatched
                ? (trimmedCustomBrand.isEmpty ? selectedCatalogue?.brand : trimmedCustomBrand)
                : (selectedCatalogue?.brand ?? (trimmedCustomBrand.isEmpty ? nil : trimmedCustomBrand)),
            productCode: shouldOverrideMatched
                ? (trimmedCustomCode.isEmpty ? selectedCatalogue?.productCode : trimmedCustomCode)
                : (selectedCatalogue?.productCode ?? (trimmedCustomCode.isEmpty ? nil : trimmedCustomCode)),
            size: shouldOverrideMatched
                ? (trimmedSize.isEmpty ? selectedCatalogue?.size : trimmedSize)
                : (selectedCatalogue?.size ?? (trimmedSize.isEmpty ? nil : trimmedSize)),
            length: shouldOverrideMatched
                ? (trimmedLength.isEmpty ? (selectedCatalogue?.length ?? selectedCatalogue?.sizeOrLength) : trimmedLength)
                : ((selectedCatalogue?.length ?? selectedCatalogue?.sizeOrLength) ?? (trimmedLength.isEmpty ? nil : trimmedLength)),
            lengthUnit: shouldOverrideMatched
                ? resolvedLengthUnit ?? selectedCatalogue?.lengthUnit
                : (selectedCatalogue?.lengthUnit ?? resolvedLengthUnit),
            category: resolvedCategory,
            websiteURL: trimmedWebsiteURL.isEmpty ? nil : trimmedWebsiteURL,
            notes: notes.isEmpty ? nil : notes
        )
        item.quantity = quantity
        item.unit = unit
        item.material = name
        item.date = cal.startOfDay(for: neededDate)
        item.catalogueItemId = selectedCatalogue?.id
        item.brand = shouldOverrideMatched
            ? (trimmedCustomBrand.isEmpty ? selectedCatalogue?.brand : trimmedCustomBrand)
            : (selectedCatalogue?.brand ?? (trimmedCustomBrand.isEmpty ? nil : trimmedCustomBrand))
        item.productCode = shouldOverrideMatched
            ? (trimmedCustomCode.isEmpty ? selectedCatalogue?.productCode : trimmedCustomCode)
            : (selectedCatalogue?.productCode ?? (trimmedCustomCode.isEmpty ? nil : trimmedCustomCode))
        item.size = shouldOverrideMatched
            ? (trimmedSize.isEmpty ? selectedCatalogue?.size : trimmedSize)
            : (selectedCatalogue?.size ?? (trimmedSize.isEmpty ? nil : trimmedSize))
        item.length = shouldOverrideMatched
            ? (trimmedLength.isEmpty ? (selectedCatalogue?.length ?? selectedCatalogue?.sizeOrLength) : trimmedLength)
            : ((selectedCatalogue?.length ?? selectedCatalogue?.sizeOrLength) ?? (trimmedLength.isEmpty ? nil : trimmedLength))
        item.lengthUnit = shouldOverrideMatched
            ? resolvedLengthUnit ?? selectedCatalogue?.lengthUnit
            : (selectedCatalogue?.lengthUnit ?? resolvedLengthUnit)
        item.category = resolvedCategory
        item.websiteURL = trimmedWebsiteURL.isEmpty ? nil : trimmedWebsiteURL
        item.notes = notes.isEmpty ? nil : notes
        if existingMaterial != nil {
            item.editedBy = addedBy
            item.editedByUserId = ownerUid
            item.editedAt = Date()
        }

        do {
            _ = try await MaterialOfflineService.saveMaterial(
                item,
                organizationId: organizationId,
                firebaseBackend: firebaseBackend,
                isOnline: smartCache.isOnline
            )
            if existingMaterial == nil {
                let managerEmails = Set(project.managerIds.compactMap { id in
                    operativeStore.managers.first(where: { $0.id == id })?.email
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }.filter { !$0.isEmpty })
                let managerUserIds = userStore.organizationUsers
                    .filter { managerEmails.contains($0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
                    .map(\.id)
                await notificationService.notifyMaterialAdded(
                    projectId: project.id,
                    siteName: project.siteName,
                    materialName: item.material,
                    addedByName: addedBy,
                    addedByUserId: ownerUid,
                    extraRecipientUserIds: managerUserIds
                )
            }
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
