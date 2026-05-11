import SwiftUI

struct SubcontractorsView: View {
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    @EnvironmentObject var userStore: UserStore
    @State private var showingAdd = false
    
    var body: some View {
        List {
            if subcontractorStore.subcontractors.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.badge.gearshape.fill")
                        .font(.system(size: 42))
                        .foregroundColor(.secondary)
                    Text("No Sub-Contractors")
                        .font(.headline)
                    Text("Add your first sub-contractor to start booking them to projects and small works.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ForEach(subcontractorStore.subcontractors.sorted(by: { $0.name < $1.name })) { subcontractor in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(subcontractor.name)
                            .font(.headline)
                        Text(subcontractor.subcontractorType)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if let website = subcontractor.website, !website.isEmpty {
                            Text(website)
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        if let address = subcontractor.address, !address.isEmpty {
                            Text(address)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if !subcontractor.contacts.isEmpty {
                            Text("\(subcontractor.contacts.count) contact\(subcontractor.contacts.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Sub Contractors")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .foregroundColor(Color.theme.primary)
                    .fontWeight(.medium)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if userStore.canManageSubcontractors() {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAdd, onDismiss: {
            Task { await subcontractorStore.loadData() }
        }) {
            AddSubcontractorView()
                .environmentObject(subcontractorStore)
        }
        .task {
            await subcontractorStore.loadData()
        }
    }
}

private struct AddSubcontractorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    
    @State private var step = 1
    @State private var name = ""
    @State private var subcontractorType = ""
    @State private var website = ""
    @State private var address = ""
    @State private var contacts: [SubcontractorContact] = []
    
    @State private var contactName = ""
    @State private var contactEmail = ""
    @State private var contactNumber = ""
    @State private var contactPosition: SubcontractorContactPosition = .projectManager
    @State private var saveErrorMessage: String?
    
    private var canProceed: Bool {
        switch step {
        case 1:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !subcontractorType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 2:
            return true
        default:
            return true
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("Step \(step) of 3")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
                
                Form {
                    if step == 1 {
                        Section("Sub Contractor Details") {
                            TextField("Sub Contractor Name *", text: $name)
                            TextField("Type *", text: $subcontractorType)
                            TextField("Website", text: $website)
                                .textInputAutocapitalization(.never)
                            TextField("Address", text: $address)
                        }
                    } else if step == 2 {
                        Section("Sub Contractor - Contact Details") {
                            TextField("Name", text: $contactName)
                            TextField("Email", text: $contactEmail)
                                .textInputAutocapitalization(.never)
                            TextField("Contact Number", text: $contactNumber)
                                .keyboardType(.phonePad)
                            Picker("Position", selection: $contactPosition) {
                                ForEach(SubcontractorContactPosition.allCases) { pos in
                                    Text(pos.rawValue).tag(pos)
                                }
                            }
                            Button("Add Contact") {
                                addContact()
                            }
                            .disabled(contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        
                        if !contacts.isEmpty {
                            Section("Added Contacts") {
                                ForEach(contacts) { contact in
                                    VStack(alignment: .leading) {
                                        Text(contact.name).font(.subheadline).bold()
                                        Text("\(contact.position.rawValue) • \(contact.email)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    } else {
                        Section("Summary") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(name).font(.headline)
                                Text(subcontractorType).font(.subheadline)
                                if !website.isEmpty { Text(website).font(.caption).foregroundColor(.blue) }
                                if !address.isEmpty { Text(address).font(.caption).foregroundColor(.secondary) }
                            }
                        }
                        
                        ForEach(SubcontractorContactPosition.allCases) { position in
                            let grouped = contacts.filter { $0.position == position }
                            if !grouped.isEmpty {
                                Section(position.rawValue) {
                                    ForEach(grouped) { contact in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(contact.name).font(.subheadline).bold()
                                            Text(contact.email).font(.caption).foregroundColor(.secondary)
                                            Text(contact.contactNumber).font(.caption).foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                
                HStack {
                    if step > 1 {
                        Button("Back") { step -= 1 }
                    }
                    Spacer()
                    Button(step == 3 ? "Save" : "Next") {
                        if step < 3 {
                            step += 1
                        } else {
                            save()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                
                if let saveErrorMessage {
                    Text(saveErrorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }
            }
            .navigationTitle("Add Sub Contractor")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
    
    private func addContact() {
        let cleanName = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        contacts.append(SubcontractorContact(
            name: cleanName,
            email: contactEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            contactNumber: contactNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            position: contactPosition
        ))
        contactName = ""
        contactEmail = ""
        contactNumber = ""
        contactPosition = .projectManager
    }
    
    private func save() {
        let subcontractor = Subcontractor(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            subcontractorType: subcontractorType.trimmingCharacters(in: .whitespacesAndNewlines),
            website: website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : website.trimmingCharacters(in: .whitespacesAndNewlines),
            address: address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : address.trimmingCharacters(in: .whitespacesAndNewlines),
            contacts: contacts,
            updatedAt: Date()
        )
        Task {
            await subcontractorStore.saveSubcontractor(subcontractor)
            if let message = subcontractorStore.errorMessage, !message.isEmpty {
                await MainActor.run {
                    saveErrorMessage = message
                }
            } else {
                dismiss()
            }
        }
    }
}
