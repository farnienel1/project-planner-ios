//
//  EditMaterialView.swift
//  Project Planner
//
//  Created by Assistant on 2025.
//

import SwiftUI
import FirebaseAuth

struct EditMaterialView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var smartCache: SmartCacheService
    
    let material: MaterialItem
    @Binding var isPresented: Bool
    
    @State private var selectedDate: Date
    /// RULEBOOK 1.48.0: quantity, order unit and what is in one (`MaterialsOrderUnitRow`).
    @State private var quantityDraft: MaterialQuantityDraft
    /// The line as opened: the quantity checks run only when it changed.
    private let originalQuantity: MaterialQuantityDraft
    @State private var quantityError: String?
    @State private var materialDescription: String
    @State private var isSaving = false
    @State private var showingPermissionAlert = false
    @State private var saveErrorMessage = ""
    @State private var showingSaveErrorAlert = false
    
    private var canManageMaterial: Bool {
        guard let currentUser = firebaseBackend.currentUser else { return false }
        if !userStore.isOperativeMode() {
            return true
        }
        if let ownerUserId = material.addedByUserId, !ownerUserId.isEmpty {
            return ownerUserId == currentUser.uid
        }
        let normalizedAddedBy = material.addedBy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let displayName = (userStore.currentUser?.fullName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let email = (userStore.currentUser?.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedAddedBy == displayName || normalizedAddedBy == email
    }
    
    init(material: MaterialItem, isPresented: Binding<Bool>) {
        self.material = material
        self._isPresented = isPresented
        self._selectedDate = State(initialValue: material.date)
        let draft = MaterialQuantityDraft(quantity: material.quantity, model: material.effectiveQuantityModel)
        self._quantityDraft = State(initialValue: draft)
        self.originalQuantity = draft
        self._materialDescription = State(initialValue: material.material)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("Material Details") {
                    DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                        .accessibilityIdentifier("editMaterial.date")
                        .datePickerStyle(.compact)
                    
                    MaterialsOrderUnitRow(draft: $quantityDraft)
                        .accessibilityIdentifier("editMaterial.quantity")
                    if let quantityError {
                        Text(quantityError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("editMaterial.quantityError")
                    }
                    
                    TextField("Material Description", text: $materialDescription, axis: .vertical)
                        .accessibilityIdentifier("editMaterial.materialDescription")
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
            .scrollContentBackground(.hidden)
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Edit Material")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("editMaterial.cancel")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        if canManageMaterial {
                            saveMaterial()
                        } else {
                            showingPermissionAlert = true
                        }
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("editMaterial.save")
                    .disabled(materialDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving || !canManageMaterial)
                }
            }
        }
        .alert("Permission Required", isPresented: $showingPermissionAlert) {
            Button("OK", role: .cancel) { }
                .accessibilityIdentifier("editMaterial.ok")
        } message: {
            Text("You can only edit materials that you booked.")
        }
        .alert("Could Not Save Material", isPresented: $showingSaveErrorAlert) {
            Button("OK", role: .cancel) { }
                .accessibilityIdentifier("editMaterial.ok2")
        } message: {
            Text(saveErrorMessage)
        }
        .onAppear {
            guard canManageMaterial else {
                showingPermissionAlert = true
                isPresented = false
                dismiss()
                return
            }
        }
    }
    
    private func saveMaterial() {
        guard canManageMaterial else { return }
        guard !materialDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // RULEBOOK 1.48.0 `materialQuantityError` / `materialContentError`, only when the quantity changed.
        if let error = quantityDraft.validationError(comparedWith: originalQuantity) {
            quantityError = error
            return
        }
        quantityError = nil
        isSaving = true
        
        let editedBy = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
        
        // Normalize date to start of day to ensure consistent filtering
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: selectedDate)
        
        var updatedMaterial = material
        if quantityDraft != originalQuantity {
            quantityDraft.apply(to: &updatedMaterial)
        }
        updatedMaterial.material = materialDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedMaterial.date = normalizedDate
        updatedMaterial.editedBy = editedBy
        updatedMaterial.editedByUserId = firebaseBackend.currentUser?.uid
        updatedMaterial.editedAt = Date()
        
        Task {
            guard let organizationId = MaterialOfflineService.resolvedOrganizationId(firebaseBackend: firebaseBackend) else {
                await MainActor.run {
                    isSaving = false
                }
                return
            }
            
            do {
                _ = try await MaterialOfflineService.saveMaterial(
                    updatedMaterial,
                    organizationId: organizationId,
                    firebaseBackend: firebaseBackend,
                    isOnline: smartCache.isOnline
                )
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
                    saveErrorMessage = error.localizedDescription
                    showingSaveErrorAlert = true
                }
            }
        }
    }
}

