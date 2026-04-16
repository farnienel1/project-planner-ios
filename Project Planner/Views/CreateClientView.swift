//
//  CreateClientView.swift
//  Project Planner
//
//  Created by Assistant on 20/10/2025.
//

import SwiftUI

struct CreateClientView: View {
    @EnvironmentObject var projectStore: ProjectStore
    @Environment(\.presentationMode) var presentationMode
    var onCreated: ((Client) -> Void)? = nil
    
    @State private var clientName = ""
    @State private var clientEmail = ""
    @State private var clientPhone = ""
    @State private var clientAddress = ""
    @State private var isLoading = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
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
                    Button(action: createClient) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text("Create Client")
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
            }
            .navigationTitle("New Client")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
            )
            .alert("Client Created", isPresented: $showingAlert) {
                Button("OK") {
                    presentationMode.wrappedValue.dismiss()
                }
            } message: {
                Text(alertMessage)
            }
        }
    }
    
    private var isFormValid: Bool {
        return !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private func createClient() {
        guard isFormValid else { return }
        
        isLoading = true
        
        // Create a simple client with the provided information
        let newClient = Client(
            name: clientName.trimmingCharacters(in: .whitespacesAndNewlines),
            contactPerson: nil,
            email: clientEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clientEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: clientPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clientPhone.trimmingCharacters(in: .whitespacesAndNewlines),
            address: clientAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clientAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        
        // Add the client to the store
        Task {
            await projectStore.addClient(newClient)
            onCreated?(newClient)
            
            DispatchQueue.main.async {
                isLoading = false
                alertMessage = "Client '\(newClient.name)' has been created successfully!"
                showingAlert = true
            }
        }
    }
}

#Preview {
    CreateClientView()
        .environmentObject(ProjectStore())
}
