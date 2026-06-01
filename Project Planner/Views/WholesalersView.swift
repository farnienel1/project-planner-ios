//
//  WholesalersView.swift
//  Project Planner
//
//  Created by Assistant on 2025.
//

import SwiftUI

struct WholesalersView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    @State private var wholesalers: [Wholesaler] = []
    @State private var showingAddWholesaler = false
    @State private var isLoading = false
    
    var body: some View {
        NavigationView {
            List {
                if wholesalers.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "building.2")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Wholesalers")
                        .font(.headline)
                    Text("Add your first wholesaler to get started")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ForEach(wholesalers.sorted(by: { $0.name < $1.name })) { wholesaler in
                    WholesalerRow(wholesaler: wholesaler)
                }
            }
            }
            .navigationTitle("Wholesalers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        showingAddWholesaler = true
                    }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationBarBackButtonHidden(true)
            .sheet(isPresented: $showingAddWholesaler) {
                AddWholesalerView(isPresented: $showingAddWholesaler)
                    .environmentObject(userStore)
                    .environmentObject(firebaseBackend)
            }
            .task {
                await loadWholesalers()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("reloadWholesalers"))) { _ in
                Task {
                    await loadWholesalers()
                }
            }
        }
    }
    
    private func loadWholesalers() async {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        isLoading = true
        
        do {
            wholesalers = try await firebaseBackend.loadWholesalers(organizationId: organizationId)
        } catch {
            print("Error loading wholesalers: \(error.localizedDescription)")
        }
        
        isLoading = false
    }
}

// MARK: - Wholesaler Row

