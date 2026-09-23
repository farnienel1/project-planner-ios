//
//  MaterialsCatalogueFlow.swift
//  Project Planner
//

import SwiftUI
import UniformTypeIdentifiers
import FirebaseAuth
import UIKit

struct MaterialCatalogueRootView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @StateObject private var store = MaterialCatalogStore()

    @State private var searchText = ""
    @State private var showingAdd = false
    @State private var showingBulkImport = false
    @State private var selectedItem: MaterialCatalogItem?
    @State private var editItem: MaterialCatalogItem?
    @State private var saveError: String?
    @State private var deleteError: String?
    @State private var expandedCategories: Set<String> = []

    private struct CategoryGroup: Identifiable {
        let id: String
        let category: String
        let items: [MaterialCatalogItem]
    }

    private var categories: [String] {
        let names = Set(store.items.map { normalizedCategory($0.category) })
        return names.sorted()
    }

    private var filteredItems: [MaterialCatalogItem] {
        var list = store.items
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter { item in
                item.name.localizedCaseInsensitiveContains(q)
                    || item.brand.localizedCaseInsensitiveContains(q)
                    || (item.productCode?.localizedCaseInsensitiveContains(q) ?? false)
            }
        }
        return list
    }

    private var groupedFilteredItems: [CategoryGroup] {
        let grouped = Dictionary(grouping: filteredItems) { normalizedCategory($0.category) }
        return grouped.keys.sorted().map { key in
            CategoryGroup(
                id: key,
                category: key,
                items: grouped[key, default: []].sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            )
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    heroCard
                    catalogueActionsRow
                    searchField
                    if store.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if filteredItems.isEmpty {
                        emptyCatalogue
                    } else {
                        ForEach(groupedFilteredItems) { group in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedCategories.contains(group.category) },
                                    set: { isExpanded in
                                        if isExpanded {
                                            expandedCategories.insert(group.category)
                                        } else {
                                            expandedCategories.remove(group.category)
                                        }
                                    }
                                )
                            ) {
                                VStack(spacing: 8) {
                                    ForEach(group.items) { item in
                                        Button { selectedItem = item } label: {
                                            catalogueRow(item)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.top, 8)
                            } label: {
                                HStack {
                                    Text(group.category.uppercased())
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(MaterialsOrderingTheme.muted)
                                    Spacer()
                                    Text("\(group.items.count) item\(group.items.count == 1 ? "" : "s")")
                                        .font(.system(size: 10))
                                        .foregroundStyle(MaterialsOrderingTheme.muted)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(MaterialsOrderingTheme.pageBackground.ignoresSafeArea())
            .navigationTitle("Material catalogue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                store.setFirebaseBackend(firebaseBackend)
                await store.load()
            }
            .sheet(isPresented: $showingAdd) {
                MaterialCatalogueEditorSheet(mode: .create) { item in
                    Task {
                        do {
                            try await store.save(item)
                            showingAdd = false
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                }
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
            }
            .sheet(item: $selectedItem) { item in
                MaterialCatalogueDetailView(
                    item: item,
                    onEdit: {
                        selectedItem = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            editItem = item
                        }
                    },
                    onDelete: {
                        Task {
                            do {
                                try await store.delete(item.id)
                                selectedItem = nil
                            } catch {
                                deleteError = error.localizedDescription
                            }
                        }
                    }
                )
                .environmentObject(store)
            }
            .sheet(item: $editItem) { item in
                MaterialCatalogueEditorSheet(mode: .edit(item)) { updated in
                    Task {
                        do {
                            try await store.save(updated)
                            editItem = nil
                            if selectedItem?.id == updated.id { selectedItem = updated }
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                }
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
            }
            .sheet(isPresented: $showingBulkImport) {
                MaterialCatalogueBulkImportView()
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
                    .environmentObject(store)
            }
            .alert("Could not save material", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
            .alert("Could not delete material", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteError ?? "")
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CATALOGUE")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("\(store.items.count) items")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Circle())
            }
            HStack(spacing: 7) {
                statTile(value: "\(store.brandCount)", label: "Brands")
                statTile(value: "\(max(store.categoryCount, categories.count))", label: "Categories")
                statTile(value: "\(store.countAddedToday())", label: "Added today")
            }
        }
        .padding(14)
        .background(MaterialsOrderingTheme.primaryGradient)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var catalogueActionsRow: some View {
        HStack(spacing: 10) {
            Button { showingBulkImport = true } label: {
                Label("Upload / Download", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(MaterialsOrderingTheme.primary)
            .accessibilityLabel("Upload or download catalogue")

            Button { showingAdd = true } label: {
                Label("Add item", systemImage: "plus.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(MaterialsOrderingTheme.primary)
            .accessibilityLabel("Add catalogue item")
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(MaterialsOrderingTheme.muted)
            TextField("Search by name, brand or code", text: $searchText)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(MaterialsOrderingTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(MaterialsOrderingTheme.border, lineWidth: 0.5))
    }

    private func catalogueRow(_ item: MaterialCatalogItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(MaterialsOrderingTheme.primaryTint)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(MaterialsOrderingTheme.primary)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MaterialsOrderingTheme.ink)
                Text(item.brand)
                    .font(.system(size: 10))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
                HStack(spacing: 6) {
                    if let code = item.productCode, !code.isEmpty {
                        Text(code)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(MaterialsOrderingTheme.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(MaterialsOrderingTheme.primaryTint)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Text(item.defaultUnit.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(red: 0.949, green: 0.953, blue: 0.961))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    if let size = item.size?.trimmingCharacters(in: .whitespacesAndNewlines), !size.isEmpty {
                        Text("Size: \(size)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color(red: 0.949, green: 0.953, blue: 0.961))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    if !item.formattedLengthSpecification.isEmpty {
                        Text("Length: \(item.formattedLengthSpecification)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color(red: 0.949, green: 0.953, blue: 0.961))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(MaterialsOrderingTheme.disabled)
        }
        .padding(12)
        .background(MaterialsOrderingTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(MaterialsOrderingTheme.border, lineWidth: 0.5))
    }

    private var emptyCatalogue: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundStyle(MaterialsOrderingTheme.disabled)
            Text("No catalogue items yet")
                .font(.system(size: 14, weight: .medium))
            Text("Add materials manually or update the catalogue from a CSV.")
                .font(.system(size: 12))
                .foregroundStyle(MaterialsOrderingTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func normalizedCategory(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Other" : trimmed
    }
}

// MARK: - Editor

private enum MaterialCatalogueEditorMode {
    case create
    case edit(MaterialCatalogItem)
}

private struct MaterialCatalogueEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    let mode: MaterialCatalogueEditorMode
    let onSave: (MaterialCatalogItem) -> Void

    @State private var name = ""
    @State private var brand = ""
    @State private var productCode = ""
    @State private var unit: MaterialUnit = .number
    @State private var sizeValue = ""
    @State private var lengthValue = ""
    @State private var lengthUnit: MaterialLengthUnit?
    @State private var category = ""
    @State private var showingDuplicateAlert = false
    @State private var duplicateMatch: MaterialCatalogItem?
    @State private var pendingSaveItem: MaterialCatalogItem?

    @StateObject private var store = MaterialCatalogStore()

    private var categorySuggestions: [String] {
        let typed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let categories = Array(
            Set(
                store.items
                    .compactMap { $0.category?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !typed.isEmpty else { return Array(categories.prefix(6)) }
        return categories.filter {
            $0.localizedCaseInsensitiveContains(typed) && $0.caseInsensitiveCompare(typed) != .orderedSame
        }
        .prefix(6)
        .map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fieldSection(title: "Item details") {
                        textFieldRow(label: "Name", text: $name, required: true)
                        textFieldRow(label: "Category", text: $category, required: true, placeholder: "e.g. Electrical")
                        textFieldRow(label: "Manufacturer / Brand", text: $brand, required: false)
                        textFieldRow(label: "Product code", text: $productCode, required: false)
                    }
                    if !categorySuggestions.isEmpty {
                        suggestionRow(title: "Category suggestions", options: categorySuggestions) { selected in
                            category = selected
                        }
                    }
                    Text("DEFAULT TYPE")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                    HStack(spacing: 6) {
                        ForEach(MaterialUnit.allCases, id: \.self) { u in
                            Button { unit = u } label: {
                                VStack(spacing: 2) {
                                    Text(u.rawValue)
                                        .font(.system(size: 11, weight: .medium))
                                    Text(unitHint(u))
                                        .font(.system(size: 9))
                                        .foregroundStyle(MaterialsOrderingTheme.muted)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(unit == u ? MaterialsOrderingTheme.primaryTint : MaterialsOrderingTheme.cardBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11)
                                        .stroke(unit == u ? MaterialsOrderingTheme.primary : MaterialsOrderingTheme.border, lineWidth: unit == u ? 1.5 : 0.5)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 11))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    textFieldRow(label: "Size", text: $sizeValue, required: false, placeholder: "Optional")
                    MaterialsLengthInputRow(lengthValue: $lengthValue, lengthUnit: $lengthUnit)
                }
                .padding(16)
            }
            .background(MaterialsOrderingTheme.pageBackground)
            .navigationTitle(modeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { attemptSave() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                store.setFirebaseBackend(firebaseBackend)
                Task { await store.load() }
                if case .edit(let item) = mode {
                    name = item.name
                    brand = item.brand
                    productCode = item.productCode ?? ""
                    unit = item.defaultUnit
                    sizeValue = item.size ?? ""
                    lengthValue = item.length ?? item.sizeOrLength ?? ""
                    lengthUnit = item.lengthUnit
                    category = item.category ?? "Other"
                }
            }
            .alert("Duplicate material", isPresented: $showingDuplicateAlert) {
                Button("Cancel", role: .cancel) {
                    pendingSaveItem = nil
                    duplicateMatch = nil
                }
                Button("Add anyway") {
                    if let item = pendingSaveItem {
                        onSave(item)
                        dismiss()
                    }
                }
            } message: {
                if let duplicateMatch {
                    Text("“\(duplicateMatch.name)” with code “\(duplicateMatch.productCode ?? "—")” is already in your catalogue. Add this entry anyway?")
                }
            }
        }
    }

    private var modeTitle: String {
        if case .edit = mode { return "Edit material" }
        return "New material"
    }

    private func unitHint(_ unit: MaterialUnit) -> String {
        switch unit {
        case .number: return "Each / piece"
        case .length: return "Metres / runs"
        case .box: return "Pack of 100"
        case .drum: return "Cable drum"
        case .pallet: return "Pallet load"
        }
    }

    private func attemptSave() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = productCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = sizeValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = lengthValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cat = category.trimmingCharacters(in: .whitespacesAndNewlines)

        let uid = firebaseBackend.currentUser?.uid ?? Auth.auth().currentUser?.uid ?? ""
        let creator = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Admin"

        let existingId: UUID
        if case .edit(let item) = mode {
            existingId = item.id
        } else {
            existingId = UUID()
        }

        let item = MaterialCatalogItem(
            id: existingId,
            name: trimmedName,
            brand: trimmedBrand.isEmpty ? "Custom" : trimmedBrand,
            productCode: code.isEmpty ? nil : code,
            defaultUnit: unit,
            size: size.isEmpty ? nil : size,
            length: length.isEmpty ? nil : length,
            lengthUnit: length.isEmpty ? nil : lengthUnit,
            category: cat.isEmpty ? "Other" : cat,
            createdAt: {
                if case .edit(let existing) = mode { return existing.createdAt }
                return Date()
            }(),
            createdByUserId: {
                if case .edit(let existing) = mode { return existing.createdByUserId }
                return uid
            }(),
            createdByName: {
                if case .edit(let existing) = mode { return existing.createdByName }
                return creator
            }()
        )

        if case .edit = mode {
            onSave(item)
            dismiss()
            return
        }

        if let match = MaterialCatalogDuplicateDetection.findCatalogueMatch(
            name: trimmedName,
            productCode: code.isEmpty ? nil : code,
            in: store.items
        ) {
            duplicateMatch = match
            pendingSaveItem = item
            showingDuplicateAlert = true
        } else {
            onSave(item)
            dismiss()
        }
    }

    @ViewBuilder
    private func fieldSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MaterialsOrderingTheme.muted)
        content()
            .background(MaterialsOrderingTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MaterialsOrderingTheme.border, lineWidth: 0.5))
    }

    private func textFieldRow(label: String, text: Binding<String>, required: Bool, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
                if required {
                    Text("*").foregroundStyle(MaterialsOrderingTheme.danger)
                }
            }
            TextField(placeholder.isEmpty ? label : placeholder, text: text)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MaterialsOrderingTheme.border).frame(height: 0.5)
        }
    }

    private func suggestionRow(title: String, options: [String], onSelect: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(MaterialsOrderingTheme.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            onSelect(option)
                        } label: {
                            Text(option)
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
    }
}

// MARK: - Detail

private struct MaterialCatalogueDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: MaterialCatalogItem
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var showingDeleteConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 16, weight: .medium))
                        Text(item.brand)
                            .font(.system(size: 12))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                        if let code = item.productCode {
                            Text("Code: \(code)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(MaterialsOrderingTheme.primary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MaterialsOrderingTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    specRow(label: "Default unit", value: unitLabel)
                    specRow(label: "Size", value: item.size?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? item.size! : "—")
                    specRow(label: "Length", value: item.length?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? item.length! : "—")
                    specRow(label: "Category", value: item.category ?? "—")
                    specRow(label: "Added", value: "\(item.createdAt.formatted(date: .abbreviated, time: .omitted)) by \(item.createdByName)")

                    Button(role: .destructive) { showingDeleteConfirm = true } label: {
                        Label("Remove from catalogue", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .padding()
                    .background(MaterialsOrderingTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(16)
            }
            .navigationTitle("Item details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") {
                        dismiss()
                        onEdit()
                    }
                }
            }
            .confirmationDialog("Remove from catalogue?", isPresented: $showingDeleteConfirm) {
                Button("Remove", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var unitLabel: String {
        if let size = item.length?.trimmingCharacters(in: .whitespacesAndNewlines), !size.isEmpty, item.defaultUnit == .box {
            return "Box · \(size)"
        }
        return item.defaultUnit.rawValue
    }

    private func specRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(MaterialsOrderingTheme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(MaterialsOrderingTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Bulk import

struct MaterialCatalogueBulkImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var store: MaterialCatalogStore

    @State private var showingFilePicker = false
    @State private var pendingImportMode: MaterialCatalogueCSVImportMode = .updateExisting
    @State private var showReplaceConfirm = false
    @State private var importError: String?
    @State private var isImporting = false
    @State private var importResult: MaterialCatalogueCSVImportResult?
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @State private var showCSVDownloadWarning = false
    @State private var pendingDownload: CatalogueDownloadKind = .currentCatalogue

    private enum CatalogueDownloadKind {
        case currentCatalogue
        case blankTemplate
    }

    private var isBusy: Bool { isImporting || store.importProgress != nil }

    private var displayedProgress: MaterialCatalogueImportProgress? {
        if importResult != nil { return nil }
        if let progress = store.importProgress { return progress }
        if isImporting {
            return MaterialCatalogueImportProgress(completed: 0, total: 1, phase: "Preparing catalogue…")
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    infoBanner

                    Text("STEP 1 · DOWNLOAD")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MaterialsOrderingTheme.muted)

                    Button {
                        pendingDownload = .currentCatalogue
                        showCSVDownloadWarning = true
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 18))
                                Text("Download Material Catalogue")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            Text("(download your current material catalogue to update, remove and add new materials)")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(MaterialsOrderingTheme.primaryGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)

                    Button {
                        pendingDownload = .blankTemplate
                        showCSVDownloadWarning = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 16))
                                .foregroundStyle(MaterialsOrderingTheme.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Download blank template")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(MaterialsOrderingTheme.ink)
                                Text("Headers only — use this to start a brand new list")
                                    .font(.system(size: 11))
                                    .foregroundStyle(MaterialsOrderingTheme.muted)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(MaterialsOrderingTheme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(MaterialsOrderingTheme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)

                    Text("STEP 2 · UPLOAD UPDATED CATALOGUE")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                        .padding(.top, 4)

                    csvDropZone(
                        title: "Use this to upload your updated catalogue",
                        subtitle: "Upload your full edited catalogue. New rows are added, matching rows are updated, and rows missing from the sheet are removed.",
                        icon: "arrow.up.doc.fill",
                        accent: MaterialsOrderingTheme.primary,
                        dashedColor: MaterialsOrderingTheme.primary.opacity(0.45)
                    ) {
                        pendingImportMode = .updateExisting
                        showingFilePicker = true
                    }

                    Text("STEP 3 · REPLACE ENTIRE CATALOGUE")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                        .padding(.top, 4)

                    csvDropZone(
                        title: "Use this to upload a brand new catalogue",
                        subtitle: "Erases every current catalogue item, then imports this file as new materials.",
                        icon: "arrow.triangle.2.circlepath",
                        accent: MaterialsOrderingTheme.warn,
                        dashedColor: MaterialsOrderingTheme.warn.opacity(0.55)
                    ) {
                        showReplaceConfirm = true
                    }

                    Text("Edit on a laptop if you can, then save as .csv and upload here. Leave Catalogue ID blank for brand new rows.")
                        .font(.system(size: 11))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                }
                .padding(16)
            }
            .background(MaterialsOrderingTheme.pageBackground.ignoresSafeArea())
            .navigationTitle("Catalogue CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isBusy)
                }
            }
            .interactiveDismissDisabled(isBusy)
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .sheet(isPresented: $showShareSheet) {
                if let shareURL {
                    MaterialTemplateShareSheet(activityItems: [shareURL])
                }
            }
            .alert("Import error", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .alert("⚠️ CSV Warning", isPresented: $showCSVDownloadWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Download CSV") { prepareDownload() }
            } message: {
                Text("When re-importing the file for a batch upload, make sure you save the file as csv and not .xls (excel) or .numbers (for mac). The batch upload function can only read .csv files. The template you download will be .csv by default.")
            }
            .overlay {
                if showReplaceConfirm {
                    replaceConfirmOverlay
                } else if let result = importResult {
                    importSummaryOverlay(result)
                } else if let progress = displayedProgress {
                    importProgressOverlay(progress)
                }
            }
        }
    }

    private var infoBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(MaterialsOrderingTheme.primary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Download the full catalogue, edit it, then upload that same file. Catalogue ID keeps each row linked so jobs stay attached. Rows you delete from the sheet are removed from the app. New rows can leave Catalogue ID blank.")
                    .font(.system(size: 11, weight: .medium))
                Text("Matching uses Catalogue ID first, then name + product code. Duplicate rows in the file are skipped automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(MaterialsOrderingTheme.primary.opacity(0.85))
            }
            .foregroundStyle(MaterialsOrderingTheme.primary)
        }
        .padding(12)
        .background(MaterialsOrderingTheme.primaryTint)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func csvDropZone(
        title: String,
        subtitle: String,
        icon: String,
        accent: Color,
        dashedColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MaterialsOrderingTheme.ink)
                    .multilineTextAlignment(.center)
                Text("Drop CSV or tap to browse")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(accent)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Max 5MB · 5,000 items")
                    .font(.system(size: 10))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 22)
            .background(MaterialsOrderingTheme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1.8, dash: [7]))
                    .foregroundStyle(dashedColor)
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private var replaceConfirmOverlay: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture { showReplaceConfirm = false }
            MaterialCatalogueReplaceConfirm(
                onContinue: {
                    showReplaceConfirm = false
                    pendingImportMode = .replaceAll
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showingFilePicker = true
                    }
                },
                onCancel: { showReplaceConfirm = false }
            )
            .padding(22)
        }
    }

    private func importProgressOverlay(_ progress: MaterialCatalogueImportProgress) -> some View {
        ZStack {
            Color.black.opacity(0.38).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(MaterialsOrderingTheme.primary)
                    Text(progress.phase)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MaterialsOrderingTheme.ink)
                }
                ProgressView(value: progress.fraction)
                    .tint(MaterialsOrderingTheme.primary)
                HStack {
                    Text("\(progress.completed) of \(progress.total)")
                    Spacer()
                    Text("\(Int((progress.fraction * 100).rounded()))%")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MaterialsOrderingTheme.muted)
                Text("Keep this screen open until the upload finishes.")
                    .font(.system(size: 11))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(MaterialsOrderingTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(MaterialsOrderingTheme.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
            .padding(22)
        }
    }

    private func importSummaryOverlay(_ result: MaterialCatalogueCSVImportResult) -> some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(MaterialsOrderingTheme.success)
                    Text(result.totalTouched == 0 ? "No changes needed" : "Catalogue updated")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MaterialsOrderingTheme.ink)
                }
                VStack(spacing: 8) {
                    summaryRow(label: "Added", value: result.added, tint: MaterialsOrderingTheme.success)
                    summaryRow(label: "Updated", value: result.updated, tint: MaterialsOrderingTheme.primary)
                    summaryRow(label: "Removed", value: result.removed, tint: MaterialsOrderingTheme.danger)
                    summaryRow(label: "Duplicates skipped", value: result.skippedDuplicates, tint: MaterialsOrderingTheme.warn)
                }
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(MaterialsOrderingTheme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(MaterialsOrderingTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(MaterialsOrderingTheme.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
            .padding(22)
        }
    }

    private func summaryRow(label: String, value: Int, tint: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(MaterialsOrderingTheme.muted)
            Spacer()
            Text("\(value)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(MaterialsOrderingTheme.pageBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func prepareDownload() {
        do {
            switch pendingDownload {
            case .currentCatalogue:
                shareURL = try MaterialCatalogCSV.writeCatalogueToTemporaryFile(items: store.items)
            case .blankTemplate:
                shareURL = try MaterialCatalogCSV.writeTemplateToTemporaryFile()
            }
            showShareSheet = shareURL != nil
        } catch {
            importError = error.localizedDescription
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Could not access the selected file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: url)
                let rows = try MaterialCatalogCSV.parse(data: data)
                Task { await importRows(rows, mode: pendingImportMode) }
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importRows(_ rows: [MaterialCatalogCSVRow], mode: MaterialCatalogueCSVImportMode) async {
        isImporting = true
        defer { isImporting = false }
        let uid = firebaseBackend.currentUser?.uid ?? Auth.auth().currentUser?.uid ?? ""
        let name = userStore.currentUser?.fullName ?? "Admin"
        do {
            importResult = try await store.importCSV(
                rows,
                mode: mode,
                createdByUserId: uid,
                createdByName: name
            )
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct MaterialCatalogueReplaceConfirm: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(MaterialsOrderingTheme.warn)
                Text("Replace entire catalogue?")
                    .font(.headline)
                    .foregroundStyle(MaterialsOrderingTheme.ink)
            }
            Text("Are you sure you want to upload a new catalogue? If you do this, then all current catalogue items will be erased. Please download your current template and save this before using this option.")
                .font(.subheadline)
                .foregroundStyle(MaterialsOrderingTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(action: onContinue) {
                    Text("Continue")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(MaterialsOrderingTheme.success)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(MaterialsOrderingTheme.danger)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(MaterialsOrderingTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(MaterialsOrderingTheme.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
    }
}

private struct MaterialTemplateShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
