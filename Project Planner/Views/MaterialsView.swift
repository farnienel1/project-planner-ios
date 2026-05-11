//
//  MaterialsView.swift
//  Project Planner
//
//  Created by Assistant on 2025.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

private func materialCanBeManagedByCurrentUser(
    _ material: MaterialItem,
    userStore: UserStore,
    firebaseBackend: FirebaseBackend
) -> Bool {
    guard let authUser = firebaseBackend.currentUser else { return false }
    if !userStore.isOperativeMode() {
        return true
    }
    if let ownerUserId = material.addedByUserId?.trimmingCharacters(in: .whitespacesAndNewlines),
       !ownerUserId.isEmpty {
        return ownerUserId == authUser.uid
    }

    let normalizedAddedBy = material.addedBy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalizedAddedBy.isEmpty {
        return false
    }

    let fullName = (userStore.currentUser?.fullName ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let appEmail = (userStore.currentUser?.email ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let authDisplayName = (authUser.displayName ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let authEmail = (authUser.email ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    return normalizedAddedBy == fullName ||
        normalizedAddedBy == appEmail ||
        normalizedAddedBy == authDisplayName ||
        normalizedAddedBy == authEmail
}

struct MaterialsView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let project: Project
    
    @State private var selectedDate: Date = Date()
    @State private var currentWeek: Date = Date()
    @State private var materials: [MaterialItem] = []
    @State private var isLoading = false
    @State private var materialsListener: ListenerRegistration?
    @State private var showMaterialsRetentionNotice = false
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading materials...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if userStore.isOperativeMode() {
                OperativeMaterialsView(
                    project: project,
                    selectedDate: $selectedDate,
                    currentWeek: $currentWeek,
                    materials: $materials
                )
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
            } else {
                AdminManagerMaterialsView(
                    project: project,
                    selectedDate: $selectedDate,
                    currentWeek: $currentWeek,
                    materials: $materials
                )
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
            }
        }
        .task {
            await loadMaterials(isInitial: true)
            await attachMaterialsListener()
        }
        .refreshable {
            await loadMaterials(isInitial: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("reloadMaterials"))) { note in
            Task {
                if let intervals = note.userInfo?["materialBookingDayIntervals"] as? [TimeInterval], !intervals.isEmpty {
                    await MainActor.run {
                        let cal = Calendar.current
                        let days = intervals.map { cal.startOfDay(for: Date(timeIntervalSince1970: $0)) }
                        if let target = days.min() {
                            selectedDate = target
                            currentWeek = target
                        }
                    }
                }
                await loadMaterials(isInitial: false)
            }
        }
        .onDisappear {
            materialsListener?.remove()
            materialsListener = nil
        }
        .alert("Materials orders retention", isPresented: $showMaterialsRetentionNotice) {
            Button("OK") {
                if let uid = firebaseBackend.currentUser?.uid, !uid.isEmpty {
                    UserDefaults.standard.set(true, forKey: Self.materialsRetentionNoticeKey(userId: uid, projectId: project.id))
                }
            }
        } message: {
            Text("Material orders are kept in the app for about one year per job (by the date the material is needed). Older lines are removed automatically to keep lists manageable.")
        }
    }
    
    private static func materialsRetentionNoticeKey(userId: String, projectId: UUID) -> String {
        "materialsOneYearRetentionNoticeShown_\(userId)_\(projectId.uuidString)"
    }
    
    /// When Firestore returns rows, the week strip may still be on “this week” while all bookings are on other dates — jump to a week that has data.
    private func syncWeekSelectionToLoadedMaterialsIfNothingForCurrentDay() {
        guard !materials.isEmpty else { return }
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: selectedDate)
        let hasMatch = materials.contains { calendar.isDate(calendar.startOfDay(for: $0.date), inSameDayAs: selectedDay) }
        if hasMatch { return }
        let uniqueDays = materials.map { calendar.startOfDay(for: $0.date) }.sorted()
        // Prefer the “needed” date nearest to what the user already has selected (avoids snapping to an unrelated
        // past week when they just booked a future day, then a stale listener snapshot runs sync).
        let targetDay = uniqueDays.min(by: { a, b in
            let da = abs(a.timeIntervalSince1970 - selectedDay.timeIntervalSince1970)
            let db = abs(b.timeIntervalSince1970 - selectedDay.timeIntervalSince1970)
            if da != db { return da < db }
            return a < b
        }) ?? uniqueDays[0]
        selectedDate = targetDay
        currentWeek = targetDay
    }
    
    private func queueMaterialsRetentionNoticeIfNeeded() {
        guard !userStore.isOperativeMode() else { return }
        guard let uid = firebaseBackend.currentUser?.uid, !uid.isEmpty else { return }
        let key = Self.materialsRetentionNoticeKey(userId: uid, projectId: project.id)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        showMaterialsRetentionNotice = true
    }
    
    private func loadMaterials(isInitial: Bool) async {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { 
            print("❌ [MaterialsView] No organization ID for loading materials")
            return 
        }
        if isInitial {
            await MainActor.run { isLoading = true }
        }
        
        print("📦 [MaterialsView] Loading materials for project: \(project.id) (org: \(organizationId)) initial=\(isInitial)")
        do {
            let loadedMaterials = try await firebaseBackend.loadMaterialItems(organizationId: organizationId, projectId: project.id)
            await MainActor.run {
                materials = loadedMaterials
                print("✅ [MaterialsView] Loaded \(loadedMaterials.count) materials and updated @State")
                if loadedMaterials.isEmpty {
                    print("   ⚠️ WARNING: No materials found in Firebase for this project!")
                } else {
                    print("   Materials loaded:")
                    for material in loadedMaterials {
                        print("     - \(material.material) for date: \(material.date)")
                    }
                }
                syncWeekSelectionToLoadedMaterialsIfNothingForCurrentDay()
                queueMaterialsRetentionNoticeIfNeeded()
                if isInitial {
                    isLoading = false
                }
            }
        } catch {
            print("❌ [MaterialsView] Error loading materials: \(error.localizedDescription)")
            await MainActor.run {
                if isInitial {
                    isLoading = false
                }
            }
        }
    }

    private func attachMaterialsListener() async {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        guard let orgId = try? await firebaseBackend.resolveOrganizationIdForMaterials(preferredOrganizationId: organizationId) else {
            print("❌ [MaterialsView] Could not resolve org for materials listener")
            return
        }
        await MainActor.run {
            materialsListener?.remove()
            materialsListener = firebaseBackend.observeMaterialItems(
                organizationId: orgId,
                projectId: project.id
            ) { updated, _ in
                // `observeMaterialItems` already ignores empty cache-only snapshots (see FirebaseBackend), so we
                // always apply non-empty and server snapshots here. Do not skip cache updates when `materials`
                // is non-empty: that blocked newly saved rows from ever appearing if a cached full snapshot
                // arrived after the initial load (common right after "Submit All" while other days already had lines).
                materials = updated
                syncWeekSelectionToLoadedMaterialsIfNothingForCurrentDay()
            }
        }
    }
}

