//
//  QualificationSelectionView.swift
//  Project Planner
//
//  Created by Assistant on 23/10/2025.
//

import SwiftUI

struct QualificationSelectionView: View {
    @EnvironmentObject var operativeStore: OperativeStore
    @Environment(\.dismiss) private var dismiss
    
    @Binding var selectedQualifications: Set<Qualification>
    @Binding var qualificationExpiryDates: [UUID: Date]
    
    @State private var showingExpiryPicker: UUID? = nil
    @State private var tempExpiryDate: Date = Date()
    
    var body: some View {
        NavigationView {
            Form {
                if operativeStore.qualifications.isEmpty {
                    Section {
                        Text("No qualifications added yet. Create qualifications from the main menu.")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                } else {
                    Section("Available Qualifications") {
                        ForEach(operativeStore.qualifications, id: \.id) { qualification in
                            QualificationSelectionRow(
                                qualification: qualification,
                                isSelected: selectedQualifications.contains(qualification),
                                expiryDate: qualificationExpiryDates[qualification.id],
                                onToggle: {
                                    if selectedQualifications.contains(qualification) {
                                        selectedQualifications.remove(qualification)
                                        qualificationExpiryDates.removeValue(forKey: qualification.id)
                                    } else {
                                        selectedQualifications.insert(qualification)
                                    }
                                },
                                onSetExpiry: {
                                    tempExpiryDate = qualificationExpiryDates[qualification.id] ?? Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
                                    showingExpiryPicker = qualification.id
                                },
                                onRemoveExpiry: {
                                    qualificationExpiryDates.removeValue(forKey: qualification.id)
                                }
                            )
                        }
                    }
                }
            }
            .navigationTitle("Select Qualifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { showingExpiryPicker != nil },
                set: { if !$0 { showingExpiryPicker = nil } }
            )) {
                if let qualificationId = showingExpiryPicker {
                    NavigationView {
                        VStack(spacing: 20) {
                            Text("Set Expiry Date")
                                .font(.title2)
                                .fontWeight(.bold)
                            
                            DatePicker("Expiry Date", selection: $tempExpiryDate, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                            
                            Spacer()
                            
                            Button("Save") {
                                qualificationExpiryDates[qualificationId] = tempExpiryDate
                                showingExpiryPicker = nil
                            }
                            .buttonStyle(.borderedProminent)
                            .padding()
                        }
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Cancel") {
                                    showingExpiryPicker = nil
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct QualificationSelectionRow: View {
    let qualification: Qualification
    let isSelected: Bool
    let expiryDate: Date?
    let onToggle: () -> Void
    let onSetExpiry: () -> Void
    let onRemoveExpiry: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(qualification.name)
                        .font(.body)
                        .fontWeight(.medium)
                    
                    if let expiryDate = expiryDate {
                        Text("Expires: \(expiryDate, style: .date)")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Text("No expiry date set")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.gray)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onToggle()
            }
            
            if isSelected {
                HStack {
                    if expiryDate == nil {
                        Button("Set Expiry Date") {
                            onSetExpiry()
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                    } else {
                        Button("Change Expiry Date") {
                            onSetExpiry()
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        
                        Button("Remove Expiry") {
                            onRemoveExpiry()
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// UUID already conforms to Identifiable, so no extension needed

#Preview {
    QualificationSelectionView(
        selectedQualifications: .constant([]),
        qualificationExpiryDates: .constant([:])
    )
    .environmentObject(OperativeStore())
}

