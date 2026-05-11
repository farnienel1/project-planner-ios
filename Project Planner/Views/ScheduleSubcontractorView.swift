import SwiftUI

struct ScheduleSubcontractorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    
    let project: Project
    
    @State private var selectedSubcontractorIds: Set<UUID> = []
    @State private var selectedDates: Set<Date> = []
    @State private var dateTimeSlots: [String: TimeSlot] = [:]
    @State private var currentMonth: Date = Date()
    @State private var quickSelectDays: Int? = nil
    @State private var isSaving = false
    @State private var searchText = ""
    @State private var selectedTypeFilter = "All Types"
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    subbiesSection
                    calendarSection
                    quickSelectSection
                    if !selectedDates.isEmpty {
                        selectedDatesSection
                    }
                    bookingSummarySection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Schedule Sub Contractor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundColor(Color.theme.primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "Booking..." : "Confirm Booking") {
                        save()
                    }
                    .disabled(isSaving || selectedSubcontractorIds.isEmpty || selectedDates.isEmpty)
                }
            }
            .task {
                await subcontractorStore.loadData()
            }
        }
    }
    
    private var selectedSubcontractorNames: [String] {
        subcontractorStore.subcontractors
            .filter { selectedSubcontractorIds.contains($0.id) }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    
    private var typeFilters: [String] {
        let types = Set(subcontractorStore.subcontractors.map(\.subcontractorType))
        return ["All Types"] + types.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    
    private var filteredSubcontractors: [Subcontractor] {
        subcontractorStore.subcontractors
            .filter { subcontractor in
                selectedTypeFilter == "All Types" || subcontractor.subcontractorType == selectedTypeFilter
            }
            .filter { subcontractor in
                searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                subcontractor.name.localizedCaseInsensitiveContains(searchText) ||
                subcontractor.subcontractorType.localizedCaseInsensitiveContains(searchText)
            }
            .sorted(by: { $0.name < $1.name })
    }
    
    private var subbiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Sub Contractors")
                .font(.title3)
                .fontWeight(.bold)
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search sub contractors...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .cornerRadius(8)
            
            Picker("Type", selection: $selectedTypeFilter) {
                ForEach(typeFilters, id: \.self) { type in
                    Text(type).tag(type)
                }
            }
            if subcontractorStore.subcontractors.isEmpty {
                Text("No sub-contractors available. Add one first.")
                    .foregroundColor(.secondary)
            } else if filteredSubcontractors.isEmpty {
                Text("No sub contractors match this search/filter.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(filteredSubcontractors) { subcontractor in
                    Button {
                        toggle(subcontractor.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(subcontractor.name)
                                    .foregroundColor(.primary)
                                Text(subcontractor.subcontractorType)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: selectedSubcontractorIds.contains(subcontractor.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedSubcontractorIds.contains(subcontractor.id) ? Color.theme.primary : .secondary)
                        }
                        .padding(10)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(14)
    }
    
    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Dates")
                .font(.title3)
                .fontWeight(.bold)
            HStack {
                Button(action: { changeMonth(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.theme.primary))
                }
                Spacer()
                Text(monthYearString)
                    .font(.headline)
                Spacer()
                Button(action: { changeMonth(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.theme.primary))
                }
            }
            calendarGrid
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(14)
    }
    
    private var quickSelectSection: some View {
        HStack(spacing: 10) {
            quickSelectButton(days: 1, label: "Today")
            quickSelectButton(days: 3, label: "3 Days")
            quickSelectButton(days: 5, label: "5 Days")
        }
    }
    
    private func quickSelectButton(days: Int, label: String) -> some View {
        Button(action: {
            quickSelectDays = days
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            selectedDates.removeAll()
            dateTimeSlots.removeAll()
            for i in 0..<days {
                if let date = cal.date(byAdding: .day, value: i, to: today) {
                    let d = cal.startOfDay(for: date)
                    selectedDates.insert(d)
                    dateTimeSlots[slotKey(for: d)] = .fullDay
                }
            }
        }) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(quickSelectDays == days ? .white : Color.theme.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(quickSelectDays == days ? Color.theme.primary : Color.theme.primary.opacity(0.1))
                )
        }
    }
    
    private var selectedDatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selected Dates")
                .font(.headline)
            ForEach(selectedDates.sorted(), id: \.self) { date in
                VStack(spacing: 8) {
                    HStack {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                        Spacer()
                        Button(role: .destructive) {
                            selectedDates.remove(date)
                            dateTimeSlots.removeValue(forKey: slotKey(for: date))
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                    }
                    Picker("Time", selection: Binding(
                        get: { dateTimeSlots[slotKey(for: date)] ?? .fullDay },
                        set: { dateTimeSlots[slotKey(for: date)] = $0 }
                    )) {
                        Text("AM").tag(TimeSlot.morning)
                        Text("PM").tag(TimeSlot.afternoon)
                        Text("FULL DAY").tag(TimeSlot.fullDay)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(12)
                .background(Color(.systemGray6))
                .cornerRadius(10)
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(14)
    }
    
    private var bookingSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Booking Summary")
                .font(.title3)
                .fontWeight(.bold)
            VStack(spacing: 10) {
                HStack {
                    Label("Booked By", systemImage: "person.fill")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Project Planner")
                        .fontWeight(.semibold)
                }
                Divider()
                HStack {
                    Label("Total Bookings", systemImage: "calendar.badge.plus")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(selectedSubcontractorIds.count * selectedDates.count)")
                        .fontWeight(.bold)
                        .foregroundColor(Color.theme.primary)
                }
                if !selectedSubcontractorNames.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Selected Sub Contractors")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        ForEach(selectedSubcontractorNames, id: \.self) { name in
                            Text(name)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .padding(14)
            .background(Color.theme.primary.opacity(0.06))
            .cornerRadius(10)
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(14)
    }
    
    private func toggle(_ id: UUID) {
        if selectedSubcontractorIds.contains(id) {
            selectedSubcontractorIds.remove(id)
        } else {
            selectedSubcontractorIds.insert(id)
        }
    }
    
    private func slotKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
    
    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: currentMonth)
    }
    
    private func changeMonth(by months: Int) {
        if let newMonth = Calendar.current.date(byAdding: .month, value: months, to: currentMonth) {
            currentMonth = newMonth
        }
    }
    
    private var calendarGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { day in
                    Text(day)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            
            let calendar = Calendar.current
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: currentMonth))!
            let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)!
            let startDate = calendar.date(byAdding: DateComponents(day: -calendar.component(.weekday, from: monthStart) + 1), to: monthStart)!
            let endDate = calendar.date(byAdding: DateComponents(day: 6 - calendar.component(.weekday, from: monthEnd) + calendar.range(of: .day, in: .month, for: monthEnd)!.count), to: monthStart)!
            let days = generateDays(start: startDate, end: endDate)
            let weeks = days.chunked(into: 7)
            
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 8) {
                    ForEach(week, id: \.self) { date in
                        dayButton(for: date, isCurrentMonth: calendar.isDate(date, equalTo: currentMonth, toGranularity: .month))
                    }
                }
            }
        }
    }
    
    private func dayButton(for date: Date, isCurrentMonth: Bool) -> some View {
        let calendar = Calendar.current
        let normalized = calendar.startOfDay(for: date)
        let isSelected = selectedDates.contains(normalized)
        
        return Button {
            if isSelected {
                selectedDates.remove(normalized)
                dateTimeSlots.removeValue(forKey: slotKey(for: normalized))
            } else {
                selectedDates.insert(normalized)
                if dateTimeSlots[slotKey(for: normalized)] == nil {
                    dateTimeSlots[slotKey(for: normalized)] = .fullDay
                }
            }
            quickSelectDays = nil
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 15, weight: isSelected ? .bold : .regular))
                .foregroundColor(isSelected ? .white : (isCurrentMonth ? .primary : .secondary))
                .frame(width: 40, height: 40)
                .background(Circle().fill(isSelected ? Color.theme.primary : Color.clear))
        }
        .frame(maxWidth: .infinity)
        .opacity(isCurrentMonth ? 1.0 : 0.3)
    }
    
    private func generateDays(start: Date, end: Date) -> [Date] {
        var days: [Date] = []
        var currentDate = start
        let calendar = Calendar.current
        while currentDate <= end {
            days.append(currentDate)
            guard let next = calendar.date(byAdding: .day, value: 1, to: currentDate) else { break }
            currentDate = next
        }
        return days
    }
    
    private func save() {
        isSaving = true
        Task {
            for subcontractorId in selectedSubcontractorIds {
                for date in selectedDates {
                    let key = slotKey(for: date)
                    let slot = dateTimeSlots[key] ?? .fullDay
                    let booking = SubcontractorBooking(
                        subcontractorId: subcontractorId,
                        projectId: project.id,
                        date: date,
                        timeSlot: slot,
                        bookedBy: "Project Planner"
                    )
                    await subcontractorStore.saveBooking(booking)
                }
            }
            await MainActor.run {
                isSaving = false
                dismiss()
            }
        }
    }
}
