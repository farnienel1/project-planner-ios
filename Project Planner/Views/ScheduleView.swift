//
//  ScheduleView.swift
//  Project Planner
//
//  Created by Assistant on 29/09/2025.
//

import SwiftUI

struct ScheduleView: View {
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    
    @State private var selectedDate = Date()
    @State private var showingAddBooking = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Date Picker
                datePickerSection
                
                // Schedule Content
                scheduleContent
            }
            .navigationTitle("Schedule")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddBooking = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddBooking) {
                AddBookingView(selectedDate: selectedDate)
                    .environmentObject(bookingStore)
                    .environmentObject(projectStore)
                    .environmentObject(operativeStore)
            }
        }
    }
    
    private var datePickerSection: some View {
        VStack(spacing: 12) {
            DatePicker(
                "Select Date",
                selection: $selectedDate,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding(.horizontal)
            
            Divider()
        }
    }
    
    private var scheduleContent: some View {
        Group {
            if bookingStore.isLoading {
                ProgressView("Loading schedule...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        // Day Summary
                        daySummarySection
                        
                        // Bookings for selected date
                        bookingsSection
                        
                        // Conflicts for selected date
                        conflictsSection
                    }
                    .padding()
                }
                .refreshable {
                    bookingStore.loadData()
                }
            }
        }
    }
    
    private var daySummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Day Summary")
                .font(.headline)
            
            HStack(spacing: 16) {
                SummaryCard(
                    title: "Total Bookings",
                    value: "\(bookingsForSelectedDate.count)",
                    icon: "calendar",
                    color: .blue
                )
                
                SummaryCard(
                    title: "Operatives",
                    value: "\(uniqueOperativesForDate.count)",
                    icon: "person.2",
                    color: .green
                )
                
                SummaryCard(
                    title: "Projects",
                    value: "\(uniqueProjectsForDate.count)",
                    icon: "folder",
                    color: .orange
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    private var bookingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bookings")
                    .font(.headline)
                Spacer()
                if !bookingsForSelectedDate.isEmpty {
                    Text("\(bookingsForSelectedDate.count) total")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if bookingsForSelectedDate.isEmpty {
                emptyBookingsView
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(bookingsForSelectedDate) { booking in
                        BookingDetailRowView(booking: booking)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    private var conflictsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conflicts")
                .font(.headline)
            
            if conflictsForSelectedDate.isEmpty {
                Text("No conflicts detected")
                    .font(.subheadline)
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(conflictsForSelectedDate) { conflict in
                        ConflictRowView(conflict: conflict)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    private var emptyBookingsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            
            Text("No bookings for this date")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Button("Add Booking") {
                showingAddBooking = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
    
    private var bookingsForSelectedDate: [Booking] {
        bookingStore.bookings.filter { 
            Calendar.current.isDate($0.date, inSameDayAs: selectedDate) &&
            ($0.status == .confirmed || $0.status == .tentative)
        }.sorted { $0.timeSlot.rawValue < $1.timeSlot.rawValue }
    }
    
    private var uniqueOperativesForDate: [UUID] {
        Array(Set(bookingsForSelectedDate.map { $0.operativeId }))
    }
    
    private var uniqueProjectsForDate: [UUID] {
        Array(Set(bookingsForSelectedDate.map { $0.projectId }))
    }
    
    private var conflictsForSelectedDate: [BookingConflict] {
        // This would need to be implemented based on the booking conflict detection logic
        // For now, return empty array
        []
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

struct BookingDetailRowView: View {
    let booking: Booking
    
    var body: some View {
        HStack(spacing: 12) {
            // Time slot indicator
            VStack(spacing: 4) {
                timeSlotIcon
                    .font(.title2)
                    .foregroundColor(timeSlotColor)
                
                Text(timeSlotText)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(width: 60)
            
            // Booking details
            VStack(alignment: .leading, spacing: 4) {
                Text("Operative Booking")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("Project: \(projectName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("Booked by: \(booking.bookedBy)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if let notes = booking.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            // Status indicator
            statusBadge
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
    
    private var timeSlotIcon: some View {
        switch booking.timeSlot {
        case .morning:
            return Image(systemName: "sunrise")
        case .afternoon:
            return Image(systemName: "sun.max")
        case .fullDay:
            return Image(systemName: "calendar.day.timeline.left")
        case .evening:
            return Image(systemName: "sunset")
        case .overtime:
            return Image(systemName: "clock.badge")
        }
    }
    
    private var timeSlotColor: Color {
        switch booking.timeSlot {
        case .morning: return .orange
        case .afternoon: return .yellow
        case .fullDay: return .blue
        case .evening: return .purple
        case .overtime: return .red
        }
    }
    
    private var timeSlotText: String {
        switch booking.timeSlot {
        case .morning: return "AM"
        case .afternoon: return "PM"
        case .fullDay: return "Full"
        case .evening: return "Eve"
        case .overtime: return "OT"
        }
    }
    
    private var statusBadge: some View {
        Text(booking.status.rawValue)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.2))
            .foregroundColor(statusColor)
            .cornerRadius(4)
    }
    
    private var statusColor: Color {
        switch booking.status {
        case .confirmed: return .green
        case .tentative: return .orange
        case .cancelled: return .red
        case .completed: return .blue
        }
    }
    
    private var projectName: String {
        // This would need to be resolved from the project store
        "Project Name"
    }
}

struct ConflictRowView: View {
    let conflict: BookingConflict
    
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Scheduling Conflict")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("Operative: \(conflict.operative.name)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("\(conflict.conflictingBookings.count) conflicting bookings")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(conflict.severity.rawValue)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(severityColor.opacity(0.2))
                .foregroundColor(severityColor)
                .cornerRadius(4)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
    
    private var severityColor: Color {
        switch conflict.severity {
        case .low: return .yellow
        case .medium: return .orange
        case .high: return .red
        case .critical: return .purple
        }
    }
}

struct AddBookingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    
    let selectedDate: Date
    
    @State private var selectedOperative: Operative?
    @State private var selectedProject: Project?
    @State private var selectedTimeSlot: TimeSlot = .morning
    @State private var bookedBy = ""
    @State private var notes = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("Booking Details") {
                    Picker("Operative", selection: $selectedOperative) {
                        Text("Select Operative").tag(nil as Operative?)
                        ForEach(operativeStore.activeOperatives) { operative in
                            Text(operative.name).tag(operative as Operative?)
                        }
                    }
                    
                    Picker("Project", selection: $selectedProject) {
                        Text("Select Project").tag(nil as Project?)
                        ForEach(projectStore.liveProjects) { project in
                            Text("\(project.jobNumber) - \(project.siteName)").tag(project as Project?)
                        }
                    }
                    
                    Picker("Time Slot", selection: $selectedTimeSlot) {
                        ForEach(TimeSlot.allCases) { slot in
                            Text(slot.displayName).tag(slot)
                        }
                    }
                }
                
                Section("Additional Info") {
                    TextField("Booked by", text: $bookedBy)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section {
                    Text("Selected Date: \(selectedDate, style: .date)")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Add Booking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveBooking()
                    }
                    .disabled(!isFormValid)
                }
            }
        }
    }
    
    private var isFormValid: Bool {
        selectedOperative != nil && 
        selectedProject != nil && 
        !bookedBy.isEmpty
    }
    
    private func saveBooking() {
        guard let operative = selectedOperative,
              let project = selectedProject else { return }
        
        Task {
            await bookingStore.bookOperative(
                operative,
                on: selectedDate,
                timeSlot: selectedTimeSlot,
                for: project,
                bookedBy: bookedBy,
                notes: notes.isEmpty ? nil : notes
            )
            dismiss()
        }
    }
}

#Preview {
    ScheduleView()
        .environmentObject(BookingStore())
        .environmentObject(ProjectStore())
        .environmentObject(OperativeStore())
}
