//
//  DailyOverviewView.swift
//  Project Planner
//
//  Created by Assistant on 27/10/2025.
//

import SwiftUI

struct DailyOverviewView: View {
    /// When nil, shows today. When set, shows that day (for historic overview).
    var displayDate: Date? = nil
    
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingPastBookings = false
    
    private var overviewDate: Date {
        Calendar.current.startOfDay(for: displayDate ?? Date())
    }
    
    private var isHistoric: Bool {
        displayDate != nil
    }
    
    private var dayBookings: [Booking] {
        bookingStore.bookings.filter { booking in
            Calendar.current.isDate(booking.date, inSameDayAs: overviewDate)
        }
    }
    
    private var dayHolidays: [HolidayBooking] {
        holidayStore.approvedBookings(covering: overviewDate)
    }

    private var isWeekday: Bool {
        let weekday = Calendar.current.component(.weekday, from: overviewDate)
        return weekday >= 2 && weekday <= 6
    }

    private var operativeUsers: [AppUser] {
        userStore.organizationUsers.filter { $0.permissions.operativeMode && $0.isActive }
    }

    private var managerUsers: [AppUser] {
        userStore.organizationUsers.filter {
            !$0.permissions.operativeMode &&
            !$0.isSuperAdmin &&
            !$0.permissions.adminAccess &&
            $0.permissions.manager &&
            $0.isActive
        }
    }

    private func hasApprovedHoliday(userId: String, operativeId: UUID?) -> Bool {
        dayHolidays.contains { holiday in
            if holiday.status != .approved { return false }
            if holiday.userId == userId { return true }
            if let operativeId, holiday.operativeId == operativeId { return true }
            return false
        }
    }

    private func operativeHasFullDayBooking(_ operativeId: UUID) -> Bool {
        let bookings = dayBookings.filter {
            $0.operativeId == operativeId && ($0.status == .confirmed || $0.status == .tentative)
        }
        if bookings.contains(where: { $0.timeSlot == .fullDay }) { return true }
        let hasAM = bookings.contains(where: { $0.timeSlot == .morning })
        let hasPM = bookings.contains(where: { $0.timeSlot == .afternoon })
        return hasAM && hasPM
    }

    private func managerHasFullDayProjectBooking(_ userId: String) -> Bool {
        let bookings: [ManagerSiteBooking] = managerScheduleStore.managerSiteBookings.filter { booking in
            let sameDay = Calendar.current.isDate(booking.date, inSameDayAs: overviewDate)
            let sameUser = booking.userId == userId
            let isProjectLocation = booking.locationType == ManagerLocationType.project || booking.locationType == ManagerLocationType.smallWork
            return sameDay && sameUser && isProjectLocation
        }
        if bookings.contains(where: { $0.timeSlot == ManagerTimeSlot.fullDay }) { return true }
        let hasAM = bookings.contains(where: { $0.timeSlot == ManagerTimeSlot.morning })
        let hasPM = bookings.contains(where: { $0.timeSlot == ManagerTimeSlot.afternoon })
        return hasAM && hasPM
    }

    private var unbookedOperativeNames: [String] {
        operativeUsers.compactMap { user in
            let linkedOperative = operativeStore.allOperatives.first { $0.email.lowercased() == user.email.lowercased() }
            if hasApprovedHoliday(userId: user.id, operativeId: linkedOperative?.id) { return nil }
            guard let operativeId = linkedOperative?.id else {
                return user.fullName.isEmpty ? user.email : user.fullName
            }
            return operativeHasFullDayBooking(operativeId) ? nil : linkedOperative?.name
        }
        .sorted()
    }

    private var unbookedManagerNames: [String] {
        managerUsers.compactMap { user in
            if hasApprovedHoliday(userId: user.id, operativeId: nil) { return nil }
            return managerHasFullDayProjectBooking(user.id) ? nil : (user.fullName.isEmpty ? user.email : user.fullName)
        }
        .sorted()
    }
    
