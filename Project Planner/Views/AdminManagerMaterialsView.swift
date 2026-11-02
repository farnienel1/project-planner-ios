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

    private var draftCutOffLabel: String? {
        guard let clock = OrgMaterialCutOff.resolve(
            stored: firebaseBackend.currentOrganization?.settings.materialCutOff,
            organizationLoaded: firebaseBackend.currentOrganization != nil
        ), let label = CanonicalBusinessEngine.formatMaterialCutOffClock(clock) else {
            return nil
        }
        return "Cut-off \(label) today"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
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
            }
            .padding(.top, 12)
            .padding(.bottom, PPMetrics.headerBottomPadding)
            .frame(maxWidth: .infinity)
            .ppNavyHeader()

            VStack(spacing: 0) {
                dayHeader
                materialsContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ppContentSheet()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PPColor.page.ignoresSafeArea())
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
            MaterialsOrderHistorySheet(project: project)
                .environmentObject(firebaseBackend)
        }
        .alert("Could Not Delete Material", isPresented: $showingDeleteErrorAlert) {
            Button("OK", role: .cancel) { }
                .accessibilityIdentifier("adminManagerMaterials.ok")
        } message: {
            Text(deleteErrorMessage)
        }
    }

    private var materialsForSend: [MaterialItem] {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: selectedDate)
        return materials.filter { calendar.isDate(calendar.startOfDay(for: $0.date), inSameDayAs: day) }
    }

    /// Admins and managers only, never operative mode (`canViewMaterialOrderHistory`). Not the Wholesalers toggle.
    private var canViewQuoteOrderHistory: Bool {
        guard let user = userStore.displayUser else { return false }
        return CanonicalBusinessEngine.canViewMaterialOrderHistory(UserStore.staffAccountRole(for: user))
    }

    private var dayHeader: some View {
        HStack(spacing: 8) {
            Text(dayTitle)
                .font(.system(.headline, design: .rounded))
                .fontWeight(.bold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            if canViewQuoteOrderHistory {
                Button("Quote/Order History") {
                    showingHistory = true
                }
                .accessibilityIdentifier("adminManagerMaterials.quoteOrderHistory")
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(MaterialsOrderingTheme.muted)
            }
            Button { showingAddMaterial = true } label: {
                Label("Add", systemImage: "plus")
                    .font(.footnote.weight(.semibold))
            }
            .accessibilityIdentifier("adminManagerMaterials.add")
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(MaterialsOrderingTheme.primary)
            Button {
                selectedMaterials = Set(dayMaterials.map(\.id))
                showingSendToWholesaler = true
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MaterialsOrderingTheme.success)
            }
            .accessibilityIdentifier("adminManagerMaterials.paperplaneFill")
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(MaterialsOrderingTheme.success)
            .disabled(dayMaterials.isEmpty)
        }
        .padding(.horizontal, 2)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return "\(f.string(from: selectedDate)) · \(dayMaterials.count) items"
    }

    @ViewBuilder
    private var materialsContent: some View {
        ScrollView {
            VStack(spacing: 10) {
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
                                .accessibilityIdentifier("adminManagerMaterials.row.\(material.id).delete")
                        }
                    }
                }
                if draftCount > 0 {
                    MaterialsDraftSendBanner(draftCount: draftCount, cutOffLabel: draftCutOffLabel) {
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
            PPIconTile(symbol: "shippingbox.fill", family: .trade, size: PPMetrics.quickActionIcon, lifted: true)
            Text("No materials for \(formattedDate(selectedDate))")
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            Text("Add what you need delivered on this day.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { showingAddMaterial = true } label: {
                Label("Add material", systemImage: "plus")
            }
            .accessibilityIdentifier("adminManagerMaterials.addMaterial")
            .ppProminentCapsule()
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
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
