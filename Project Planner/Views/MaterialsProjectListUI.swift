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
        userStore.canViewWholesalerOrderHistory()
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
            MaterialsOrderHistorySheet(project: project, selectedDate: selectedDate)
                .environmentObject(firebaseBackend)
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
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    let project: Project
    let selectedDate: Date
    @State private var records: [MaterialSendRecord] = []
    @State private var expandedRecordIds: Set<UUID> = []
    @State private var isLoading = true
    @State private var loadErrorMessage: String?

    private var dayRecords: [MaterialSendRecord] {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: selectedDate)
        return records
            .filter { calendar.isDate($0.historyDay(calendar: calendar), inSameDayAs: day) }
            .sorted { $0.sentAt > $1.sentAt }
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMM"
        return f.string(from: selectedDate)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sends on \(dayTitle)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if let loadErrorMessage {
                        VStack(spacing: 8) {
                            Text("Could not load history")
                                .font(.system(size: 15, weight: .semibold))
                            Text(loadErrorMessage)
                                .font(.system(size: 13))
                                .foregroundStyle(MaterialsOrderingTheme.muted)
                                .multilineTextAlignment(.center)
                        }
                    } else if dayRecords.isEmpty {
                        VStack(spacing: 8) {
                            Text("No quotes or orders for this materials day")
                                .font(.system(size: 15, weight: .semibold))
                            Text("When you send a quote or order for materials on \(dayTitle), it appears here. The day strip above the list is the materials day, not the day you tapped send.")
                                .font(.system(size: 13))
                                .foregroundStyle(MaterialsOrderingTheme.muted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .padding(.horizontal, 8)
                    } else {
                        ForEach(dayRecords) { record in
                            historyTimelineCard(record)
                        }
                    }
                }
                .padding(16)
            }
            .background(MaterialsOrderingTheme.pageBackground)
            .navigationTitle("Quote & order history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await loadHistory() }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("materialSendHistoryDidChange"))) { _ in
                Task { await loadHistory() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadHistory() async {
        await MainActor.run {
            isLoading = true
            loadErrorMessage = nil
        }
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            await MainActor.run {
                isLoading = false
                loadErrorMessage = "No organisation selected."
            }
            return
        }
        do {
            var loaded = try await firebaseBackend.loadMaterialSendRecords(
                organizationId: organizationId,
                projectId: project.id
            )
            if loaded.isEmpty {
                let all = try await firebaseBackend.loadAllMaterialSendRecords(organizationId: organizationId)
                loaded = all.filter { $0.projectId == project.id }
            }
            await MainActor.run {
                records = loaded
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
                records = []
                loadErrorMessage = error.localizedDescription
            }
            print("🔥🔥🔥 DEBUG: loadMaterialSendRecords failed: \(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private func historyTimelineCard(_ record: MaterialSendRecord) -> some View {
        let isExpanded = expandedRecordIds.contains(record.id)
        let isQuote = record.requestType == .quote
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isExpanded { expandedRecordIds.remove(record.id) }
                else { expandedRecordIds.insert(record.id) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(isQuote ? Color(red: 0.06, green: 0.65, blue: 0.91) : Color(red: 0.98, green: 0.45, blue: 0.09))
                        .frame(width: 10, height: 10)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(isQuote ? "QUOTE" : "ORDER")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isQuote ? Color(red: 0.06, green: 0.65, blue: 0.91) : Color(red: 0.086, green: 0.639, blue: 0.29))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(isQuote ? Color(red: 0.88, green: 0.96, blue: 1) : Color(red: 0.882, green: 0.969, blue: 0.929))
                                .clipShape(Capsule())
                            Spacer()
                            Text(record.sentAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(MaterialsOrderingTheme.muted)
                        }
                        Text("\(record.itemCountLabel) · sent by \(record.sentBy)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MaterialsOrderingTheme.ink)
                        Text(recipientSummary(record))
                            .font(.system(size: 12))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                        if !isExpanded, !record.lines.isEmpty {
                            Text(record.lines.map(\.name).joined(separator: " · "))
                                .font(.system(size: 12))
                                .foregroundStyle(MaterialsOrderingTheme.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MaterialsOrderingTheme.muted)
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SENT TO")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                        ForEach(record.recipients, id: \.email) { recipient in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recipient.name)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(recipient.email)
                                    .font(.system(size: 12))
                                    .foregroundStyle(MaterialsOrderingTheme.muted)
                                if let firm = recipient.wholesalerName, !firm.isEmpty {
                                    Text(firm)
                                        .font(.system(size: 11))
                                        .foregroundStyle(MaterialsOrderingTheme.primary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(MaterialsOrderingTheme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MATERIALS ON THIS \(record.requestTypeLabel.uppercased())")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(MaterialsOrderingTheme.muted)
                        ForEach(record.lines, id: \.materialId) { line in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.name)
                                        .font(.system(size: 13, weight: .medium))
                                    if let length = line.lengthDisplay, !length.isEmpty {
                                        Text("Length: \(length)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(MaterialsOrderingTheme.muted)
                                    }
                                }
                                Spacer()
                                Text("\(line.quantity) \(line.unit.quantityLabel(for: line.quantity))")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(MaterialsOrderingTheme.primary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(MaterialsOrderingTheme.border, lineWidth: 0.5)
        )
    }

    private func recipientSummary(_ record: MaterialSendRecord) -> String {
        let names = record.recipients.map { recipient in
            if let firm = recipient.wholesalerName, !firm.isEmpty {
                return "\(recipient.name) (\(firm))"
            }
            return recipient.name
        }
        if names.isEmpty { return "No recipients recorded" }
        if names.count <= 2 { return "To: " + names.joined(separator: ", ") }
        return "To: \(names.prefix(2).joined(separator: ", ")) +\(names.count - 2) more"
    }
}

/// Split row: Length (optional) + Unit M/MM on one line.
struct MaterialsLengthInputRow: View {
    @Binding var lengthValue: String
    @Binding var lengthUnit: MaterialLengthUnit?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LENGTH (OPTIONAL)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
                TextField("e.g. 3", text: $lengthValue)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 14, weight: .medium))
                    .padding(10)
                    .background(MaterialsOrderingTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("UNIT (OPTIONAL)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
                Picker("Length unit", selection: Binding(
                    get: { lengthUnit ?? .metres },
                    set: { newValue in
                        lengthUnit = lengthValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newValue
                    }
                )) {
                    ForEach(MaterialLengthUnit.allCases, id: \.self) { u in
                        Text(u.displayName).tag(u)
                    }
                }
                .pickerStyle(.menu)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .onChange(of: lengthValue) { _, newValue in
                    if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lengthUnit = nil
                    } else if lengthUnit == nil {
                        lengthUnit = .metres
                    }
                }
            }
        }
    }
}

struct MaterialsQuantityTypeRow: View {
    @Binding var quantity: Int
    @Binding var unit: MaterialUnit

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("QUANTITY")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
                TextField("1", value: $quantity, format: .number)
                    .keyboardType(.numberPad)
                    .font(.system(size: 14, weight: .medium))
                    .padding(10)
                    .background(MaterialsOrderingTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(MaterialUnit.typePickerTitle.uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MaterialsOrderingTheme.muted)
                Picker(MaterialUnit.typePickerTitle, selection: $unit) {
                    ForEach(MaterialUnit.allCases, id: \.self) { u in
                        Text(u.rawValue).tag(u)
                    }
                }
                .pickerStyle(.menu)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(MaterialsOrderingTheme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 11))
            }
        }
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
