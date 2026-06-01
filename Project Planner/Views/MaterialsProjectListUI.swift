//
//  MaterialsProjectListUI.swift
//  Project Planner
//

import SwiftUI

struct MaterialsWeekNavigator: View {
    @Binding var currentWeek: Date
    let weekRangeLabel: String
    let weekItemCount: Int

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { shiftWeek(-1) } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                }
                Spacer()
                VStack(spacing: 2) {
                    Text(weekRangeLabel)
                        .font(.system(size: 12, weight: .medium))
                    Text("\(weekItemCount) items this week")
                        .font(.system(size: 10))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                }
                Spacer()
                Button { shiftWeek(1) } label: {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(MaterialsOrderingTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MaterialsOrderingTheme.border, lineWidth: 0.5))
        }
        .padding(.horizontal, 16)
    }

    private func shiftWeek(_ delta: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: delta * 7, to: currentWeek) {
            currentWeek = next
        }
    }
}

struct MaterialsDayStrip: View {
    @Binding var selectedDate: Date
    let weekDays: [Date]
    let materials: [MaterialItem]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(weekDays, id: \.self) { day in
                let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedDate)
                let hasItems = materials.contains { Calendar.current.isDate($0.date, inSameDayAs: day) }
                Button { selectedDate = day } label: {
                    VStack(spacing: 3) {
                        Text(shortWeekday(day))
                            .font(.system(size: 9))
                            .opacity(isSelected ? 0.85 : 1)
                        Text("\(Calendar.current.component(.day, from: day))")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(isSelected ? Color.white : (hasItems ? MaterialsOrderingTheme.ink : MaterialsOrderingTheme.disabled))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if isSelected {
                            MaterialsOrderingTheme.primaryGradient
                        } else if hasItems {
                            MaterialsOrderingTheme.cardBackground
                        } else {
                            MaterialsOrderingTheme.pageBackground
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(MaterialsOrderingTheme.border, lineWidth: isSelected ? 0 : 0.5)
                    )
                    .overlay(alignment: .topTrailing) {
                        if hasItems && !isSelected {
                            Circle()
                                .fill(MaterialsOrderingTheme.primary)
                                .frame(width: 5, height: 5)
                                .offset(x: -3, y: 3)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private func shortWeekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }
}

struct MaterialsLineCard: View {
    let material: MaterialItem
    let canManage: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(material.material)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MaterialsOrderingTheme.ink)
                            .multilineTextAlignment(.leading)
                        if !material.subtitleLine.isEmpty {
                            Text(material.subtitleLine)
                                .font(.system(size: 10))
                                .foregroundStyle(MaterialsOrderingTheme.muted)
                        }
                    }
                    Spacer(minLength: 8)
                    MaterialsQuantityBadge(quantity: material.quantity, unit: material.unit)
                }
                HStack(spacing: 6) {
                    MaterialsStatusPill(status: material.status)
                    Text(metaLine)
                        .font(.system(size: 10))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                        .lineLimit(1)
                }
            }
            .padding(11)
            .background(MaterialsOrderingTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(MaterialsOrderingTheme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(canManage)
        .opacity(canManage ? 1 : 0.92)
    }

    private var metaLine: String {
        if material.status == .draft {
            return "Not yet sent"
        }
        let who = material.editedBy ?? material.addedBy
        if let sent = material.lastSentAt {
            return "\(who) · \(sent.formatted(.relative(presentation: .named)))"
        }
        return who
    }
}

struct MaterialsDraftSendBanner: View {
    let draftCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Draft ready to send")
                        .font(.system(size: 12, weight: .medium))
                    Text("Cut-off 16:00 today")
                        .font(.system(size: 10))
                        .opacity(0.85)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.white)
            .padding(12)
            .background(MaterialsOrderingTheme.primaryGradient)
            .clipShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}