// MARK: - Operative Materials View

private struct OperativeMaterialsView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let project: Project
    @Binding var selectedDate: Date
    @Binding var currentWeek: Date
    @Binding var materials: [MaterialItem]
    
    @State private var showingAddMaterial = false
    @State private var deleteErrorMessage = ""
    @State private var showingDeleteErrorAlert = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Week Navigation
            weekNavigationView
            
            // Week Calendar
            weekCalendarView
            
            // Materials List for Selected Day
            materialsListView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingAddMaterial) {
            AddMaterialView(
                project: project,
                date: selectedDate,
                isPresented: $showingAddMaterial
            )
            .environmentObject(userStore)
            .environmentObject(firebaseBackend)
        }
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
        let dayMaterials = materialsForSelectedDate.sorted(by: { $0.addedAt > $1.addedAt })
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Materials for \(formattedDate(selectedDate))")
                    .font(.headline)
                Spacer()
                Button(action: {
                    showingAddMaterial = true
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal)
            
            if dayMaterials.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "cube.box")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No materials added for this day")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if !materials.isEmpty {
                        Text("(\(materials.count) total for this project — none on this day)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Text("Use the week arrows to find the week when those materials were booked.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                List {
                    ForEach(dayMaterials) { material in
                        MaterialItemRow(material: material)
                            .environmentObject(userStore)
                            .environmentObject(firebaseBackend)
                            .swipeActions(edge: .trailing, allowsFullSwipe: canManage(material)) {
                                if canManage(material) {
                                    Button(role: .destructive) {
                                        deleteMaterial(material)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.vertical)
        .alert("Could Not Delete Material", isPresented: $showingDeleteErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(deleteErrorMessage)
        }
    }

    private var materialsForSelectedDate: [MaterialItem] {
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: selectedDate)
        return materials.filter { material in
            let materialDay = calendar.startOfDay(for: material.date)
            return calendar.isDate(materialDay, inSameDayAs: selectedDay)
        }
    }

    private func canManage(_ material: MaterialItem) -> Bool {
        materialCanBeManagedByCurrentUser(material, userStore: userStore, firebaseBackend: firebaseBackend)
    }

    private func deleteMaterial(_ material: MaterialItem) {
        guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        Task {
            do {
                try await firebaseBackend.deleteMaterialItem(material.id, organizationId: organizationId)
                await MainActor.run {
                    if let idx = materials.firstIndex(where: { $0.id == material.id }) {
                        materials.remove(at: idx)
                    }
                }
            } catch {
                await MainActor.run {
                    deleteErrorMessage = error.localizedDescription
                    showingDeleteErrorAlert = true
                }
            }
        }
    }
    
    private func changeWeek(by weeks: Int) {
        MaterialsWeekNavigation.applyWeekDelta(weeks, currentWeek: &currentWeek, selectedDate: &selectedDate)
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

// MARK: - Material Item Row

struct MaterialItemRow: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let material: MaterialItem
    @State private var showingEditMaterial = false
    
    private var canManageMaterial: Bool {
        materialCanBeManagedByCurrentUser(material, userStore: userStore, firebaseBackend: firebaseBackend)
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: material.addedAt)
    }

    private var shouldShowBookingTime: Bool {
        Calendar.current.isDate(material.date, inSameDayAs: material.addedAt)
    }
    
    private var bookingTimeColor: Color {
        let hour = Calendar.current.component(.hour, from: material.addedAt)
        return (hour >= 7 && hour < 16) ? .green : .red
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(material.material)
                    .font(.body)
                    .fontWeight(.medium)
                Text("\(material.quantity) \(material.unit.rawValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Show editedBy if material was edited, otherwise show addedBy
                if let editedBy = material.editedBy {
                    Text("Edited by \(editedBy)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("Added by \(material.addedBy)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()

            if shouldShowBookingTime {
                Text(timeString)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(bookingTimeColor.opacity(0.15))
                    .foregroundColor(bookingTimeColor)
                    .cornerRadius(6)
            }
            
            if userStore.isOperativeMode() && !canManageMaterial {
                Image(systemName: "lock.fill")
                    .foregroundColor(.secondary)
                    .font(.body)
            } else {
                Button(action: {
                    guard canManageMaterial else { return }
                    showingEditMaterial = true
                }) {
                    Image(systemName: "pencil")
                        .foregroundColor(.blue)
                        .font(.body)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .sheet(isPresented: Binding(
            get: { showingEditMaterial && canManageMaterial },
            set: { showingEditMaterial = $0 }
        )) {
            EditMaterialView(material: material, isPresented: $showingEditMaterial)
                .environmentObject(userStore)
                .environmentObject(firebaseBackend)
        }
    }
}

// MARK: - Add Material View

struct AddMaterialView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let project: Project
    let date: Date
    @Binding var isPresented: Bool
    
    @State private var materialEntries: [MaterialEntryForm] = []
    @State private var isSaving = false
    @State private var showingLateSubmissionAlert = false
    @State private var showingSaveErrorAlert = false
    @State private var saveErrorMessage = ""
    
    struct MaterialEntryForm: Identifiable {
        let id = UUID()
        var selectedDate: Date
        var quantity: Int = 1
        var unit: MaterialUnit = .number
        var materialDescription: String = ""
        
        init(selectedDate: Date) {
            self.selectedDate = selectedDate
        }
    }
    
    init(project: Project, date: Date, isPresented: Binding<Bool>) {
        self.project = project
        self.date = date
        self._isPresented = isPresented
        self._materialEntries = State(initialValue: [MaterialEntryForm(selectedDate: date)])
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("Material Entries") {
                    ForEach(materialEntries) { entry in
                        MaterialEntrySection(
                            entry: entry,
                            entries: $materialEntries
                        )
                    }
                    
                    Button(action: {
                        materialEntries.append(MaterialEntryForm(selectedDate: date))
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Another Material")
                        }
                        .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("Add Materials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Submit All") {
                        handleSubmitAllTapped()
                    }
                    .disabled(materialEntries.allSatisfy { $0.materialDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || isSaving)
                }
            }
        }
        .alert("Material Time Check", isPresented: $showingLateSubmissionAlert) {
            Button("Book Materials") {
                saveAllMaterials()
            }
            Button("Change Date", role: .cancel) { }
        } message: {
            Text("Some materials are being added for today after 4:00 PM. Continue or change the date.")
        }
        .alert("Could Not Save Materials", isPresented: $showingSaveErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(saveErrorMessage)
        }
    }

    private func handleSubmitAllTapped() {
        if hasTodayEntriesAfterCutoff() {
            showingLateSubmissionAlert = true
            return
        }
        saveAllMaterials()
    }

    private func hasTodayEntriesAfterCutoff() -> Bool {
        let calendar = Calendar.current
        let now = Date()
        guard calendar.component(.hour, from: now) >= 16 else { return false }
        return materialEntries.contains {
            calendar.isDate($0.selectedDate, inSameDayAs: now) &&
            !$0.materialDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    
    private func saveAllMaterials() {
        let validEntries = materialEntries.filter { !$0.materialDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validEntries.isEmpty else { return }
        
        isSaving = true
        let addedBy = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Unknown User"
        let calendar = Calendar.current
        
        Task {
            guard let organizationId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
                await MainActor.run {
                    isSaving = false
                }
                return
            }
            
            var savedCount = 0
            var firstError: String?
            for entry in validEntries {
                let normalizedDate = calendar.startOfDay(for: entry.selectedDate)
                
                let material = MaterialItem(
                    quantity: entry.quantity,
                    unit: entry.unit,
                    material: entry.materialDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                    addedBy: addedBy,
                    addedByUserId: firebaseBackend.currentUser?.uid,
                    projectId: project.id,
                    date: normalizedDate
                )
                
                do {
                    try await firebaseBackend.saveMaterialItem(material, organizationId: organizationId)
                    savedCount += 1
                    print("✅ Material saved: \(material.material) for date: \(normalizedDate)")
                } catch {
                    print("❌ Error saving material: \(error.localizedDescription)")
                    if firstError == nil {
                        firstError = error.localizedDescription
                    }
                }
            }
            
            // Per job: keep ~1 year of past “needed” dates for this project only; older rows for this project are removed.
            try? await firebaseBackend.cleanupOldMaterials(organizationId: organizationId, projectId: project.id, keepDays: 365)
            
            await MainActor.run {
                isSaving = false
                if savedCount > 0 {
                    isPresented = false
                    let bookingDayIntervals = validEntries.map {
                        calendar.startOfDay(for: $0.selectedDate).timeIntervalSince1970
                    }
                    NotificationCenter.default.post(
                        name: NSNotification.Name("reloadMaterials"),
                        object: nil,
                        userInfo: ["materialBookingDayIntervals": bookingDayIntervals]
                    )
                } else {
                    saveErrorMessage = firstError ?? "No materials were saved."
                    showingSaveErrorAlert = true
                }
            }
        }
    }
}

// MARK: - Material Entry Section

private struct MaterialEntrySection: View {
    let entry: AddMaterialView.MaterialEntryForm
    @Binding var entries: [AddMaterialView.MaterialEntryForm]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Material Entry")
                    .font(.headline)
                Spacer()
                if entries.count > 1 {
                    Button(action: {
                        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                            entries.remove(at: index)
                        }
                    }) {
                        Image(systemName: "minus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                            .contentShape(Rectangle())
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                }
            }
            
            DatePicker("Date", selection: Binding(
                get: { entry.selectedDate },
                set: { newValue in
                    if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                        entries[index].selectedDate = newValue
                    }
                }
            ), displayedComponents: .date)
            .datePickerStyle(.compact)
            
            Picker("Quantity", selection: Binding(
                get: { entry.quantity },
                set: { newValue in
                    if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                        entries[index].quantity = newValue
                    }
                }
            )) {
                ForEach(1...100, id: \.self) { num in
                    Text("\(num)").tag(num)
                }
            }
            
            Picker("Unit", selection: Binding(
                get: { entry.unit },
                set: { newValue in
                    if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                        entries[index].unit = newValue
                    }
                }
            )) {
                ForEach(MaterialUnit.allCases, id: \.self) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            
            TextField("Material Description", text: Binding(
                get: { entry.materialDescription },
                set: { newValue in
                    if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                        entries[index].materialDescription = newValue
                    }
                }
            ), axis: .vertical)
            .lineLimit(3...6)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Week strip keeps `selectedDate` in the visible week (shared by operative + admin views)

enum MaterialsWeekNavigation {
    /// Moving the week arrows used to update only `currentWeek`, so the list still filtered an old day while the strip showed another week.
    static func applyWeekDelta(_ weeks: Int, currentWeek: inout Date, selectedDate: inout Date) {
        let calendar = Calendar.current
        guard let anchor = calendar.date(byAdding: .weekOfYear, value: weeks, to: currentWeek) else { return }
        guard let oldWeekStart = calendar.dateInterval(of: .weekOfYear, for: currentWeek)?.start,
              let newWeekStart = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start else { return }
        let rawOffset = calendar.dateComponents([.day], from: oldWeekStart, to: calendar.startOfDay(for: selectedDate)).day ?? 0
        let dayOffset = max(0, min(6, rawOffset))
        currentWeek = anchor
        selectedDate = calendar.date(byAdding: .day, value: dayOffset, to: newWeekStart) ?? newWeekStart
    }
}