struct WholesalerRow: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let wholesaler: Wholesaler
    @State private var showingEditWholesaler = false
    @State private var contactToEdit: WholesalerContact?
    @State private var showingAddContact = false
    
    private var hasAddress: Bool {
        let a = wholesaler.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !a.isEmpty
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Wholesaler card
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(wholesaler.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                    
                    if hasAddress, let address = wholesaler.address {
                        Text(address)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                Button(action: { showingEditWholesaler = true }) {
                    Image(systemName: "pencil")
                        .foregroundColor(.blue)
                        .font(.body)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            
            // Contact buttons listed below the card
            VStack(alignment: .leading, spacing: 8) {
                ForEach(wholesaler.contacts) { contact in
                    Button(action: { contactToEdit = contact }) {
                        HStack(spacing: 8) {
                            Text(contact.name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            Text(contact.email)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                if wholesaler.contacts.isEmpty {
                    Button(action: { showingEditWholesaler = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.badge.plus")
                            Text("Add contact")
                                .font(.subheadline)
                        }
                        .foregroundColor(.blue)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingEditWholesaler) {
            EditWholesalerView(wholesaler: wholesaler, isPresented: $showingEditWholesaler)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .sheet(item: $contactToEdit) { contact in
            EditWholesalerContactView(wholesaler: wholesaler, contact: contact, onDismiss: { contactToEdit = nil })
                .environmentObject(firebaseBackend)
        }
        .sheet(isPresented: $showingAddContact) {
            AddWholesalerContactView(
                wholesaler: wholesaler,
                isPresented: $showingAddContact
            )
            .environmentObject(userStore)
            .environmentObject(firebaseBackend)
        }
    }
}

// MARK: - Contact Tile

struct ContactTile: View {
    let contact: WholesalerContact
    
    var body: some View {
        Button(action: {
            if let url = URL(string: "mailto:\(contact.email)") {
                UIApplication.shared.open(url)
            }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(contact.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                Text(contact.email)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
    }
}

// MARK: - Add Wholesaler View

struct AddWholesalerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    @Binding var isPresented: Bool
    
    @State private var name: String = ""
    @State private var address: String = ""
    @State private var contacts: [ContactFormData] = [ContactFormData()]
    @State private var isSaving = false
    
    struct ContactFormData: Identifiable {
        let id = UUID()
        var firstName: String = ""
        var lastName: String = ""
        var email: String = ""
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("Wholesaler Details") {
                    TextField("Wholesaler Name", text: $name)
                    TextField("Address (Optional)", text: $address)
                }
                
                Section("Contacts") {
                    ForEach(contacts) { contact in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("First Name", text: Binding(
                                get: { contact.firstName },
                                set: { newValue in
                                    if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
                                        contacts[index].firstName = newValue
                                    }
                                }
                            ))
                            
                            TextField("Last Name", text: Binding(
                                get: { contact.lastName },
                                set: { newValue in
                                    if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
                                        contacts[index].lastName = newValue
                                    }
                                }
                            ))
                            
                            TextField("Email", text: Binding(
                                get: { contact.email },
                                set: { newValue in
                                    if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
                                        contacts[index].email = newValue
                                    }
                                }
                            ))
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                        }
                    }
                    
                    Button(action: {
                        contacts.append(ContactFormData())
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Contact")
                        }
                        .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("Add Wholesaler")
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
        }
    }
    
    private func saveWholesaler() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSaving = true
        
        // Convert contact form data to WholesalerContact
        let wholesalerContacts = contacts.compactMap { contactForm -> WholesalerContact? in
            let firstName = contactForm.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
            let lastName = contactForm.lastName.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = contactForm.email.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Only include contacts with at least first name and email
            guard !firstName.isEmpty, !email.isEmpty else { return nil }
            
            let fullName = lastName.isEmpty ? firstName : "\(firstName) \(lastName)"
            return WholesalerContact(name: fullName, email: email)
        }
        
        let wholesaler = Wholesaler(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            address: address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : address.trimmingCharacters(in: .whitespacesAndNewlines),
            contacts: wholesalerContacts
        )
        
        Task {
            guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                await MainActor.run {
                    isSaving = false
                }
                return
            }
            
            do {
                try await firebaseBackend.saveWholesaler(wholesaler, organizationId: organizationId)
                await MainActor.run {
                    isSaving = false
                    isPresented = false
                    // Post notification to reload wholesalers
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
}

// MARK: - Edit Wholesaler Contact View

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
        NavigationView {
            Form {
                Section("Contact Details") {
                    TextField("Contact Name", text: $contactName)
                    TextField("Email", text: $contactEmail)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }
                Section {
                    Button(role: .destructive, action: { showingDeleteConfirmation = true }) {
                        HStack {
                            Spacer()
                            Text("Remove contact from wholesaler")
                            Spacer()
                        }
                    }
                    .disabled(isDeleting)
                }
            }
            .navigationTitle("Edit Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveContact()
                    }
                    .disabled(
                        contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        isSaving
                    )
                }
            }
            .alert("Remove Contact", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Remove", role: .destructive) {
                    deleteContact()
                }
            } message: {
                Text("Remove \(contact.name) from \(wholesaler.name)? They can be added again later.")
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
                print("Error updating contact: \(error.localizedDescription)")
                await MainActor.run { isSaving = false }
            }
        }
    }
    
    private func deleteContact() {
        isDeleting = true
        var updatedWholesaler = wholesaler
        updatedWholesaler.contacts.removeAll { $0.id == contact.id }
        
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
                print("Error removing contact: \(error.localizedDescription)")
                await MainActor.run { isDeleting = false }
            }
        }
    }
}

// MARK: - Add Wholesaler Contact View

struct AddWholesalerContactView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let wholesaler: Wholesaler
    @Binding var isPresented: Bool
    
    @State private var contactName: String = ""
    @State private var contactEmail: String = ""
    @State private var isSaving = false
    
    var body: some View {
        NavigationView {
            Form {
                Section("Contact Details") {
                    TextField("Contact Name", text: $contactName)
                    TextField("Email", text: $contactEmail)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }
            }
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveContact()
                    }
                    .disabled(contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || 
                             contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || 
                             isSaving)
                }
            }
        }
    }
    
    private func saveContact() {
        guard !contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSaving = true
        
        let contact = WholesalerContact(
            name: contactName.trimmingCharacters(in: .whitespacesAndNewlines),
            email: contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        
        Task {
            guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                await MainActor.run {
                    isSaving = false
                }
                return
            }
            
            do {
                try await firebaseBackend.addContactToWholesaler(contact, wholesalerId: wholesaler.id, organizationId: organizationId)
                await MainActor.run {
                    isSaving = false
                    isPresented = false
                    // Post notification to reload wholesalers
                    NotificationCenter.default.post(name: NSNotification.Name("reloadWholesalers"), object: nil)
                }
            } catch {
                print("Error saving contact: \(error.localizedDescription)")
                await MainActor.run {
                    isSaving = false
                }
            }
        }
    }
}