struct OperativeMaterialsPanel: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    let project: Project
    @Binding var selectedDate: Date
    @Binding var currentWeek: Date
    @Binding var materials: [MaterialItem]

    @State private var showingAddMaterial = false
    @State private var showingHistory = false
    @State private var editingMaterial: MaterialItem?
    @State private var deleteErrorMessage = ""
    @State private var showingDeleteErrorAlert = false

    private var dayMaterials: [MaterialItem] {
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: selectedDate)
        return materials.filter { calendar.isDate(calendar.startOfDay(for: $0.date), inSameDayAs: selectedDay) }
            .sorted { $0.addedAt > $1.addedAt }
    }

    private var canViewQuoteOrderHistory: Bool {
        !userStore.isOperativeMode()
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
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 8) {
                    if dayMaterials.isEmpty {
                        Text("No materials for this day")
                            .font(.system(size: 13))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                            .padding(.vertical, 40)
                    } else {
                        ForEach(dayMaterials) { material in
                            let canManage = materialCanBeManagedByCurrentUser(material, userStore: userStore, firebaseBackend: firebaseBackend)
                            MaterialsLineCard(material: material, canManage: canManage) {
                                if canManage { editingMaterial = material }
                            }
                            .contextMenu {
                                if canManage {
                                    Button(role: .destructive) {
                                        deleteMaterial(material)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(MaterialsOrderingTheme.pageBackground)
        .sheet(isPresented: $showingAddMaterial) {
            MaterialsAddWithCatalogueSheet(project: project, date: selectedDate, canSendQuoteOrOrder: false)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .sheet(item: $editingMaterial) { material in
            MaterialsAddWithCatalogueSheet(project: project, date: material.date, existingMaterial: material, canSendQuoteOrOrder: false)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
        .sheet(isPresented: $showingHistory) {
            MaterialsOrderHistorySheet(
                date: selectedDate,
                materials: dayMaterials
            )
        }
        .alert("Could Not Delete Material", isPresented: $showingDeleteErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(deleteErrorMessage)
        }
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return "\(f.string(from: selectedDate)) · \(dayMaterials.count) items"
    }

    private func deleteMaterial(_ material: MaterialItem) {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        Task {
            do {
                try await firebaseBackend.deleteMaterialItem(material.id, organizationId: organizationId)
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
}

enum MaterialsWeekHelpers {
    static func weekDays(containing date: Date, calendar: Calendar = .current) -> [Date] {
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekInterval.start) }
    }

    static func weekRangeString(for week: Date, calendar: Calendar = .current) -> String {
        let days = weekDays(containing: week, calendar: calendar)
        guard let first = days.first, let last = days.last else { return "" }
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return "\(calendar.component(.day, from: first)) – \(f.string(from: last))"
    }

    static func itemsThisWeek(_ materials: [MaterialItem], week: Date, calendar: Calendar = .current) -> Int {
        let days = Set(weekDays(containing: week, calendar: calendar).map { calendar.startOfDay(for: $0) })
        return materials.filter { days.contains(calendar.startOfDay(for: $0.date)) }.count
    }
}

struct MaterialsOrderHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let date: Date
    let materials: [MaterialItem]
    @State private var expandedItemIds: Set<UUID> = []

    private var historyItems: [MaterialItem] {
        materials
            .filter { $0.status != .draft }
            .sorted { ($0.lastSentAt ?? .distantPast) > ($1.lastSentAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                if historyItems.isEmpty {
                    Text("No quote or order history for this day.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(historyItems) { item in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedItemIds.contains(item.id) },
                                set: { isExpanded in
                                    if isExpanded { expandedItemIds.insert(item.id) }
                                    else { expandedItemIds.remove(item.id) }
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.material)
                                    .font(.system(size: 13, weight: .medium))
                                Text("\(item.quantity) \(item.unit.quantityLabel(for: item.quantity))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                if let brand = item.brand, !brand.isEmpty {
                                    Text("Manufacturer: \(brand)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                if let code = item.productCode, !code.isEmpty {
                                    Text("Code: \(code)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        } label: {
                            HStack {
                                Text(item.lastSentAt?.formatted(date: .abbreviated, time: .shortened) ?? "Sent")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                MaterialsStatusPill(status: item.status)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Quote/Order History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MaterialsQuantityBadge: View {
    let quantity: Int
    let unit: MaterialUnit

    var body: some View {
        Text("\(quantity) \(unit.quantityLabel(for: quantity))")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MaterialsOrderingTheme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(MaterialsOrderingTheme.primaryTint)
            .clipShape(Capsule())
    }
}

struct MaterialsStatusPill: View {
    let status: MaterialWorkflowStatus

    var body: some View {
        Text(status.displayLabel.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(palette.background)
            .clipShape(Capsule())
    }

    private var palette: (foreground: Color, background: Color) {
        switch status {
        case .draft:
            return (MaterialsOrderingTheme.muted, MaterialsOrderingTheme.pageBackground)
        case .sentForQuote:
            return (.white, MaterialsOrderingTheme.primary)
        case .ordered:
            return (.white, MaterialsOrderingTheme.success)
        }
    }
}
