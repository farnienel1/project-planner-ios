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

private enum OperativeAnnualLeaveHubTab: String, CaseIterable, Identifiable {
    case manage
    case approved
    case requests

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manage: return "Manage user annual leave"
        case .approved: return "View approved bookings"
        case .requests: return "View annual leave requests"
        }
    }
}

struct OperativeAnnualLeaveHubView: View {
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService

    @State private var activeTab: OperativeAnnualLeaveHubTab = .manage

    private var isAdmin: Bool { userStore.hasAdminAccess() }

    var body: some View {
        VStack(spacing: 0) {
            if isAdmin {
                VStack(spacing: 8) {
                    ForEach(OperativeAnnualLeaveHubTab.allCases) { tab in
                        Button {
                            activeTab = tab
                        } label: {
                            HStack {
                                Text(tab.title)
                                    .font(.subheadline.weight(activeTab == tab ? .semibold : .regular))
                                    .foregroundStyle(activeTab == tab ? HolidayChrome.accent : HolidayChrome.ink)
                                Spacer(minLength: 0)
                                if activeTab == tab {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(HolidayChrome.accent)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(activeTab == tab ? HolidayChrome.accent.opacity(0.1) : Color.white)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(activeTab == tab ? HolidayChrome.accent : HolidayChrome.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Group {
                switch activeTab {
                case .manage:
                    OperativeAnnualLeaveDirectoryView(showNavigationTitle: false)
                case .approved:
                    OperativeAnnualLeaveApprovedListView()
                case .requests:
                    OperativeAnnualLeaveRequestsListView()
                }
            }
        }
        .background(HolidayChrome.canvas.ignoresSafeArea())
        .navigationTitle("View and manage user annual leave")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await holidayStore.loadData()
        }
    }
}

struct OperativeAnnualLeaveDirectoryView: View {
    var showNavigationTitle: Bool = true

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
                Text("Select a person to view their calendar, book approved leave, or approve pending requests.")
            }
        }
        .if(showNavigationTitle) { view in
            view.navigationTitle("Operative annual leave")
                .navigationBarTitleDisplayMode(.inline)
        }
        .searchable(text: $searchText, prompt: "Search name, email, or trade")
    }
}

private struct OperativeAnnualLeaveApprovedListView: View {
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore

    private var people: [AnnualLeavePerson] {
        AnnualLeavePersonBuilder.build(
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )
    }

    private var approvedBookings: [HolidayBooking] {
        holidayStore.bookings
            .filter { $0.status == .approved && personFor(booking: $0) != nil }
            .sorted { $0.startDate > $1.startDate }
    }

    private func personFor(booking: HolidayBooking) -> AnnualLeavePerson? {
        people.first { person in
            if let uid = person.userId, booking.userId == uid { return true }
            if let oid = person.operativeId, booking.operativeId == oid { return true }
            return false
        }
    }

    var body: some View {
        List {
            if approvedBookings.isEmpty {
                Text("No approved operative bookings.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(approvedBookings) { booking in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(personFor(booking: booking)?.displayName ?? "Unknown")
                            .font(.subheadline.weight(.semibold))
                        Text(dateRangeLabel(booking))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(booking.timeSlot.rawValue)
                            .font(.caption2)
                            .foregroundStyle(HolidayChrome.muted)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func dateRangeLabel(_ booking: HolidayBooking) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        if Calendar.current.isDate(booking.startDate, inSameDayAs: booking.endDate) {
            return f.string(from: booking.startDate)
        }
        return "\(f.string(from: booking.startDate)) – \(f.string(from: booking.endDate))"
    }
}

private struct OperativeAnnualLeaveRequestsListView: View {
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService

    private var people: [AnnualLeavePerson] {
        AnnualLeavePersonBuilder.build(
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )
    }

    private var pendingRequests: [HolidayBooking] {
        holidayStore.bookings
            .filter { $0.status == .pending && personFor(booking: $0) != nil }
            .sorted { $0.startDate > $1.startDate }
    }

    private func personFor(booking: HolidayBooking) -> AnnualLeavePerson? {
        people.first { person in
            if let uid = person.userId, booking.userId == uid { return true }
            if let oid = person.operativeId, booking.operativeId == oid { return true }
            return false
        }
    }

    var body: some View {
        List {
            if pendingRequests.isEmpty {
                Text("No pending requests.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pendingRequests) { request in
                    HolidayRequestRowView(
                        request: request,
                        requesterName: personFor(booking: request)?.displayName ?? "Unknown",
                        conflictingApprovedOperatives: [],
                        canApprove: true,
                        onApprove: { approve(request) },
                        onDecline: { decline(request) }
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
        }
    }

    private func approve(_ request: HolidayBooking) {
        guard let uid = firebaseBackend.currentUser?.uid else { return }
        Task {
            await holidayStore.approveBooking(request, approvedByUserId: uid)
            let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Admin"
            await notifyDecision(to: request, approved: true, decidedByName: approverName)
        }
    }

    private func decline(_ request: HolidayBooking) {
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
}

struct OperativeAnnualLeaveCalendarView: View {
    let person: AnnualLeavePerson

    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService

    @State private var displayedMonth = Date()
    @State private var selectedDay: Date?
    @State private var bookSlot: HolidayTimeSlot = .fullDay
    @State private var changeSlot: HolidayTimeSlot = .fullDay
    @State private var isSaving = false
    @State private var showBookConfirm = false
    @State private var showChangeConfirm = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var successMessage: String?
    @State private var showSuccess = false
    @ObservedObject private var bankHolidayService = BankHolidayService.shared
    @State private var bankHolidayTooltip: String?
    @State private var bankHolidayAlertTitle = "Annual leave calendar"
    @State private var bankHolidayCalendarTick = 0

    private let calendar = Calendar.current

    private var bankHolidayRegion: BankHolidayRegion {
        BankHolidayRegionDirectory.resolvedRegion(for: firebaseBackend.currentOrganization)
    }

    private func reloadBankHolidays(referenceDate: Date = Date(), forceRefresh: Bool = false) async {
        await bankHolidayService.ensureLoaded(
            region: bankHolidayRegion,
            referenceDate: referenceDate,
            forceRefresh: forceRefresh
        )
        bankHolidayCalendarTick += 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                legendRow
                monthNavigator
                calendarGrid
                if let day = selectedDay {
                    dayActionPanel(for: day)
                }
            }
            .padding(16)
        }
        .background(HolidayChrome.canvas.ignoresSafeArea())
        .navigationTitle(person.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Confirm annual leave booking", isPresented: $showBookConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Book leave") {
                Task { await bookSelectedDay() }
            }
        } message: {
            if let day = selectedDay {
                Text("Book \(bookSlot.rawValue) annual leave for \(person.displayName) on \(day.formatted(date: .abbreviated, time: .omitted))?")
            }
        }
        .alert("Confirm annual leave booking change", isPresented: $showChangeConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Save change") {
                Task { await saveBookingChange() }
            }
        } message: {
            if let booking = approvedBooking(on: selectedDay) {
                Text("Change booking on \(booking.startDate.formatted(date: .abbreviated, time: .omitted)) to \(changeSlot.rawValue)?")
            }
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
        .alert(bankHolidayAlertTitle, isPresented: Binding(
            get: { bankHolidayTooltip != nil },
            set: { if !$0 { bankHolidayTooltip = nil } }
        )) {
            Button("OK") { bankHolidayTooltip = nil }
        } message: {
            if let bankHolidayTooltip { Text(bankHolidayTooltip) }
        }
        .task {
            await holidayStore.loadData()
            await reloadBankHolidays(forceRefresh: false)
        }
        .onChange(of: displayedMonth) { _, newMonth in
            Task { await reloadBankHolidays(referenceDate: newMonth) }
        }
        .onChange(of: firebaseBackend.currentOrganization?.settings.bankHolidayRegionId) { _, _ in
            Task { await reloadBankHolidays(forceRefresh: true) }
        }
        .onChange(of: bankHolidayService.holidaysByDayKey.count) { _, _ in
            bankHolidayCalendarTick += 1
        }
    }

    @ViewBuilder
    private func dayActionPanel(for day: Date) -> some View {
        let kind = dayKind(for: day)
        switch kind {
        case .none:
            bookPanel(for: day)
        case .approvedFull, .approvedHalf:
            changePanel(for: day)
        case .pendingFull, .pendingHalf:
            requestPanel(for: day)
        }
    }

    private func bookPanel(for day: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Book annual leave for \(person.displayName)")
                .font(.subheadline.weight(.semibold))
            Text(day.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(HolidayChrome.muted)
            slotPicker(selection: $bookSlot)
            Button {
                showBookConfirm = true
            } label: {
                Text("Confirm annual leave booking")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(HolidayChrome.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func changePanel(for day: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change approved booking")
                .font(.subheadline.weight(.semibold))
            if let booking = approvedBooking(on: day) {
                Text("\(day.formatted(date: .abbreviated, time: .omitted)) · currently \(booking.timeSlot.rawValue)")
                    .font(.caption)
                    .foregroundStyle(HolidayChrome.muted)
            }
            slotPicker(selection: $changeSlot)
            Button {
                showChangeConfirm = true
            } label: {
                Text("Confirm annual leave booking change")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(HolidayChrome.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isSaving || changeSlot == approvedBooking(on: day)?.timeSlot)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func requestPanel(for day: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pending request")
                .font(.subheadline.weight(.semibold))
            if let booking = pendingBooking(on: day) {
                Text("\(day.formatted(date: .abbreviated, time: .omitted)) · \(booking.timeSlot.rawValue)")
                    .font(.caption)
                    .foregroundStyle(HolidayChrome.muted)
            }
            HStack(spacing: 12) {
                Button {
                    Task { await approvePending(on: day) }
                } label: {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(HolidayChrome.taken)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                Button {
                    Task { await declinePending(on: day) }
                } label: {
                    Label("Decline", systemImage: "xmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(HolidayChrome.pending)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(HolidayChrome.pending.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HolidayChrome.pending.opacity(0.25), lineWidth: 1)
        )
    }

    private func slotPicker(selection: Binding<HolidayTimeSlot>) -> some View {
        HStack(spacing: 8) {
            slotChip("Full day", slot: .fullDay, selection: selection)
            slotChip("AM", slot: .morning, selection: selection)
            slotChip("PM", slot: .afternoon, selection: selection)
        }
    }

    private func slotChip(_ label: String, slot: HolidayTimeSlot, selection: Binding<HolidayTimeSlot>) -> some View {
        let on = selection.wrappedValue == slot
        return Button {
            selection.wrappedValue = slot
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(on ? HolidayChrome.accent.opacity(0.15) : Color.white)
                .foregroundStyle(on ? HolidayChrome.accent : HolidayChrome.ink)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(on ? HolidayChrome.accent : HolidayChrome.border, lineWidth: on ? 1.5 : 1)
                )
        }
        .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                legendDot(color: HolidayChrome.taken, label: "Approved full day")
                legendDot(color: HolidayChrome.halfDayBooked, label: "Approved half day")
                legendDot(color: HolidayChrome.pending, label: "Pending")
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle().stroke(AnnualLeaveCalendarChrome.weekendStroke, lineWidth: 2).frame(width: 8, height: 8)
                    Text("Weekend")
                }
                HStack(spacing: 4) {
                    Circle().stroke(AnnualLeaveCalendarChrome.bankHolidayStroke, lineWidth: 2).frame(width: 8, height: 8)
                    Text("Bank holiday")
                }
            }
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
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(monthYearString(displayedMonth)).font(.headline)
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
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
            .id(bankHolidayCalendarTick)
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HolidayChrome.border, lineWidth: 1)
        )
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

    private func approvedBooking(on day: Date?) -> HolidayBooking? {
        guard let day else { return nil }
        let dayStart = calendar.startOfDay(for: day)
        return personBookings.first { booking in
            guard booking.status == .approved, booking.cancellationRequestedAt == nil else { return false }
            let start = calendar.startOfDay(for: booking.startDate)
            let end = calendar.startOfDay(for: booking.endDate)
            return dayStart >= start && dayStart <= end
        }
    }

    private func pendingBooking(on day: Date?) -> HolidayBooking? {
        guard let day else { return nil }
        let dayStart = calendar.startOfDay(for: day)
        return personBookings.first { booking in
            guard booking.status == .pending else { return false }
            let start = calendar.startOfDay(for: booking.startDate)
            let end = calendar.startOfDay(for: booking.endDate)
            return dayStart >= start && dayStart <= end
        }
    }

    private func dayCell(date: Date) -> some View {
        let day = calendar.startOfDay(for: date)
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isInMonth = calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        let kind = dayKind(for: day)
        let blockReason = AnnualLeaveCalendarRules.blockReason(
            for: day,
            bankHolidays: bankHolidayService.holidaysByDayKey,
            calendar: calendar
        )

        return Button {
            if let blockReason {
                switch blockReason {
                case .weekend:
                    bankHolidayAlertTitle = "Annual leave calendar"
                    bankHolidayTooltip = "Weekends cannot be booked as annual leave."
                case .bankHoliday(let name):
                    bankHolidayAlertTitle = name
                    bankHolidayTooltip = "Bank holidays cannot be booked as annual leave."
                }
                return
            }
            if isSelected {
                selectedDay = nil
            } else {
                selectedDay = day
                if let approved = approvedBooking(on: day) {
                    changeSlot = approved.timeSlot
                } else {
                    bookSlot = .fullDay
                }
            }
        } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.subheadline)
                .fontWeight(isSelected ? .bold : .regular)
                .frame(width: 36, height: 36)
                .annualLeaveBlockedDayStyle(
                    blockReason: blockReason,
                    isSelected: isSelected,
                    isInMonth: isInMonth,
                    defaultInk: HolidayChrome.ink,
                    defaultMuted: HolidayChrome.muted
                )
                .overlay(dayOverlay(kind: kind))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
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
                Color.clear
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

    @MainActor
    private func bookSelectedDay() async {
        guard let day = selectedDay else { return }
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
            let booking = HolidayBooking(
                organizationId: orgId,
                userId: person.userId,
                operativeId: person.operativeId,
                startDate: day,
                endDate: day,
                status: .approved,
                timeSlot: bookSlot,
                approvedByUserId: approverId,
                approvedAt: Date()
            )
            try await holidayStore.saveBooking(booking)

            if let notifyUserId = resolvedNotificationUserId() {
                let bookedBy = userStore.currentUser?.fullName
                    ?? userStore.currentUser?.email
                    ?? "Your manager"
                await notificationService.notifyAnnualLeaveBookingConfirmation(
                    userId: notifyUserId,
                    bookingId: booking.id,
                    bookedByName: bookedBy,
                    startDate: day,
                    endDate: day,
                    timeSlot: bookSlot
                )
            }

            selectedDay = nil
            successMessage = "Annual leave booked."
            showSuccess = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    @MainActor
    private func saveBookingChange() async {
        guard var booking = approvedBooking(on: selectedDay) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            booking.timeSlot = changeSlot
            try await holidayStore.saveBooking(booking)
            selectedDay = nil
            successMessage = "Annual leave booking updated."
            showSuccess = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    @MainActor
    private func approvePending(on day: Date) async {
        guard let booking = pendingBooking(on: day),
              let uid = firebaseBackend.currentUser?.uid else { return }
        isSaving = true
        defer { isSaving = false }
        await holidayStore.approveBooking(booking, approvedByUserId: uid)
        let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Admin"
        await notifyDecision(to: booking, approved: true, decidedByName: approverName)
        selectedDay = nil
        successMessage = "Request approved."
        showSuccess = true
    }

    @MainActor
    private func declinePending(on day: Date) async {
        guard let booking = pendingBooking(on: day),
              let uid = firebaseBackend.currentUser?.uid else { return }
        isSaving = true
        defer { isSaving = false }
        await holidayStore.rejectBooking(booking, rejectedByUserId: uid)
        let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Admin"
        await notifyDecision(to: booking, approved: false, decidedByName: approverName)
        selectedDay = nil
        successMessage = "Request declined."
        showSuccess = true
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
            if AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: user) { continue }
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
               AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: linkedUser) {
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

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