    // Group bookings by project
    private var bookingsByProject: [UUID: [Booking]] {
        Dictionary(grouping: dayBookings) { $0.projectId }
    }
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter
    }
    
    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                    // Title and Date
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Daily Overview")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.blue)
                        
                        Text(dateFormatter.string(from: overviewDate))
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if !isHistoric {
                            Button(action: { showingPastBookings = true }) {
                                Label("View By Date", systemImage: "calendar")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    
                    if isWeekday && (!unbookedManagerNames.isEmpty || !unbookedOperativeNames.isEmpty) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Unbooked Labour")
                                .font(.headline)
                                .foregroundColor(.primary)
                                .padding(.horizontal, 20)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(unbookedManagerNames, id: \.self) { name in
                                    Label(name, systemImage: "person.badge.key.fill")
                                        .font(.subheadline)
                                }
                                ForEach(unbookedOperativeNames, id: \.self) { name in
                                    Label(name, systemImage: "person.fill")
                                        .font(.subheadline)
                                }
                            }
                            .padding(12)
                            .background(Color.yellow.opacity(0.14))
                            .cornerRadius(12)
                            .padding(.horizontal, 20)
                        }
                    }

                    // On holiday
                    if !dayHolidays.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isHistoric ? "On holiday" : "On holiday today")
                                .font(.headline)
                                .foregroundColor(.primary)
                                .padding(.horizontal, 20)
                            ForEach(dayHolidays) { booking in
                                OnHolidayRowView(booking: booking)
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    
                    // Bookings List
                    if dayBookings.isEmpty && dayHolidays.isEmpty {
                        noBookingsView
                    } else if !dayBookings.isEmpty {
                        LazyVStack(spacing: 16) {
                            ForEach(Array(bookingsByProject.keys.sorted(by: { projectId1, projectId2 in
                                let allProjects = projectStore.projects + projectStore.smallWorks
                                guard let project1 = allProjects.first(where: { $0.id == projectId1 }),
                                      let project2 = allProjects.first(where: { $0.id == projectId2 }) else {
                                    return false
                                }
                                return project1.siteName < project2.siteName
                            })), id: \.self) { projectId in
                                let allProjects = projectStore.projects + projectStore.smallWorks
                                if let project = allProjects.first(where: { $0.id == projectId }),
                                   let bookings = bookingsByProject[projectId] {
                                    ProjectBookingCard(project: project, bookings: bookings)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 30)
        }
    }
    
    var body: some View {
        Group {
            if isHistoric {
                overviewContent
            } else {
                NavigationView {
                    overviewContent
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showingPastBookings) {
            HistoricDailyOverviewView()
                .environmentObject(bookingStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(holidayStore)
                .environmentObject(managerScheduleStore)
        }
    }
    
    private var noBookingsView: some View {
        VStack(spacing: 16) {
            Text("No bookings")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
    }
}

struct OnHolidayRowView: View {
    let booking: HolidayBooking
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    
    private var displayName: String {
        if let uid = booking.userId,
           let user = userStore.organizationUsers.first(where: { $0.id == uid }) {
            return user.fullName
        }
        if let oid = booking.operativeId,
           let operative = operativeStore.operatives.first(where: { $0.id == oid }) {
            return operative.name
        }
        return "On holiday"
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max.fill")
                .font(.subheadline)
                .foregroundColor(.orange)
            Text(displayName)
                .font(.subheadline)
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(12)
    }
}

/// Date Overview: pick any date (past or future) and see that day's bookings and holidays.
struct HistoricDailyOverviewView: View {
    @State private var selectedDate: Date = {
        let cal = Calendar.current
        return cal.startOfDay(for: Date())
    }()
    @Environment(\.dismiss) private var dismiss
    
    private var minDate: Date {
        Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date())
    }

    private var maxDate: Date {
        Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date())
    }
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select date")
                        .font(.headline)
                        .foregroundColor(.primary)
                    DatePicker("", selection: $selectedDate, in: minDate...maxDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
                
                Divider()
                
                DailyOverviewView(displayDate: selectedDate)
            }
            .navigationTitle("Date Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ManagerScheduleRowView: View {
    let booking: ManagerSiteBooking
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore

    private var locationTitle: String {
        if booking.locationType == .office { return "Office" }
        guard let id = booking.locationId,
              let p = projectStore.projects.first(where: { $0.id == id }) else { return "Site" }
        return "\(p.jobNumber) \(p.siteName)"
    }

    private var userName: String {
        guard let u = userStore.organizationUsers.first(where: { $0.id == booking.userId }) else {
            return booking.userId
        }
        return u.fullName
    }

    var body: some View {
        HStack {
            Text(booking.timeSlot.displayName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.indigo)
                .cornerRadius(8)
            VStack(alignment: .leading, spacing: 2) {
                Text(userName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(locationTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
    }
}

struct ProjectBookingCard: View {
    let project: Project
    let bookings: [Booking]
    @EnvironmentObject var operativeStore: OperativeStore
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Project Identifier and Name
            HStack(alignment: .firstTextBaseline) {
                Text(project.jobNumber)
                    .font(.headline)
                    .foregroundColor(.blue)
                
                Text(project.siteName)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            // Operative Assignments
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sortedBookings, id: \.id) { booking in
                    if let operative = operativeStore.operatives.first(where: { $0.id == booking.operativeId }) {
                        HStack(spacing: 8) {
                            // Time slot badge
                            Text(timeSlotDisplayText(for: booking.timeSlot))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue)
                                .cornerRadius(8)
                            
                            Text(operative.name)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    private var sortedBookings: [Booking] {
        bookings.sorted { booking1, booking2 in
            // Sort by time slot order: AM, PM, FULL DAY, etc.
            let order1 = timeSlotOrder(booking1.timeSlot)
            let order2 = timeSlotOrder(booking2.timeSlot)
            if order1 != order2 {
                return order1 < order2
            }
            // If same time slot, sort by operative name
            if let operative1 = operativeStore.operatives.first(where: { $0.id == booking1.operativeId }),
               let operative2 = operativeStore.operatives.first(where: { $0.id == booking2.operativeId }) {
                return operative1.name < operative2.name
            }
            return false
        }
    }
    
    private func timeSlotOrder(_ timeSlot: TimeSlot) -> Int {
        switch timeSlot {
        case .morning: return 1
        case .afternoon: return 2
        case .fullDay: return 3
        case .evening: return 4
        case .overtime: return 5
        }
    }
    
    private func timeSlotDisplayText(for timeSlot: TimeSlot) -> String {
        switch timeSlot {
        case .morning: return "AM"
        case .afternoon: return "PM"
        case .fullDay: return "FULL DAY"
        case .evening: return "EVENING"
        case .overtime: return "OVERTIME"
        }
    }
}











