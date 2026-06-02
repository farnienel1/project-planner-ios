//
//  OperativeAnnualLeaveViews.swift
//  Project Planner
//
//  Team annual leave directory + per-person calendar for admins and operative managers.
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
    static let pending = Color(red: 0.89, green: 0.22, blue: 0.22)
    static let halfDayBooked = Color(red: 0.95, green: 0.52, blue: 0.12)
}

struct AnnualLeavePerson: Identifiable, Hashable {
    let id: String
    let displayName: String
    let subtitle: String
    let tradeLabel: String
    let firstNameSort: String
    let surnameSort: String
    let userId: String?
    let operativeId: UUID?

    var navigationTitle: String { displayName }
}

private enum AnnualLeavePersonSort: String, CaseIterable, Identifiable {
    case firstName = "First name"
    case surname = "Surname"
    case trade = "Trade"

    var id: String { rawValue }
}

struct OperativeAnnualLeaveDirectoryView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService

    @State private var searchText = ""
    @State private var tradeFilter: String?
    @State private var sortMode: AnnualLeavePersonSort = .firstName

    private var people: [AnnualLeavePerson] {
        AnnualLeavePersonBuilder.build(
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )
    }

    private var tradeChoices: [String] {
        Array(Set(people.map(\.tradeLabel).filter { !$0.isEmpty })).sorted()
    }

    private var filteredPeople: [AnnualLeavePerson] {
        var rows = people
        if let tradeFilter, !tradeFilter.isEmpty {
            rows = rows.filter { $0.tradeLabel == tradeFilter }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            rows = rows.filter {
                $0.displayName.localizedCaseInsensitiveContains(q) ||
                $0.subtitle.localizedCaseInsensitiveContains(q) ||
                $0.tradeLabel.localizedCaseInsensitiveContains(q)
            }
        }
        switch sortMode {
        case .firstName:
            rows.sort { $0.firstNameSort.localizedCaseInsensitiveCompare($1.firstNameSort) == .orderedAscending }
        case .surname:
            rows.sort { $0.surnameSort.localizedCaseInsensitiveCompare($1.surnameSort) == .orderedAscending }
        case .trade:
            rows.sort {
                if $0.tradeLabel != $1.tradeLabel {
                    return $0.tradeLabel.localizedCaseInsensitiveCompare($1.tradeLabel) == .orderedAscending
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
        return rows
    }

    var body: some View {
        List {
            Section {
                Picker("Sort by", selection: $sortMode) {
                    ForEach(AnnualLeavePersonSort.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                if !tradeChoices.isEmpty {
                    Picker("Trade", selection: Binding(
                        get: { tradeFilter ?? "All trades" },
                        set: { tradeFilter = $0 == "All trades" ? nil : $0 }
                    )) {
                        Text("All trades").tag("All trades")
                        ForEach(tradeChoices, id: \.self) { trade in
                            Text(trade).tag(trade)
                        }
                    }
                }
            }

            Section {
                if filteredPeople.isEmpty {
                    Text("No active team members match your filters.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredPeople) { person in
                        NavigationLink {
                            OperativeAnnualLeaveCalendarView(person: person)
                                .environmentObject(holidayStore)
                                .environmentObject(firebaseBackend)
                                .environmentObject(notificationService)
                                .environmentObject(operativeStore)
                                .environmentObject(userStore)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(person.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(person.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } header: {
                Text("Active team")
            } footer: {
                Text("Select a person to view their annual leave calendar and book approved leave on their behalf.")
            }
        }
        .navigationTitle("Operative annual leave")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search name, email, or trade")
    }
}

struct OperativeAnnualLeaveCalendarView: View {
    let person: AnnualLeavePerson

    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService

    @State private var displayedMonth = Date()
    @State private var selectedDates: Set<Date> = []
    @State private var selectedTimeSlot: HolidayTimeSlot = .fullDay
    @State private var isSaving = false
    @State private var showConfirm = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var successMessage: String?
    @State private var showSuccess = false

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                legendRow
                monthNavigator
                calendarGrid
                if !selectedDates.isEmpty {
                    selectionSummary
                    confirmButton
                }
            }
            .padding(16)
        }
        .background(HolidayChrome.canvas.ignoresSafeArea())
        .navigationTitle(person.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Confirm annual leave booking", isPresented: $showConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Book leave") {
                Task { await bookSelectedDays() }
            }
        } message: {
            Text(confirmMessage)
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
        .alert("Success", isPresented: $showSuccess) {
            Button("OK") { showSuccess = false }
        } message: {
            if let successMessage { Text(successMessage) }
        }
        .task {
            await holidayStore.loadData()
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(person.displayName)
                .font(.title3.weight(.semibold))
            Text(person.subtitle)
                .font(.subheadline)
                .foregroundStyle(HolidayChrome.muted)
            if !person.tradeLabel.isEmpty {
                Text(person.tradeLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HolidayChrome.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(HolidayChrome.accent.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HolidayChrome.border, lineWidth: 1)
        )
    }

    private var legendRow: some View {
        HStack(spacing: 12) {
            legendDot(color: HolidayChrome.taken, label: "Approved full day")
            legendDot(color: HolidayChrome.halfDayBooked, label: "Approved half day")
            legendDot(color: HolidayChrome.pending, label: "Pending")
        }
        .font(.caption2)
        .foregroundStyle(HolidayChrome.muted)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private var monthNavigator: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(monthYearString(displayedMonth))
                .font(.headline)
            Spacer()
            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .foregroundStyle(HolidayChrome.accent)
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
                        Color.clear.frame(height: 36)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HolidayChrome.border, lineWidth: 1)
        )
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected days")
                .font(.subheadline.weight(.semibold))
            ForEach(selectedDates.sorted(), id: \.self) { day in
                Text("\(day.formatted(date: .abbreviated, time: .omitted)) · \(selectedTimeSlot.rawValue)")
                    .font(.caption)
                    .foregroundStyle(HolidayChrome.muted)
            }
            Picker("Duration", selection: $selectedTimeSlot) {
                ForEach(HolidayTimeSlot.allCases, id: \.self) { slot in
                    Text(slot.rawValue).tag(slot)
                }
            }
            .pickerStyle(.segmented)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var confirmButton: some View {
        Button {
            showConfirm = true
        } label: {
            HStack {
                Spacer()
                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    Text("Confirm annual leave booking")
                        .fontWeight(.semibold)
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .background(HolidayChrome.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    private var confirmMessage: String {
        let count = selectedDates.count
        return "Book \(count) day\(count == 1 ? "" : "s") of \(selectedTimeSlot.rawValue) annual leave for \(person.displayName)? They will receive a confirmation notification."
    }

    private enum DayKind {
        case none
        case pendingFull
        case pendingHalf
        case approvedFull
        case approvedHalf
    }

    private func dayKind(for day: Date) -> DayKind {
        let dayStart = calendar.startOfDay(for: day)
        var pendingHalf: HolidayBooking?
        var approvedHalf: HolidayBooking?
        for booking in personBookings {
            let start = calendar.startOfDay(for: booking.startDate)
            let end = calendar.startOfDay(for: booking.endDate)
            guard dayStart >= start && dayStart <= end else { continue }
            switch booking.status {
            case .rejected:
                continue
            case .pending:
                if booking.timeSlot == .fullDay || !calendar.isDate(booking.startDate, inSameDayAs: booking.endDate) {
                    return .pendingFull
                }
                pendingHalf = booking
            case .approved:
                if booking.cancellationRequestedAt != nil { continue }
                if booking.timeSlot == .fullDay || !calendar.isDate(booking.startDate, inSameDayAs: booking.endDate) {
                    return .approvedFull
                }
                approvedHalf = booking
            }
        }
        if pendingHalf != nil { return .pendingHalf }
        if approvedHalf != nil { return .approvedHalf }
        return .none
    }

    private var personBookings: [HolidayBooking] {
        holidayStore.bookings.filter { booking in
            if let uid = person.userId, booking.userId == uid { return true }
            if let oid = person.operativeId, booking.operativeId == oid { return true }
            return false
        }
    }

    private func dayCell(date: Date) -> some View {
        let day = calendar.startOfDay(for: date)
        let isSelected = selectedDates.contains(day)
        let isInMonth = calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        let kind = dayKind(for: day)
        let locked: Bool = {
            switch kind {
            case .approvedFull, .pendingFull: return true
            default: return false
            }
        }()

        return Button {
            guard !locked else { return }
            if isSelected {
                selectedDates.remove(day)
            } else {
                selectedDates.insert(day)
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
                .background(dayBackground(kind: kind, isSelected: isSelected))
                .overlay(dayOverlay(kind: kind))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }

    @ViewBuilder
    private func dayBackground(kind: DayKind, isSelected: Bool) -> some View {
        if isSelected {
            HolidayChrome.accent
        } else {
            switch kind {
            case .approvedFull:
                HolidayChrome.taken.opacity(0.55)
            case .approvedHalf:
                HolidayChrome.halfDayBooked.opacity(0.35)
            case .pendingFull:
                HolidayChrome.pending.opacity(0.88)
            case .pendingHalf:
                Color.clear
            case .none:
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func dayOverlay(kind: DayKind) -> some View {
        switch kind {
        case .approvedHalf:
            Circle().stroke(HolidayChrome.halfDayBooked, lineWidth: 2)
        case .pendingHalf:
            Circle().stroke(HolidayChrome.pending, lineWidth: 2)
        case .pendingFull:
            Circle().stroke(HolidayChrome.pending.opacity(0.35), lineWidth: 1)
        default:
            EmptyView()
        }
    }

    private func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = next
        }
    }

    private func monthYearString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    private func daysInDisplayedMonth() -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) else { return [] }
        let firstWeekdayRaw = calendar.component(.weekday, from: first)
        let firstWeekday = (firstWeekdayRaw + 5) % 7
        var days: [Date?] = Array(repeating: nil, count: firstWeekday)
        for d in 1...range.count {
            if let date = calendar.date(byAdding: .day, value: d - 1, to: first) {
                days.append(date)
            }
        }
        return days
    }

    private func hasExistingHoliday(on day: Date) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        return personBookings.contains { booking in
            guard booking.status != .rejected else { return false }
            let start = calendar.startOfDay(for: booking.startDate)
            let end = calendar.startOfDay(for: booking.endDate)
            return dayStart >= start && dayStart <= end
        }
    }

    @MainActor
    private func bookSelectedDays() async {
        let days = selectedDates.sorted()
        guard !days.isEmpty else { return }
        guard let orgId = firebaseBackend.currentOrganization?.firestoreDocumentId else {
            errorMessage = "Organization not loaded."
            showError = true
            return
        }
        guard let approverId = firebaseBackend.currentUser?.uid else {
            errorMessage = "Not signed in."
            showError = true
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            for day in days where hasExistingHoliday(on: day) {
                throw NSError(
                    domain: "Holiday",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "One or more selected days already have annual leave booked."]
                )
            }

            var firstBookingId: UUID?
            for day in days {
                let booking = HolidayBooking(
                    organizationId: orgId,
                    userId: person.userId,
                    operativeId: person.operativeId,
                    startDate: day,
                    endDate: day,
                    status: .approved,
                    timeSlot: selectedTimeSlot,
                    approvedByUserId: approverId,
                    approvedAt: Date()
                )
                try await holidayStore.saveBooking(booking)
                firstBookingId = firstBookingId ?? booking.id
            }

            if let notifyUserId = resolvedNotificationUserId(),
               let bookingId = firstBookingId,
               let start = days.first,
               let end = days.last {
                let bookedBy = userStore.currentUser?.fullName
                    ?? userStore.currentUser?.email
                    ?? "Your manager"
                await notificationService.notifyAnnualLeaveBookingConfirmation(
                    userId: notifyUserId,
                    bookingId: bookingId,
                    bookedByName: bookedBy,
                    startDate: start,
                    endDate: end,
                    timeSlot: selectedTimeSlot
                )
            }

            selectedDates.removeAll()
            successMessage = "Annual leave booked for \(days.count) day\(days.count == 1 ? "" : "s")."
            showSuccess = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func resolvedNotificationUserId() -> String? {
        if let uid = person.userId { return uid }
        if let oid = person.operativeId,
           let op = operativeStore.allOperatives.first(where: { $0.id == oid }) {
            let email = op.email.lowercased()
            return userStore.organizationUsers.first(where: { $0.email.lowercased() == email })?.id
        }
        return nil
    }
}

private enum AnnualLeavePersonBuilder {
    static func build(users: [AppUser], operatives: [Operative]) -> [AnnualLeavePerson] {
        var rows: [AnnualLeavePerson] = []
        var seenEmails = Set<String>()

        let operativesByEmail = Dictionary(
            operatives.map { ($0.email.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for user in users where user.isActive {
            if user.permissions.annualLeaveSelfBook { continue }
            let email = user.email.lowercased()
            guard seenEmails.insert(email).inserted else { continue }
            let linkedOp = operativesByEmail[email]
            let trade = tradeLabel(for: user, operative: linkedOp)
            let (first, last) = nameParts(
                display: user.fullName.isEmpty ? user.email : user.fullName,
                operative: linkedOp
            )
            let roleHint: String = {
                if user.permissions.operativeMode || user.role == .operative { return "Operative" }
                if user.permissions.adminAccess || user.role == .admin { return "Admin" }
                if user.permissions.manager { return "Manager" }
                return "Team member"
            }()
            rows.append(
                AnnualLeavePerson(
                    id: "user-\(user.id)",
                    displayName: user.fullName.isEmpty ? user.email : user.fullName,
                    subtitle: "\(roleHint) · \(user.email)",
                    tradeLabel: trade,
                    firstNameSort: first,
                    surnameSort: last,
                    userId: user.id,
                    operativeId: linkedOp?.id
                )
            )
        }

        for op in operatives where op.isActive {
            let email = op.email.lowercased()
            if let linkedUser = users.first(where: { $0.email.lowercased() == email }),
               linkedUser.permissions.annualLeaveSelfBook {
                continue
            }
            guard seenEmails.insert(email).inserted else { continue }
            rows.append(
                AnnualLeavePerson(
                    id: "op-\(op.id.uuidString)",
                    displayName: op.name.isEmpty ? op.email : op.name,
                    subtitle: "Operative · \(op.email)",
                    tradeLabel: operativeTradeLabel(op),
                    firstNameSort: op.firstName,
                    surnameSort: op.lastName,
                    userId: nil,
                    operativeId: op.id
                )
            )
        }

        return rows
    }

    private static func tradeLabel(for user: AppUser, operative: Operative?) -> String {
        if let operative { return operativeTradeLabel(operative) }
        if user.permissions.manager { return "Management" }
        return "General"
    }

    private static func operativeTradeLabel(_ op: Operative) -> String {
        let custom = op.tradeTypeCustom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let preset = op.tradeTypePreset?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return preset.isEmpty ? "General" : preset
    }

    private static func nameParts(display: String, operative: Operative?) -> (String, String) {
        if let operative, !operative.firstName.isEmpty {
            return (operative.firstName, operative.lastName)
        }
        let parts = display.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count >= 2 {
            return (String(parts[0]), String(parts.last!))
        }
        return (display, display)
    }
}
