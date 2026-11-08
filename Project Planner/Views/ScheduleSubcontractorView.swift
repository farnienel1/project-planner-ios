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
                VStack(alignment: .leading, spacing: 0) {
                    subcontractorHeader
                    VStack(alignment: .leading, spacing: 4) {
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
                    .padding(.bottom, 24)
                    .ppContentSheet()
                }
            }
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Schedule subcontractor")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .fontWeight(.semibold)
                        .fixedSize()
                    }
                        .accessibilityIdentifier("scheduleSubcontractor.back")
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
                    .accessibilityIdentifier("scheduleSubcontractor.ok")
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
        VStack(alignment: .leading, spacing: 10) {
            PPSheetSectionTitle("Choose subcontractor")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search sub contractors...", text: $searchText)
                    .accessibilityIdentifier("scheduleSubcontractor.searchSubContractors")
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(PPColor.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(PPBookingColor.cardBorder, lineWidth: 0.5)
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(typeFilters, id: \.self) { type in
                        let selected = selectedTypeFilter == type
                        Button {
                            selectedTypeFilter = type
                        } label: {
                            Text(type == "All Types" ? "All trades" : type)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(selected ? PPBookingColor.selected : PPColor.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(PPBookingColor.cardBorder, lineWidth: selected ? 0 : 0.5))
                        }
                        .accessibilityIdentifier("scheduleSubcontractor.row.\(type).allTypes")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
            if subcontractorStore.subcontractors.isEmpty {
                Text("No sub contractors available. Add one first.")
                    .foregroundStyle(.secondary)
            } else if filteredSubcontractors.isEmpty {
                Text("No sub contractors match this search/filter.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredSubcontractors.enumerated()), id: \.element.id) { index, subcontractor in
                        if index > 0 {
                            Divider().padding(.leading, 62)
                        }
                        subcontractorRow(subcontractor)
                    }
                }
                .background(PPColor.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(PPBookingColor.cardBorder, lineWidth: 0.5)
                )
            }
        }
    }

    private func subcontractorRow(_ subcontractor: Subcontractor) -> some View {
        let selected = selectedSubcontractorId == subcontractor.id
        let count = subcontractor.contacts.count
        return Button {
            selectSubcontractor(subcontractor.id)
        } label: {
            HStack(spacing: 12) {
                Text(initials(for: subcontractor.name))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(PPFamily.people.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subcontractor.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subcontractor.subcontractorType)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                PPChip(text: "\(count) op\(count == 1 ? "" : "s")", tone: .neutral)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? PPColor.brand : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(selected ? PPColor.brand.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("scheduleSubcontractor.row.\(subcontractor.id).op")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .buttonStyle(.plain)
    }

    private var subcontractorHeader: some View {
        PPJobHeaderBlock(
            code: project.jobNumber,
            name: project.siteName,
            detail: project.client.name,
            address: project.siteAddress,
            isSmallWorks: project.isSmallWorksDocument
        )
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private var attendanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selectedSubcontractor {
                PPSheetSectionTitle("Who's attending")
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $useGeneralAttendance) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(selectedSubcontractor.name) (General)")
                                .font(.subheadline.weight(.semibold))
                            Text("Use if named operatives are not confirmed yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("scheduleSubcontractor.general")
                    .tint(PPColor.brand)
                    if !useGeneralAttendance, !selectedSubcontractor.contacts.isEmpty {
                        ForEach(selectedSubcontractor.contacts) { contact in
                            let picked = selectedContactIds.contains(contact.id)
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
                                        Text(contact.displayTrade)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: picked ? "checkmark.square.fill" : "square")
                                        .font(.title3)
                                        .foregroundStyle(picked ? PPColor.brand : Color.secondary)
                                }
                                .padding(10)
                                .background(PPBookingColor.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("scheduleSubcontractor.row.\(contact.id).checkmarkSquareFill")
                            .accessibilityAddTraits(picked ? .isSelected : [])
                            .buttonStyle(.plain)
                        }
                    }
                }
                .ppBookingCard(padding: 14)
            }
        }
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PPSheetSectionTitle("Dates") {
                PPChip(text: "\(selectedDates.count) selected", tone: .blue)
            }
            VStack(spacing: 10) {
                HStack {
                    Button(action: { changeMonth(by: -1) }) {
                        Image(systemName: "chevron.left")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(PPBookingColor.field, in: Circle())
                    }
                    .accessibilityIdentifier("scheduleSubcontractor.back2")
                    .accessibilityLabel("Previous month")
                    .buttonStyle(.plain)
                    Spacer()
                    Text(monthYearString)
                        .font(.headline)
                    Spacer()
                    Button(action: { changeMonth(by: 1) }) {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(PPBookingColor.field, in: Circle())
                    }
                    .accessibilityIdentifier("scheduleSubcontractor.chevronRight")
                    .accessibilityLabel("Next month")
                    .buttonStyle(.plain)
                }
                calendarGrid
            }
            .ppBookingCard(padding: 12)
        }
    }

    /// The existing Today / 3 Days / 5 Days actions, relabelled as on Schedule booking, with their old identifiers.
    private var quickSelectSection: some View {
        PPChipRow {
            quickSelectButton(days: 1, label: "Today", idLabel: "Today")
            quickSelectButton(days: 3, label: "Next 3 working days", idLabel: "3 Days")
            quickSelectButton(days: 5, label: "Next 5 working days", idLabel: "5 Days")
        }
        .padding(.top, 6)
    }

    private func quickSelectButton(days: Int, label: String, idLabel: String) -> some View {
        let selected = quickSelectDays == days
        return Button(action: {
            quickSelectDays = days
            var dates: Set<Date> = []
            ScheduleDateSelectionPolicy.quickSelect(count: days, into: &dates)
            selectedDates = dates
            dateTimeSlots.removeAll()
            for d in dates.sorted() {
                dateTimeSlots[slotKey(for: d)] = .defaultPickerSlot(on: d)
            }
        }) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(selected ? Color.white : PPColor.brand)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? PPBookingColor.selected : PPColor.card, in: Capsule())
                .overlay(Capsule().strokeBorder(PPBookingColor.cardBorder, lineWidth: selected ? 0 : 0.5))
        }
            .accessibilityIdentifier("scheduleSubcontractor.\(AccessibilityID.token(idLabel))")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .buttonStyle(.plain)
    }

    private var selectedDatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PPSheetSectionTitle("Selected dates")
            VStack(spacing: 8) {
                ForEach(selectedDates.sorted(), id: \.self) { date in
                    VStack(spacing: 8) {
                        HStack {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.body.weight(.semibold))
                            Spacer()
                            Button(role: .destructive) {
                                selectedDates.remove(date)
                                dateTimeSlots.removeValue(forKey: slotKey(for: date))
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                                .accessibilityIdentifier("scheduleSubcontractor.row.\(date).clear")
                                .accessibilityLabel("Remove \(date.formatted(date: .abbreviated, time: .omitted))")
                                .buttonStyle(.plain)
                        }
                        // RULEBOOK 1.13.1 §4.3 `allowedTimeSlotsOnDay`: Saturday and Sunday are custom hours only.
                        let offered = CanonicalBusinessEngine.allowedTimeSlots(on: date)
                        Picker("Time", selection: Binding(
                            get: { dateTimeSlots[slotKey(for: date)] ?? .defaultPickerSlot(on: date) },
                            set: { dateTimeSlots[slotKey(for: date)] = $0 }
                        )) {
                            if offered.contains(.am) { Text("AM").tag(TimeSlot.morning) }
                            if offered.contains(.pm) { Text("PM").tag(TimeSlot.afternoon) }
                            if offered.contains(.fullDay) { Text("FULL DAY").tag(TimeSlot.fullDay) }
                            Text("Custom").tag(TimeSlot.customHours)
                        }
                        .accessibilityIdentifier("scheduleSubcontractor.row.\(date).time")
                        .pickerStyle(.segmented)
                    }
                    .ppBookingCard(padding: 12, radius: 16)
                }
            }
        }
    }

    private var bookingSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Booking Summary")
                .font(.system(.title3, design: .rounded))
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
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    /// Bottom bar: who is selected (with the slot summary) and the day count, then Confirm booking. Disabled, the
    /// button says what is missing instead of fading.
    private var bookingFooter: some View {
        let canConfirm = !(isSaving || selectedSubcontractorId == nil || selectedDates.isEmpty)
        let missing: String = {
            if isSaving { return "Booking..." }
            if selectedSubcontractorId == nil { return "Choose a subcontractor to confirm" }
            return "Choose dates to confirm"
        }()
        return PPBottomActionBar(
            title: "Confirm booking",
            isEnabled: canConfirm,
            disabledTitle: missing,
            isBusy: isSaving,
            accessibilityIdentifier: "scheduleSubcontractor.booking",
            action: { save() }
        ) {
            PPChipRow {
                PPChip(
                    text: summaryLine,
                    symbol: selectedSubcontractor == nil ? "exclamationmark.circle" : "checkmark",
                    tone: selectedSubcontractor == nil ? .amber : .blue
                )
                PPChip(
                    text: "\(selectedDates.count) day\(selectedDates.count == 1 ? "" : "s")",
                    symbol: "calendar",
                    tone: selectedDates.isEmpty ? .neutral : .blue
                )
            }
        }
    }

    private var summaryLine: String {
        let who = selectedSubcontractor?.name ?? "No sub contractor selected"
        if selectedDates.isEmpty { return who }
        let slots = Set(selectedDates.map { dateTimeSlots[slotKey(for: $0)] ?? .defaultPickerSlot(on: $0) })
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
        dateTimeSlots = [slotKey(for: today): .defaultPickerSlot(on: today)]
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
                ForEach(MondayFirstCalendarSupport.weekdayHeaderItems, id: \.id) { day in
                    Text(day.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            let calendar = Calendar.current
            let range = MondayFirstCalendarSupport.gridRange(for: currentMonth, calendar: calendar)
            let days = MondayFirstCalendarSupport.days(from: range.start, through: range.end, calendar: calendar)
            let weeks = days.chunked(into: 7)

            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
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
        let isToday = calendar.isDateInToday(date)

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
                    dateTimeSlots[slotKey(for: normalized)] = .defaultPickerSlot(on: normalized)
                }
            }
            quickSelectDays = nil
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.subheadline.weight(isSelected ? .bold : (isToday ? .semibold : .regular)))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white : (isCurrentMonth ? (isToday ? PPColor.brand : Color.primary) : Color.secondary))
                .frame(width: 36, height: 36)
                .background {
                    if isSelected {
                        Circle().fill(PPColor.brand)
                    } else if isToday {
                        Circle().strokeBorder(PPColor.brand, lineWidth: 1.5)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("scheduleSubcontractor.day")
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .buttonStyle(.plain)
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
                let slot = dateTimeSlots[key] ?? .defaultPickerSlot(on: date)
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
