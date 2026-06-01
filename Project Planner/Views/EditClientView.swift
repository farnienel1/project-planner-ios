//
//  EditClientView.swift
//  Project Planner
//
//  Created by Assistant on 27/10/2025.
//

import SwiftUI

struct EditClientView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @Environment(\.dismiss) private var dismiss
    
    let client: Client
    
    @State private var clientName: String
    @State private var clientEmail: String
    @State private var clientPhone: String
    @State private var clientAddress: String
    @State private var isLoading = false
    @State private var showingDeleteAlert = false
    
    init(client: Client) {
        self.client = client
        _clientName = State(initialValue: client.name)
        _clientEmail = State(initialValue: client.email ?? "")
        _clientPhone = State(initialValue: client.phone ?? "")
        _clientAddress = State(initialValue: client.address ?? "")
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Client Information")) {
                    TextField("Client Name", text: $clientName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    TextField("Email", text: $clientEmail)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                    
                    TextField("Phone", text: $clientPhone)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.phonePad)
                    
                    TextField("Address", text: $clientAddress)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                Section {
                    Button(action: saveClient) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text("Save Changes")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isFormValid ? Color.blue : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(!isFormValid || isLoading)
                }
                .listRowBackground(Color.clear)
                
                Section {
                    Button(action: {
                        showingDeleteAlert = true
                    }) {
                        HStack {
                            Spacer()
                            Text("Delete Client")
                                .fontWeight(.semibold)
                                .foregroundColor(.red)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Edit Client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Delete Client", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    deleteClient()
                }
            } message: {
                Text("Are you sure you want to delete \(client.name)? This action cannot be undone.")
            }
        }
    }
    
    private var isFormValid: Bool {
        return !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private func saveClient() {
        guard isFormValid else { return }
        
        isLoading = true
        
        let updatedClient = Client(
            id: client.id,
            name: clientName.trimmingCharacters(in: .whitespacesAndNewlines),
            contactPerson: client.contactPerson,
            email: clientEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clientEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: clientPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clientPhone.trimmingCharacters(in: .whitespacesAndNewlines),
            address: clientAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clientAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        
        Task {
            await projectStore.updateClient(updatedClient)
            await MainActor.run {
                isLoading = false
                dismiss()
            }
        }
    }
    
    private func deleteClient() {
        Task {
            await projectStore.deleteClient(client)
            await MainActor.run {
                dismiss()
            }
        }
    }
}

