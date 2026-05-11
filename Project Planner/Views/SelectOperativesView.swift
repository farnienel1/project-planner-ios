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
    let unavailableOperativeIds: Set<UUID>
    @State private var searchText = ""
    @State private var selectedFilter: AvailabilityFilter = .all
    
    enum AvailabilityFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case available = "Available"
        case annualLeave = "Annual Leave"
        
        var id: String { rawValue }
    }
    
    private var availableOperatives: [Operative] {
        let active = operativeStore.activeOperatives
        return active.isEmpty ? operativeStore.allOperatives : active
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search bar
                if !availableOperatives.isEmpty {
                    OperativeSearchBar(text: $searchText)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(AvailabilityFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
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
                        
                        Text(unavailableOperativeIds.isEmpty ? "No Operatives Available" : "No Matching Operatives")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text(unavailableOperativeIds.isEmpty
                             ? "Add operatives in the Operatives section"
                             : "Selected dates include approved holiday for one or more operatives.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List(filteredOperatives) { operative in
                        let isOnAnnualLeave = unavailableOperativeIds.contains(operative.id)
                        OperativeSelectionRow(
                            operative: operative,
                            isSelected: selectedOperatives.contains(operative.id),
                            isDisabled: isOnAnnualLeave,
                            onToggle: {
                                if isOnAnnualLeave { return }
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
        let operatives = availableOperatives.filter { operative in
            switch selectedFilter {
            case .all:
                return true
            case .available:
                return !unavailableOperativeIds.contains(operative.id)
            case .annualLeave:
                return unavailableOperativeIds.contains(operative.id)
            }
        }
        
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
    let isDisabled: Bool
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
                    HStack(spacing: 6) {
                        Text(operative.name)
                        if isDisabled {
                            Text("AL")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(6)
                        }
                    }
                        .font(.headline)
                        .foregroundColor(isDisabled ? .secondary : .primary)
                    
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
        .opacity(isDisabled ? 0.55 : 1)
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
    SelectOperativesView(selectedOperatives: .constant(Set<UUID>()), unavailableOperativeIds: [])
        .environmentObject(OperativeStore())
}

