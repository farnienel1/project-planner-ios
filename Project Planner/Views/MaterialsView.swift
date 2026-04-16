//
//  MaterialsView.swift
//  Project Planner
//
//  Created by Assistant on 2025.
//

import SwiftUI

struct MaterialsView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let project: Project
    
    @State private var selectedDate: Date = Date()
    @State private var currentWeek: Date = Date()
    @State private var materials: [MaterialItem] = []
    @State private var isLoading = false
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading materials...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if userStore.isOperativeMode() {
                OperativeMaterialsView(
                    project: project,
                    selectedDate: $selectedDate,
                    currentWeek: $currentWeek,
                    materials: $materials
                )
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
            } else {
                AdminManagerMaterialsView(
                    project: project,
                    selectedDate: $selectedDate,
                    currentWeek: $currentWeek,
                    materials: $materials
                )
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
            }
        }
        .task {
            await loadMaterials()
        }
        .refreshable {
            await loadMaterials()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("reloadMaterials"))) { _ in
            Task {
                await loadMaterials()
            }
        }
    }
    
    private func loadMaterials() async {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { 
            print("❌ [MaterialsView] No organization ID for loading materials")
            return 
        }
        isLoading = true
        
        print("📦 [MaterialsView] Loading materials for project: \(project.id) (org: \(organizationId))")
        do {
            let loadedMaterials = try await firebaseBackend.loadMaterialItems(organizationId: organizationId, projectId: project.id)
            await MainActor.run {
                materials = loadedMaterials
                print("✅ [MaterialsView] Loaded \(loadedMaterials.count) materials and updated @State")
                if loadedMaterials.isEmpty {
                    print("   ⚠️ WARNING: No materials found in Firebase for this project!")
                } else {
                    print("   Materials loaded:")
                    for material in loadedMaterials {
                        print("     - \(material.material) for date: \(material.date)")
                    }
                }
                isLoading = false
            }
        } catch {
            print("❌ [MaterialsView] Error loading materials: \(error.localizedDescription)")
            await MainActor.run {
                isLoading = false
            }
        }
    }
}

// MARK: - Operative Materials View

