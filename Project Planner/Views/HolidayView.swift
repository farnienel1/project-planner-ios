//
//  HolidayView.swift
//  Project Planner
//
//  All users: book or request holiday via interactive calendar.
//

import SwiftUI
import FirebaseAuth

struct HolidayView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var appSettings: AppSettingsStore

    var showRequests: Bool = false

    private var isOperativeMode: Bool { userStore.isOperativeMode() }
    private var isManagerRequestMode: Bool {
        guard let u = userStore.displayUser else { return false }
        if u.permissions.operativeMode { return false }
        if userStore.hasAdminAccess() { return false }
        return u.permissions.manager
    }
    private var isRequestMode: Bool { isOperativeMode || isManagerRequestMode }
    // Admins don't show Requests by default. Requests section becomes available only when opened from a notification.
    private var canApproveRequests: Bool { userStore.hasAdminAccess() && showRequests }

    @State private var displayedMonth: Date = Date()
    @State private var selectedStart: Date?
    @State private var selectedEnd: Date?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var activeSection: HolidaySection = .calendar

    enum HolidaySection: String, CaseIterable {
        case calendar = "Book"
        case myHoliday = "My Holiday"
        case requests = "Pending"
    }

    private let calendar = Calendar.current

    var body: some View {
        NavigationView {
            Group {
                if holidayStore.isLoading && holidayStore.bookings.isEmpty {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if isRequestMode || canApproveRequests {
                                Picker("Section", selection: $activeSection) {
                                    Text(isRequestMode ? "Request" : "Book").tag(HolidaySection.calendar)
                                    Text("My Holiday").tag(HolidaySection.myHoliday)
                                    Text("Pending").tag(HolidaySection.requests)
                                }
                                .pickerStyle(.segmented)
                            }

                            switch activeSection {
                            case .calendar:
                                calendarSection
                            case .myHoliday:
                                myHolidaySection
                            case .requests:
                                holidayRequestsSection
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Holiday")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                    }
                }
            }
            .onAppear {
                if showRequests { activeSection = .requests }
                Task { await holidayStore.loadData() }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { showError = false }
            } message: {
                if let msg = errorMessage { Text(msg) }
            }
        }
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            monthNavigation
            calendarGrid
            selectedRangeSummary
            submitButton
        }
    }

    private var monthNavigation: some View {
        HStack {
            Button {
                if let newMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) {
                    displayedMonth = newMonth
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Text(monthYearString(displayedMonth))
                .font(.headline)
            Spacer()
            Button {
                if let newMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) {
                    displayedMonth = newMonth
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
        }
    }

    private func monthYearString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    private var calendarGrid: some View {
        let days = daysInDisplayedMonth()
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { d in
                    Text(d)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let date = day {
                        dayCell(date: date)
                    } else {
                        Color.clear
                            .frame(height: 36)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func dayCell(date: Date) -> some View {
        let isInRange = isDateInSelectedRange(date)
        let isStartOrEnd = isStartOrEndDate(date)
        let isInMonth = calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        return Button {
            if selectedStart == nil {
                selectedStart = date
                selectedEnd = date
            } else {
                selectedEnd = date
                if let start = selectedStart, let end = selectedEnd, start > end {
                    selectedStart = end
                    selectedEnd = start
                }
            }
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.subheadline)
                .fontWeight(isStartOrEnd ? .bold : .regular)
                .foregroundColor(isInMonth ? (isStartOrEnd ? .white : .primary) : .secondary)
                .frame(width: 36, height: 36)
                .background(
                    Group {
                        if isStartOrEnd {
                            Color.theme.primary(for: appSettings.settings.colorScheme)
                        } else if isInRange {
                            Color.theme.primary(for: appSettings.settings.colorScheme).opacity(0.3)
                        } else {
                            Color.clear
                        }
                    }
                )
                .clipShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func isDateInSelectedRange(_ date: Date) -> Bool {
        guard let start = selectedStart, let end = selectedEnd else { return false }
        let d = calendar.startOfDay(for: date)
        let s = calendar.startOfDay(for: start)
        let e = calendar.startOfDay(for: end)
        return d >= s && d <= e
    }

    private func isStartOrEndDate(_ date: Date) -> Bool {
        guard let start = selectedStart, let end = selectedEnd else { return false }
        let d = calendar.startOfDay(for: date)
        let s = calendar.startOfDay(for: start)
        let e = calendar.startOfDay(for: end)
        return d == s || d == e
    }

    private func daysInDisplayedMonth() -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: first) - 1
        let totalDays = range.count
        var days: [Date?] = Array(repeating: nil, count: firstWeekday)
        for d in 1...totalDays {
            if let date = calendar.date(byAdding: .day, value: d - 1, to: first) {
                days.append(date)
            }
        }
        return days
    }

    private var selectedRangeSummary: some View {
        Group {
            if let start = selectedStart, let end = selectedEnd {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(.secondary)
                    Text("\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))")
                        .font(.subheadline)
                }
            } else {
                Text("Tap dates to select a range")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var submitButton: some View {
        Button {
            submitHoliday()
        } label: {
            HStack {
                if isSaving {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: isRequestMode ? "paperplane.fill" : "checkmark.circle.fill")
                    Text(isRequestMode ? "Request holiday" : "Book holiday")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(selectedStart != nil && selectedEnd != nil ? Color.theme.primary(for: appSettings.settings.colorScheme) : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(selectedStart == nil || selectedEnd == nil || isSaving)
    }

    private func submitHoliday() {
        guard let start = selectedStart, let end = selectedEnd,
              let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else { return }
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        guard startDay <= endDay else { return }

        isSaving = true
        errorMessage = nil

        Task {
            do {
                if isOperativeMode {
                    guard let operative = currentOperative else {
                        await MainActor.run {
                            errorMessage = "Operative profile not found."
                            showError = true
                            isSaving = false
                        }
                        return
                    }
                    let booking = HolidayBooking(
                        organizationId: orgId,
                        userId: nil,
                        operativeId: operative.id,
                        startDate: startDay,
                        endDate: endDay,
                        status: .pending
                    )
                    try await holidayStore.saveBooking(booking)
                    await notificationService.notifyHolidayRequestSubmitted(
                        bookingId: booking.id,
                        operativeName: operative.firstName + " " + operative.lastName,
                        startDate: startDay,
                        endDate: endDay
                    )
                } else {
                    guard let uid = firebaseBackend.currentUser?.uid else {
                        await MainActor.run {
                            errorMessage = "Not signed in."
                            showError = true
                            isSaving = false
                        }
                        return
                    }
                    let booking = HolidayBooking(
                        organizationId: orgId,
                        userId: uid,
                        operativeId: nil,
                        startDate: startDay,
                        endDate: endDay,
                        status: isManagerRequestMode ? .pending : .approved
                    )
                    try await holidayStore.saveBooking(booking)
                    if isManagerRequestMode {
                        let requesterName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Manager"
                        await notificationService.notifyHolidayRequestSubmittedByUser(
                            bookingId: booking.id,
                            requesterName: requesterName,
                            startDate: startDay,
                            endDate: endDay
                        )
                    }
                }
                await MainActor.run {
                    selectedStart = nil
                    selectedEnd = nil
                    isSaving = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isSaving = false
                }
            }
        }
    }

    private var currentOperative: Operative? {
        guard let email = userStore.currentUser?.email else { return nil }
        return operativeStore.allOperatives.first { $0.email.lowercased() == email.lowercased() }
    }

    private var myHolidaySection: some View {
        let myBookings = myBookingsList
        return VStack(alignment: .leading, spacing: 12) {
            Text("My holiday")
                .font(.headline)
            if myBookings.isEmpty {
                Text("No holiday booked.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ForEach(myBookings) { b in
                    HolidayRowView(booking: b)
                }
            }
        }
    }

    /// Approved holidays only (no pending/rejected placeholders).
    private var myBookingsList: [HolidayBooking] {
        let uid = firebaseBackend.currentUser?.uid
        let oid = currentOperative?.id
        return holidayStore.myBookings(userId: uid, operativeId: oid)
            .filter { $0.status == .approved }
            .sorted { $0.startDate > $1.startDate }
    }
    
    private var myPendingHolidayList: [HolidayBooking] {
        let uid = firebaseBackend.currentUser?.uid
        let oid = currentOperative?.id
        return holidayStore.myBookings(userId: uid, operativeId: oid)
            .filter { $0.status == .pending }
            .sorted { $0.startDate > $1.startDate }
    }

    private var holidayRequestsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pending")
                .font(.headline)
            if canApproveRequests {
                if holidayStore.pendingRequests.isEmpty {
                    Text("No pending requests.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(holidayStore.pendingRequests) { request in
                        HolidayRequestRowView(
                            request: request,
                            requesterName: requesterName(for: request),
                            canApprove: true,
                            onApprove: { approveRequest(request) },
                            onDecline: { declineRequest(request) }
                        )
                    }
                }
            } else {
                let myRequests = myPendingHolidayList
                if myRequests.isEmpty {
                    Text("No requests.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(myRequests) { request in
                        HolidayRowView(booking: request)
                    }
                }
            }
        }
    }

    private func approveRequest(_ request: HolidayBooking) {
        guard let uid = firebaseBackend.currentUser?.uid else { return }
        Task {
            await holidayStore.approveBooking(request, approvedByUserId: uid)
            let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Admin"
            await notifyDecision(to: request, approved: true, decidedByName: approverName)
        }
    }

    private func declineRequest(_ request: HolidayBooking) {
        guard let uid = firebaseBackend.currentUser?.uid else { return }
        Task {
            await holidayStore.rejectBooking(request, rejectedByUserId: uid)
            let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Admin"
            await notifyDecision(to: request, approved: false, decidedByName: approverName)
        }
    }

    private func notifyDecision(to request: HolidayBooking, approved: Bool, decidedByName: String) async {
        if let requesterUserId = request.userId {
            await notificationService.notifyHolidayRequestDecisionToUser(
                userId: requesterUserId,
                bookingId: request.id,
                approved: approved,
                decidedByName: decidedByName
            )
            return
        }
        if let oid = request.operativeId,
           let op = operativeStore.allOperatives.first(where: { $0.id == oid }),
           let operativeUser = userStore.organizationUsers.first(where: { $0.permissions.operativeMode && $0.email.lowercased() == op.email.lowercased() }) {
            await notificationService.notifyHolidayRequestDecisionToUser(
                userId: operativeUser.id,
                bookingId: request.id,
                approved: approved,
                decidedByName: decidedByName
            )
        }
    }

    private func requesterName(for request: HolidayBooking) -> String {
        if let uid = request.userId,
           let u = userStore.organizationUsers.first(where: { $0.id == uid }) {
            return u.fullName
        }
        if let oid = request.operativeId,
           let op = operativeStore.allOperatives.first(where: { $0.id == oid }) {
            return op.firstName + " " + op.lastName
        }
        return "User"
    }
}

struct HolidayRowView: View {
    let booking: HolidayBooking

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(booking.startDate.formatted(date: .abbreviated, time: .omitted)) – \(booking.endDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    private var statusText: String {
        switch booking.status {
        case .pending: return "Pending approval"
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        }
    }

    private var statusColor: Color {
        switch booking.status {
        case .pending: return .orange
        case .approved: return .green
        case .rejected: return .red
        }
    }
}

struct HolidayRequestRowView: View {
    let request: HolidayBooking
    let requesterName: String
    let canApprove: Bool
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(requesterName)
                .font(.headline)
            Text("\(request.startDate.formatted(date: .abbreviated, time: .omitted)) – \(request.endDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if canApprove {
                HStack(spacing: 12) {
                    Button(action: onApprove) {
                        Label("Approve", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.green)
                            .cornerRadius(10)
                    }
                    Button(action: onDecline) {
                        Label("Decline", systemImage: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red)
                            .cornerRadius(10)
                    }
                }
            } else {
                Text("Pending approval")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

#Preview {
    HolidayView()
        .environmentObject(HolidayStore())
        .environmentObject(UserStore())
        .environmentObject(OperativeStore())
        .environmentObject(FirebaseBackend())
        .environmentObject(NotificationService())
        .environmentObject(AppSettingsStore())
}
