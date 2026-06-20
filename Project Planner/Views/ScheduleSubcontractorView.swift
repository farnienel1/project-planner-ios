import SwiftUI

struct ScheduleSubcontractorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let project: Project
    
    @State private var selectedSubcontractorId: UUID?
    @State private var selectedContactIds: Set<UUID> = []
    @State private var useGeneralAttendance = true
    @State private var selectedDates: Set<Date> = []
    @State private var dateTimeSlots: [String: TimeSlot] = [:]
    @State private var currentMonth: Date = Date()
    @State private var quickSelectDays: Int? = nil
    @State private var showingDateSelectionAlert = false
    @State private var dateSelectionAlertMessage = ""
    @State private var isSaving = false
    @State private var searchText = ""
    @State private var selectedTypeFilter = "All Types"
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    projectHeaderCard
                    subbiesSection
                    if selectedSubcontractor != nil {
                        attendanceSection
                    }
                    calendarSection
                    quickSelectSection
                    if !selectedDates.isEmpty {
                        selectedDatesSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 84)
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
            }
            .safeAreaInset(edge: .bottom) {
                bookingFooter
            }
            .task {
                await subcontractorStore.loadData()
            }
            .alert("Date selection", isPresented: $showingDateSelectionAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(dateSelectionAlertMessage)
            }
        }
    }

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }
    
    private var selectedSubcontractor: Subcontractor? {
        guard let selectedSubcontractorId else { return nil }
        return subcontractorStore.subcontractors.first(where: { $0.id == selectedSubcontractorId })
    }

    private var selectedSubcontractorNames: [String] {
        guard let selectedSubcontractor else { return [] }
        return [selectedSubcontractor.name]
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
            Text("Choose sub contractor")
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
            .background(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(.systemGray5), lineWidth: 0.8)
            )
            .cornerRadius(10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(typeFilters, id: \.self) { type in
                        Button {
                            selectedTypeFilter = type
                        } label: {
                            Text(type == "All Types" ? "All trades" : type)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(selectedTypeFilter == type ? .white : .secondary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(selectedTypeFilter == type ? Color.purple : Color.white)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(Color(.systemGray5), lineWidth: selectedTypeFilter == type ? 0 : 0.8)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if subcontractorStore.subcontractors.isEmpty {
                Text("No sub contractors available. Add one first.")
                    .foregroundColor(.secondary)
            } else if filteredSubcontractors.isEmpty {
                Text("No sub contractors match this search/filter.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(filteredSubcontractors) { subcontractor in
                    Button {
                        selectSubcontractor(subcontractor.id)
                    } label: {
                        HStack(spacing: 10) {
                            Text(initials(for: subcontractor.name))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.purple.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(subcontractor.name)
                                    .foregroundColor(.primary)
                                    .fontWeight(.semibold)
                                Text(subcontractor.subcontractorType)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(subcontractor.contacts.count) op\(subcontractor.contacts.count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Image(systemName: selectedSubcontractorId == subcontractor.id ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedSubcontractorId == subcontractor.id ? .purple : .secondary)
                        }
                        .padding(10)
                        .background(selectedSubcontractorId == subcontractor.id ? Color.purple.opacity(0.08) : Color(.systemGray6))
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

    private var projectHeaderCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(project.jobNumber) \(project.siteName)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.theme.primary)
            Text("\(project.client.name) · \(project.siteAddress)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white)
        .cornerRadius(12)
    }

    private var attendanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selectedSubcontractor {
                Text("Who's attending")
                    .font(.headline)
                Toggle(isOn: $useGeneralAttendance) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(selectedSubcontractor.name) (General)")
                            .font(.subheadline.weight(.semibold))
                        Text("Use if named operatives are not confirmed yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.purple)
                if !useGeneralAttendance, !selectedSubcontractor.contacts.isEmpty {
                    ForEach(selectedSubcontractor.contacts) { contact in
                        Button {
                            if selectedContactIds.contains(contact.id) {
                                selectedContactIds.remove(contact.id)
                            } else {
                                selectedContactIds.insert(contact.id)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.name)
                                        .foregroundStyle(.primary)
                                    Text(contact.position.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selectedContactIds.contains(contact.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedContactIds.contains(contact.id) ? Color.purple : Color.secondary)
                            }
                            .padding(10)
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
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
            var dates: Set<Date> = []
            ScheduleDateSelectionPolicy.quickSelect(count: days, into: &dates)
            selectedDates = dates
            dateTimeSlots.removeAll()
            for d in dates.sorted() {
                dateTimeSlots[slotKey(for: d)] = .fullDay
            }
        }) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(quickSelectDays == days ? .white : .purple)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(quickSelectDays == days ? Color.purple : Color.purple.opacity(0.1))
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
                    Text("\((selectedSubcontractorId == nil ? 0 : 1) * selectedDates.count)")
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

    private var bookingFooter: some View {
        VStack(spacing: 8) {
            HStack {
                Text(summaryLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(selectedDates.count) day\(selectedDates.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
            }
            Button {
                save()
            } label: {
                Text(isSaving ? "Booking..." : "Confirm booking")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(isSaving || selectedSubcontractorId == nil || selectedDates.isEmpty)
            .opacity((isSaving || selectedSubcontractorId == nil || selectedDates.isEmpty) ? 0.55 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.white)
    }

    private var summaryLine: String {
        let who = selectedSubcontractor?.name ?? "No sub contractor selected"
        if selectedDates.isEmpty { return who }
        let slots = Set(selectedDates.map { dateTimeSlots[slotKey(for: $0)] ?? .fullDay })
        let slotLabel: String
        if slots.count == 1, let only = slots.first {
            switch only {
            case .morning: slotLabel = "AM"
            case .afternoon: slotLabel = "PM"
            case .fullDay: slotLabel = "Full day"
            case .evening: slotLabel = "Evening"
            case .overtime: slotLabel = "Overtime"
            case .customHours: slotLabel = "Custom hours"
            }
        } else {
            slotLabel = "Mixed slots"
        }
        return "\(who) · \(slotLabel)"
    }
    
    private func selectSubcontractor(_ id: UUID) {
        if selectedSubcontractorId == id {
            selectedSubcontractorId = nil
            useGeneralAttendance = true
            selectedContactIds.removeAll()
            selectedDates.removeAll()
            dateTimeSlots.removeAll()
            quickSelectDays = nil
        } else {
            selectedSubcontractorId = id
            useGeneralAttendance = true
            selectedContactIds.removeAll()
            defaultSelectTodayOnCalendar()
        }
    }

    private func defaultSelectTodayOnCalendar() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        selectedDates = [today]
        dateTimeSlots = [slotKey(for: today): .fullDay]
        quickSelectDays = nil
        currentMonth = today
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let value = parts.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "SC" : value
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
                ForEach(MondayFirstCalendarSupport.weekdayHeaders, id: \.self) { day in
                    Text(day)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            let calendar = Calendar.current
            let range = MondayFirstCalendarSupport.gridRange(for: currentMonth, calendar: calendar)
            let days = MondayFirstCalendarSupport.days(from: range.start, through: range.end, calendar: calendar)
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
                var next = selectedDates
                if let message = ScheduleDateSelectionPolicy.toggle(
                    date: date,
                    selected: &next,
                    policy: payrollTimePolicy,
                    calendar: calendar
                ) {
                    dateSelectionAlertMessage = message
                    showingDateSelectionAlert = true
                    return
                }
                selectedDates = next
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
        guard let selectedSubcontractorId else { return }
        isSaving = true
        Task {
            for date in selectedDates {
                let key = slotKey(for: date)
                let slot = dateTimeSlots[key] ?? .fullDay
                let contactIds: [UUID] = useGeneralAttendance ? [] : Array(selectedContactIds)
                let booking = SubcontractorBooking(
                    subcontractorId: selectedSubcontractorId,
                    projectId: project.id,
                    date: date,
                    timeSlot: slot,
                    bookedBy: "Project Planner",
                    bookedContactIds: contactIds
                )
                await subcontractorStore.saveBooking(booking)
            }
            await MainActor.run {
                isSaving = false
                dismiss()
            }
        }
    }
}