private struct OperativeMaterialsView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let project: Project
    @Binding var selectedDate: Date
    @Binding var currentWeek: Date
    @Binding var materials: [MaterialItem]
    
    @State private var showingAddMaterial = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Week Navigation
            weekNavigationView
            
            // Week Calendar
            weekCalendarView
            
            // Materials List for Selected Day
            materialsListView
        }
        .sheet(isPresented: $showingAddMaterial) {
            AddMaterialView(
                project: project,
                date: selectedDate,
                isPresented: $showingAddMaterial
            )
            .environmentObject(userStore)
            .environmentObject(firebaseBackend)
        }
        .task {
            await loadMaterials()
        }
        .refreshable {
            await loadMaterials()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("reloadMaterials"))) { _ in
            Task {
                await loadMaterials()
            }
        }
    }
    
    private func loadMaterials() async {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        do {
            materials = try await firebaseBackend.loadMaterialItems(organizationId: organizationId, projectId: project.id)
        } catch {
            print("Error loading materials: \(error.localizedDescription)")
        }
    }
    
    private var weekNavigationView: some View {
        HStack {
            Button(action: { changeWeek(by: -1) }) {
                Image(systemName: "chevron.left")
                    .foregroundColor(.blue)
            }
            
            Spacer()
            
            Text(weekRangeString)
                .font(.headline)
            
            Spacer()
            
            Button(action: { changeWeek(by: 1) }) {
                Image(systemName: "chevron.right")
                    .foregroundColor(.blue)
            }
        }
        .padding()
    }
    
    private var weekCalendarView: some View {
        HStack(spacing: 8) {
            ForEach(weekDays, id: \.self) { date in
                Button(action: {
                    selectedDate = date
                }) {
                    VStack(spacing: 4) {
                        Text(dayName(for: date))
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(dayNumber(for: date))
                            .font(.headline)
                        Text(monthName(for: date))
                            .font(.caption2)
                    }
                    .foregroundColor(isSelected(date) ? .white : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(isSelected(date) ? Color.blue : Color(.systemGray6))
                    .cornerRadius(8)
                }
            }
        }
        .padding(.horizontal)
    }
    
    private var materialsListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Materials for \(formattedDate(selectedDate))")
                        .font(.headline)
                    Spacer()
                    Button(action: {
                        showingAddMaterial = true
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal)
                
                let calendar = Calendar.current
                let selectedDay = calendar.startOfDay(for: selectedDate)
                let dayMaterials = materials.filter { material in
                    let materialDay = calendar.startOfDay(for: material.date)
                    return calendar.isDate(materialDay, inSameDayAs: selectedDay)
                }
                
                if dayMaterials.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "cube.box")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No materials added for this day")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(dayMaterials) { material in
                        MaterialItemRow(material: material)
                            .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
    }
    
    private func changeWeek(by weeks: Int) {
        if let newWeek = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: currentWeek) {
            currentWeek = newWeek
        }
    }
    
    private var weekDays: [Date] {
        let calendar = Calendar.current
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: currentWeek)?.start else {
            return []
        }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }
    
    private func isSelected(_ date: Date) -> Bool {
        Calendar.current.isDate(date, inSameDayAs: selectedDate)
    }
    
    private func dayName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
    
    private func dayNumber(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }
    
    private func monthName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter.string(from: date)
    }
    
    private var weekRangeString: String {
        let calendar = Calendar.current
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: currentWeek)?.start,
              let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else {
            return ""
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return "\(formatter.string(from: weekStart)) - \(formatter.string(from: weekEnd))"
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Material Item Row

struct MaterialItemRow: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let material: MaterialItem
    @State private var showingEditMaterial = false
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(material.material)
                    .font(.body)
                    .fontWeight(.medium)
                Text("\(material.quantity) \(material.unit.rawValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Show editedBy if material was edited, otherwise show addedBy
                if let editedBy = material.editedBy {
                    Text("Edited by \(editedBy)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("Added by \(material.addedBy)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            
            if !userStore.isOperativeMode() {
                Button(action: {
                    showingEditMaterial = true
                }) {
                    Image(systemName: "pencil")
                        .foregroundColor(.blue)
                        .font(.body)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .sheet(isPresented: $showingEditMaterial) {
            EditMaterialView(material: material, isPresented: $showingEditMaterial)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
    }
}

// MARK: - Add Material View

struct AddMaterialView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let project: Project
    let date: Date
    @Binding var isPresented: Bool
    
    @State private var materialEntries: [MaterialEntryForm] = []
    @State private var isSaving = false
    
    struct MaterialEntryForm: Identifiable {
        let id = UUID()
        var selectedDate: Date
        var quantity: Int = 1
        var unit: MaterialUnit = .number
        var materialDescription: String = ""
        
        init(selectedDate: Date) {
            self.selectedDate = selectedDate
        }
    }
    
    init(project: Project, date: Date, isPresented: Binding<Bool>) {
        self.project = project
        self.date = date
        self._isPresented = isPresented
        self._materialEntries = State(initialValue: [MaterialEntryForm(selectedDate: date)])
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("Material Entries") {
                    ForEach(materialEntries) { entry in
                        MaterialEntrySection(
                            entry: entry,
                            entries: $materialEntries
                        )
                    }
                    
                    Button(action: {
                        materialEntries.append(MaterialEntryForm(selectedDate: date))
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Another Material")
                        }
                        .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("Add Materials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Submit All") {
                        saveAllMaterials()
                    }
                    .disabled(materialEntries.allSatisfy { $0.materialDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || isSaving)
                }
            }
        }
    }
    
    private func saveAllMaterials() {
        let validEntries = materialEntries.filter { !$0.materialDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validEntries.isEmpty else { return }
        
        isSaving = true
        let addedBy = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
        let calendar = Calendar.current
        
        Task {
            guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                await MainActor.run {
                    isSaving = false
                }
                return
            }
            
            var savedCount = 0
            for entry in validEntries {
                let normalizedDate = calendar.startOfDay(for: entry.selectedDate)
                
                let material = MaterialItem(
                    quantity: entry.quantity,
                    unit: entry.unit,
                    material: entry.materialDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                    addedBy: addedBy,
                    projectId: project.id,
                    date: normalizedDate
                )
                
                do {
                    try await firebaseBackend.saveMaterialItem(material, organizationId: organizationId)
                    savedCount += 1
                    print("✅ Material saved: \(material.material) for date: \(normalizedDate)")
                } catch {
                    print("❌ Error saving material: \(error.localizedDescription)")
                }
            }
            
            // Clean up old materials (older than 50 days)
            try? await firebaseBackend.cleanupOldMaterials(organizationId: organizationId, keepDays: 50)
            
            await MainActor.run {
                isSaving = false
                isPresented = false
                
                // Post notification to reload materials in parent view
                NotificationCenter.default.post(name: NSNotification.Name("reloadMaterials"), object: nil)
            }
        }
    }
}

// MARK: - Material Entry Section

private struct MaterialEntrySection: View {
    let entry: AddMaterialView.MaterialEntryForm
    @Binding var entries: [AddMaterialView.MaterialEntryForm]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Material Entry")
                    .font(.headline)
                Spacer()
                if entries.count > 1 {
                    Button(action: {
                        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                            entries.remove(at: index)
                        }
                    }) {
                        Image(systemName: "minus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                            .contentShape(Rectangle())
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                }
            }
            
            DatePicker("Date", selection: Binding(
                get: { entry.selectedDate },
                set: { newValue in
                    if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                        entries[index].selectedDate = newValue
                    }
                }
            ), displayedComponents: .date)
            .datePickerStyle(.compact)
            
            Picker("Quantity", selection: Binding(
                get: { entry.quantity },
                set: { newValue in
                    if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                        entries[index].quantity = newValue
                    }
                }
            )) {
                ForEach(1...100, id: \.self) { num in
                    Text("\(num)").tag(num)
                }
            }
            
            Picker("Unit", selection: Binding(
                get: { entry.unit },
                set: { newValue in
                    if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                        entries[index].unit = newValue
                    }
                }
            )) {
                ForEach(MaterialUnit.allCases, id: \.self) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            
            TextField("Material Description", text: Binding(
                get: { entry.materialDescription },
                set: { newValue in
                    if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                        entries[index].materialDescription = newValue
                    }
                }
            ), axis: .vertical)
            .lineLimit(3...6)
        }
        .padding(.vertical, 8)
    }
}

