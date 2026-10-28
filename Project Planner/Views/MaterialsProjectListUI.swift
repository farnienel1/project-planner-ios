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
            HStack(spacing: 12) {
                Button { shiftWeek(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                .accessibilityIdentifier("materialsWeekNavigator.back")
                Spacer(minLength: 4)
                VStack(spacing: 2) {
                    Text(weekRangeLabel)
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("\(weekItemCount) items this week")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(PPColor.onNavySecondary)
                }
                Spacer(minLength: 4)
                Button { shiftWeek(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(PPOnNavyCircleButtonStyle(size: 36))
                .accessibilityIdentifier("materialsWeekNavigator.chevronRight")
            }
        }
        .padding(.horizontal, PPMetrics.screenGutter)
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
                            .font(.caption2.weight(.semibold))
                            .opacity(isSelected ? 0.85 : 1)
                        Text("\(Calendar.current.component(.day, from: day))")
                            .font(.system(.headline, design: .rounded))
                            .fontWeight(.bold)
                            .monospacedDigit()
                    }
                    .foregroundStyle(isSelected ? PPColor.navy : (hasItems ? Color.white : PPColor.onNavySecondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if isSelected {
                            Color.white
                        } else if hasItems {
                            PPColor.onNavyFill
                        } else {
                            Color.clear
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(PPColor.onNavyStroke, lineWidth: isSelected ? 0 : 0.5)
                    )
                    .overlay(alignment: .topTrailing) {
                        if hasItems && !isSelected {
                            Circle()
                                .fill(PPColor.warningAmber)
                                .frame(width: 6, height: 6)
                                .offset(x: -4, y: 4)
                        }
                    }
                }
                .accessibilityIdentifier("materialsDayStrip.row.\(day)")
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, PPMetrics.screenGutter)
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
            HStack(alignment: .top, spacing: 13) {
                PPIconTile(symbol: "shippingbox.fill", family: .trade, size: PPMetrics.menuIcon)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(material.material)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            if !material.subtitleLine.isEmpty {
                                Text(material.subtitleLine)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        MaterialsQuantityBadge(quantity: material.quantity, unit: material.unit)
                    }
                    HStack(spacing: 6) {
                        MaterialsStatusPill(status: material.status)
                        Text(metaLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        }
        .accessibilityIdentifier("materialsLineCard.\(AccessibilityID.token(metaLine))")
        .buttonStyle(PPPressableButtonStyle())
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
    var cutOffLabel: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PPIconTile(symbol: "paperplane.fill", family: .plan, size: PPMetrics.chipIcon)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Draft ready to send")
                        .font(.subheadline.weight(.semibold))
                    if let cutOffLabel {
                        Text(cutOffLabel)
                            .font(.caption)
                            .opacity(0.7)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(
                PPNavyBackdrop()
                    .clipShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
            )
        }
        .accessibilityIdentifier("materialsDraftSendBanner.paperplaneFill")
        .buttonStyle(PPPressableButtonStyle())
    }
}

struct OperativeMaterialsPanel: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var smartCache: SmartCacheService

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

    /// Admins and managers only, never operative mode (`canViewMaterialOrderHistory`). Not the Wholesalers toggle.
    private var canViewQuoteOrderHistory: Bool {
        guard let user = userStore.displayUser else { return false }
        return CanonicalBusinessEngine.canViewMaterialOrderHistory(UserStore.staffAccountRole(for: user))
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
                        .accessibilityIdentifier("operativeMaterialsPanel.quoteOrderHistory")
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(MaterialsOrderingTheme.muted)
                    }
                    Button { showingAddMaterial = true } label: {
                        Label("Add", systemImage: "plus")
                            .font(.footnote.weight(.semibold))
                    }
                    .accessibilityIdentifier("operativeMaterialsPanel.add")
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(MaterialsOrderingTheme.primary)
                }
                .padding(.horizontal, 2)
                .padding(.top, 18)
                .padding(.bottom, 10)

                ScrollView {
                    VStack(spacing: 10) {
                        if dayMaterials.isEmpty {
                            Text("No materials for this day")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
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
                                            .accessibilityIdentifier("operativeMaterialsPanel.row.\(material.id).delete")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ppContentSheet()
        }
        .background(PPColor.page.ignoresSafeArea())
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
            MaterialsOrderHistorySheet(project: project)
                .environmentObject(firebaseBackend)
        }
        .alert("Could Not Delete Material", isPresented: $showingDeleteErrorAlert) {
            Button("OK", role: .cancel) { }
                .accessibilityIdentifier("operativeMaterialsPanel.ok")
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
    @State private var records: [MaterialSendRecord] = []
    @State private var expandedRecordIds: Set<UUID> = []
    @State private var isLoading = true
    @State private var loadErrorMessage: String?

    /// Every send for this job, newest first, as web `ProjectMaterialsSection` lists `materialSendRecords`.
    private var jobRecords: [MaterialSendRecord] {
        records.sorted { $0.sentAt > $1.sentAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Text("Every quote and order sent for this job")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PPColor.onNavySecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PPMetrics.screenGutter)
                        .padding(.top, 12)
                        .padding(.bottom, PPMetrics.headerBottomPadding)
                        .ppNavyHeader()

                    VStack(alignment: .leading, spacing: 12) {
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else if let loadErrorMessage {
                            VStack(spacing: 8) {
                                PPIconTile(symbol: "exclamationmark.triangle.fill", family: .alert, size: PPMetrics.quickActionIcon, lifted: true)
                                Text("Could not load history")
                                    .font(.system(.headline, design: .rounded))
                                    .fontWeight(.bold)
                                Text(loadErrorMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(20)
                            .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                        } else if jobRecords.isEmpty {
                            VStack(spacing: 8) {
                                PPIconTile(symbol: "clock.arrow.circlepath", family: .plan, size: PPMetrics.quickActionIcon, lifted: true)
                                Text("No quotes or orders for this job yet")
                                    .font(.system(.headline, design: .rounded))
                                    .fontWeight(.bold)
                                    .multilineTextAlignment(.center)
                                Text("When you send a quote or order to a wholesaler, it appears here.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .padding(.horizontal, 16)
                            .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                        } else {
                            ForEach(jobRecords) { record in
                                historyTimelineCard(record)
                            }
                        }
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                    .ppContentSheet()
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Quote & order history")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("materialsOrderHistory.close")
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
                    PPIconTile(
                        symbol: isQuote ? "doc.text.fill" : "shippingbox.fill",
                        family: isQuote ? .plan : .sites,
                        size: PPMetrics.menuIcon
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(isQuote ? "QUOTE" : "ORDER")
                                .font(.caption2.weight(.bold))
                                .tracking(0.4)
                                .foregroundStyle(isQuote ? PPFamily.plan.bottom : PPFamily.sites.bottom)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background((isQuote ? PPFamily.plan.top : PPFamily.sites.top).opacity(0.16))
                                .clipShape(Capsule())
                            Spacer()
                            Text(record.sentAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Text("\(record.itemCountLabel) · sent by \(record.sentBy)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(recipientSummary(record))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                        if let required = record.requiredDeliverySummary {
                            Text(required)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(MaterialsOrderingTheme.ink)
                                .multilineTextAlignment(.leading)
                        }
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
            .accessibilityIdentifier("materialsOrderHistory.quote")
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SENT TO")
                            .font(.caption.weight(.semibold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
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
                            .background(PPColor.well)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MATERIALS ON THIS \(record.requestTypeLabel.uppercased())")
                            .font(.caption.weight(.semibold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
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
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
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
                    .accessibilityIdentifier("materialsLengthInput.eG3")
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
                .accessibilityIdentifier("materialsLengthInput.lengthUnit")
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
                    .accessibilityIdentifier("materialsQuantityType.n1")
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
                .accessibilityIdentifier("materialsQuantityType.picker")
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
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.primary)
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
            .font(.caption2.weight(.bold))
            .tracking(0.4)
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(palette.background)
            .clipShape(Capsule())
    }

    private var palette: (foreground: Color, background: Color) {
        switch status {
        case .draft:
            return (MaterialsOrderingTheme.muted, PPColor.well)
        case .sentForQuote:
            return (.white, MaterialsOrderingTheme.primary)
        case .ordered:
            return (.white, MaterialsOrderingTheme.success)
        }
    }
}
