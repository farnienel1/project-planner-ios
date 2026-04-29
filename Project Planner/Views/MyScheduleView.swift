//
//  MyScheduleView.swift
//  Project Planner
//
//  Admins/Managers: book themselves into a site (project/small work) or office – AM, PM, Full Day.
//  Operatives: view their week-only schedule and "Add to Calendar".
//

import SwiftUI
import EventKit
import FirebaseAuth

struct MyScheduleView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var holidayStore: HolidayStore

    private var isOperativeMode: Bool { userStore.isOperativeMode() }
    /// Office / site attendance booking is only for organisation admins and managers — not operatives or basic users.
    private var canBookManagerSiteAttendance: Bool {
        if isOperativeMode { return false }
        guard let u = userStore.displayUser else { return false }
        return userStore.hasAdminAccess() || u.permissions.manager
    }

    var body: some View {
        NavigationView {
            Group {
                if isOperativeMode {
                    OperativeScheduleContentView()
                        .environmentObject(bookingStore)
                        .environmentObject(projectStore)
                        .environmentObject(operativeStore)
                        .environmentObject(userStore)
                        .environmentObject(holidayStore)
                } else if canBookManagerSiteAttendance {
                    ManagerScheduleContentView()
                        .environmentObject(firebaseBackend)
                        .environmentObject(managerScheduleStore)
                        .environmentObject(projectStore)
                        .environmentObject(bookingStore)
                        .environmentObject(operativeStore)
                        .environmentObject(userStore)
                        .environmentObject(holidayStore)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Office and site attendance booking is only available to administrators and managers.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("My Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            managerScheduleStore.loadData()
        }
    }
}

// MARK: - Manager / Admin: book into site or office (AM, PM, Full Day)

struct ManagerScheduleContentView: View {
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var holidayStore: HolidayStore

    private let calendar = Calendar.current
    @State private var weekStart: Date = Date()
    @State private var selectedDate: Date?
    /// Expanded "Book yourself in" item: true = Office, non-nil UUID = that project/small work (only one expanded at a time).
    @State private var expandedOffice = false
    @State private var expandedLocationId: UUID?
    @State private var clashWarning: String?
    @State private var clashWarningFading = false
    @State private var clashWarningWorkItem: DispatchWorkItem?
    @State private var isMultiDaySelectionEnabled = false
    @State private var selectedDates: Set<Date> = []

    private var weekDates: [Date] {
        guard let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var liveProjects: [Project] {
        projectStore.projects.filter { $0.isLive && $0.jobType != .smallWorks }
    }

    private var liveSmallWorks: [Project] {
        projectStore.projects.filter { $0.isLive && $0.jobType == .smallWorks }
    }

    /// Some admins/managers also have an operative profile and can be booked onto projects/small works.
    private func myOperativeBookings(on day: Date) -> [Booking] {
        guard let email = userStore.currentUser.map({ $0.email.lowercased() }),
              let op = operativeStore.allOperatives.first(where: { $0.email.lowercased() == email }) else { return [] }
        return bookingStore.bookings.filter {
            $0.operativeId == op.id &&
            ($0.status == .confirmed || $0.status == .tentative) &&
            calendar.isDate($0.date, inSameDayAs: day)
        }
    }

    private func myHolidayBookings(on day: Date) -> [HolidayBooking] {
        guard let uid = firebaseBackend.currentUser?.uid else { return [] }
        let targetDay = calendar.startOfDay(for: day)
        return holidayStore.myBookings(userId: uid, operativeId: nil)
            .filter { $0.status != .rejected }
            .filter { booking in
                let start = calendar.startOfDay(for: booking.startDate)
                let end = calendar.startOfDay(for: booking.endDate)
                return targetDay >= start && targetDay <= end
            }
            .sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                weekSelector
                dayStrip
                Divider()
                if let day = selectedDate ?? weekDates.first {
                    dayContent(for: day)
                }
            }
            if clashWarning != nil {
                clashWarningTile
                    .opacity(clashWarningFading ? 0 : 1)
                    .animation(.easeOut(duration: 0.4), value: clashWarningFading)
            }
        }
    }

    private var clashWarningTile: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.body)
            Text("Warning - Booking clash")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            Spacer(minLength: 8)
            Button {
                clearClashWarning()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func clearClashWarning() {
        clashWarningWorkItem?.cancel()
        clashWarningWorkItem = nil
        withAnimation(.easeOut(duration: 0.4)) {
            clashWarningFading = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            clashWarning = nil
            clashWarningFading = false
        }
    }

    private func showClashWarning() {
        clashWarningWorkItem?.cancel()
        clashWarningFading = false
        clashWarning = "shown"
        let work = DispatchWorkItem { [self] in
            clearClashWarning()
        }
        clashWarningWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Full day = no other slot that day. AM/PM = no other AM/PM that day; AM+PM different sites is OK.
    private func wouldClash(on date: Date, newSlot: ManagerTimeSlot) -> Bool {
        let existing = managerScheduleStore.myBookings(on: date)
        if existing.isEmpty { return false }
        if newSlot == .fullDay { return true }
        return existing.contains { b in
            if b.timeSlot == .fullDay { return true }
            return b.timeSlot == newSlot
        }
    }

    private var weekSelector: some View {
        HStack {
            Button(action: { moveWeek(by: -1) }) {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            if isMultiDaySelectionEnabled {
                Button("Clear") {
                    selectedDates = []
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
            Spacer()
            Text(weekRangeText)
                .font(.headline)
            Spacer()
            Button(isMultiDaySelectionEnabled ? "Multi-day: On" : "Multi-day") {
                isMultiDaySelectionEnabled.toggle()
                if isMultiDaySelectionEnabled {
                    if let day = selectedDate ?? weekDates.first {
                        selectedDates = [calendar.startOfDay(for: day)]
                    }
                } else {
                    selectedDates = []
                }
            }
            .font(.caption)
            .buttonStyle(.bordered)
            Button(action: { moveWeek(by: 1) }) {
                Image(systemName: "chevron.right")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var weekRangeText: String {
        guard let start = weekDates.first, let end = weekDates.last else { return "" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    private func moveWeek(by delta: Int) {
        if let newStart = calendar.date(byAdding: .weekOfYear, value: delta, to: weekStart) {
            weekStart = newStart
            if let first = weekDates.first {
                selectedDate = first
            }
        }
    }

    private var dayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(weekDates, id: \.self) { date in
                    dayButton(date: date)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private func dayButton(date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate ?? .distantPast)
        let isMultiSelected = selectedDates.contains(calendar.startOfDay(for: date))
        let hasBooking = !managerScheduleStore.myBookings(on: date).isEmpty
        return Button(action: { selectedDate = date }) {
            VStack(spacing: 4) {
                Text(dayLabel(date))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(calendar.component(.day, from: date))")
                    .font(.title2)
                    .fontWeight(isSelected ? .bold : .regular)
                if hasBooking {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 48, height: 64)
            .background(isSelected ? Color.blue.opacity(0.15) : Color(.systemGray6))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isMultiSelected ? Color.indigo : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(TapGesture().onEnded {
            guard isMultiDaySelectionEnabled else { return }
            let key = calendar.startOfDay(for: date)
            if selectedDates.contains(key) {
                selectedDates.remove(key)
            } else {
                selectedDates.insert(key)
            }
        })
    }

    private func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private func dayContent(for day: Date) -> some View {
        let bookings = managerScheduleStore.myBookings(on: day)
        let operativeBookings = myOperativeBookings(on: day)
        let holidayBookings = myHolidayBookings(on: day)
        let isExpandedOffice = expandedOffice
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !holidayBookings.isEmpty {
                    Section {
                        ForEach(holidayBookings) { holiday in
                            HStack {
                                Label("Holiday", systemImage: "sun.max.fill")
                                    .font(.subheadline)
                                    .foregroundColor(.orange)
                                Spacer()
                                Text(holiday.status == .pending ? "Pending" : "Approved")
                                    .font(.caption)
                                    .foregroundColor(holiday.status == .pending ? .orange : .green)
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Your holiday")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                }

                Section {
                    if bookings.isEmpty {
                        Text("No bookings for this day.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(bookings) { b in
                            bookingRow(b: b)
                        }
                    }
                } header: {
                    Text("Your bookings")
                        .font(.title3)
                        .fontWeight(.semibold)
                }

                if !operativeBookings.isEmpty {
                    Section {
                        ForEach(operativeBookings) { b in
                            let p = projectStore.projects.first(where: { $0.id == b.projectId }) ??
                                projectStore.smallWorks.first(where: { $0.id == b.projectId })
                            HStack {
                                Text(b.timeSlot.displayName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.indigo.opacity(0.18))
                                    .cornerRadius(6)
                                Text(p.map { "\($0.jobNumber) \($0.siteName)" } ?? "Project booking")
                                    .font(.body)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Project/Small Works bookings")
                            .font(.headline)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Book yourself in")
                            .font(.title3)
                            .fontWeight(.semibold)
                        // Office: single button, expand to Full Day / AM / PM
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if isExpandedOffice {
                                    expandedOffice = false
                                } else {
                                    expandedOffice = true
                                    expandedLocationId = nil
                                }
                            }
                        } label: {
                            HStack {
                                Text("Office")
                                    .font(.body)
                                Spacer()
                                Image(systemName: isExpandedOffice ? "chevron.down" : "chevron.right")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        if isExpandedOffice {
                            slotButtons(day: day, locationType: .office, locationId: nil)
                        }

                        Text("Projects")
                            .font(.body)
                            .fontWeight(.semibold)
                            .padding(.top, 8)
                        ForEach(liveProjects, id: \.id) { p in
                            expandableLocationRow(
                                title: "\(p.jobNumber) \(p.siteName)",
                                isExpanded: expandedLocationId == p.id && !expandedOffice
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedOffice = false
                                    if expandedLocationId == p.id {
                                        expandedLocationId = nil
                                    } else {
                                        expandedLocationId = p.id
                                    }
                                }
                            }
                            if expandedLocationId == p.id, !expandedOffice {
                                slotButtons(day: day, locationType: .project, locationId: p.id)
                            }
                        }

                        Text("Small Works")
                            .font(.body)
                            .fontWeight(.semibold)
                            .padding(.top, 8)
                        ForEach(liveSmallWorks, id: \.id) { p in
                            expandableLocationRow(
                                title: "\(p.jobNumber) \(p.siteName)",
                                isExpanded: expandedLocationId == p.id && !expandedOffice
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedOffice = false
                                    if expandedLocationId == p.id {
                                        expandedLocationId = nil
                                    } else {
                                        expandedLocationId = p.id
                                    }
                                }
                            }
                            if expandedLocationId == p.id, !expandedOffice {
                                slotButtons(day: day, locationType: .smallWork, locationId: p.id)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bookingRow(b: ManagerSiteBooking) -> some View {
        HStack {
            Text(b.timeSlot.displayName)
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.2))
                .cornerRadius(6)
            locationName(for: b)
                .font(.body)
            Spacer()
            Button {
                Task {
                    await managerScheduleStore.deleteBooking(b)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func expandableLocationRow(title: String, isExpanded: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Color(.systemGray6))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func slotButtons(day: Date, locationType: ManagerLocationType, locationId: UUID?) -> some View {
        HStack(spacing: 14) {
            ForEach([ManagerTimeSlot.fullDay, ManagerTimeSlot.morning, ManagerTimeSlot.afternoon], id: \.self) { slot in
                Button(slot.displayName) {
                    let daysToBook: [Date]
                    if isMultiDaySelectionEnabled, !selectedDates.isEmpty {
                        daysToBook = selectedDates.map { $0 }.sorted()
                    } else {
                        daysToBook = [day]
                    }
                    attemptBook(days: daysToBook, timeSlot: slot, locationType: locationType, locationId: locationId)
                }
                .font(.body)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.blue.opacity(0.12))
                .cornerRadius(10)
            }
        }
        .padding(.leading, 14)
        .padding(.bottom, 12)
    }

    private func attemptBook(days: [Date], timeSlot: ManagerTimeSlot, locationType: ManagerLocationType, locationId: UUID?) {
        for day in days {
            if wouldClash(on: day, newSlot: timeSlot) {
                showClashWarning()
                return
            }
        }
        for day in days {
            saveBooking(date: day, timeSlot: timeSlot, locationType: locationType, locationId: locationId)
        }
    }

    private func locationName(for b: ManagerSiteBooking) -> Text {
        if b.locationType == .office {
            return Text("Office")
        }
        if let id = b.locationId {
            if let p = projectStore.projects.first(where: { $0.id == id }) {
                return Text("\(p.jobNumber) \(p.siteName)")
            }
        }
        return Text("Site")
    }

    private func saveBooking(date: Date, timeSlot: ManagerTimeSlot, locationType: ManagerLocationType, locationId: UUID?) {
        guard let uid = firebaseBackend.currentUser?.uid else { return }
        let b = ManagerSiteBooking(userId: uid, date: date, timeSlot: timeSlot, locationType: locationType, locationId: locationId)
        Task {
            await managerScheduleStore.saveBooking(b)
        }
    }
}

// MARK: - Manager booking sheet (confirm or pick location)

struct ManagerBookingSheet: View {
    let date: Date
    let timeSlot: ManagerTimeSlot
    let locationType: ManagerLocationType
    let locationId: UUID?
    let existingBookings: [ManagerSiteBooking]
    let onSave: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @Environment(\.dismiss) private var dismiss

    private var locationTitle: String {
        if locationType == .office { return "Office" }
        guard let id = locationId, let p = projectStore.projects.first(where: { $0.id == id }) else { return "Site" }
        return "\(p.jobNumber) \(p.siteName)"
    }

    private var alreadyBooked: Bool {
        existingBookings.contains { $0.timeSlot == timeSlot && $0.locationType == locationType && $0.locationId == locationId }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text(locationTitle)
                    .font(.title2)
                Text("\(date, style: .date) · \(timeSlot.displayName)")
                    .foregroundColor(.secondary)
                if alreadyBooked {
                    Text("You're already booked here for this slot.")
                        .foregroundColor(.secondary)
                    Button("Remove booking", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                } else {
                    Button("Confirm booking") {
                        onSave()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Operative: read-only week, swipe weeks, Add to Calendar

struct OperativeScheduleContentView: View {
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var holidayStore: HolidayStore

    private let calendar = Calendar.current
    @State private var weekStart: Date = Date()
    @State private var addToCalendarMessage: String?

    private var currentOperative: Operative? {
        guard let email = userStore.currentUser?.email else { return nil }
        return operativeStore.allOperatives.first { $0.email.lowercased() == email.lowercased() }
    }

    private var weekDates: [Date] {
        guard let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var myBookingsThisWeek: [Booking] {
        guard let op = currentOperative else { return [] }
        return bookingStore.bookings.filter { b in
            b.operativeId == op.id &&
            (b.status == .confirmed || b.status == .tentative) &&
            weekDates.contains { calendar.isDate(b.date, inSameDayAs: $0) }
        }
    }

    private var myApprovedHolidays: [HolidayBooking] {
        guard let userId = userStore.currentUser?.id else { return [] }
        let operativeId = currentOperative?.id
        return holidayStore.myBookings(userId: userId, operativeId: operativeId)
            .filter { $0.status == .approved }
    }

    private func holidayCoversDay(_ date: Date) -> Bool {
        let day = calendar.startOfDay(for: date)
        return myApprovedHolidays.contains { holiday in
            let start = calendar.startOfDay(for: holiday.startDate)
            let end = calendar.startOfDay(for: holiday.endDate)
            return day >= start && day <= end
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            weekNavigation
            weekContent
            addToCalendarButton
        }
        .alert("Calendar", isPresented: .constant(addToCalendarMessage != nil)) {
            Button("OK") { addToCalendarMessage = nil }
        } message: {
            if let msg = addToCalendarMessage { Text(msg) }
        }
    }

    private var weekNavigation: some View {
        HStack {
            Button(action: { moveWeek(-1) }) {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Text(weekRangeText)
                .font(.headline)
            Spacer()
            Button(action: { moveWeek(1) }) {
                Image(systemName: "chevron.right")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
        }
        .padding()
    }

    private var weekRangeText: String {
        guard let start = weekDates.first, let end = weekDates.last else { return "" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    private func moveWeek(_ delta: Int) {
        if let newStart = calendar.date(byAdding: .weekOfYear, value: delta, to: weekStart) {
            weekStart = newStart
        }
    }

    private var weekContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(weekDates, id: \.self) { date in
                    dayRow(date: date)
                }
            }
            .padding()
        }
    }

    private func dayRow(date: Date) -> some View {
        let dayBookings = myBookingsThisWeek.filter { calendar.isDate($0.date, inSameDayAs: date) }
        let isOnHoliday = holidayCoversDay(date)
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMM"
        return VStack(alignment: .leading, spacing: 8) {
            Text(f.string(from: date))
                .font(.headline)
            if isOnHoliday {
                Label("Holiday", systemImage: "sun.max.fill")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }
            if dayBookings.isEmpty && !isOnHoliday {
                Text("No bookings")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(dayBookings) { b in
                    if let project = projectStore.projects.first(where: { $0.id == b.projectId }) ??
                        projectStore.smallWorks.first(where: { $0.id == b.projectId }) {
                        HStack {
                            Text(b.timeSlot.displayName)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(4)
                            Text("\(project.jobNumber) \(project.siteName)")
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var addToCalendarButton: some View {
        Button(action: addCurrentWeekToCalendar) {
            Label("Add this week to Calendar", systemImage: "calendar.badge.plus")
                .frame(maxWidth: .infinity)
                .padding()
        }
        .buttonStyle(.borderedProminent)
        .padding()
    }

    private func addCurrentWeekToCalendar() {
        let eventStore = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .denied {
            addToCalendarMessage = "Calendar access was denied. You can enable it in Settings."
            return
        }
        if status == .notDetermined {
            if #available(iOS 17.0, *) {
                Task {
                    let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
                    await MainActor.run {
                        if granted {
                            performAddToCalendar(eventStore: eventStore)
                        } else {
                            addToCalendarMessage = "Calendar access is needed to add events. Enable it in Settings."
                        }
                    }
                }
            } else {
                eventStore.requestAccess(to: .event) { [self] granted, _ in
                    DispatchQueue.main.async {
                        if granted {
                            performAddToCalendar(eventStore: eventStore)
                        } else {
                            addToCalendarMessage = "Calendar access is needed to add events. Enable it in Settings."
                        }
                    }
                }
            }
            return
        }
        performAddToCalendar(eventStore: eventStore)
    }

    private func performAddToCalendar(eventStore: EKEventStore) {
        guard currentOperative != nil else {
            addToCalendarMessage = "Could not find your operative profile."
            return
        }
        guard !weekDates.isEmpty else { return }
        let cal = Calendar.current
        var added = 0
        for b in myBookingsThisWeek {
            guard let project = projectStore.projects.first(where: { $0.id == b.projectId }) else { continue }
            let event = EKEvent(eventStore: eventStore)
            event.title = "\(project.jobNumber) \(project.siteName) – \(b.timeSlot.displayName)"
            event.startDate = b.date
            event.endDate = cal.date(byAdding: .hour, value: 8, to: b.date) ?? b.date
            event.calendar = eventStore.defaultCalendarForNewEvents
            do {
                try eventStore.save(event, span: .thisEvent)
                added += 1
            } catch {
                addToCalendarMessage = "Could not add some events: \(error.localizedDescription)"
                return
            }
        }
        addToCalendarMessage = added > 0 ? "Added \(added) event(s) to your calendar." : "No bookings this week to add."
    }
}

