//
//  CreateOperativeView.swift
//  Project Planner
//
//  Created by Assistant on 23/10/2025.
//

import SwiftUI

struct CreateOperativeView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var operativeFirstName = ""
    @State private var operativeSurname = ""
    @State private var operativeEmail = ""
    @State private var operativePhone = ""
    @State private var operativeDayRate = ""
    @State private var tradePresetRaw = StaffTradeType.electrician.rawValue
    @State private var tradeCustomText = ""
    @State private var selectedSkills: Set<String> = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 10) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                        
                        Text("Create New Operative")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Add a new operative to your organisation.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)
                    
                    // Form
                    VStack(spacing: 15) {
                        TextField("First Name *", text: $operativeFirstName)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Surname *", text: $operativeSurname)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Email *", text: $operativeEmail)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                        
                        TextField("Phone *", text: $operativePhone)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.phonePad)
                        
                        StaffTradeTypeFormSection(
                            presetRaw: $tradePresetRaw,
                            customText: $tradeCustomText,
                            title: "Trade type *",
                            footnote: "Required. Choose Other to enter a custom trade."
                        )
                        
                        TextField("Day Rate (Optional)", text: $operativeDayRate)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                        
                        // Skills Selection
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Skills")
                                .font(.headline)
                            
                            if operativeStore.organizationSkills.isEmpty {
                                Text("No skills available. Add skills in the Skills Management section.")
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(8)
                            } else {
                                LazyVGrid(columns: [
                                    GridItem(.adaptive(minimum: 120))
                                ], spacing: 8) {
                                    ForEach(operativeStore.organizationSkills) { skill in
                                        Button(action: {
                                            if selectedSkills.contains(skill.id) {
                                                selectedSkills.remove(skill.id)
                                            } else {
                                                selectedSkills.insert(skill.id)
                                            }
                                        }) {
                                            HStack {
                                                Image(systemName: selectedSkills.contains(skill.id) ? "checkmark.circle.fill" : "circle")
                                                    .foregroundColor(selectedSkills.contains(skill.id) ? .blue : .gray)
                                                Text(skill.listTitle)
                                                    .font(.caption)
                                                    .foregroundColor(selectedSkills.contains(skill.id) ? .blue : .primary)
                                                    .multilineTextAlignment(.leading)
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(selectedSkills.contains(skill.id) ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                                            .cornerRadius(8)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    // Error Message
                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }
                    
                    // Create Button
                    Button(isSaving ? "Creating..." : "Create Operative") {
                        createOperative()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || isSaving || !isFormValid)
                    .padding()
                }
            }
            .navigationTitle("New Operative")
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
        !operativeFirstName.isEmpty &&
        !operativeSurname.isEmpty &&
        !operativeEmail.isEmpty &&
        !operativePhone.isEmpty &&
        StaffTradeTypeFormSection.isValid(presetRaw: tradePresetRaw, customText: tradeCustomText)
    }
    
    private func createOperative() {
        // Prevent multiple saves
        guard !isSaving else {
            print("🔥🔥🔥 DEBUG: Already saving operative, ignoring duplicate request")
            return
        }
        
        // Check for duplicate operatives
        let duplicateExists = operativeStore.allOperatives.contains { existingOperative in
            existingOperative.firstName.lowercased().trimmingCharacters(in: .whitespaces) == operativeFirstName.lowercased().trimmingCharacters(in: .whitespaces) &&
            existingOperative.lastName.lowercased().trimmingCharacters(in: .whitespaces) == operativeSurname.lowercased().trimmingCharacters(in: .whitespaces)
        }
        
        if duplicateExists {
            errorMessage = "An operative with the name '\(operativeFirstName) \(operativeSurname)' already exists."
            return
        }
        
        isSaving = true
        isLoading = true
        errorMessage = nil
        
        let parsedRate = operativeDayRate.isEmpty ? nil : Double(operativeDayRate.replacingOccurrences(of: ",", with: "."))
        let tp = tradePresetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let tc = tradeCustomText.trimmingCharacters(in: .whitespacesAndNewlines)
        let operative = Operative(
            firstName: operativeFirstName.trimmingCharacters(in: .whitespaces),
            lastName: operativeSurname.trimmingCharacters(in: .whitespaces),
            email: operativeEmail.trimmingCharacters(in: .whitespaces),
            phone: operativePhone.trimmingCharacters(in: .whitespaces),
            startDate: Date(),
            skills: selectedSkills,
            hourlyRate: parsedRate,
            dayRate: parsedRate,
            tradeTypePreset: tp.isEmpty ? nil : tp,
            tradeTypeCustom: tc.isEmpty ? nil : tc
        )
        
        Task {
            await operativeStore.addOperative(operative)
            
            // Send notification
            let creatorName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
            await notificationService.notifyOperativeCreated(
                operativeId: operative.id,
                operativeName: operative.name,
                createdBy: creatorName
            )
            
            await MainActor.run {
                isLoading = false
                isSaving = false
                dismiss()
            }
        }
    }
}

#Preview {
    CreateOperativeView()
        .environmentObject(OperativeStore())
}
