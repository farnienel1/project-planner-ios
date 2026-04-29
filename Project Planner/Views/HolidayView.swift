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
    private var canApproveRequests: Bool {
        guard let u = userStore.displayUser else { return false }
        if u.permissions.operativeMode { return false }
        if u.permissions.manager { return true }
        return userStore.hasAdminAccess() && showRequests
    }

    @State private var displayedMonth: Date = Date()
    @State private var selectedDates: Set<Date> = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var successMessage: String?
    @State private var showSuccess = false
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
                    VStack(spacing: 12) {
                        ProgressView("Loading…")
                        if let msg = holidayStore.errorMessage, !msg.isEmpty {
                            Text(msg)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        Button("Retry") {
                            Task { await holidayStore.loadData() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if let msg = holidayStore.errorMessage, !msg.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Some holiday data could not be synced.")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text(msg)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                    Button("Retry") {
                                        Task { await holidayStore.loadData() }
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                            }
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
                    .refreshable {
                        await holidayStore.loadData()
                        await notificationService.loadNotifications()
                    }
                }
            }
            .navigationTitle("Annual Leave")
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
            .alert("Success", isPresented: $showSuccess) {
                Button("OK") { showSuccess = false }
            } message: {
                if let msg = successMessage { Text(msg) }
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
        let day = calendar.startOfDay(for: date)
        let isSelected = selectedDates.contains(day)
        let isInMonth = calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        return Button {
            if selectedDates.contains(day) {
                selectedDates.remove(day)
            } else {
                selectedDates.insert(day)
            }
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.subheadline)
                .fontWeight(isSelected ? .bold : .regular)
                .foregroundColor(isInMonth ? (isSelected ? .white : .primary) : .secondary)
                .frame(width: 36, height: 36)
                .background(
                    Group {
                        if isSelected {
                            Color.theme.primary(for: appSettings.settings.colorScheme)
                        } else if isToday {
                            Color.gray.opacity(0.35)
                        } else {
                            Color.clear
                        }
                    }
                )
                .clipShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
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
            let sorted = selectedDates.sorted()
            if let first = sorted.first, let last = sorted.last {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(.secondary)
                    if sorted.count == 1 {
                        Text(first.formatted(date: .abbreviated, time: .omitted))
                            .font(.subheadline)
                    } else {
                        Text("\(sorted.count) days selected (\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted)))")
                            .font(.subheadline)
                    }
                }
            } else {
                Text("Tap each day you want to book")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var selectedDatesPreview: some View {
        let sorted = selectedDates.sorted()
        return VStack(alignment: .leading, spacing: 8) {
            if sorted.isEmpty {
                EmptyView()
            } else {
                Text("Selected days")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                ForEach(sorted, id: \.self) { day in
                    Text(day.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var selectedDatesSorted: [Date] {
        selectedDates.sorted()
    }

    private func hasExistingHoliday(on day: Date, userId: String?, operativeId: UUID?) -> Bool {
        holidayStore.bookings.contains { booking in
            guard booking.status != .rejected else { return false }
            let matchesUser = userId != nil && booking.userId == userId
            let matchesOperative = operativeId != nil && booking.operativeId == operativeId
            guard matchesUser || matchesOperative else {
                return false
            }
            let target = calendar.startOfDay(for: day)
            let start = calendar.startOfDay(for: booking.startDate)
            let end = calendar.startOfDay(for: booking.endDate)
            return target >= start && target <= end
        }
    }

    private func clearSelection() {
        selectedDates.removeAll()
    }

    private func submitHoliday() {
        let selectedDays = selectedDatesSorted
        guard !selectedDays.isEmpty else { return }
        let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId
            ?? userStore.currentUser?.organizationId
            ?? ""
        guard !orgId.isEmpty else {
            errorMessage = "Organization not loaded yet. Please try again in a moment."
            showError = true
            return
        }

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
                    guard let uid = firebaseBackend.currentUser?.uid else {
                        await MainActor.run {
                            errorMessage = "Not signed in."
                            showError = true
                            isSaving = false
                        }
                        return
                    }
                    for day in selectedDays {
                        if hasExistingHoliday(on: day, userId: uid, operativeId: operative.id) {
                            throw NSError(domain: "Holiday", code: 409, userInfo: [NSLocalizedDescriptionKey: "One or more selected days already have a holiday booking/request."])
                        }
                    }
                    var createdBookingIds: [UUID] = []
                    for day in selectedDays {
                        let booking = HolidayBooking(
                            organizationId: orgId,
                            userId: uid,
                            operativeId: operative.id,
                            startDate: day,
                            endDate: day,
                            status: .pending
                        )
                        try await holidayStore.saveBooking(booking)
                        createdBookingIds.append(booking.id)
                    }
                    if let firstBookingId = createdBookingIds.first,
                       let startDate = selectedDays.first,
                       let endDate = selectedDays.last {
                        await notificationService.notifyHolidayRequestSubmitted(
                            bookingId: firstBookingId,
                            operativeName: operative.firstName + " " + operative.lastName,
                            startDate: startDate,
                            endDate: endDate,
                            assignedManagerUserId: effectiveAssignedManagerUserIdForCurrentUser()
                        )
                    }
                    await MainActor.run {
                        successMessage = "Holiday request submitted for \(selectedDays.count) day\(selectedDays.count == 1 ? "" : "s")."
                        showSuccess = true
                    }
                } else {
                    guard let uid = firebaseBackend.currentUser?.uid else {
                        await MainActor.run {
                            errorMessage = "Not signed in."
                            showError = true
                            isSaving = false
                        }
                        return
                    }
                    for day in selectedDays {
                        if hasExistingHoliday(on: day, userId: uid, operativeId: nil) {
                            throw NSError(domain: "Holiday", code: 409, userInfo: [NSLocalizedDescriptionKey: "One or more selected days already have a holiday booking/request."])
                        }
                    }
                    var firstBookingId: UUID?
                    for day in selectedDays {
                        let booking = HolidayBooking(
                            organizationId: orgId,
                            userId: uid,
                            operativeId: nil,
                            startDate: day,
                            endDate: day,
                            status: isManagerRequestMode ? .pending : .approved
                        )
                        try await holidayStore.saveBooking(booking)
                        firstBookingId = firstBookingId ?? booking.id
                    }
                    if isManagerRequestMode,
                       let bookingId = firstBookingId,
                       let startDate = selectedDays.first,
                       let endDate = selectedDays.last {
                        let requesterName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Manager"
                        await notificationService.notifyHolidayRequestSubmittedByUser(
                            bookingId: bookingId,
                            requesterName: requesterName,
                            startDate: startDate,
                            endDate: endDate,
                            assignedManagerUserId: effectiveAssignedManagerUserIdForCurrentUser()
                        )
                    }
                    await MainActor.run {
                        if isManagerRequestMode {
                            successMessage = "Holiday request submitted for \(selectedDays.count) day\(selectedDays.count == 1 ? "" : "s")."
                        } else {
                            successMessage = "Holiday booked for \(selectedDays.count) day\(selectedDays.count == 1 ? "" : "s")."
                        }
                        showSuccess = true
                    }
                }
                await MainActor.run {
                    clearSelection()
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

    private var submitButton: some View {
        VStack(alignment: .leading, spacing: 12) {
            selectedDatesPreview
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
                .background(!selectedDates.isEmpty ? Color.theme.primary(for: appSettings.settings.colorScheme) : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(selectedDates.isEmpty || isSaving)
        }
    }

    private var currentOperative: Operative? {
        guard let email = userStore.currentUser?.email else { return nil }
        return operativeStore.allOperatives.first { $0.email.lowercased() == email.lowercased() }
    }

    private var myHolidaySection: some View {
        let myBookings = myBookingsList
        return VStack(alignment: .leading, spacing: 12) {
            Text("My annual leave")
                .font(.headline)
            if myBookings.isEmpty {
                Text("No annual leave booked.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ForEach(myBookings) { b in
                    HolidayRowView(
                        booking: b,
                        onRequestCancellation: canRequestCancellation(for: b) ? { requestCancellation(for: b) } : nil
                    )
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
                let requests = approverPendingRequests
                if requests.isEmpty {
                    Text("No pending requests.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(requests) { request in
                        HolidayRequestRowView(
                            request: request,
                            requesterName: requesterName(for: request),
                            conflictingApprovedOperatives: conflictingApprovedOperatives(for: request),
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

    private var approverPendingRequests: [HolidayBooking] {
        guard let me = userStore.currentUser else { return [] }
        let all = holidayStore.pendingRequests.sorted { $0.startDate > $1.startDate }
        // Managers only approve requests assigned to them.
        if me.permissions.manager && !me.isSuperAdmin && !me.permissions.adminAccess && me.role != .admin {
            return all.filter { assignedApproverUserId(for: $0) == me.id }
        }
        // Admin/super-admin can approve unassigned requests (fallback) and requests assigned directly to them.
        if userStore.hasAdminAccess() {
            return all.filter {
                let assigned = assignedApproverUserId(for: $0)
                return assigned == nil || assigned == me.id
            }
        }
        return []
    }

    private func assignedApproverUserId(for request: HolidayBooking) -> String? {
        if let uid = request.userId,
           let requester = userStore.organizationUsers.first(where: { $0.id == uid }) {
            let managerId = requester.assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (managerId?.isEmpty == false) ? managerId : nil
        }
        if let oid = request.operativeId,
           let op = operativeStore.allOperatives.first(where: { $0.id == oid }),
           let requester = userStore.organizationUsers.first(where: {
               ($0.permissions.operativeMode || $0.role == .operative) &&
               $0.email.lowercased() == op.email.lowercased()
           }) {
            let managerId = requester.assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (managerId?.isEmpty == false) ? managerId : nil
        }
        return nil
    }

    private func approveRequest(_ request: HolidayBooking) {
        guard let uid = firebaseBackend.currentUser?.uid else { return }
        Task {
            if request.cancellationRequestedAt != nil {
                await holidayStore.deleteBooking(request)
                let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Manager"
                await notificationService.notifyHolidayRequestDecisionToUser(
                    userId: request.userId ?? uid,
                    bookingId: request.id,
                    approved: true,
                    decidedByName: "\(approverName) approved your annual leave cancellation"
                )
                return
            } else {
                await holidayStore.approveBooking(request, approvedByUserId: uid)
            }
            let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Admin"
            await notifyDecision(to: request, approved: true, decidedByName: approverName)
        }
    }

    private func declineRequest(_ request: HolidayBooking) {
        if request.cancellationRequestedAt != nil { return }
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
           let operativeUser = userStore.organizationUsers.first(where: {
               ($0.permissions.operativeMode || $0.role == .operative) &&
               $0.email.lowercased() == op.email.lowercased()
           }) {
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

    private func effectiveAssignedManagerUserIdForCurrentUser() -> String? {
        guard let current = userStore.currentUser else { return nil }
        if let latest = userStore.organizationUsers.first(where: { $0.id == current.id }) {
            let managerId = latest.assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines)
            if managerId?.isEmpty == false {
                print("🔥🔥🔥 DEBUG: [HOLIDAY MANAGER RESOLVE] user=\(current.id) manager(from org users)=\(managerId!)")
                return managerId
            }
        }
        let fallback = current.assignedManagerUserId?.trimmingCharacters(in: .whitespacesAndNewlines)
        print("🔥🔥🔥 DEBUG: [HOLIDAY MANAGER RESOLVE] user=\(current.id) manager(from current user)=\(fallback ?? "nil")")
        return (fallback?.isEmpty == false) ? fallback : nil
    }

    private func canRequestCancellation(for booking: HolidayBooking) -> Bool {
        booking.status == .approved && booking.cancellationRequestedAt == nil
    }

    private func requestCancellation(for booking: HolidayBooking) {
        guard let uid = firebaseBackend.currentUser?.uid else { return }
        Task {
            await holidayStore.requestCancellation(booking, by: uid)
            await notificationService.notifyHolidayRequestSubmitted(
                bookingId: booking.id,
                operativeName: requesterName(for: booking),
                startDate: booking.startDate,
                endDate: booking.endDate,
                assignedManagerUserId: effectiveAssignedManagerUserIdForCurrentUser()
            )
        }
    }

    private func conflictingApprovedOperatives(for request: HolidayBooking) -> [String] {
        guard request.cancellationRequestedAt == nil else { return [] }
        guard let myManagerId = assignedApproverUserId(for: request) else { return [] }
        return holidayStore.bookings
            .filter { $0.id != request.id && $0.status == .approved && $0.cancellationRequestedAt == nil }
            .filter { booking in
                assignedApproverUserId(for: booking) == myManagerId &&
                booking.startDate <= request.endDate &&
                booking.endDate >= request.startDate
            }
            .compactMap { booking in
                if let uid = booking.userId,
                   let user = userStore.organizationUsers.first(where: { $0.id == uid }) {
                    return user.fullName
                }
                if let oid = booking.operativeId,
                   let operative = operativeStore.allOperatives.first(where: { $0.id == oid }) {
                    return "\(operative.firstName) \(operative.lastName)"
                }
                return nil
            }
    }
}

struct HolidayRowView: View {
    let booking: HolidayBooking
    var onRequestCancellation: (() -> Void)? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(booking.startDate.formatted(date: .abbreviated, time: .omitted)) – \(booking.endDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)
                if let onRequestCancellation {
                    Button("Request cancellation") {
                        onRequestCancellation()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                } else if booking.cancellationRequestedAt != nil {
                    Text("Cancellation pending manager approval")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    private var statusText: String {
        if booking.cancellationRequestedAt != nil {
            return "Cancellation requested"
        }
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
    let conflictingApprovedOperatives: [String]
    let canApprove: Bool
    let onApprove: () -> Void
    let onDecline: () -> Void
    @State private var showConflicts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(requesterName)
                    .font(.headline)
                if !conflictingApprovedOperatives.isEmpty {
                    Button {
                        showConflicts = true
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                }
            }
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
                    if request.cancellationRequestedAt == nil {
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
        .alert("Annual Leave Overlap", isPresented: $showConflicts) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conflictingApprovedOperatives.joined(separator: "\n"))
        }
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
