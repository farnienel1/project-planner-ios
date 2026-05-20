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
    @State private var selectedCategory: String?
    @State private var showingAdd = false
    @State private var showingBulkImport = false
    @State private var selectedItem: MaterialCatalogItem?
    @State private var editItem: MaterialCatalogItem?
    @State private var saveError: String?
    @State private var deleteError: String?

    private struct CategoryGroup: Identifiable {
        let id: String
        let category: String
        let items: [MaterialCatalogItem]
    }

    private var categories: [String] {
        let names = Set(store.items.map { normalizedCategory($0.category) })
        return names.sorted()
    }

    private var categoryCounts: [String: Int] {
        Dictionary(grouping: store.items) { normalizedCategory($0.category) }
            .mapValues(\.count)
    }

    private var filteredItems: [MaterialCatalogItem] {
        var list = store.items
        if let cat = selectedCategory {
            list = list.filter { normalizedCategory($0.category) == cat }
        }
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
                    searchField
                    categoryChips
                    categoryTiles
                    if store.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if filteredItems.isEmpty {
                        emptyCatalogue
                    } else {
                        ForEach(groupedFilteredItems) { group in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(group.category.uppercased())
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(MaterialsOrderingTheme.muted)
                                    .padding(.leading, 2)
                                ForEach(group.items) { item in
                                    Button { selectedItem = item } label: {
                                        catalogueRow(item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button { showingBulkImport = true } label: {
                            Image(systemName: "square.and.arrow.down")
                                .foregroundStyle(MaterialsOrderingTheme.primary)
                        }
                        Button { showingAdd = true } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(MaterialsOrderingTheme.primary)
                        }
                    }
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

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: "All · \(store.items.count)", isOn: selectedCategory == nil) {
                    selectedCategory = nil
                }
                ForEach(categories, id: \.self) { cat in
                    let count = categoryCounts[cat] ?? 0
                    chip(title: "\(cat) · \(count)", isOn: selectedCategory == cat) {
                        selectedCategory = cat
                    }
                }
            }
        }
    }

    private var categoryTiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories, id: \.self) { cat in
                    let count = categoryCounts[cat] ?? 0
                    Button {
                        selectedCategory = cat
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cat)
                                .font(.system(size: 11, weight: .semibold))
                            Text("\(count) item\(count == 1 ? "" : "s")")
                                .font(.system(size: 9))
                                .foregroundStyle(MaterialsOrderingTheme.muted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(MaterialsOrderingTheme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(selectedCategory == cat ? MaterialsOrderingTheme.primary : MaterialsOrderingTheme.border, lineWidth: selectedCategory == cat ? 1.4 : 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? Color.white : MaterialsOrderingTheme.muted)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(isOn ? MaterialsOrderingTheme.primary : MaterialsOrderingTheme.cardBackground)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(MaterialsOrderingTheme.border, lineWidth: isOn ? 0 : 0.5))
        }
        .buttonStyle(.plain)
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
                    if let size = item.sizeOrLengthLabel {
                        Text(size)
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
            Text("Add materials manually or import a CSV template.")
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
    @State private var sizeOrLength = ""
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
                    Text("DEFAULT QUANTITY UNIT")
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
                    textFieldRow(label: "Size/Length", text: $sizeOrLength, required: false, placeholder: "Optional")
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
                    sizeOrLength = item.sizeOrLength ?? ""
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
        case .length: return "3m / 6m"
        case .box: return "Pack of 100"
        }
    }

    private func attemptSave() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = productCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = sizeOrLength.trimmingCharacters(in: .whitespacesAndNewlines)
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
            sizeOrLength: size.isEmpty ? nil : size,
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
                    specRow(label: "Size/Length", value: item.sizeOrLengthLabel ?? "—")
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
        if let size = item.sizeOrLengthLabel, item.defaultUnit == .box {
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
    @State private var importError: String?
    @State private var parsedRows: [MaterialCatalogCSVRow] = []
    @State private var duplicateReview: [MaterialCatalogDuplicateCandidate] = []
    @State private var showingDuplicateReview = false
    @State private var isImporting = false
    @State private var templateShareURL: URL?
    @State private var showTemplateShare = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    infoBanner
                    Text("STEP 1 · DOWNLOAD TEMPLATE")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                    Button {
                        if templateShareURL == nil {
                            templateShareURL = try? MaterialCatalogCSV.writeTemplateToTemporaryFile()
                        }
                        showTemplateShare = templateShareURL != nil
                    } label: {
                        Label("Download CSV template", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MaterialsOrderingTheme.primary)

                    Text("STEP 2 · UPLOAD YOUR FILE")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                    Button { showingFilePicker = true } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.up.doc")
                                .font(.system(size: 28))
                                .foregroundStyle(MaterialsOrderingTheme.primary)
                            Text("Drop CSV or tap to browse")
                                .font(.system(size: 13, weight: .medium))
                            Text("Max 5MB · 5,000 items")
                                .font(.system(size: 10))
                                .foregroundStyle(MaterialsOrderingTheme.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .background(MaterialsOrderingTheme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6]))
                                .foregroundStyle(MaterialsOrderingTheme.border)
                        )
                    }
                    .buttonStyle(.plain)

                    Text("Fill the template on a laptop, then upload here or share the file from your phone.")
                        .font(.system(size: 11))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                }
                .padding(16)
            }
            .navigationTitle("Bulk import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.commaSeparatedText, .plainText], allowsMultipleSelection: false) { result in
                handleFileImport(result)
            }
            .sheet(isPresented: $showingDuplicateReview) {
                MaterialCatalogueDuplicateReviewView(
                    candidates: $duplicateReview,
                    rows: parsedRows,
                    onComplete: { dismiss() }
                )
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
                .environmentObject(store)
            }
            .sheet(isPresented: $showTemplateShare) {
                if let templateShareURL {
                    MaterialTemplateShareSheet(activityItems: [templateShareURL])
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
        }
    }

    private var infoBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(MaterialsOrderingTheme.primary)
            Text("Add many materials at once. Columns: Name, Manufacturer, Code, Default Unit, Size/Length, Length, Category. Duplicate checks use material name.")
                .font(.system(size: 11))
                .foregroundStyle(MaterialsOrderingTheme.primary)
        }
        .padding(11)
        .background(MaterialsOrderingTheme.primaryTint)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            templateShareURL = try? MaterialCatalogCSV.writeTemplateToTemporaryFile()
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
                parsedRows = rows
                duplicateReview = MaterialCatalogDuplicateDetection.buildBatchDuplicateReview(
                    incomingRows: rows,
                    existingCatalogue: store.items
                )
                if duplicateReview.isEmpty {
                    Task { await importAllRows(rows, skipKeys: []) }
                } else {
                    showingDuplicateReview = true
                }
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importAllRows(_ rows: [MaterialCatalogCSVRow], skipKeys: Set<String>) async {
        isImporting = true
        defer { isImporting = false }
        let uid = firebaseBackend.currentUser?.uid ?? Auth.auth().currentUser?.uid ?? ""
        let name = userStore.currentUser?.fullName ?? "Admin"
        do {
            _ = try await store.importRows(rows, createdByUserId: uid, createdByName: name, skipDuplicateKeys: skipKeys)
            dismiss()
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct MaterialTemplateShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct MaterialCatalogueDuplicateReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var store: MaterialCatalogStore

    @Binding var candidates: [MaterialCatalogDuplicateCandidate]
    let rows: [MaterialCatalogCSVRow]
    let onComplete: () -> Void

    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("These rows look like duplicates by material name. Use Keep to import or Remove to skip each row.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates.indices, id: \.self) { index in
                    let candidate = candidates[index]
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.incomingName)
                                .font(.system(size: 13, weight: .medium))
                            Text("Code: \(candidate.incomingCode.isEmpty ? "—" : candidate.incomingCode)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(MaterialsOrderingTheme.muted)
                            Text("Matches: \(candidate.existingName)")
                                .font(.system(size: 11))
                                .foregroundStyle(MaterialsOrderingTheme.warn)
                        }
                        Spacer()
                        HStack(spacing: 10) {
                            Button {
                                var updated = candidates[index]
                                updated.include = false
                                candidates[index] = updated
                            } label: {
                                Text("Remove")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(MaterialsOrderingTheme.danger)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            Button {
                                var updated = candidates[index]
                                updated.include = true
                                candidates[index] = updated
                            } label: {
                                Text("Keep")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(MaterialsOrderingTheme.success)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Duplicates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { Task { await finishImport() } }
                        .disabled(isSaving)
                }
            }
        }
    }

    private func finishImport() async {
        isSaving = true
        defer { isSaving = false }
        let skipKeys = Set(
            candidates
                .filter { !$0.include }
                .compactMap { c -> String? in
                    guard let idx = c.batchRowIndex, idx < rows.count else { return nil }
                    let row = rows[idx]
                    return store.duplicateKey(name: row.name, code: row.productCode)
                }
        )
        let forceKeys = Set(
            candidates
                .filter { $0.include }
                .compactMap { c -> String? in
                    guard let idx = c.batchRowIndex, idx < rows.count else { return nil }
                    let row = rows[idx]
                    return store.duplicateKey(name: row.name, code: row.productCode)
                }
        )
        let uid = firebaseBackend.currentUser?.uid ?? Auth.auth().currentUser?.uid ?? ""
        let name = userStore.currentUser?.fullName ?? "Admin"
        do {
            _ = try await store.importRows(
                rows,
                createdByUserId: uid,
                createdByName: name,
                skipDuplicateKeys: skipKeys,
                forceImportKeys: forceKeys
            )
            dismiss()
            onComplete()
        } catch {
            // Parent could show error — for now dismiss
            dismiss()
        }
    }
}
