//
//  ScheduleOperativeView.swift
//  Project Planner
//
//  Created by Assistant on 22/10/2025.
//

import SwiftUI
import MapKit
import FirebaseAuth

struct ScheduleOperativeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    
    let project: Project
    
    @State private var selectedOperatives: Set<UUID> = []
    @State private var showingSelectOperatives = false
    @State private var selectedDates: Set<Date> = []
    @State private var dateTimeSlots: [String: TimeSlot] = [:]
    @State private var currentMonth: Date = Date()
    @State private var quickSelectDays: Int? = nil
    @State private var showingBookingConfirmation = false
    @State private var isBooking = false
    @State private var showingClashWarning = false
    @State private var detectedClashes: [BookingClash] = []
    @EnvironmentObject var notificationService: NotificationService
    
    // Get logged-in user name
    private var loggedInUserName: String {
        if let user = userStore.currentUser {
            if !user.firstName.isEmpty || !user.surname.isEmpty {
                return "\(user.firstName) \(user.surname)".trimmingCharacters(in: .whitespaces)
            }
            return user.email
        }
        // Fallback to Firebase user email if available
        if let firebaseUser = firebaseBackend.currentUser {
            return firebaseUser.email ?? "Unknown User"
        }
        return "Unknown User"
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(.systemGroupedBackground),
                        Color(.systemGroupedBackground).opacity(0.8)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Project Header Card
                        projectHeaderCard
                        
                        // Select Operatives Section
                        selectOperativesSection
                        
                        // Calendar Section
                        calendarSection
                        
                        // Quick Select Section
                        quickSelectSection
                        
                        // Selected Dates List
                        if !selectedDates.isEmpty {
                            selectedDatesSection
                        }
                        
                        // Booking Summary
                        bookingSummarySection
                        
                        // Book Button (sticky at bottom)
                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 100)
                }
            }
            .navigationTitle("Schedule Booking")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingClashWarning) {
                BookingClashWarningView(
                    clashes: $detectedClashes,
                    isPresented: $showingClashWarning,
                    onCancel: {
                        showingClashWarning = false
                    },
                    onContinue: {
                        showingClashWarning = false
                        proceedWithBooking()
                    }
                )
                .environmentObject(projectStore)
                .environmentObject(userStore)
            }
            .sheet(isPresented: $showingBookingConfirmation) {
                BookingConfirmationView(isPresented: $showingBookingConfirmation)
                    .presentationDetents([.fraction(0.35)])
                    .interactiveDismissDisabled(true)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundColor(Color.theme.primary)
                        .fontWeight(.medium)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomActionBar
            }
            .sheet(isPresented: $showingSelectOperatives) {
                SelectOperativesView(selectedOperatives: $selectedOperatives)
                    .environmentObject(operativeStore)
            }
        }
    }
    
    // MARK: - Project Header Card
    
    private var projectHeaderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.jobNumber)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(Color.theme.primary.opacity(0.8))
                    
                    Text(project.siteName)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundColor(Color.theme.primary.opacity(0.6))
            }
            
            Divider()
                .padding(.vertical, 4)
            
            HStack(spacing: 16) {
                Label(project.client.name, systemImage: "building.2")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Label(project.customJobType ?? "N/A", systemImage: "wrench.and.screwdriver")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
        )
    }
    
    // MARK: - Select Operatives Section
    
    private var selectOperativesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "person.3.fill")
                    .font(.title3)
                    .foregroundColor(Color.theme.primary)
                
                Text("Select Operatives")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
            
            Button(action: { showingSelectOperatives = true }) {
                HStack(spacing: 12) {
                    Image(systemName: selectedOperatives.isEmpty ? "person.badge.plus" : "person.3.fill")
                        .font(.title3)
                        .foregroundColor(selectedOperatives.isEmpty ? Color.theme.primary.opacity(0.6) : Color.theme.primary)
                        .frame(width: 24)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        if selectedOperatives.isEmpty {
                            Text("Tap to select operatives")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            Text("\(selectedOperatives.count) operative\(selectedOperatives.count == 1 ? "" : "s") selected")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            if selectedOperatives.count <= 3 {
                                let names = operativeStore.activeOperatives
                                    .filter { selectedOperatives.contains($0.id) }
                                    .map { $0.name }
                                    .prefix(3)
                                Text(names.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(selectedOperatives.isEmpty ? Color(.systemGray6) : Color.theme.primary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(selectedOperatives.isEmpty ? Color.clear : Color.theme.primary.opacity(0.3), lineWidth: 1.5)
                )
            }
        }
    }
    
    // MARK: - Calendar Section
    
    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "calendar")
                    .font(.title3)
                    .foregroundColor(Color.theme.primary)
                
                Text("Select Dates")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
            
            VStack(spacing: 16) {
                // Month navigation
                HStack {
                    Button(action: { changeMonth(by: -1) }) {
                        Image(systemName: "chevron.left")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(Color.theme.primary)
                            )
                    }
                    
                    Spacer()
                    
                    VStack(spacing: 2) {
                        Text(monthYearString)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        Text("Tap dates to select")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: { changeMonth(by: 1) }) {
                        Image(systemName: "chevron.right")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(Color.theme.primary)
                            )
                    }
                }
                .padding(.horizontal, 8)
                
                Divider()
                
                // Calendar grid
                calendarGrid
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
            )
        }
    }
    
    private var calendarGrid: some View {
        VStack(spacing: 12) {
            // Days of week header
            HStack(spacing: 0) {
                ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { day in
                    Text(day)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
            
            // Calendar dates
            let calendar = Calendar.current
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: currentMonth))!
            let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)!
            let startDate = calendar.date(byAdding: DateComponents(day: -calendar.component(.weekday, from: monthStart) + 1), to: monthStart)!
            let endDate = calendar.date(byAdding: DateComponents(day: 6 - calendar.component(.weekday, from: monthEnd) + calendar.range(of: .day, in: .month, for: monthEnd)!.count), to: monthStart)!
            
            let days = generateDaysInMonth(start: startDate, end: endDate)
            let weeks = days.chunked(into: 7)
            
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 8) {
                    ForEach(week, id: \.self) { date in
                        calendarDayButton(for: date, isCurrentMonth: calendar.isDate(date, equalTo: currentMonth, toGranularity: .month))
                    }
                }
            }
        }
    }
    
    private func calendarDayButton(for date: Date, isCurrentMonth: Bool) -> some View {
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: date)
        let isSelected = selectedDates.contains(normalizedDate)
        let isToday = calendar.isDateInToday(date)
        
        return Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                toggleDateSelection(date)
            }
        }) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 15, weight: isSelected ? .bold : (isToday ? .semibold : .regular)))
                .foregroundColor(
                    isSelected ? .white :
                    (isCurrentMonth ? (isToday ? Color.theme.primary : .primary) : .secondary)
                )
                .frame(width: 44, height: 44)
                .background(
                    Group {
                        if isSelected {
                            Circle()
                                .fill(Color.theme.primary)
                                .shadow(color: Color.theme.primary.opacity(0.3), radius: 4, x: 0, y: 2)
                        } else if isToday {
                            Circle()
                                .stroke(Color.theme.primary, lineWidth: 2)
                                .background(Circle().fill(Color.theme.primary.opacity(0.1)))
                        } else {
                            Circle()
                                .fill(Color.clear)
                        }
                    }
                )
        }
        .frame(maxWidth: .infinity)
        .opacity(isCurrentMonth ? 1.0 : 0.3)
    }
    
    // MARK: - Quick Select Section
    
    private var quickSelectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .foregroundColor(Color.theme.primary)
                
                Text("Quick Select")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 10) {
                quickSelectButton(days: 1, label: "Today", icon: "1.circle.fill")
                quickSelectButton(days: 3, label: "3 Days", icon: "3.circle.fill")
                quickSelectButton(days: 5, label: "5 Days", icon: "5.circle.fill")
            }
        }
    }
    
    private func quickSelectButton(days: Int, label: String, icon: String) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                quickSelectDays(days: days)
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .foregroundColor(quickSelectDays == days ? .white : Color.theme.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(quickSelectDays == days ? Color.theme.primary : Color.theme.primary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(quickSelectDays == days ? Color.clear : Color.theme.primary.opacity(0.3), lineWidth: 1.5)
            )
        }
    }
    
    // MARK: - Selected Dates Section
    
    private var selectedDatesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(Color.theme.primary)
                
                Text("Selected Dates")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("\(selectedDates.count)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(Color.theme.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.theme.primary.opacity(0.15))
                    )
            }
            
            VStack(spacing: 12) {
                ForEach(Array(selectedDates.sorted()), id: \.self) { date in
                    selectedDateRow(for: date)
                }
            }
        }
    }
    
    private func selectedDateRow(for date: Date) -> some View {
        let timeSlot = dateTimeSlots[slotKey(for: date)] ?? .fullDay
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, d MMM yyyy"
        
        return VStack(spacing: 12) {
            HStack {
                Image(systemName: "calendar")
                    .font(.subheadline)
                    .foregroundColor(Color.theme.primary)
                
                Text(dateFormatter.string(from: date))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedDates.remove(date)
                        dateTimeSlots.removeValue(forKey: slotKey(for: date))
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red.opacity(0.7))
                        .font(.title3)
                }
            }
            
            Divider()
            
            // Time slot buttons
            HStack(spacing: 10) {
                Text("Time Slot:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                HStack(spacing: 8) {
                    timeSlotButton(slot: .morning, selected: timeSlot == .morning, date: date)
                    timeSlotButton(slot: .afternoon, selected: timeSlot == .afternoon, date: date)
                    timeSlotButton(slot: .fullDay, selected: timeSlot == .fullDay, date: date)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
        )
    }
    
    private func timeSlotButton(slot: TimeSlot, selected: Bool, date: Date) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                let key = slotKey(for: date)
                dateTimeSlots[key] = selected && dateTimeSlots[key] == slot ? .fullDay : slot
            }
        }) {
            Text(slot.shortDisplayName)
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? Color.theme.primary : Color.clear)
                )
                .foregroundColor(selected ? .white : Color.theme.primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Color.clear : Color.theme.primary.opacity(0.4), lineWidth: 1.5)
                )
        }
    }
    
    // MARK: - Booking Summary Section
    
    private var bookingSummarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .font(.title3)
                    .foregroundColor(Color.theme.primary)
                
                Text("Booking Summary")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
            
            VStack(spacing: 12) {
                HStack {
                    Label("Booked By", systemImage: "person.fill")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(loggedInUserName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                }
                
                Divider()
                
                HStack {
                    Label("Total Bookings", systemImage: "calendar.badge.plus")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("\(selectedOperatives.count * selectedDates.count)")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundColor(Color.theme.primary)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.theme.primary.opacity(0.05))
            )
        }
    }
    
    // MARK: - Bottom Action Bar
    
    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if !selectedOperatives.isEmpty && !selectedDates.isEmpty {
                        Text("Ready to Book")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("\(selectedOperatives.count) operative\(selectedOperatives.count == 1 ? "" : "s") × \(selectedDates.count) date\(selectedDates.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                    } else {
                        Text("Select operatives and dates")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Button(action: {
                    bookOperatives()
                }) {
                    HStack(spacing: 8) {
                        if isBooking {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.subheadline)
                        }
                        
                        Text(isBooking ? "Booking..." : "Confirm Booking")
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selectedOperatives.isEmpty || selectedDates.isEmpty || isBooking ? Color.gray : Color.theme.primary)
                    )
                    .shadow(color: (selectedOperatives.isEmpty || selectedDates.isEmpty || isBooking) ? Color.clear : Color.theme.primary.opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .disabled(selectedOperatives.isEmpty || selectedDates.isEmpty || isBooking)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                Color(.systemBackground)
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: -2)
            )
        }
    }
    
    // MARK: - Helper Methods
    
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
    
    private func toggleDateSelection(_ date: Date) {
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: date)
        let key = slotKey(for: normalizedDate)
        
        if selectedDates.contains(normalizedDate) {
            selectedDates.remove(normalizedDate)
            dateTimeSlots.removeValue(forKey: key)
        } else {
            selectedDates.insert(normalizedDate)
            if dateTimeSlots[key] == nil {
                dateTimeSlots[key] = .fullDay
            }
        }
        
        quickSelectDays = nil
    }
    
    private func quickSelectDays(days: Int) {
        quickSelectDays = days
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        selectedDates.removeAll()
        dateTimeSlots.removeAll()
        
        for i in 0..<days {
            if let date = calendar.date(byAdding: .day, value: i, to: today) {
                let normalizedDate = calendar.startOfDay(for: date)
                selectedDates.insert(normalizedDate)
                dateTimeSlots[slotKey(for: normalizedDate)] = .fullDay
            }
        }
    }
    
    private func generateDaysInMonth(start: Date, end: Date) -> [Date] {
        var days: [Date] = []
        var currentDate = start
        let calendar = Calendar.current
        
        while currentDate <= end {
            days.append(currentDate)
            if let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) {
                currentDate = nextDate
            } else {
                break
            }
        }
        
        return days
    }
    
    private func bookOperatives() {
        guard !selectedOperatives.isEmpty, !selectedDates.isEmpty else { return }
        
        // Check for clashes before booking
        let clashes = detectClashes()
        
        if !clashes.isEmpty {
            detectedClashes = clashes
            showingClashWarning = true
        } else {
            proceedWithBooking()
        }
    }
    
    private func detectClashes() -> [BookingClash] {
        var clashes: [BookingClash] = []
        let operatives = operativeStore.activeOperatives.filter { selectedOperatives.contains($0.id) }
        let dates = Array(selectedDates.sorted())
        
        for operative in operatives {
            for date in dates {
                if let timeSlot = dateTimeSlots[slotKey(for: date)] {
                    // Check for existing bookings for this operative on this date
                    let existingBookings = bookingStore.bookings.filter { booking in
                        booking.operativeId == operative.id &&
                        Calendar.current.isDate(booking.date, inSameDayAs: date) &&
                        (booking.status == .confirmed || booking.status == .tentative)
                    }
                    
                    // Check if time slots clash
                    for existingBooking in existingBookings {
                        if timeSlotsClash(timeSlot, existingBooking.timeSlot) {
                            // Find the project for the existing booking
                            let existingProject = projectStore.projects.first(where: { $0.id == existingBooking.projectId }) ??
                                projectStore.smallWorks.first(where: { $0.id == existingBooking.projectId })
                            
                            clashes.append(BookingClash(
                                operative: operative,
                                date: date,
                                newTimeSlot: timeSlot,
                                existingBooking: existingBooking,
                                existingProject: existingProject
                            ))
                        }
                    }
                }
            }
        }
        
        return clashes
    }
    
    private func timeSlotsClash(_ slot1: TimeSlot, _ slot2: TimeSlot) -> Bool {
        // Full day clashes with everything
        if slot1 == .fullDay || slot2 == .fullDay {
            return true
        }
        // Same slot clashes
        if slot1 == slot2 {
            return true
        }
        return false
    }

    private func slotKey(for date: Date) -> String {
        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month, .day], from: normalizedDate)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
    
    private func proceedWithBooking() {
        isBooking = true
        
        Task {
            let operatives = operativeStore.activeOperatives.filter { selectedOperatives.contains($0.id) }
            let dates = Array(selectedDates.sorted())
            
            // Filter out cancelled clashes before creating bookings
            let activeClashes = detectedClashes.filter { !$0.cancelled }
            
            // Create bookings for each operative on each selected date
            for operative in operatives {
                for date in dates {
                    if let timeSlot = dateTimeSlots[slotKey(for: date)] {
                        // Check if this booking was cancelled due to clash
                        let isCancelled = activeClashes.contains { clash in
                            clash.operative.id == operative.id &&
                            Calendar.current.isDate(clash.date, inSameDayAs: date) &&
                            clash.newTimeSlot == timeSlot
                        }
                        
                        if !isCancelled {
                            await bookingStore.bookOperative(
                                operative,
                                on: date,
                                timeSlot: timeSlot,
                                for: project,
                                bookedBy: loggedInUserName,
                                notificationService: notificationService
                            )
                        }
                    }
                }
            }
            
            // Send notifications for any clashes that were confirmed (not cancelled)
            for clash in activeClashes {
                // Find the user ID for the existing booking's creator
                // bookedBy might be email or name, we need to find the user
                let existingBookedBy = clash.existingBooking.bookedBy
                
                await notificationService.notifyBookingClash(
                    booking1Id: clash.existingBooking.id,
                    booking2Id: UUID(), // New booking ID (we don't have it yet, but notification will work)
                    operativeName: clash.operative.name,
                    date: clash.date,
                    userId1: existingBookedBy, // Existing booking creator
                    userId2: loggedInUserName // Current user
                )
            }
            
            await MainActor.run {
                isBooking = false
                showingBookingConfirmation = true
                detectedClashes = []
                // Stay on Schedule Operative page; reset selections so user can continue booking quickly.
                selectedDates.removeAll()
                selectedOperatives.removeAll()
                dateTimeSlots.removeAll()
            }
        }
    }
    
    struct BookingClash: Identifiable {
        let id = UUID()
        let operative: Operative
        let date: Date
        let newTimeSlot: TimeSlot
        let existingBooking: Booking
        let existingProject: Project?
        var cancelled: Bool = false
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

#Preview {
    ScheduleOperativeView(project: Project(
        jobNumber: "C646",
        siteName: "Lancelot Place",
        siteAddress: "8 Lancelot Place, SW7 1DR, London",
        client: Client(name: "Test Client"),
        startDate: Date(),
        endDate: Date(),
        jobType: .catA,
        manager: .na
    ))
    .environmentObject(BookingStore())
    .environmentObject(OperativeStore())
    .environmentObject(ProjectStore())
    .environmentObject(UserStore())
    .environmentObject(FirebaseBackend())
}

