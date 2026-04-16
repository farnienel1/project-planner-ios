//
//  AdminManagerMaterialsView.swift
//  Project Planner
//
//  Created by Assistant on 2025.
//

import SwiftUI

struct AdminManagerMaterialsView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let project: Project
    @Binding var selectedDate: Date
    @Binding var currentWeek: Date
    @Binding var materials: [MaterialItem]
    
    @State private var showingAddMaterial = false
    @State private var showingSendToWholesaler = false
    @State private var selectedMaterials: Set<UUID> = []
    
    var body: some View {
        VStack(spacing: 0) {
            // Week Navigation
            weekNavigationView
            
            // Week Calendar
            weekCalendarView
            
            // Materials List for Selected Day
            materialsListView
        }
        .sheet(isPresented: $showingAddMaterial) {
            AddMaterialView(
                project: project,
                date: selectedDate,
                isPresented: $showingAddMaterial
            )
            .environmentObject(userStore)
            .environmentObject(firebaseBackend)
        }
            .sheet(isPresented: $showingSendToWholesaler) {
            SendToWholesalerView(
                project: project,
                materials: dayMaterials,
                selectedMaterials: $selectedMaterials,
                isPresented: $showingSendToWholesaler
            )
            .environmentObject(userStore)
            .environmentObject(firebaseBackend)
        }
    }
    
    private var dayMaterials: [MaterialItem] {
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: selectedDate)
        
        let filtered = materials.filter { material in
            let materialDay = calendar.startOfDay(for: material.date)
            return calendar.isDate(materialDay, inSameDayAs: selectedDay)
        }
        
        // Debug: Log materials for troubleshooting
        print("📦 Materials Debug:")
        print("   Total materials: \(materials.count)")
        print("   Selected date: \(selectedDate)")
        print("   Selected day (normalized): \(selectedDay)")
        print("   Filtered materials for this day: \(filtered.count)")
        for material in filtered {
            print("   - \(material.material) (date: \(material.date))")
        }
        
        return filtered
    }
    
    private var weekNavigationView: some View {
        HStack {
            Button(action: { changeWeek(by: -1) }) {
                Image(systemName: "chevron.left")
                    .foregroundColor(.blue)
            }
            
            Spacer()
            
            Text(weekRangeString)
                .font(.headline)
            
            Spacer()
            
            Button(action: { changeWeek(by: 1) }) {
                Image(systemName: "chevron.right")
                    .foregroundColor(.blue)
            }
        }
        .padding()
    }
    
    private var weekCalendarView: some View {
        HStack(spacing: 8) {
            ForEach(weekDays, id: \.self) { date in
                Button(action: {
                    selectedDate = date
                }) {
                    VStack(spacing: 4) {
                        Text(dayName(for: date))
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(dayNumber(for: date))
                            .font(.headline)
                        Text(monthName(for: date))
                            .font(.caption2)
                    }
                    .foregroundColor(isSelected(date) ? .white : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(isSelected(date) ? Color.blue : Color(.systemGray6))
                    .cornerRadius(8)
                }
            }
        }
        .padding(.horizontal)
    }
    
    private var materialsListView: some View {
        let filtered = dayMaterials
        print("🔄 [AdminManagerMaterialsView] Rendering materialsListView - filtered count: \(filtered.count)")
        
        return VStack(spacing: 0) {
            HStack {
                Text("Materials for \(formattedDate(selectedDate))")
                    .font(.headline)
                    .padding(.horizontal)
                Spacer()
                HStack(spacing: 12) {
                    Button(action: {
                        showingAddMaterial = true
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                    }
                    Button(action: {
                        // Select all materials by default
                        selectedMaterials = Set(filtered.map { $0.id })
                        showingSendToWholesaler = true
                    }) {
                        Image(systemName: "paperplane.fill")
                            .font(.title2)
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
            
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "cube.box")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No materials added for this day")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if !materials.isEmpty {
                        Text("(\(materials.count) total materials for this project)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("No materials found for this project")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(filtered.sorted(by: { $0.addedAt > $1.addedAt })) { material in
                            MaterialItemRow(material: material)
                                .environmentObject(userStore)
                                .environmentObject(firebaseBackend)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id("materials-list-\(materials.count)-\(selectedDate.timeIntervalSince1970)") // Force refresh when materials or date changes
    }
    
    private func deleteMaterial(_ material: MaterialItem) {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        Task {
            do {
                try await firebaseBackend.deleteMaterialItem(material.id, organizationId: organizationId)
                // Remove from local array
                await MainActor.run {
                    if let index = materials.firstIndex(where: { $0.id == material.id }) {
                        materials.remove(at: index)
                    }
                }
                // Post notification to reload
                NotificationCenter.default.post(name: NSNotification.Name("reloadMaterials"), object: nil)
            } catch {
                print("Error deleting material: \(error.localizedDescription)")
            }
        }
    }
    
    private func deleteMaterials(at offsets: IndexSet) {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        
        let materialsToDelete = offsets.map { dayMaterials[$0] }
        
        Task {
            for material in materialsToDelete {
                do {
                    try await firebaseBackend.deleteMaterialItem(material.id, organizationId: organizationId)
                    // Remove from local array
                    await MainActor.run {
                        if let index = materials.firstIndex(where: { $0.id == material.id }) {
                            materials.remove(at: index)
                        }
                    }
                } catch {
                    print("Error deleting material: \(error.localizedDescription)")
                }
            }
            // Post notification to reload
            NotificationCenter.default.post(name: NSNotification.Name("reloadMaterials"), object: nil)
        }
    }
    
    private func changeWeek(by weeks: Int) {
        if let newWeek = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: currentWeek) {
            currentWeek = newWeek
        }
    }
    
    private var weekDays: [Date] {
        let calendar = Calendar.current
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: currentWeek)?.start else {
            return []
        }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }
    
    private func isSelected(_ date: Date) -> Bool {
        Calendar.current.isDate(date, inSameDayAs: selectedDate)
    }
    
    private func dayName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
    
    private func dayNumber(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }
    
    private func monthName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter.string(from: date)
    }
    
    private var weekRangeString: String {
        let calendar = Calendar.current
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: currentWeek)?.start,
              let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else {
            return ""
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return "\(formatter.string(from: weekStart)) - \(formatter.string(from: weekEnd))"
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

