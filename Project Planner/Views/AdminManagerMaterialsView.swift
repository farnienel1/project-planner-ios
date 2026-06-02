//
//  AdminManagerMaterialsView.swift
//  Project Planner
//

import SwiftUI

struct AdminManagerMaterialsView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var smartCache: SmartCacheService

    let project: Project
    @Binding var selectedDate: Date
    @Binding var currentWeek: Date
    @Binding var materials: [MaterialItem]

    @State private var showingAddMaterial = false
    @State private var showingSendToWholesaler = false
    @State private var editingMaterial: MaterialItem?
    @State private var selectedMaterials: Set<UUID> = []
    @State private var showingHistory = false
    @State private var deleteErrorMessage = ""
    @State private var showingDeleteErrorAlert = false

    private var dayMaterials: [MaterialItem] {
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: selectedDate)
        return materials.filter { calendar.isDate(calendar.startOfDay(for: $0.date), inSameDayAs: selectedDay) }
            .sorted { $0.addedAt > $1.addedAt }
    }

    private var draftCount: Int {
        materials.filter { $0.status == .draft }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            MaterialsWeekNavigator(
                currentWeek: $currentWeek,
                weekRangeLabel: MaterialsWeekHelpers.weekRangeString(for: currentWeek),
                weekItemCount: MaterialsWeekHelpers.itemsThisWeek(materials, week: currentWeek)
            )
            MaterialsDayStrip(
                selectedDate: $selectedDate,
                weekDays: MaterialsWeekHelpers.weekDays(containing: currentWeek),
                materials: materials
            )
            .padding(.bottom, 12)

            dayHeader
            materialsContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MaterialsOrderingTheme.pageBackground)
        .sheet(isPresented: $showingAddMaterial) {
            MaterialsAddWithCatalogueSheet(project: project, date: selectedDate)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .sheet(item: $editingMaterial) { material in
            MaterialsAddWithCatalogueSheet(project: project, date: material.date, existingMaterial: material)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .sheet(isPresented: $showingSendToWholesaler) {
            MaterialsSendListSheet(
                project: project,
                materials: materialsForSend,
                materialsDay: selectedDate,
                isPresented: $showingSendToWholesaler
            )
            .environmentObject(userStore)
            .environmentObject(firebaseBackend)
        }
        .sheet(isPresented: $showingHistory) {
            MaterialsOrderHistorySheet(project: project, selectedDate: selectedDate)
                .environmentObject(firebaseBackend)
        }
        .alert("Could Not Delete Material", isPresented: $showingDeleteErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(deleteErrorMessage)
        }
    }

    private var materialsForSend: [MaterialItem] {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: selectedDate)
        return materials.filter { calendar.isDate(calendar.startOfDay(for: $0.date), inSameDayAs: day) }
    }

    private var canViewQuoteOrderHistory: Bool {
        userStore.canViewWholesalerOrderHistory()
    }

    private var dayHeader: some View {
        HStack {
            Text(dayTitle)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            if canViewQuoteOrderHistory {
                Button("Quote/Order History") {
                    showingHistory = true
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.bordered)
                .tint(MaterialsOrderingTheme.muted)
            }
            Button { showingAddMaterial = true } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(MaterialsOrderingTheme.primary)
            Button {
                selectedMaterials = Set(dayMaterials.map(\.id))
                showingSendToWholesaler = true
            } label: {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(MaterialsOrderingTheme.success)
            }
            .disabled(dayMaterials.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return "\(f.string(from: selectedDate)) · \(dayMaterials.count) items"
    }

    @ViewBuilder
    private var materialsContent: some View {
        ScrollView {
            VStack(spacing: 8) {
                if dayMaterials.isEmpty {
                    emptyDay
                } else {
                    ForEach(dayMaterials) { material in
                        MaterialsLineCard(material: material, canManage: true) {
                            editingMaterial = material
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteMaterial(material)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                if draftCount > 0 {
                    MaterialsDraftSendBanner(draftCount: draftCount) {
                        selectedMaterials = Set(materials.filter { $0.status == .draft }.map(\.id))
                        showingSendToWholesaler = true
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private var emptyDay: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 44))
                .foregroundStyle(MaterialsOrderingTheme.disabled)
            Text("No materials for \(formattedDate(selectedDate))")
                .font(.system(size: 14, weight: .medium))
            Text("Add what you need delivered on this day.")
                .font(.system(size: 11))
                .foregroundStyle(MaterialsOrderingTheme.muted)
            Button { showingAddMaterial = true } label: {
                Label("Add material", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(MaterialsOrderingTheme.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func deleteMaterial(_ material: MaterialItem) {
        guard let organizationId = MaterialOfflineService.resolvedOrganizationId(firebaseBackend: firebaseBackend) else { return }
        Task {
            do {
                _ = try await MaterialOfflineService.deleteMaterial(
                    material.id,
                    projectId: project.id,
                    organizationId: organizationId,
                    firebaseBackend: firebaseBackend,
                    isOnline: smartCache.isOnline
                )
                await MainActor.run {
                    materials.removeAll { $0.id == material.id }
                }
                NotificationCenter.default.post(name: NSNotification.Name("reloadMaterials"), object: nil)
            } catch {
                await MainActor.run {
                    deleteErrorMessage = error.localizedDescription
                    showingDeleteErrorAlert = true
                }
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}
