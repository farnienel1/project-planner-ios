//
//  EditMaterialView.swift
//  Project Planner
//
//  Created by Assistant on 2025.
//

import SwiftUI

struct EditMaterialView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let material: MaterialItem
    @Binding var isPresented: Bool
    
    @State private var selectedDate: Date
    @State private var quantity: Int
    @State private var unit: MaterialUnit
    @State private var materialDescription: String
    @State private var isSaving = false
    
    init(material: MaterialItem, isPresented: Binding<Bool>) {
        self.material = material
        self._isPresented = isPresented
        self._selectedDate = State(initialValue: material.date)
        self._quantity = State(initialValue: material.quantity)
        self._unit = State(initialValue: material.unit)
        self._materialDescription = State(initialValue: material.material)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("Material Details") {
                    DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                    
                    Picker("Quantity", selection: $quantity) {
                        ForEach(1...100, id: \.self) { num in
                            Text("\(num)").tag(num)
                        }
                    }
                    
                    Picker("Unit", selection: $unit) {
                        ForEach(MaterialUnit.allCases, id: \.self) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    
                    TextField("Material Description", text: $materialDescription, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section("Original Entry") {
                    HStack {
                        Text("Added by")
                        Spacer()
                        Text(material.addedBy)
                            .foregroundColor(.secondary)
                    }
                    if let editedBy = material.editedBy {
                        HStack {
                            Text("Last edited by")
                            Spacer()
                            Text(editedBy)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Edit Material")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveMaterial()
                    }
                    .disabled(materialDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
    }
    
    private func saveMaterial() {
        guard !materialDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSaving = true
        
        let editedBy = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
        
        // Normalize date to start of day to ensure consistent filtering
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: selectedDate)
        
        var updatedMaterial = material
        updatedMaterial.quantity = quantity
        updatedMaterial.unit = unit
        updatedMaterial.material = materialDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedMaterial.date = normalizedDate
        updatedMaterial.editedBy = editedBy
        updatedMaterial.editedAt = Date()
        
        Task {
            guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                await MainActor.run {
                    isSaving = false
                }
                return
            }
            
            do {
                try await firebaseBackend.saveMaterialItem(updatedMaterial, organizationId: organizationId)
                print("✅ Material updated: \(updatedMaterial.material) for date: \(normalizedDate)")
                
                await MainActor.run {
                    isSaving = false
                    isPresented = false
                    
                    // Post notification to reload materials in parent view
                    NotificationCenter.default.post(name: NSNotification.Name("reloadMaterials"), object: nil)
                }
            } catch {
                print("❌ Error updating material: \(error.localizedDescription)")
                await MainActor.run {
                    isSaving = false
                }
            }
        }
    }
}

