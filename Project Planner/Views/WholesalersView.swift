//
//  WholesalersView.swift
//  Project Planner
//

import SwiftUI

struct WholesalersView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    var presentedAsSheet: Bool = false
    @State private var wholesalers: [Wholesaler] = []

    var body: some View {
        NavigationStack {
            WholesalersListContent(presentedAsSheet: presentedAsSheet, wholesalers: $wholesalers)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .task {
            await loadWholesalers()
        }
    }

    private func loadWholesalers() async {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        do {
            wholesalers = try await firebaseBackend.loadWholesalers(organizationId: organizationId)
        } catch {
            print("Error loading wholesalers: \(error.localizedDescription)")
        }
    }
}

// Legacy contact editor — used from other flows if needed
struct EditWholesalerContactView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    let wholesaler: Wholesaler
    let contact: WholesalerContact
    var onDismiss: () -> Void

    @State private var contactName: String
    @State private var contactEmail: String
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var showingDeleteConfirmation = false

    init(wholesaler: Wholesaler, contact: WholesalerContact, onDismiss: @escaping () -> Void) {
        self.wholesaler = wholesaler
        self.contact = contact
        self.onDismiss = onDismiss
        self._contactName = State(initialValue: contact.name)
        self._contactEmail = State(initialValue: contact.email)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Contact Details") {
                    TextField("Contact Name", text: $contactName)
                    TextField("Email", text: $contactEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Button(role: .destructive) { showingDeleteConfirmation = true } label: {
                        Text("Remove contact from wholesaler")
                    }
                    .disabled(isDeleting)
                }
            }
            .navigationTitle("Edit Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveContact() }
                        .disabled(
                            contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || isSaving
                        )
                }
            }
            .alert("Remove Contact", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) { deleteContact() }
            } message: {
                Text("Remove \(contact.name) from \(wholesaler.name)?")
            }
        }
    }

    private func saveContact() {
        let name = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty else { return }
        isSaving = true
        let updatedContact = WholesalerContact(
            id: contact.id,
            name: name,
            email: email,
            isPrimary: contact.isPrimary,
            createdAt: contact.createdAt
        )
        Task {
            guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                await MainActor.run { isSaving = false }
                return
            }
            do {
                try await firebaseBackend.addContactToWholesaler(updatedContact, wholesalerId: wholesaler.id, organizationId: organizationId)
                await MainActor.run {
                    isSaving = false
                    onDismiss()
                    NotificationCenter.default.post(name: NSNotification.Name("reloadWholesalers"), object: nil)
                }
            } catch {
                await MainActor.run { isSaving = false }
            }
        }
    }

    private func deleteContact() {
        isDeleting = true
        var updatedWholesaler = wholesaler
        updatedWholesaler.contacts.removeAll { $0.id == contact.id }
        ensurePrimary(on: &updatedWholesaler)
        Task {
            guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                await MainActor.run { isDeleting = false }
                return
            }
            do {
                try await firebaseBackend.saveWholesaler(updatedWholesaler, organizationId: organizationId)
                await MainActor.run {
                    isDeleting = false
                    onDismiss()
                    NotificationCenter.default.post(name: NSNotification.Name("reloadWholesalers"), object: nil)
                }
            } catch {
                await MainActor.run { isDeleting = false }
            }
        }
    }

    private func ensurePrimary(on wholesaler: inout Wholesaler) {
        if wholesaler.contacts.isEmpty { return }
        if !wholesaler.contacts.contains(where: \.isPrimary) {
            wholesaler.contacts[0].isPrimary = true
        }
        wholesaler.primaryContactId = wholesaler.contacts.first(where: \.isPrimary)?.id
    }
}

struct AddWholesalerContactView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    let wholesaler: Wholesaler
    @Binding var isPresented: Bool

    @State private var contactName = ""
    @State private var contactEmail = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Contact Details") {
                    TextField("Contact Name", text: $contactName)
                    TextField("Email", text: $contactEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveContact() }
                        .disabled(
                            contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || isSaving
                        )
                }
            }
        }
    }

    private func saveContact() {
        let name = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty else { return }
        isSaving = true
        let contact = WholesalerContact(name: name, email: email, isPrimary: wholesaler.contacts.isEmpty)
        Task {
            guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                await MainActor.run { isSaving = false }
                return
            }
            do {
                try await firebaseBackend.addContactToWholesaler(contact, wholesalerId: wholesaler.id, organizationId: organizationId)
                await MainActor.run {
                    isSaving = false
                    isPresented = false
                    NotificationCenter.default.post(name: NSNotification.Name("reloadWholesalers"), object: nil)
                }
            } catch {
                await MainActor.run { isSaving = false }
            }
        }
    }
}
