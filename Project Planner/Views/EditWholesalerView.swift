//
//  EditWholesalerView.swift
//  Project Planner
//
//  Created by Assistant on 2025.
//

import SwiftUI

struct EditWholesalerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let wholesaler: Wholesaler
    @Binding var isPresented: Bool
    
    @State private var name: String
    @State private var address: String
    @State private var contacts: [WholesalerContact]
    @State private var isSaving = false
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var showingAddContact = false
    
    init(wholesaler: Wholesaler, isPresented: Binding<Bool>) {
        self.wholesaler = wholesaler
        self._isPresented = isPresented
        self._name = State(initialValue: wholesaler.name)
        self._address = State(initialValue: wholesaler.address ?? "")
        self._contacts = State(initialValue: wholesaler.contacts)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("Wholesaler Details") {
                    TextField("Wholesaler Name", text: $name)
                    TextField("Address (Optional)", text: $address)
                }
                
                Section("Staff / Contacts") {
                    ForEach(contacts) { contact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(contact.name)
                                .font(.body)
                                .fontWeight(.medium)
                            Text(contact.email)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Button(action: { showingAddContact = true }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add contact")
                        }
                        .foregroundColor(.blue)
                    }
                }
                
                Section {
                    Button(action: {
                        showingDeleteConfirmation = true
                    }) {
                        HStack {
                            Spacer()
                            Text("Delete Wholesaler")
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                    .disabled(isDeleting)
                }
            }
            .navigationTitle("Edit Wholesaler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveWholesaler()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .alert("Delete Wholesaler", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    performDeleteWholesaler()
                }
            } message: {
                Text("Are you sure you want to delete \(wholesaler.name)? This action cannot be undone.")
            }
            .sheet(isPresented: $showingAddContact) {
                AddWholesalerContactView(wholesaler: updatedWholesalerForAddContact, isPresented: $showingAddContact)
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
                    .onDisappear {
                        Task { await refreshContacts() }
                    }
            }
        }
    }
    
    private var updatedWholesalerForAddContact: Wholesaler {
        var w = wholesaler
        w.contacts = contacts
        w.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        w.address = address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : address.trimmingCharacters(in: .whitespacesAndNewlines)
        return w
    }
    
    private func refreshContacts() async {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        do {
            let all = try await firebaseBackend.loadWholesalers(organizationId: organizationId)
            if let updated = all.first(where: { $0.id == wholesaler.id }) {
                await MainActor.run {
                    contacts = updated.contacts
                }
            }
        } catch {
            print("Error refreshing contacts: \(error.localizedDescription)")
        }
    }
    
    private func saveWholesaler() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSaving = true
        
        var updatedWholesaler = wholesaler
        updatedWholesaler.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedWholesaler.address = address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : address.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedWholesaler.contacts = contacts
        updatedWholesaler.updatedAt = Date()
        
        Task {
            guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                await MainActor.run {
                    isSaving = false
                }
                return
            }
            
            do {
                try await firebaseBackend.saveWholesaler(updatedWholesaler, organizationId: organizationId)
                await MainActor.run {
                    isSaving = false
                    isPresented = false
                    NotificationCenter.default.post(name: NSNotification.Name("reloadWholesalers"), object: nil)
                }
            } catch {
                print("Error saving wholesaler: \(error.localizedDescription)")
                await MainActor.run {
                    isSaving = false
                }
            }
        }
    }
    
    private func performDeleteWholesaler() {
        isDeleting = true
        let backend: FirebaseBackend = firebaseBackend
        let wholesalerId = wholesaler.id
        Task {
            guard let organizationId = backend.currentOrganization?.firestoreDocumentId else {
                await MainActor.run {
                    isDeleting = false
                }
                return
            }
            
            do {
                try await backend.deleteWholesaler(wholesalerId: wholesalerId, organizationId: organizationId)
                await MainActor.run {
                    isDeleting = false
                    isPresented = false
                    NotificationCenter.default.post(name: NSNotification.Name("reloadWholesalers"), object: nil)
                }
            } catch {
                print("Error deleting wholesaler: \(error.localizedDescription)")
                await MainActor.run {
                    isDeleting = false
                }
            }
        }
    }
}

