//
//  CreateManagerView.swift
//  Project Planner
//
//  Created by Assistant on 23/10/2025.
//

import SwiftUI

struct CreateManagerView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var managerFirstName = ""
    @State private var managerLastName = ""
    @State private var managerEmail = ""
    @State private var managerMobileNumber = ""
    @State private var managerDepartment = ""
    @State private var managerNotes = ""
    @State private var tradePresetRaw = StaffTradeType.electrician.rawValue
    @State private var tradeCustomText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.square.badge.plus")
                            .font(.system(size: 60))
                            .foregroundColor(.purple)
                        
                        Text("Create New Manager")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Add a new manager to your organisation.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)
                    
                    // Form
                    VStack(spacing: 15) {
                        TextField("First Name *", text: $managerFirstName)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Last Name *", text: $managerLastName)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Email *", text: $managerEmail)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                        
                        TextField("Mobile Number *", text: $managerMobileNumber)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.phonePad)
                        
                        StaffTradeTypeFormSection(
                            presetRaw: $tradePresetRaw,
                            customText: $tradeCustomText,
                            title: "Trade type *",
                            footnote: "Required. Choose Other to enter a custom trade."
                        )
                        
                        TextField("Department (Optional)", text: $managerDepartment)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Notes (Optional)", text: $managerNotes, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                    }
                    .padding(.horizontal)
                    
                    // Error Message
                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }
                    
                    // Create Button
                    Button("Create Manager") {
                        createManager()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || !isFormValid)
                    .padding()
                }
            }
            .navigationTitle("New Manager")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var isFormValid: Bool {
        !managerFirstName.isEmpty &&
        !managerLastName.isEmpty &&
        !managerEmail.isEmpty &&
        !managerMobileNumber.isEmpty &&
        StaffTradeTypeFormSection.isValid(presetRaw: tradePresetRaw, customText: tradeCustomText)
    }
    
    private func createManager() {
        isLoading = true
        errorMessage = nil
        
        let tp = tradePresetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let tc = tradeCustomText.trimmingCharacters(in: .whitespacesAndNewlines)
        let manager = Manager(
            firstName: managerFirstName,
            lastName: managerLastName,
            email: managerEmail,
            mobileNumber: managerMobileNumber,
            department: managerDepartment.isEmpty ? nil : managerDepartment,
            notes: managerNotes.isEmpty ? nil : managerNotes,
            tradeTypePreset: tp.isEmpty ? nil : tp,
            tradeTypeCustom: tc.isEmpty ? nil : tc
        )
        
        Task {
            await operativeStore.addManager(manager)
            
            // Send notification
            let creatorName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
            await notificationService.notifyManagerCreated(
                managerId: manager.id,
                managerName: manager.fullName,
                createdBy: creatorName
            )
            
            await MainActor.run {
                isLoading = false
                dismiss()
            }
        }
    }
}

#Preview {
    CreateManagerView()
        .environmentObject(OperativeStore())
}











