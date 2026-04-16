//
//  SelectOperativesView.swift
//  Project Planner
//
//  Created by Assistant on 22/10/2025.
//

import SwiftUI

struct SelectOperativesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var operativeStore: OperativeStore
    
    @Binding var selectedOperatives: Set<UUID>
    @State private var searchText = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search bar
                if !operativeStore.activeOperatives.isEmpty {
                    OperativeSearchBar(text: $searchText)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
                
                // Operatives list
                if operativeStore.isLoading {
                    ProgressView("Loading operatives...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredOperatives.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        
                        Text("No Operatives Available")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text("Add operatives in the Operatives section")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List(filteredOperatives) { operative in
                        OperativeSelectionRow(
                            operative: operative,
                            isSelected: selectedOperatives.contains(operative.id),
                            onToggle: {
                                if selectedOperatives.contains(operative.id) {
                                    selectedOperatives.remove(operative.id)
                                } else {
                                    selectedOperatives.insert(operative.id)
                                }
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationTitle("Select Operatives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .foregroundColor(Color.theme.primary)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(Color.theme.primary)
                }
            }
        }
    }
    
    private var filteredOperatives: [Operative] {
        let operatives = operativeStore.activeOperatives
        
        if searchText.isEmpty {
            return operatives
        }
        
        return operatives.filter { operative in
            operative.name.localizedCaseInsensitiveContains(searchText) ||
            operative.email.localizedCaseInsensitiveContains(searchText)
        }
    }
}

struct OperativeSelectionRow: View {
    let operative: Operative
    let isSelected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Selection indicator
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.theme.primary : Color.gray.opacity(0.3), lineWidth: 2)
                        .frame(width: 24, height: 24)
                    
                    if isSelected {
                        Circle()
                            .fill(Color.theme.primary)
                            .frame(width: 16, height: 16)
                    }
                }
                
                // Operative info
                VStack(alignment: .leading, spacing: 4) {
                    Text(operative.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(operative.email)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    // Qualifications and skills tags
                    HStack(spacing: 8) {
                        if !operative.qualifications.isEmpty {
                            Text("\(operative.qualifications.count) qualifications")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.theme.primaryLight.opacity(0.2))
                                .foregroundColor(Color.theme.primary)
                                .cornerRadius(8)
                        }
                        
                        if !operative.skills.isEmpty {
                            Text("\(operative.skills.count) skills")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.theme.primaryLight.opacity(0.2))
                                .foregroundColor(Color.theme.primary)
                                .cornerRadius(8)
                        }
                    }
                }
                
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct OperativeSearchBar: View {
    @Binding var text: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("Search operatives...", text: $text)
                .textFieldStyle(PlainTextFieldStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

#Preview {
    SelectOperativesView(selectedOperatives: .constant(Set<UUID>()))
        .environmentObject(OperativeStore())
}

