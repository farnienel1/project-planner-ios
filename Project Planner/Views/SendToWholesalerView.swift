//
//  SendToWholesalerView.swift
//  Project Planner
//
//  Created by Assistant on 2025.
//

import SwiftUI

struct SendToWholesalerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let project: Project
    let materials: [MaterialItem]
    @Binding var selectedMaterials: Set<UUID>
    @Binding var isPresented: Bool
    
    @State private var wholesalers: [Wholesaler] = []
    @State private var selectedContacts: Set<UUID> = []
    @State private var requestType: MaterialOrderRequest.RequestType = .quote
    @State private var isSending = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Send For Quote / Send Order buttons at top
                HStack(spacing: 12) {
                    Button(action: {
                        requestType = .quote
                        sendRequest()
                    }) {
                        Text("Send For Quote")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                    .disabled(selectedMaterials.isEmpty || selectedContacts.isEmpty || isSending)
                    
                    Button(action: {
                        requestType = .order
                        sendRequest()
                    }) {
                        Text("Send Order")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .cornerRadius(10)
                    }
                    .disabled(selectedMaterials.isEmpty || selectedContacts.isEmpty || isSending)
                }
                .padding()
                .background(Color(.systemGroupedBackground))
                
                Form {
                    Section("Project Information") {
                        HStack {
                            Text("Project Number")
                            Spacer()
                            Text(project.jobNumber)
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Project Name")
                            Spacer()
                            Text(project.siteName)
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Site Address")
                            Spacer()
                            Text(project.siteAddress)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    
                    Section("Materials") {
                        ForEach(materials) { material in
                            Toggle(isOn: Binding(
                                get: { selectedMaterials.contains(material.id) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedMaterials.insert(material.id)
                                    } else {
                                        selectedMaterials.remove(material.id)
                                    }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(material.material)
                                        .font(.body)
                                    Text("\(material.quantity) \(material.unit.rawValue)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    
                    Section("Select Wholesalers") {
                        if wholesalers.isEmpty {
                            Text("No wholesalers added yet")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(wholesalers.sorted(by: { $0.name < $1.name })) { wholesaler in
                                DisclosureGroup(wholesaler.name) {
                                    ForEach(wholesaler.contacts) { contact in
                                        Toggle(isOn: Binding(
                                            get: { selectedContacts.contains(contact.id) },
                                            set: { isSelected in
                                                if isSelected {
                                                    selectedContacts.insert(contact.id)
                                                } else {
                                                    selectedContacts.remove(contact.id)
                                                }
                                            }
                                        )) {
                                            HStack(spacing: 6) {
                                                Text(contact.name)
                                                    .font(.body)
                                                    .lineLimit(1)
                                                Text("·")
                                                    .foregroundColor(.secondary)
                                                Text(contact.email)
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.8)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Send to Wholesaler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
            .alert("Multiple Wholesalers Selected", isPresented: $showingMultipleWholesalerAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("You can only send an order to one wholesaler at a time. Please select contacts from only one wholesaler.")
            }
            .task {
                await loadWholesalers()
                // Select all materials by default
                selectedMaterials = Set(materials.map { $0.id })
            }
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
    
    @State private var showingMultipleWholesalerAlert = false
    
    private func sendRequest() {
        guard !selectedMaterials.isEmpty, !selectedContacts.isEmpty else { return }
        
        // Check if sending an ORDER to multiple wholesalers
        if requestType == .order {
            // Get unique wholesalers from selected contacts
            let selectedWholesalerIds = Set(wholesalers.compactMap { wholesaler in
                wholesaler.contacts.contains(where: { selectedContacts.contains($0.id) }) ? wholesaler.id : nil
            })
            
            // If more than one wholesaler is selected for an order, show alert
            if selectedWholesalerIds.count > 1 {
                showingMultipleWholesalerAlert = true
                return
            }
        }
        
        isSending = true
        
        let selectedMaterialItems = materials.filter { selectedMaterials.contains($0.id) }
        let selectedContactObjects = wholesalers.flatMap { $0.contacts }.filter { selectedContacts.contains($0.id) }
        
        // Signature order: Name, phone (if any), email, company name
        let userName = userStore.currentUser?.fullName ?? "Unknown User"
        let userPhone = userStore.currentUser?.mobileNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userEmail = userStore.currentUser?.email ?? ""
        let orgName = firebaseBackend.currentOrganization?.name ?? ""
        var senderSignature = userName
        if let phone = userPhone, !phone.isEmpty {
            senderSignature += "\n\(phone)"
        }
        if !userEmail.isEmpty {
            senderSignature += "\n\(userEmail)"
        }
        if !orgName.isEmpty {
            senderSignature += "\n\(orgName)"
        }
        
        let request = MaterialOrderRequest(
            projectNumber: project.jobNumber,
            projectName: project.siteName,
            siteAddress: project.siteAddress,
            materials: selectedMaterialItems,
            requestType: requestType,
            sentBy: senderSignature,
            recipientContacts: selectedContactObjects
        )
        
        Task {
            guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                await MainActor.run {
                    isSending = false
                }
                return
            }
            
            do {
                try await firebaseBackend.sendMaterialRequest(request, organizationId: organizationId)
                await MainActor.run {
                    isSending = false
                    isPresented = false
                }
            } catch {
                print("Error sending material request: \(error.localizedDescription)")
                await MainActor.run {
                    isSending = false
                }
            }
        }
    }
}

