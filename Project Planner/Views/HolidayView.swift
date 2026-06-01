//
//  HolidayView.swift
//  Project Planner
//
//  All users: book or request holiday via interactive calendar.
//

import SwiftUI
import FirebaseAuth

private enum HolidayChrome {
    static let canvas = Color(red: 0.97, green: 0.973, blue: 0.98)
    static let ink = Color(red: 0.043, green: 0.063, blue: 0.125)
    static let muted = Color(red: 0.42, green: 0.447, blue: 0.502)
    static let border = Color(red: 0.933, green: 0.941, blue: 0.953)
    static let accent = Color(red: 0.094, green: 0.373, blue: 0.647)
    static let taken = Color(red: 0.133, green: 0.545, blue: 0.318)
    static let pending = Color(red: 0.98, green: 0.62, blue: 0.09)
    /// Approved half-day on the booking calendar (distinct from pending request orange).
    static let halfDayBooked = Color(red: 0.95, green: 0.52, blue: 0.12)
}

struct HolidayView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var appSettings: AppSettingsStore

    var showRequests: Bool = false
    /// When `true`, the back chevron calls `dismiss()` (sheet from home / notifications). When `false`, posts `goBackToPreviousTab` (bottom-bar Holiday tab).
    var presentedAsSheet: Bool = false

    private var isOperativeMode: Bool { userStore.isOperativeMode() }
    private var isManagerRequestMode: Bool {
        guard let u = userStore.displayUser else { return false }
        if u.permissions.operativeMode { return false }
        if userStore.hasAdminAccess() { return false }
        return u.permissions.manager && !u.permissions.annualLeaveSelfBook
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
    @State private var selectedHolidayTimeSlot: HolidayTimeSlot = .fullDay
    @State private var showSelfServeBookedAnnualLeaveSheet = false
    @State private var halfDayBookingEditor: HolidayBooking?

    enum HolidaySection: String, CaseIterable {
        case calendar = "Book"
        case myHoliday = "My Holiday"
        case requests = "Pending"
    }

    private let calendar = Calendar.current

    private var holidayProfileUser: AppUser? {
        guard let uid = firebaseBackend.currentUser?.uid else { return nil }
        return userStore.organizationUsers.first(where: { $0.id == uid }) ?? userStore.currentUser
    }

    private var annualLeaveSummary: AnnualLeaveUsageSummary? {
        guard let u = holidayProfileUser else { return nil }
        let oid = currentOperative?.id
        return AnnualLeavePolicy.usageSummary(
            bookings: holidayStore.bookings,
            profileUserId: u.id,
            operativeId: oid,
            daysPerYear: u.annualLeaveDaysPerYear,
            startMonth: u.annualLeaveYearStartMonth,
            endMonth: u.annualLeaveYearEndMonth,
            carriesOver: u.annualLeaveCarriesOver,
            referenceDate: Date(),
            calendar: calendar
        )
    }

    private var isAnnualLeaveAvailable: Bool {
        holidayProfileUser?.annualLeaveEnabled ?? true
    }

    /// Admins and managers who self-book approved leave without a separate approver.
    private var canShowSelfServeBookedAnnualLeave: Bool {
        guard let u = userStore.displayUser else { return false }
        if u.permissions.operativeMode { return false }
        if userStore.hasAdminAccess() || u.role == .admin { return true }
        return u.permissions.manager && u.permissions.annualLeaveSelfBook
    }

    private var selfBookedApprovedHolidayBookings: [HolidayBooking] {
        guard canShowSelfServeBookedAnnualLeave, let uid = firebaseBackend.currentUser?.uid else { return [] }
        return holidayStore.bookings
            .filter {
                $0.status == .approved &&
                $0.cancellationRequestedAt == nil &&
                $0.userId == uid &&
                !$0.isOperativeRequest
            }
            .sorted { $0.startDate > $1.startDate }
    }

    private enum ApprovedCalendarDayKind {
        case none
        case fullDay
        case halfDay(HolidayBooking)
    }

    private func approvedCalendarDayKind(for day: Date) -> ApprovedCalendarDayKind {
        let dayStart = calendar.startOfDay(for: day)
        guard let uid = firebaseBackend.currentUser?.uid else { return .none }
        let oid = currentOperative?.id
        var halfCandidate: HolidayBooking?
        for booking in holidayStore.bookings {
            guard booking.status == .approved, booking.cancellationRequestedAt == nil else { continue }
            let matchesUser = booking.userId == uid
            let matchesOperative = oid != nil && booking.operativeId == oid
            guard matchesUser || matchesOperative else { continue }
            let start = calendar.startOfDay(for: booking.startDate)
            let end = calendar.startOfDay(for: booking.endDate)
            guard dayStart >= start && dayStart <= end else { continue }
            let singleCalendarDay = calendar.isDate(booking.startDate, inSameDayAs: booking.endDate)
            if booking.timeSlot == .fullDay || !singleCalendarDay {
                return .fullDay
            }
            halfCandidate = booking
        }
        if let b = halfCandidate { return .halfDay(b) }
        return .none
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: {
                    if presentedAsSheet {
                        dismiss()
                    } else {
                        NotificationCenter.default.post(name: NSNotification.Name("goBackToPreviousTab"), object: nil)
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(HolidayChrome.accent)
                        .font(.system(size: 17, weight: .semibold))
                }
                Spacer()
                Text("Annual leave")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(HolidayChrome.ink)
                Spacer()
                Color.clear.frame(width: 20, height: 20)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))

            Group {
                if !isAnnualLeaveAvailable {
                    annualLeaveDisabledPlaceholder
                } else if holidayStore.isLoading && holidayStore.bookings.isEmpty {
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
                        VStack(alignment: .leading, spacing: 20) {
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
                                    Text("My holiday").tag(HolidaySection.myHoliday)
                                    Text("Pending").tag(HolidaySection.requests)
                                }
                                .pickerStyle(.segmented)
                                .tint(HolidayChrome.accent)
                            }

                            switch activeSection {
                            case .calendar:
                                if let summary = annualLeaveSummary {
                                    leaveUsageHero(summary: summary)
                                }
                                if canShowSelfServeBookedAnnualLeave {
                                    Button {
                                        showSelfServeBookedAnnualLeaveSheet = true
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "list.bullet.rectangle.portrait.fill")
                                                .font(.body.weight(.semibold))
                                            Text("Booked annual leave")
                                                .font(.subheadline.weight(.semibold))
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(HolidayChrome.muted)
                                        }
                                        .foregroundStyle(HolidayChrome.ink)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(Color.white)
                                                .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(HolidayChrome.border, lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                                calendarSection
                            case .myHoliday:
                                myHolidaySection
                            case .requests:
                                holidayRequestsSection
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(HolidayChrome.canvas)
                    .refreshable {
                        if userStore.isOperativeMode() {
                            operativeStore.loadData()
                        }
                        await holidayStore.loadData()
                        await notificationService.loadNotifications()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            if showRequests { activeSection = .requests }
            // Segmented control hidden for this mode — stay on Book so we never drive a Picker with a stale selection.
            if !(isRequestMode || canApproveRequests), activeSection != .calendar {
                activeSection = .calendar
            }
            if userStore.isOperativeMode() {
                operativeStore.loadData()
            }
            Task { await holidayStore.loadData() }
        }
        .onChange(of: userStore.currentUser?.id) { _, _ in
            if !(isRequestMode || canApproveRequests), activeSection != .calendar {
                activeSection = .calendar
            }
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
        .sheet(isPresented: $showSelfServeBookedAnnualLeaveSheet) {
            selfServeBookedAnnualLeaveSheet
        }
        .sheet(item: $halfDayBookingEditor) { booking in
            HalfDayHolidayBookingEditorSheet(
                booking: booking,
                onSave: { updated in
                    Task {
                        let slotViolation: String? = await MainActor.run {
                            guard let u = holidayProfileUser else { return nil }
                            return AnnualLeavePolicy.validateTimeSlotIncreaseAgainstAllowance(
                                booking: booking,
                                newTimeSlot: updated.timeSlot,
                                bookings: holidayStore.bookings,
                                profileUserId: u.id,
                                operativeId: currentOperative?.id,
                                daysPerYear: u.annualLeaveDaysPerYear,
                                startMonth: u.annualLeaveYearStartMonth,
                                endMonth: u.annualLeaveYearEndMonth,
                                carriesOver: u.annualLeaveCarriesOver,
                                calendar: calendar
                            )
                        }
                        if let slotViolation {
                            await MainActor.run {
                                errorMessage = slotViolation
                                showError = true
                            }
                            return
                        }
                        do {
                            try await holidayStore.saveBooking(updated)
                            await MainActor.run {
                                halfDayBookingEditor = nil
                                successMessage = "Leave updated."
                                showSuccess = true
                            }
                        } catch {
                            await MainActor.run {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    }
                },
                onCancel: { halfDayBookingEditor = nil }
            )
        }
    }

    private var annualLeaveDisabledPlaceholder: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 24)
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(HolidayChrome.muted)
            Text("Annual leave is turned off")
                .font(.title3.weight(.semibold))
                .foregroundStyle(HolidayChrome.ink)
                .multilineTextAlignment(.center)
            Text("Your organisation has disabled annual leave for this account. Ask an administrator or your line manager to turn it back on in Manage users if that is a mistake.")
                .font(.subheadline)
                .foregroundStyle(HolidayChrome.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HolidayChrome.canvas)
    }

    private var selfServeBookedAnnualLeaveSheet: some View {
        NavigationStack {
            List {
                Section {
                    if selfBookedApprovedHolidayBookings.isEmpty {
                        Text("No booked annual leave.")
                            .foregroundStyle(HolidayChrome.muted)
                    } else {
                        ForEach(selfBookedApprovedHolidayBookings) { booking in
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(booking.startDate.formatted(date: .abbreviated, time: .omitted)) – \(booking.endDate.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(HolidayChrome.ink)
                                    Text(booking.timeSlot.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(HolidayChrome.muted)
                                }
                                Spacer(minLength: 8)
                                Button {
                                    Task { await holidayStore.deleteBooking(booking) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(Color.red.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove booking")
                            }
                            .listRowBackground(Color.white)
                        }
                    }
                } footer: {
                    Text("These days are already approved. Remove a row to delete that booking without a separate approval step.")
                        .font(.caption)
                        .foregroundStyle(HolidayChrome.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(HolidayChrome.canvas)
            .navigationTitle("Booked annual leave")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showSelfServeBookedAnnualLeaveSheet = false }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func leaveUsageHero(summary: AnnualLeaveUsageSummary) -> some View {
        let usedPortion = summary.entitlementDays > 0
            ? min(1, (summary.takenDays + summary.pendingDays) / summary.entitlementDays)
            : 0
        return VStack(alignment: .leading, spacing: 12) {
            Text("Current leave year")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HolidayChrome.muted)
            Text(summary.leaveYearLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HolidayChrome.ink)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remaining")
                        .font(.caption2)
                        .foregroundStyle(HolidayChrome.muted)
                    Text(formatLeaveDays(summary.remainingDays))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(HolidayChrome.ink)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Allowance")
                        .font(.caption2)
                        .foregroundStyle(HolidayChrome.muted)
                    Text(formatLeaveDays(summary.entitlementDays))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(HolidayChrome.accent)
                }
            }
            HStack(spacing: 0) {
                heroMetric(title: "Taken", value: summary.takenDays, color: HolidayChrome.taken)
                heroMetric(title: "Pending", value: summary.pendingDays, color: HolidayChrome.pending)
            }
            ProgressView(value: usedPortion, total: 1)
                .tint(HolidayChrome.accent)
            if summary.carryOverDays > 0.001 {
                Text("Includes \(formatLeaveDays(summary.carryOverDays)) carried forward")
                    .font(.caption2)
                    .foregroundStyle(HolidayChrome.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.94, blue: 0.90),
                            Color(red: 0.96, green: 0.97, blue: 0.99),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(HolidayChrome.border, lineWidth: 1)
        )
    }

    private func heroMetric(title: String, value: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(HolidayChrome.muted)
            Text(formatLeaveDays(value))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatLeaveDays(_ d: Double) -> String {
        if abs(d - floor(d + 0.0001)) < 0.02 {
            return String(Int((d * 2).rounded() / 2))
        }
        return String(format: "%.1f", d)
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            monthNavigation
            calendarGrid
            selectedRangeSummary
            if let allowanceMsg = selectionAllowanceViolationMessage {
                Text(allowanceMsg)
                    .font(.footnote)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                .foregroundStyle(HolidayChrome.ink)
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
        .foregroundStyle(HolidayChrome.accent)
    }

    private func monthYearString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    private var calendarGrid: some View {
        let days = daysInDisplayedMonth()
        let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { d in
                    Text(d)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(HolidayChrome.muted)
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HolidayChrome.border, lineWidth: 1)
        )
    }

    private func dayCell(date: Date) -> some View {
        let day = calendar.startOfDay(for: date)
        let isSelected = selectedDates.contains(day)
        let isInMonth = calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        let approvedKind = approvedCalendarDayKind(for: day)
        let approvedFullDayLocksCell: Bool = {
            if case .fullDay = approvedKind { return true }
            return false
        }()

        return Button {
            switch approvedKind {
            case .fullDay:
                break
            case .halfDay(let b):
                halfDayBookingEditor = b
            case .none:
                let sod = calendar.startOfDay(for: day)
                if selectedDates.contains(sod) {
                    selectedDates.remove(sod)
                } else {
                    var trial = selectedDates
                    trial.insert(sod)
                    if let violation = allowanceViolationForProposedSelection(trial) {
                        errorMessage = violation
                        showError = true
                    } else {
                        selectedDates = trial
                    }
                }
            }
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.subheadline)
                .fontWeight(isSelected ? .bold : .regular)
                .foregroundStyle(
                    isInMonth
                        ? (isSelected ? Color.white : HolidayChrome.ink)
                        : HolidayChrome.muted
                )
                .frame(width: 36, height: 36)
                .background(
                    Group {
                        if isSelected {
                            HolidayChrome.accent
                        } else if isToday {
                            HolidayChrome.border
                        } else if case .fullDay = approvedKind {
                            HolidayChrome.taken.opacity(0.55)
                        } else if case .halfDay = approvedKind {
                            HolidayChrome.halfDayBooked.opacity(0.35)
                        } else {
                            Color.clear
                        }
                    }
                )
                .overlay(
                    Group {
                        if case .halfDay = approvedKind {
                            Circle()
                                .stroke(HolidayChrome.halfDayBooked, lineWidth: 2)
                        }
                    }
                )
                .clipShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(approvedFullDayLocksCell)
    }

    private func daysInDisplayedMonth() -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) else { return [] }
        let firstWeekdayRaw = calendar.component(.weekday, from: first)
        let firstWeekday = (firstWeekdayRaw + 5) % 7
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
                    Spacer()
                    Text(selectedHolidayTimeSlot.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                    Text("\(day.formatted(date: .abbreviated, time: .omitted)) (\(selectedHolidayTimeSlot.rawValue))")
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

    /// Validates selected calendar days + duration against current/pending usage (per leave year).
    private func allowanceViolationForProposedSelection(_ startOfDays: Set<Date>) -> String? {
        guard let u = holidayProfileUser else { return nil }
        let sorted = startOfDays.sorted()
        guard !sorted.isEmpty else { return nil }
        return AnnualLeavePolicy.validateProposedDayBookingsAgainstAllowance(
            selectedStartOfDays: sorted,
            timeSlot: selectedHolidayTimeSlot,
            bookings: holidayStore.bookings,
            profileUserId: u.id,
            operativeId: currentOperative?.id,
            daysPerYear: u.annualLeaveDaysPerYear,
            startMonth: u.annualLeaveYearStartMonth,
            endMonth: u.annualLeaveYearEndMonth,
            carriesOver: u.annualLeaveCarriesOver,
            calendar: calendar
        )
    }

    private var selectionAllowanceViolationMessage: String? {
        allowanceViolationForProposedSelection(selectedDates)
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
            let allowanceViolation = await MainActor.run {
                let normalizedSelection = Set(selectedDays.map { calendar.startOfDay(for: $0) })
                return allowanceViolationForProposedSelection(normalizedSelection)
            }
            if let allowanceViolation {
                await MainActor.run {
                    errorMessage = allowanceViolation
                    showError = true
                    isSaving = false
                }
                return
            }
            do {
                if isOperativeMode {
                    guard let uid = firebaseBackend.currentUser?.uid else {
                        await MainActor.run {
                            errorMessage = "Not signed in."
                            showError = true
                            isSaving = false
                        }
                        return
                    }
                    // Prefer linked operative roster row (email match) for operativeId; otherwise userId-only booking is valid.
                    let operative = currentOperative
                    let operativeId = operative?.id
                    let operativeDisplayName: String = {
                        if let o = operative {
                            let n = "\(o.firstName) \(o.lastName)".trimmingCharacters(in: .whitespaces)
                            return n.isEmpty ? (userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Operative") : n
                        }
                        return userStore.currentUser?.fullName
                            ?? userStore.currentUser?.email
                            ?? "Operative"
                    }()
                    for day in selectedDays {
                        if hasExistingHoliday(on: day, userId: uid, operativeId: operativeId) {
                            throw NSError(domain: "Holiday", code: 409, userInfo: [NSLocalizedDescriptionKey: "One or more selected days already have a holiday booking/request."])
                        }
                    }
                    var createdBookingIds: [UUID] = []
                    for day in selectedDays {
                        let booking = HolidayBooking(
                            organizationId: orgId,
                            userId: uid,
                            operativeId: operativeId,
                            startDate: day,
                            endDate: day,
                            status: .pending,
                            timeSlot: selectedHolidayTimeSlot
                        )
                        try await holidayStore.saveBooking(booking)
                        createdBookingIds.append(booking.id)
                    }
                    if let firstBookingId = createdBookingIds.first,
                       let startDate = selectedDays.first,
                       let endDate = selectedDays.last {
                        await notificationService.notifyHolidayRequestSubmitted(
                            bookingId: firstBookingId,
                            operativeName: operativeDisplayName,
                            startDate: startDate,
                            endDate: endDate,
                            assignedManagerUserId: effectiveAssignedManagerUserIdForCurrentUser(),
                            excludeUserIdMatchingRequester: uid
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
                            status: isManagerRequestMode ? .pending : .approved,
                            timeSlot: selectedHolidayTimeSlot
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
                            requesterUserId: uid,
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Duration")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HolidayChrome.muted)
            HStack(spacing: 8) {
                durationChip(.fullDay, label: "Full day")
                durationChip(.morning, label: "AM")
                durationChip(.afternoon, label: "PM")
            }
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
                        Text(isRequestMode ? "Submit request" : "Confirm booking")
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(!selectedDates.isEmpty ? HolidayChrome.accent : Color.gray.opacity(0.45))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(selectedDates.isEmpty || isSaving || selectionAllowanceViolationMessage != nil)
        }
    }

    private func durationChip(_ slot: HolidayTimeSlot, label: String) -> some View {
        let on = selectedHolidayTimeSlot == slot
        return Button {
            selectedHolidayTimeSlot = slot
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(on ? HolidayChrome.accent.opacity(0.15) : Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(on ? HolidayChrome.accent : HolidayChrome.border, lineWidth: on ? 1.5 : 1)
                )
                .foregroundStyle(on ? HolidayChrome.accent : HolidayChrome.ink)
        }
        .buttonStyle(.plain)
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
            if requester.permissions.manager &&
                !requester.permissions.annualLeaveSelfBook &&
                !requester.permissions.operativeMode &&
                !requester.isSuperAdmin &&
                !requester.permissions.adminAccess &&
                requester.role != .admin {
                return nil
            }
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
            if approved,
               let requester = userStore.organizationUsers.first(where: { $0.id == requesterUserId }),
               requester.permissions.manager,
               !requester.permissions.annualLeaveSelfBook,
               !requester.permissions.operativeMode,
               !requester.isSuperAdmin,
               !requester.permissions.adminAccess,
               requester.role != .admin {
                await notificationService.notifyAdminAnnualLeaveApproval(
                    managerName: requester.fullName,
                    approvedByName: decidedByName,
                    excludingUserId: firebaseBackend.currentUser?.uid
                )
            }
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
                print("🔥🔥🔥 DEBUG: [HOLIDAY MANAGER RESOLVE] user=\(current.id) manager(from org users)=\(managerId ?? "")")
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
                assignedManagerUserId: effectiveAssignedManagerUserIdForCurrentUser(),
                excludeUserIdMatchingRequester: uid
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

private struct HalfDayHolidayBookingEditorSheet: View {
    let booking: HolidayBooking
    let onSave: (HolidayBooking) -> Void
    let onCancel: () -> Void
    @State private var draftSlot: HolidayTimeSlot

    init(booking: HolidayBooking, onSave: @escaping (HolidayBooking) -> Void, onCancel: @escaping () -> Void) {
        self.booking = booking
        self.onSave = onSave
        self.onCancel = onCancel
        _draftSlot = State(initialValue: booking.timeSlot)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Duration", selection: $draftSlot) {
                        ForEach(HolidayTimeSlot.allCases, id: \.self) { slot in
                            Text(slot.rawValue).tag(slot)
                        }
                    }
                    .pickerStyle(.inline)
                } footer: {
                    Text("Choose full day, AM, or PM. Full days appear solid green on the calendar; half days are orange until you switch to a full day.")
                        .font(.caption)
                }
            }
            .navigationTitle("Update booking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = booking
                        updated.timeSlot = draftSlot
                        onSave(updated)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
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
                Text(booking.timeSlot.rawValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
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
            Text(request.timeSlot.rawValue)
                .font(.caption2)
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
