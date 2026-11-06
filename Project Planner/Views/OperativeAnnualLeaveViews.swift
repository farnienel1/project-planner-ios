//
//  OperativeAnnualLeaveViews.swift
//  Project Planner
//
//  Team annual leave directory + per-person calendar for admins and operative managers.
//

import SwiftUI
import FirebaseAuth

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

enum AnnualLeavePersonSort: String, CaseIterable, Identifiable {
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

    var shortTitle: String {
        switch self {
        case .manage: return "Team"
        case .approved: return "Approved"
        case .requests: return "Requests"
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
            VStack(alignment: .leading, spacing: 0) {
                if isAdmin {
                    Picker("Team view", selection: $activeTab) {
                        ForEach(OperativeAnnualLeaveHubTab.allCases) { tab in
                            Text(tab.shortTitle).tag(tab)
                        }
                    }
                    .accessibilityIdentifier("operativeAnnualLeaveHub.teamView")
                    .pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, PPMetrics.screenGutter)
            .padding(.top, 10)
            .padding(.bottom, PPMetrics.contentOverlap + 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(PPNavyHeaderBackground(bleed: 0))

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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PPColor.page)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: PPMetrics.contentCornerRadius,
                    topTrailingRadius: PPMetrics.contentCornerRadius,
                    style: .continuous
                )
            )
            .padding(.top, -PPMetrics.contentOverlap)
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle("View and manage user annual leave")
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .task(id: firebaseBackend.currentOrganization?.firestoreDocumentId ?? "") {
            guard !(firebaseBackend.currentOrganization?.firestoreDocumentId ?? "").isEmpty else { return }
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
                    .accessibilityIdentifier("operativeAnnualLeaveDirectory.sortBy")
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
                        .accessibilityIdentifier("operativeAnnualLeaveDirectory.trade")
                }
            }
            .listRowBackground(PPColor.card)

            Section {
                if filteredPeople.isEmpty {
                    Text("No active team members match your filters.")
                        .font(.subheadline)
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
                            HStack(spacing: 13) {
                                PPIconTile(symbol: "person.fill", family: .people, size: PPMetrics.menuIcon)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(person.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(person.subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                            .accessibilityIdentifier("operativeAnnualLeaveDirectory.row.\(person.id)")
                    }
                }
            } header: {
                Text("Active team")
                    .font(.footnote.weight(.semibold))
                    .tracking(0.8)
            } footer: {
                Text("Select a person to view their calendar, book approved leave, or approve pending requests.")
            }
            .listRowBackground(PPColor.card)
        }
        .scrollContentBackground(.hidden)
        .background(PPColor.page)
        .if(showNavigationTitle) { view in
            view.navigationTitle("Operative annual leave")
                .navigationBarTitleDisplayMode(.inline)
                .ppNavyNavigationBar()
        }
        .searchable(text: $searchText, prompt: "Search name, email, or trade")
    }
}

private struct OperativeAnnualLeaveApprovedListView: View {
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    @State private var bookingPendingRemoval: HolidayBooking?

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

    /// RULEBOOK §9, §16: a holiday delete follows the same deciders as approval (`canDecideLeave`).
    private func canRemove(_ booking: HolidayBooking) -> Bool {
        let viewer = userStore.currentUser.map { me in
            userStore.organizationUsers.first(where: { $0.id == me.id }) ?? me
        }
        return AnnualLeaveApproval.canDecide(
            booking,
            viewer: viewer,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )
    }

