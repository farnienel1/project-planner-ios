//
//  QualificationsManagementView.swift
//  Project Planner
//
//  Created by Assistant on 23/10/2025.
//

import SwiftUI

struct QualificationsManagementView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddQualification = false
    
    var body: some View {
        NavigationView {
            VStack {
                if operativeStore.qualifications.isEmpty {
                    // Empty state
                    VStack(spacing: 20) {
                        Image(systemName: "graduationcap.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        
                        Text("No Qualifications Added Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Add qualifications for your operatives. Some qualifications can have expiration dates.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button("Create New Qualification") {
                            showingAddQualification = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    // List of qualifications
                    List {
                        ForEach(operativeStore.qualifications) { qualification in
                            QualificationRowView(qualification: qualification)
                        }
                        .onDelete(perform: deleteQualifications)
                    }
                    .listStyle(PlainListStyle())
                }
                
                Spacer()
            }
            .navigationTitle("Qualifications")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.blue)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create New Qualification") {
                        showingAddQualification = true
                    }
                }
            }
            .sheet(isPresented: $showingAddQualification) {
                AddQualificationView()
                    .environmentObject(operativeStore)
            }
        }
    }
    
    private func deleteQualifications(offsets: IndexSet) {
        for index in offsets {
            let qualification = operativeStore.qualifications[index]
            Task {
                await operativeStore.deleteQualification(qualification)
            }
        }
    }
}

struct QualificationRowView: View {
    let qualification: Qualification
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(qualification.name)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    
                    // Expiration is only shown when qualification is assigned to an operative
                    // Qualifications themselves don't have expiration dates
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    if qualification.hasEndDate {
                        Image(systemName: "clock.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Image(systemName: "infinity.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct AddQualificationView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var qualificationName = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            Form {
                Section("Qualification Details") {
                    TextField("Qualification Name", text: $qualificationName)
                        .textFieldStyle(.roundedBorder)
                    
                    Text("Note: Expiration dates can be set when assigning this qualification to an operative.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Add Qualification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveQualification()
                    }
                    .disabled(!isFormValid)
                }
            }
        }
    }
    
    private var isFormValid: Bool {
        !qualificationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private func saveQualification() {
        isLoading = true
        errorMessage = nil
        
        let qualification = Qualification(
            name: qualificationName.trimmingCharacters(in: .whitespacesAndNewlines),
            hasEndDate: false, // Expiration is only set when assigning to operatives
            endDate: nil
        )
        
        Task {
            await operativeStore.addQualification(qualification)
            await MainActor.run {
                isLoading = false
                dismiss()
            }
        }
    }
}

#Preview {
    QualificationsManagementView()
        .environmentObject(OperativeStore())
}