    var body: some View {
        List {
            if approvedBookings.isEmpty {
                Text("No approved operative bookings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(PPColor.card)
            } else {
                ForEach(approvedBookings) { booking in
                    HStack(alignment: .center, spacing: 13) {
                        PPIconTile(symbol: "sun.max.fill", family: .sites, size: PPMetrics.menuIcon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(personFor(booking: booking)?.displayName ?? "Unknown")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(dateRangeLabel(booking))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(booking.timeSlot.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if canRemove(booking) {
                            Button {
                                bookingPendingRemoval = booking
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(HolidayChrome.pending)
                            }
                            .accessibilityIdentifier("operativeAnnualLeaveApprovedList.row.\(booking.id).removeAnnualLeaveBooking")
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove annual leave booking")
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(PPColor.card)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PPColor.page)
        .overlay {
            if bookingPendingRemoval != nil {
                ZStack {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        
                        .accessibilityIdentifier("operativeAnnualLeaveApprovedList.removeAnnualLeaveBooking").onTapGesture { bookingPendingRemoval = nil }
                    AnnualLeaveRemoveBookingConfirm(
                        onYes: {
                            guard let booking = bookingPendingRemoval else { return }
                            bookingPendingRemoval = nil
                            Task { await holidayStore.deleteBooking(booking) }
                        },
                        onNo: { bookingPendingRemoval = nil }
                    )
                    .padding(28)
                }
            }
        }
    }

    private func dateRangeLabel(_ booking: HolidayBooking) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.timeZone = OrganizationRulebookContext.timeZone
        if OrganizationRulebookContext.calendar.isDate(booking.startDate, inSameDayAs: booking.endDate) {
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

    /// D6: pending requests and cancellation asks this viewer may decide (`leaveApproverIds`; admins see all).
    private var pendingRequests: [HolidayBooking] {
        AnnualLeaveApproval.decidableRequests(
            holidayStore.pendingRequests.filter { personFor(booking: $0) != nil },
            viewer: approvalViewer,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )
        .sorted { $0.startDate > $1.startDate }
    }

    private var approvalViewer: AppUser? {
        guard let me = userStore.currentUser else { return nil }
        return userStore.organizationUsers.first(where: { $0.id == me.id }) ?? me
    }

    private func canDecide(_ request: HolidayBooking) -> Bool {
        AnnualLeaveApproval.canDecide(
            request,
            viewer: approvalViewer,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )
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
                Text("Nothing is waiting. New leave requests and cancellation requests will show here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(PPColor.card)
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
                    .listRowBackground(PPColor.card)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PPColor.page)
    }

    private func approve(_ request: HolidayBooking) {
        guard let uid = firebaseBackend.currentUser?.uid, canDecide(request) else { return }
        Task {
            if request.cancellationRequestedAt != nil {
                await holidayStore.deleteBooking(request)
                let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Manager"
                if let ownerId = request.userId {
                    await notificationService.notifyAnnualLeaveCancelledByManager(
                        userId: ownerId,
                        booking: request,
                        managerName: approverName
                    )
                }
                await notifyAnnualLeavePeerManagers(
                    request: request,
                    actorUserId: uid,
                    actorName: approverName,
                    // Web peer copy: accepting a cancellation is "approved … annual leave cancellation".
                    actionVerb: "approved",
                    users: userStore.organizationUsers,
                    operatives: operativeStore.allOperatives,
                    notificationService: notificationService
                )
                return
            } else {
                await holidayStore.approveBooking(request, approvedByUserId: uid)
            }
            let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Admin"
            await notifyDecision(to: request, approved: true, decidedByName: approverName)
            await notifyAnnualLeavePeerManagers(
                request: request,
                actorUserId: uid,
                actorName: approverName,
                actionVerb: "approved",
                users: userStore.organizationUsers,
                operatives: operativeStore.allOperatives,
                notificationService: notificationService
            )
        }
    }

    private func decline(_ request: HolidayBooking) {
        guard let uid = firebaseBackend.currentUser?.uid, canDecide(request) else { return }
        if request.cancellationRequestedAt != nil {
            // Refuse the cancellation (§9): the leave stays approved; the requester is told
            // (`holidayDecisionRecipients`) and the other line managers (`lineManagerPeerRecipients`).
            Task {
                guard await holidayStore.refuseCancellation(request) else { return }
                let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Manager"
                if let ownerId = request.userId {
                    await notificationService.notifyAnnualLeaveCancellationRefused(
                        userId: ownerId,
                        booking: request,
                        decidedByName: approverName
                    )
                }
                await notifyAnnualLeavePeerManagers(
                    request: request,
                    actorUserId: uid,
                    actorName: approverName,
                    actionVerb: "declined",
                    users: userStore.organizationUsers,
                    operatives: operativeStore.allOperatives,
                    notificationService: notificationService
                )
            }
            return
        }
        Task {
            await holidayStore.rejectBooking(request, rejectedByUserId: uid)
            let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Admin"
            await notifyDecision(to: request, approved: false, decidedByName: approverName)
            await notifyAnnualLeavePeerManagers(
                request: request,
                actorUserId: uid,
                actorName: approverName,
                actionVerb: "declined",
                users: userStore.organizationUsers,
                operatives: operativeStore.allOperatives,
                notificationService: notificationService
            )
        }
    }

    private func notifyDecision(to request: HolidayBooking, approved: Bool, decidedByName: String) async {
        // RULEBOOK §9, §13: the requester is the account the record names (`resolveBookingPerson` on its `userId`,
        // else its `operativeId`); `notifyHolidayRequestDecisionToUser` then asks `holidayDecisionRecipients` (never
        // the decider, no admin copy). No email or operative-mode match here.
        let requesterId = AnnualLeaveApproval.requester(
            for: request,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )?.id ?? request.userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requesterId, !requesterId.isEmpty else { return }
        await notificationService.notifyHolidayRequestDecisionToUser(
            userId: requesterId,
            bookingId: request.id,
            approved: approved,
            decidedByName: decidedByName
        )
    }
}

struct OperativeAnnualLeaveCalendarView: View {
    let person: AnnualLeavePerson

    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject private var smartCache: SmartCacheService
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
    @State private var bookingPendingDelete: HolidayBooking?
    @ObservedObject private var bankHolidayService = BankHolidayService.shared
    @State private var bankHolidayTooltip: String?
    @State private var bankHolidayAlertTitle = "Annual leave calendar"
    @State private var bankHolidayCalendarTick = 0
    @State private var bookingPendingRemoval: HolidayBooking?

    /// Leave days are organisation business days (§1).
    private var calendar: Calendar { OrganizationRulebookContext.calendar }

    /// `BANK_HOLIDAY_REGIONS` row for the saved region (rulebook §4.4). Nil only when the script did not answer.
    private var bankHolidayRegion: BankHolidayRegion? {
        CanonicalBusinessEngine.resolvedBankHolidayRegion(for: firebaseBackend.currentOrganization)
    }

    private func reloadBankHolidays(referenceDate: Date = Date(), forceRefresh: Bool = false) async {
        guard let region = bankHolidayRegion else { return }
        await bankHolidayService.ensureLoaded(
            region: region,
            referenceDate: referenceDate,
            forceRefresh: forceRefresh
        )
        bankHolidayCalendarTick += 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerCard

                VStack(alignment: .leading, spacing: 18) {
                    if let summary = annualLeaveSummary {
                        AnnualLeaveBalanceHero(summary: summary, pendingCaption: "Awaiting approval")
                    }
                    bookedLeaveCard
                    pendingLeaveCard
                    AnnualLeaveLegend()
                    monthNavigator
                    calendarGrid
                    if let day = selectedDay {
                        dayActionPanel(for: day)
                    }
                    futureApprovedList
                }
                .padding(.top, 20)
                .padding(.bottom, 28)
                .ppContentSheet()
            }
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationTitle(person.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .overlay {
            if bookingPendingRemoval != nil {
                ZStack {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        
                        .accessibilityIdentifier("operativeAnnualLeaveCalendar.tap").onTapGesture { bookingPendingRemoval = nil }
                    AnnualLeaveRemoveBookingConfirm(
                        onYes: {
                            guard let booking = bookingPendingRemoval else { return }
                            bookingPendingRemoval = nil
                            Task { await removeApprovedBooking(booking) }
                        },
                        onNo: { bookingPendingRemoval = nil }
                    )
                    .padding(28)
                }
            }
        }
        .alert("Confirm annual leave booking", isPresented: $showBookConfirm) {
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.cancel")
            Button("Book leave") {
                Task { await bookSelectedDay() }
            }
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.bookLeave")
        } message: {
            if let day = selectedDay {
                Text("Book \(bookSlot.rawValue) annual leave for \(person.displayName) on \(day.formatted(date: .abbreviated, time: .omitted))?")
            }
        }
        .alert("Confirm annual leave booking change", isPresented: $showChangeConfirm) {
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.cancel2")
            Button("Save change") {
                Task { await saveBookingChange() }
            }
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.saveChange")
        } message: {
            if let booking = approvedBooking(on: selectedDay) {
                Text("Change booking on \(booking.startDate.formatted(date: .abbreviated, time: .omitted)) to \(changeSlot.rawValue)?")
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { showError = false }
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.ok")
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
        .alert("Success", isPresented: $showSuccess) {
            Button("OK") { showSuccess = false }
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.ok2")
        } message: {
            if let successMessage { Text(successMessage) }
        }
        .alert("Cancel and delete annual leave", isPresented: Binding(
            get: { bookingPendingDelete != nil },
            set: { if !$0 { bookingPendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { bookingPendingDelete = nil }
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.cancel3")
            Button("Delete annual leave", role: .destructive) {
                let booking = bookingPendingDelete
                bookingPendingDelete = nil
                guard let booking else { return }
                Task { await removeApprovedBooking(booking) }
            }
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.deleteAnnualLeave")
        } message: {
            if let booking = bookingPendingDelete {
                Text("Delete \(person.displayName)'s approved annual leave on \(booking.startDate.formatted(date: .abbreviated, time: .omitted))?")
            }
        }
        .alert(bankHolidayAlertTitle, isPresented: Binding(
            get: { bankHolidayTooltip != nil },
            set: { if !$0 { bankHolidayTooltip = nil } }
        )) {
            Button("OK") { bankHolidayTooltip = nil }
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.ok3")
        } message: {
            if let bankHolidayTooltip { Text(bankHolidayTooltip) }
        }
        .task(id: bankHolidayRegion?.id) {
            await reloadBankHolidays(forceRefresh: false)
        }
        .task(id: displayedMonth) {
            await reloadBankHolidays(referenceDate: displayedMonth)
        }
        .task(id: firebaseBackend.currentOrganization?.firestoreDocumentId ?? "") {
            guard !(firebaseBackend.currentOrganization?.firestoreDocumentId ?? "").isEmpty else { return }
            await holidayStore.loadData()
        }
        .onChange(of: firebaseBackend.currentOrganization?.settings.bankHolidayRegionId) { _, _ in
            Task { await reloadBankHolidays(forceRefresh: true) }
        }
        .onChange(of: bankHolidayService.holidaysByDayKey.count) { _, _ in
            bankHolidayCalendarTick += 1
        }
        .navigationTitle(person.displayName)
        .navigationBarTitleDisplayMode(.inline)
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
            .accessibilityIdentifier("operativeAnnualLeaveCalendar.confirmAnnualLeaveBooking")
            .buttonStyle(.plain)
            .disabled(isSaving)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
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
            .accessibilityIdentifier("operativeAnnualLeaveCalendar.confirmAnnualLeaveBookingChange")
            .buttonStyle(.plain)
            .disabled(isSaving || changeSlot == approvedBooking(on: day)?.timeSlot)
            // RULEBOOK §9, §16: a holiday delete follows the deciders (`canDecideLeave`).
            if let booking = approvedBooking(on: day), canDecide(booking) {
                Button {
                    bookingPendingRemoval = booking
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(HolidayChrome.pending)
                        Text("Remove this annual leave day")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(HolidayChrome.pending)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(HolidayChrome.pending.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.clear")
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
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
            if let pending = pendingBooking(on: day), !canDecide(pending) {
                Text("This request goes to the people who approve this person's leave.")
                    .font(.caption)
                    .foregroundStyle(HolidayChrome.muted)
            } else {
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
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.approve")
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
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.decline")
                .buttonStyle(.plain)
            }
            // RULEBOOK §2: annual leave approval is online only.
            .onlineOnly(isOnline: smartCache.isOnline)
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
                .background(on ? HolidayChrome.accent.opacity(0.15) : PPColor.card)
                .foregroundStyle(on ? HolidayChrome.accent : HolidayChrome.ink)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(on ? HolidayChrome.accent : HolidayChrome.border, lineWidth: on ? 1.5 : 1)
                )
        }
        .accessibilityIdentifier("operativeAnnualLeaveCalendar.\(AccessibilityID.token(label))")
        .buttonStyle(.plain)
    }

    private var leaveProfileUser: AppUser? {
        if let uid = person.userId {
            return userStore.organizationUsers.first(where: { $0.id == uid })
        }
        if let oid = person.operativeId,
           let op = operativeStore.allOperatives.first(where: { $0.id == oid }) {
            // RULEBOOK 1.34.0 §11: a converted ghost's row has no email and keeps the ghost's id.
            let email = op.email.lowercased()
            return userStore.organizationUsers.first { !email.isEmpty && $0.email.lowercased() == email }
                ?? userStore.organizationUsers.first { $0.id.caseInsensitiveCompare(op.documentId) == .orderedSame }
        }
        return nil
    }

    private var annualLeaveSummary: AnnualLeaveUsageSummary? {
        let defaults = firebaseBackend.currentOrganization?.settings.annualLeaveDefaults ?? .default
        let user = leaveProfileUser
        return AnnualLeavePolicy.usageSummary(
            bookings: personHolidayBookings,
            daysPerYear: user?.annualLeaveDaysPerYear ?? defaults.daysPerYear,
            startMonth: user?.annualLeaveYearStartMonth ?? defaults.startMonth,
            endMonth: user?.annualLeaveYearEndMonth ?? defaults.endMonth,
            carriesOver: user?.annualLeaveCarriesOver ?? defaults.carriesOver,
            referenceDate: Date(),
            calendar: calendar,
            annualLeaveEnabled: user?.annualLeaveEnabled ?? true,
            orgDaysPerYear: defaults.daysPerYear,
            orgStartMonth: defaults.startMonth,
            orgEndMonth: defaults.endMonth,
            yearAllowance: user?.annualLeaveYearAllowance,
            yearAllowanceKey: user?.annualLeaveYearAllowanceKey,
            employmentStartDayKey: user?.employmentStartDate
        )
    }

    /// RULEBOOK 1.9.0 §9: the person's leave by every id of their account (`leaveRecordsForAccount`).
    private var personHolidayBookings: [HolidayBooking] {
        holidayStore.myBookings(
            account: leaveProfileUser,
            operatives: operativeStore.allOperatives,
            operativeId: person.operativeId,
            userId: person.userId
        )
    }

    private var approvedLeaveBookings: [HolidayBooking] {
        personHolidayBookings
            .filter { $0.status == .approved }
            .sorted { $0.startDate > $1.startDate }
    }

    private var pendingLeaveBookings: [HolidayBooking] {
        personHolidayBookings
            .filter { $0.status == .pending }
            .sorted { $0.startDate > $1.startDate }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            PPNavyPageTitle(title: person.displayName, subtitle: person.subtitle)
            if !person.tradeLabel.isEmpty {
                PPOnNavyPill(text: person.tradeLabel, symbol: "wrench.and.screwdriver.fill")
            }
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 16)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private var bookedLeaveCard: some View {
        leaveListCard(
            title: "Booked annual leave",
            emptyText: "No booked annual leave.",
            bookings: approvedLeaveBookings,
            accent: HolidayChrome.taken,
            allowsRemove: true
        )
    }

    private var pendingLeaveCard: some View {
        leaveListCard(
            title: "Pending requests",
            emptyText: "No pending requests.",
            bookings: pendingLeaveBookings,
            accent: HolidayChrome.pendingMetric,
            allowsRemove: false
        )
    }

    private func leaveListCard(
        title: String,
        emptyText: String,
        bookings: [HolidayBooking],
        accent: Color,
        allowsRemove: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HolidayChrome.ink)
            if bookings.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(HolidayChrome.muted)
            } else {
                ForEach(bookings) { booking in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(accent)
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(leaveDateLabel(booking))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(HolidayChrome.ink)
                            Text(booking.timeSlot.rawValue)
                                .font(.caption2)
                                .foregroundStyle(HolidayChrome.muted)
                        }
                        Spacer(minLength: 0)
                        if allowsRemove && canDecide(booking) {
                            Button {
                                bookingPendingRemoval = booking
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(HolidayChrome.pending)
                            }
                            .accessibilityIdentifier("operativeAnnualLeaveCalendar.row.\(booking.id).removeAnnualLeaveBooking")
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove annual leave booking")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private func leaveDateLabel(_ booking: HolidayBooking) -> String {
        return AnnualLeaveDateFormat.bookingTitle(booking, calendar: calendar)
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
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.back")
            Spacer()
            Text(monthYearString(displayedMonth)).font(.headline)
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityIdentifier("operativeAnnualLeaveCalendar.chevronRight")
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
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private enum DayKind {
        case none
        case pendingFull
        case pendingHalf
        case approvedFull
        case approvedHalf
    }

    /// RULEBOOK 1.23.0 §9 `CanonicalBusinessEngine.leaveDayKind`: the record's leave days only (weekends and bank
    /// holidays inside a multi-day record are blank), rejected never, approved leave with a pending cancellation still
    /// approved, pendingFull > approvedFull > pendingHalf > approvedHalf — on the organisation day.
    private func dayKind(for day: Date) -> DayKind {
        let kind: RulebookLeaveDayKind = CanonicalBusinessEngine.leaveDayKind(
            records: personBookings.map(\.rulebookLeaveRecord),
            dayKey: OrganizationRulebookContext.dayKey(day),
            nonWorkingDayKeys: OrganizationBankHolidays.dayKeys
        ) ?? RulebookLeaveDayKind.none
        switch kind {
        case .pendingFull: return .pendingFull
        case .pendingHalf: return .pendingHalf
        case .approvedFull: return .approvedFull
        case .approvedHalf: return .approvedHalf
        case .none: return .none
        }
    }

    private var personBookings: [HolidayBooking] {
        holidayStore.bookings.filter { booking in
            if let uid = person.userId, booking.userId == uid { return true }
            if let oid = person.operativeId, booking.operativeId == oid { return true }
            return false
        }
    }

    private var futureApprovedBookings: [HolidayBooking] {
        let today = calendar.startOfDay(for: Date())
        return personBookings.filter { booking in
            guard booking.status == .approved, booking.cancellationRequestedAt == nil else { return false }
            return calendar.startOfDay(for: booking.endDate) >= today
        }
        .sorted { $0.startDate < $1.startDate }
    }

    private var futureApprovedList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Upcoming booked annual leave")
                .font(.subheadline.weight(.semibold))
            if futureApprovedBookings.isEmpty {
                Text("No upcoming approved leave for this person.")
                    .font(.caption)
                    .foregroundStyle(HolidayChrome.muted)
            } else {
                ForEach(futureApprovedBookings) { booking in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(leaveDateLabel(booking))
                                .font(.subheadline.weight(.semibold))
                            Text(booking.timeSlot.rawValue)
                                .font(.caption)
                                .foregroundStyle(HolidayChrome.muted)
                        }
                        Spacer(minLength: 8)
                        if canDecide(booking) {
                            Button {
                                bookingPendingRemoval = booking
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(Color.red.opacity(0.85))
                            }
                            .accessibilityIdentifier("operativeAnnualLeaveCalendar.row.\(booking.id).deleteAnnualLeave")
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete annual leave")
                        }
                    }
                    .padding(12)
                    .background(ProjectWorksRevampColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(HolidayChrome.border, lineWidth: 1)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }

    private func approvedBooking(on day: Date?) -> HolidayBooking? {
        guard let day else { return nil }
        let dayStart = calendar.startOfDay(for: day)
        return personBookings.first { booking in
            guard booking.status == .approved, booking.cancellationRequestedAt == nil else { return false }
            return LeaveRecordDays.covers(booking, day: dayStart)
        }
    }

    private func pendingBooking(on day: Date?) -> HolidayBooking? {
        guard let day else { return nil }
        let dayStart = calendar.startOfDay(for: day)
        return personBookings.first { booking in
            guard booking.status == .pending else { return false }
            return LeaveRecordDays.covers(booking, day: dayStart)
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
                    bankHolidayAlertTitle = "Weekend"
                    bankHolidayTooltip = "Weekends cannot be booked as annual leave."
                case .bankHoliday(let name):
                    bankHolidayAlertTitle = name
                    bankHolidayTooltip = "\(name) is a bank holiday. It cannot be booked as annual leave and it is not taken out of the allowance."
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
            AnnualLeaveDayFace(
                dayNumber: calendar.component(.day, from: date),
                visual: personFaceVisual(kind: kind, blockReason: blockReason),
                isSelected: isSelected,
                isToday: calendar.isDateInToday(day),
                accessibilityLabel: personDayAccessibility(date: day, kind: kind, blockReason: blockReason, isSelected: isSelected)
            )
            .opacity(isInMonth ? 1 : 0.35)
        }
        .accessibilityIdentifier("operativeAnnualLeaveCalendar.weekend")
        .buttonStyle(.plain)
    }

    private func personFaceVisual(kind: DayKind, blockReason: AnnualLeaveDayBlockReason?) -> AnnualLeaveDayVisual {
        if let blockReason {
            switch blockReason {
            case .bankHoliday: return .bankHoliday
            case .weekend: return .weekend
            }
        }
        switch kind {
        case .approvedFull: return .approvedFull
        case .approvedHalf: return .approvedHalf
        case .pendingFull, .pendingHalf: return .pending
        case .none: return .none
        }
    }

    private func personDayAccessibility(date: Date, kind: DayKind, blockReason: AnnualLeaveDayBlockReason?, isSelected: Bool) -> String {
        let spoken = date.formatted(date: .long, time: .omitted)
        if isSelected { return "\(spoken), selected" }
        if let blockReason {
            switch blockReason {
            case .weekend: return "\(spoken), weekend, not bookable"
            case .bankHoliday(let name): return "\(spoken), \(name), bank holiday, not bookable"
            }
        }
        switch kind {
        case .approvedFull: return "\(spoken), approved full day"
        case .approvedHalf: return "\(spoken), approved half day"
        case .pendingFull, .pendingHalf: return "\(spoken), pending"
        case .none: return spoken
        }
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

        _ = orgId
        do {
            // One document per request range (`holidayRequestRanges` → `holidayRequestWriteFields`).
            let created = try await holidayStore.createRequests(
                picks: [(day: day, timeSlot: bookSlot)],
                userId: person.userId,
                operativeId: person.operativeId,
                status: .approved,
                approvedByUserId: approverId
            )
            guard let booking = created.first else {
                errorMessage = "Annual leave could not be booked."
                showError = true
                return
            }

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
            let managerName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Manager"
            if let ownerId = booking.userId ?? person.userId {
                await notificationService.notifyAnnualLeaveBookingConfirmation(
                    userId: ownerId,
                    bookingId: booking.id,
                    bookedByName: managerName,
                    startDate: booking.startDate,
                    endDate: booking.endDate,
                    timeSlot: booking.timeSlot
                )
            }
            selectedDay = nil
            successMessage = "Annual leave booking updated."
            showSuccess = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    @MainActor
    private func removeApprovedBooking(_ booking: HolidayBooking) async {
        guard canDecide(booking) else { return }
        isSaving = true
        defer { isSaving = false }
        await holidayStore.deleteBooking(booking)
        if let err = holidayStore.errorMessage, !err.isEmpty {
            errorMessage = err
            showError = true
            return
        }
        let managerName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Manager"
        if let ownerId = booking.userId ?? person.userId {
            await notificationService.notifyAnnualLeaveCancelledByManager(
                userId: ownerId,
                booking: booking,
                managerName: managerName
            )
        }
        if let selected = selectedDay, LeaveRecordDays.covers(booking, day: selected) {
            selectedDay = nil
        }
        successMessage = "Annual leave deleted."
        showSuccess = true
    }

    @MainActor
    private func deletePendingBooking() async {
        guard let booking = bookingPendingDelete else { return }
        bookingPendingDelete = nil
        await removeApprovedBooking(booking)
    }

    /// D6: admins decide any request; anyone else only where `leaveApproverIds` names them. Never their own.
    private func canDecide(_ request: HolidayBooking) -> Bool {
        let viewer = userStore.currentUser.flatMap { me in
            userStore.organizationUsers.first(where: { $0.id == me.id }) ?? me
        }
        return AnnualLeaveApproval.canDecide(
            request,
            viewer: viewer,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )
    }

    @MainActor
    private func approvePending(on day: Date) async {
        guard let booking = pendingBooking(on: day),
              let uid = firebaseBackend.currentUser?.uid,
              canDecide(booking) else { return }
        isSaving = true
        defer { isSaving = false }
        await holidayStore.approveBooking(booking, approvedByUserId: uid)
        let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Admin"
        await notifyDecision(to: booking, approved: true, decidedByName: approverName)
        await notifyAnnualLeavePeerManagers(
            request: booking,
            actorUserId: uid,
            actorName: approverName,
            actionVerb: "approved",
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives,
            notificationService: notificationService
        )
        selectedDay = nil
        successMessage = "Request approved."
        showSuccess = true
    }

    @MainActor
    private func declinePending(on day: Date) async {
        guard let booking = pendingBooking(on: day),
              let uid = firebaseBackend.currentUser?.uid,
              canDecide(booking) else { return }
        isSaving = true
        defer { isSaving = false }
        await holidayStore.rejectBooking(booking, rejectedByUserId: uid)
        let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Admin"
        await notifyDecision(to: booking, approved: false, decidedByName: approverName)
        await notifyAnnualLeavePeerManagers(
            request: booking,
            actorUserId: uid,
            actorName: approverName,
            actionVerb: "declined",
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives,
            notificationService: notificationService
        )
        selectedDay = nil
        successMessage = "Request declined."
        showSuccess = true
    }

    private func notifyDecision(to request: HolidayBooking, approved: Bool, decidedByName: String) async {
        // RULEBOOK §9, §13: the requester is the account the record names (`resolveBookingPerson` on its `userId`,
        // else its `operativeId`); `notifyHolidayRequestDecisionToUser` then asks `holidayDecisionRecipients` (never
        // the decider, no admin copy). No email or operative-mode match here.
        let requesterId = AnnualLeaveApproval.requester(
            for: request,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )?.id ?? request.userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requesterId, !requesterId.isEmpty else { return }
        await notificationService.notifyHolidayRequestDecisionToUser(
            userId: requesterId,
            bookingId: request.id,
            approved: approved,
            decidedByName: decidedByName
        )
    }

    /// The person's account: their `userId`, else the account behind their catalogue row (`resolveBookingPerson`).
    private func resolvedNotificationUserId() -> String? {
        if let uid = person.userId { return uid }
        guard let oid = person.operativeId else { return nil }
        return LabourBookingPeople(operatives: operativeStore.allOperatives, users: userStore.organizationUsers)
            .person(for: oid).user?.id
    }
}

enum AnnualLeavePersonBuilder {
    static func build(users: [AppUser], operatives: [Operative]) -> [AnnualLeavePerson] {
        var rows: [AnnualLeavePerson] = []
        // RULEBOOK 1.34.0 §11 `personDedupeKey`: one row per email, else per id, so every ghost (no email) is listed.
        var seenKeys = Set<String>()

        let operativesByEmail = Dictionary(
            operatives.filter { !$0.email.isEmpty }.map { ($0.email.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        func operativeKey(_ op: Operative) -> String {
            GhostRulebook.dedupeKey(id: op.documentId, email: op.email)
        }

        for user in users where user.isActive {
            if AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: user, users: users) { continue }
            let email = user.email.lowercased()
            guard seenKeys.insert(GhostRulebook.dedupeKey(id: user.id, email: user.email)).inserted else { continue }
            // A converted ghost's row keeps the ghost's id and has no email.
            let linkedOp = email.isEmpty
                ? operatives.first { $0.documentId.caseInsensitiveCompare(user.id) == .orderedSame }
                : operativesByEmail[email]
            if let linkedOp { seenKeys.insert(operativeKey(linkedOp)) }
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
            if let linkedUser = users.first(where: { !email.isEmpty && $0.email.lowercased() == email }),
               AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: linkedUser, users: users) {
                continue
            }
            guard seenKeys.insert(operativeKey(op)).inserted else { continue }
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
