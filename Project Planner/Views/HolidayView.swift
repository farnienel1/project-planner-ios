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
    /// When `true`, the back chevron calls `dismiss()` (sheet from home / notifications). When `false`, posts `goBackToPreviousTab` (bottom-bar Holiday tab).
    var presentedAsSheet: Bool = false

    private var isOperativeMode: Bool { userStore.isOperativeMode() }
    private var isManagerRequestMode: Bool {
        guard let u = userStore.displayUser else { return false }
        return AnnualLeaveSelfBookPolicy.usesAnnualLeaveRequestFlow(for: u)
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
    @State private var leavePage: AnnualLeavePage = .mine
    @State private var selectedHolidayTimeSlot: HolidayTimeSlot = .fullDay
    @State private var selectedDaySlots: [Date: HolidayTimeSlot] = [:]
    @State private var declineDraft: HolidayBooking?
    @State private var declineReason = ""
    @State private var showSelfServeBookedAnnualLeaveSheet = false
    @State private var halfDayBookingEditor: HolidayBooking?
    @ObservedObject private var bankHolidayService = BankHolidayService.shared
    @State private var bankHolidayTooltip: String?
    @State private var bankHolidayAlertTitle = "Annual leave calendar"
    @State private var bankHolidayCalendarTick = 0
    @State private var teamDisplayedMonth = Date()
    @State private var teamSort = AnnualLeavePersonSort.firstName
    @State private var teamTradeFilter: String?
    @State private var teamSearch = ""
    @State private var isManagingTeamLeave = false

    enum HolidaySection: String, CaseIterable {
        case calendar = "Book"
        case myHoliday = "My Annual Leave"
        case requests = "Pending"
    }

    enum AnnualLeavePage {
        case mine
        case team
    }

    private var showsTeamTab: Bool {
        if userStore.isOperativeMode() { return false }
        return userStore.canAccessOperativeAnnualLeaveDirectory() || canApproveRequests
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
            profileEmail: u.email,
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

    /// Managers/admins with self-book (or no line manager) book approved leave without a separate approver.
    private var canShowSelfServeBookedAnnualLeave: Bool {
        guard let u = userStore.displayUser else { return false }
        return AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: u)
    }

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

    private var selfBookedApprovedHolidayBookings: [HolidayBooking] {
        guard canShowSelfServeBookedAnnualLeave, let uid = firebaseBackend.currentUser?.uid else { return [] }
        return holidayStore.bookings
            .filter {
                $0.status == .approved &&
                $0.cancellationRequestedAt == nil &&
                bookingMatchesSignedInUser($0, uid: uid) &&
                !$0.isOperativeRequest
            }
            .sorted { $0.startDate > $1.startDate }
    }

    private enum CalendarDayKind {
        case none
        case approvedFull
        case approvedHalf(HolidayBooking)
        case pendingFull
        case pendingHalf(HolidayBooking)
    }

    private func bookingMatchesSignedInUser(_ booking: HolidayBooking, uid: String) -> Bool {
        AnnualLeavePolicy.holidayUserMatches(
            bookingUserId: booking.userId,
            profileUserId: uid,
            profileEmail: firebaseBackend.currentUser?.email ?? holidayProfileUser?.email
        )
    }

    private func calendarDayKind(for day: Date) -> CalendarDayKind {
        let dayStart = calendar.startOfDay(for: day)
        guard let uid = firebaseBackend.currentUser?.uid else { return .none }
        let oid = currentOperative?.id
        var pendingHalf: HolidayBooking?
        var approvedHalf: HolidayBooking?
        for booking in holidayStore.bookings {
            guard booking.status != .rejected else { continue }
            let matchesUser = bookingMatchesSignedInUser(booking, uid: uid)
            let matchesOperative = oid != nil && booking.operativeId == oid
            guard matchesUser || matchesOperative else { continue }
            let start = calendar.startOfDay(for: booking.startDate)
            let end = calendar.startOfDay(for: booking.endDate)
            guard dayStart >= start && dayStart <= end else { continue }
            let singleCalendarDay = calendar.isDate(booking.startDate, inSameDayAs: booking.endDate)
            switch booking.status {
            case .pending:
                if booking.timeSlot == .fullDay || !singleCalendarDay { return .pendingFull }
                pendingHalf = booking
            case .approved:
                guard booking.cancellationRequestedAt == nil else { continue }
                if booking.timeSlot == .fullDay || !singleCalendarDay { return .approvedFull }
                approvedHalf = booking
            case .rejected:
                continue
            }
        }
        if let b = pendingHalf { return .pendingHalf(b) }
        if let b = approvedHalf { return .approvedHalf(b) }
        return .none
    }

    var body: some View {
        NavigationStack {
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

                                if showsTeamTab {
                                    leavePageTabs
                                }

                                if leavePage == .team && showsTeamTab {
                                    teamLeavePage
                                } else {
                                    myLeavePage
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
                        await reloadBankHolidays(forceRefresh: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(HolidayChrome.canvas)
            .navigationTitle("Annual leave")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if !isManagingTeamLeave {
                    ToolbarItem(placement: .topBarLeading) {
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
                        .accessibilityLabel("Back")
                    }
                }
            }
        }
        .task(id: bankHolidayRegion.id) {
            await reloadBankHolidays(forceRefresh: false)
        }
        .task(id: displayedMonth) {
            await reloadBankHolidays(referenceDate: displayedMonth)
        }
        .task(id: teamDisplayedMonth) {
            await reloadBankHolidays(referenceDate: teamDisplayedMonth)
        }
        .onAppear {
            if showRequests, showsTeamTab { leavePage = .team }
            // Segmented control hidden for this mode — stay on Book so we never drive a Picker with a stale selection.
            if !(isRequestMode || canApproveRequests), activeSection != .calendar {
                activeSection = .calendar
            }
            if userStore.isOperativeMode() {
                operativeStore.loadData()
            }
            Task {
                await holidayStore.loadData()
            }
        }
        .onChange(of: leavePage) { _, _ in
            Task { await holidayStore.loadData() }
        }
        .onChange(of: firebaseBackend.currentOrganization?.settings.bankHolidayRegionId) { _, _ in
            Task { await reloadBankHolidays(forceRefresh: true) }
        }
        .onChange(of: bankHolidayService.holidaysByDayKey.count) { _, _ in
            bankHolidayCalendarTick += 1
        }
        .sheet(isPresented: Binding(
            get: { bankHolidayTooltip != nil },
            set: { if !$0 { bankHolidayTooltip = nil } }
        )) {
            VStack(alignment: .leading, spacing: 12) {
                Text(bankHolidayAlertTitle)
                    .font(.title3.weight(.bold))
                Text(bankHolidayTooltip ?? "")
                    .font(.body)
                    .foregroundStyle(AnnualLeavePalette.ink2)
                Button("Close") { bankHolidayTooltip = nil }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AnnualLeavePalette.soft)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(20)
            .presentationDetents([.height(220)])
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
        .overlay(alignment: .bottom) {
            if showSuccess, let successMessage {
                Text(successMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AnnualLeavePalette.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .onAppear {
                        Task {
                            try? await Task.sleep(nanoseconds: 2_200_000_000)
                            showSuccess = false
                        }
                    }
            }
        }
        .sheet(item: $declineDraft) { request in
            NavigationStack {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Decline \(requesterName(for: request))'s request for \(AnnualLeaveDateFormat.bookingTitle(request)). A reason is optional.")
                        .font(.subheadline)
                        .foregroundStyle(AnnualLeavePalette.ink2)
                    TextField("Reason", text: $declineReason, axis: .vertical)
                        .lineLimit(3...5)
                        .padding(12)
                        .background(AnnualLeavePalette.soft)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Spacer()
                }
                .padding(20)
                .navigationTitle("Decline request")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { declineDraft = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Decline") {
                            let reason = declineReason
                            declineDraft = nil
                            declineReason = ""
                            declineRequest(request, reason: reason)
                        }
                        .foregroundStyle(AnnualLeavePalette.red)
                    }
                }
            }
            .presentationDetents([.medium])
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

    private var leavePageTabs: some View {
        HStack(spacing: 4) {
            pageTab("My leave", page: .mine, badge: nil)
            pageTab("Team", page: .team, badge: approverPendingRequests.count)
        }
        .padding(4)
        .background(AnnualLeavePalette.soft)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func pageTab(_ title: String, page: AnnualLeavePage, badge: Int?) -> some View {
        Button {
            leavePage = page
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if let badge, badge > 0, page == .team {
                    Text("\(badge)")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AnnualLeavePalette.amber)
                        .clipShape(Capsule())
                }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(leavePage == page ? AnnualLeavePalette.ink : AnnualLeavePalette.ink2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(leavePage == page ? AnnualLeavePalette.card : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var myLeavePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = annualLeaveSummary {
                AnnualLeaveBalanceHero(summary: summary, pendingCaption: "Yours awaiting")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Book time off")
                    .font(.title3.weight(.bold))
                Text(isRequestMode
                     ? "Tap the days you want. Each day can be a full day, morning, or afternoon. Your line manager approves the request."
                     : "Tap the days you want. Each day can be a full day, morning, or afternoon. These book straight onto your allowance.")
                    .font(.footnote)
                    .foregroundStyle(AnnualLeavePalette.ink3)
            }
            calendarSection
            upcomingLeaveSection
            ownRequestsSection
        }
    }

    private var teamLeavePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            teamHero
            teamWaitingSection
            teamAwayCalendarSection
            teamPeopleSection
        }
    }

    private var teamHero: some View {
        let away = teamAwayTodayCount
        let waiting = approverPendingRequests.count
        let people = teamPeople.count
        let booked = teamDaysBooked
        let soon = teamAwaySoonCount
        let ring = people > 0 ? min(1, Double(away) / Double(people)) : 0
        return VStack(alignment: .leading, spacing: 12) {
            Text("TEAM · \(annualLeaveSummary?.leaveYearLabel ?? "This leave year")")
                .font(.footnote.weight(.heavy))
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.2))
                .clipShape(Capsule())
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(away)")
                        .font(.largeTitle.weight(.heavy))
                    Text("away today")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
                ZStack {
                    Circle().stroke(Color.white.opacity(0.28), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: ring)
                        .stroke(style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .foregroundStyle(.white)
                    Text(soon == 1 ? "1 soon" : "\(soon) soon")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white)
                        .dynamicTypeSize(.xSmall ... .accessibility1)
                }
                .frame(width: 86, height: 86)
            }
            HStack(spacing: 8) {
                teamHeroTile("\(waiting)", "Requests waiting")
                teamHeroTile("\(people)", "People")
                teamHeroTile(AnnualLeavePolicy.formatAllowanceDays(booked), "Days booked")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [AnnualLeavePalette.blue, AnnualLeavePalette.blue.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func teamHeroTile(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.heavy))
            Text(title).font(.footnote.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(10)
        .background(Color.white.opacity(0.17))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var teamWaitingSection: some View {
        let requests = approverPendingRequests
        return VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for you")
                .font(.title3.weight(.bold))
            if requests.isEmpty {
                Text("Nothing is waiting for you. New leave requests and cancellation requests from your team will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(AnnualLeavePalette.ink3)
                    .multilineTextAlignment(.center)
                    .padding(22)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(AnnualLeavePalette.line, style: StrokeStyle(lineWidth: 1, dash: [5]))
                    )
            } else {
                ForEach(requests) { request in
                    teamRequestCard(request)
                }
            }
        }
    }

    private func teamRequestCard(_ request: HolidayBooking) -> some View {
        let person = teamPerson(for: request)
        let name = person?.displayName ?? requesterName(for: request)
        let trade = person?.tradeLabel ?? ""
        let days = AnnualLeaveDateFormat.consumedDays(from: request.startDate, to: request.endDate, slot: request.timeSlot)
        let isCancellation = request.cancellationRequestedAt != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(initials(from: name))
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(AnnualLeavePalette.leave)
                    .frame(width: 38, height: 38)
                    .background(AnnualLeavePalette.leaveTint)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.body.weight(.semibold))
                    if !trade.isEmpty {
                        Text(trade).font(.footnote).foregroundStyle(AnnualLeavePalette.ink3)
                    }
                }
                Spacer(minLength: 0)
                if isCancellation {
                    Text("Cancellation")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(AnnualLeavePalette.violet)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AnnualLeavePalette.violetTint)
                        .clipShape(Capsule())
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(AnnualLeaveDateFormat.bookingTitle(request)) · \(AnnualLeaveDateFormat.dayCount(days))")
                    .font(.subheadline.weight(.semibold))
                if let note = remainingAfterNote(for: request, person: person) {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(AnnualLeavePalette.ink3)
                }
                let clashes = conflictingApprovedOperatives(for: request)
                if !clashes.isEmpty {
                    Text("Also off: \(clashes.joined(separator: ", "))")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AnnualLeavePalette.amber)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AnnualLeavePalette.soft)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            HStack(spacing: 8) {
                if !isCancellation {
                    Button("Decline") { declineDraft = request }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AnnualLeavePalette.soft)
                        .foregroundStyle(AnnualLeavePalette.ink2)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                Button("Approve") { approveRequest(request) }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(AnnualLeavePalette.approved)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .padding(14)
        .background(AnnualLeavePalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isCancellation ? AnnualLeavePalette.violet : AnnualLeavePalette.amber)
                .frame(width: 5)
        }
    }

    private var teamAwayCalendarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who is off, and when")
                .font(.title3.weight(.bold))
            Text("Initials show on each day, so a clash is obvious before you approve it.")
                .font(.footnote)
                .foregroundStyle(AnnualLeavePalette.ink3)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        if let next = calendar.date(byAdding: .month, value: -1, to: teamDisplayedMonth) {
                            teamDisplayedMonth = next
                        }
                    } label: {
                        Image(systemName: "chevron.left").frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(monthYearString(teamDisplayedMonth)).font(.headline)
                    Spacer()
                    Button {
                        if let next = calendar.date(byAdding: .month, value: 1, to: teamDisplayedMonth) {
                            teamDisplayedMonth = next
                        }
                    } label: {
                        Image(systemName: "chevron.right").frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(AnnualLeavePalette.ink2)
                let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
                HStack(spacing: 0) {
                    ForEach(weekdays, id: \.self) { day in
                        Text(day)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(AnnualLeavePalette.ink3)
                            .frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                    ForEach(Array(monthDays(teamDisplayedMonth).enumerated()), id: \.offset) { _, day in
                        if let date = day {
                            teamDayCell(date)
                        } else {
                            Color.clear.frame(minHeight: 44)
                        }
                    }
                }
                AnnualLeaveLegend()
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(AnnualLeavePalette.blue.opacity(0.2))
                        .frame(width: 13, height: 13)
                    Text("Two or more away")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AnnualLeavePalette.ink2)
                }
            }
            .padding(14)
            .background(AnnualLeavePalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AnnualLeavePalette.line, lineWidth: 1)
            )
        }
    }

    private func teamDayCell(_ date: Date) -> some View {
        let day = calendar.startOfDay(for: date)
        let away = teamAway(on: day)
        let block = AnnualLeaveCalendarRules.blockReason(
            for: day,
            bankHolidays: bankHolidayService.holidaysByDayKey,
            calendar: calendar
        )
        let visual: AnnualLeaveDayVisual = {
            if away.count >= 1 { return .approvedFull }
            if let block {
                switch block {
                case .bankHoliday: return .bankHoliday
                case .weekend: return .weekend
                }
            }
            return .none
        }()
        let initials = away.prefix(2).map { initials(from: $0.displayName) }.joined(separator: " ")
        return AnnualLeaveDayFace(
            dayNumber: calendar.component(.day, from: date),
            visual: away.count >= 2 ? .none : visual,
            isToday: calendar.isDateInToday(day),
            initials: initials.isEmpty ? nil : initials,
            accessibilityLabel: teamDayLabel(date: day, away: away, block: block)
        )
        .background {
            if away.count >= 2 {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(AnnualLeavePalette.blue.opacity(0.22))
            }
        }
    }

    private func teamDayLabel(date: Date, away: [AnnualLeavePerson], block: AnnualLeaveDayBlockReason?) -> String {
        let spoken = date.formatted(date: .long, time: .omitted)
        if !away.isEmpty {
            return "\(spoken), \(away.map(\.displayName).joined(separator: ", ")) away"
        }
        if let block {
            switch block {
            case .weekend: return "\(spoken), weekend"
            case .bankHoliday(let name): return "\(spoken), \(name), bank holiday"
            }
        }
        return spoken
    }

    private var teamPeopleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your team")
                .font(.title3.weight(.bold))
            TextField("Search name or trade", text: $teamSearch)
                .padding(12)
                .background(AnnualLeavePalette.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack {
                Picker("Sort by", selection: $teamSort) {
                    ForEach(AnnualLeavePersonSort.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                if !teamTradeChoices.isEmpty {
                    Picker("Trade", selection: Binding(
                        get: { teamTradeFilter ?? "All trades" },
                        set: { teamTradeFilter = $0 == "All trades" ? nil : $0 }
                    )) {
                        Text("All trades").tag("All trades")
                        ForEach(teamTradeChoices, id: \.self) { trade in
                            Text(trade).tag(trade)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            if filteredTeamPeople.isEmpty {
                Text("No one on the team matches those filters. People who book their own leave are not listed here.")
                    .font(.subheadline)
                    .foregroundStyle(AnnualLeavePalette.ink3)
                    .padding(18)
            } else {
                ForEach(filteredTeamPeople) { person in
                    NavigationLink {
                        OperativeAnnualLeaveCalendarView(person: person)
                            .environmentObject(holidayStore)
                            .environmentObject(firebaseBackend)
                            .environmentObject(notificationService)
                            .environmentObject(operativeStore)
                            .environmentObject(userStore)
                    } label: {
                        teamPersonRow(person)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func teamPersonRow(_ person: AnnualLeavePerson) -> some View {
        let balance = teamBalance(for: person)
        return HStack(spacing: 11) {
            Text(initials(from: person.displayName))
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(AnnualLeavePalette.leave)
                .frame(width: 38, height: 38)
                .background(AnnualLeavePalette.leaveTint)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AnnualLeavePalette.ink)
                Text(person.tradeLabel)
                    .font(.footnote)
                    .foregroundStyle(AnnualLeavePalette.ink3)
            }
            Spacer(minLength: 0)
            if let balance {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(AnnualLeavePolicy.formatAllowanceDays(balance.remaining))
                        .font(.headline)
                        .foregroundStyle(balance.remaining < -0.001 ? AnnualLeavePalette.red : AnnualLeavePalette.ink)
                    Text("of \(AnnualLeavePolicy.formatAllowanceDays(balance.allowance)) left")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AnnualLeavePalette.ink3)
                }
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AnnualLeavePalette.ink3)
        }
        .padding(12)
        .background(AnnualLeavePalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AnnualLeavePalette.line, lineWidth: 1)
        )
    }

    private var teamPeople: [AnnualLeavePerson] {
        AnnualLeavePersonBuilder.build(
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )
    }

    private var teamTradeChoices: [String] {
        Array(Set(teamPeople.map(\.tradeLabel).filter { !$0.isEmpty && $0 != "General" })).sorted()
    }

    private var filteredTeamPeople: [AnnualLeavePerson] {
        var rows = teamPeople
        if let teamTradeFilter, !teamTradeFilter.isEmpty {
            rows = rows.filter { $0.tradeLabel == teamTradeFilter }
        }
        let query = teamSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            rows = rows.filter {
                $0.displayName.localizedCaseInsensitiveContains(query) ||
                $0.tradeLabel.localizedCaseInsensitiveContains(query) ||
                $0.subtitle.localizedCaseInsensitiveContains(query)
            }
        }
        switch teamSort {
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

    private var teamAwayTodayCount: Int {
        let today = calendar.startOfDay(for: Date())
        return Set(teamAway(on: today).map(\.id)).count
    }

    private var teamAwaySoonCount: Int {
        let today = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 14, to: today) else { return 0 }
        var ids = Set<String>()
        var day = today
        while day <= end {
            for person in teamAway(on: day) { ids.insert(person.id) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return ids.count
    }

    private var teamDaysBooked: Double {
        teamPeople.reduce(0) { partial, person in
            partial + (teamBalance(for: person)?.taken ?? 0)
        }
    }

    private func teamAway(on day: Date) -> [AnnualLeavePerson] {
        let dayStart = calendar.startOfDay(for: day)
        var seen = Set<String>()
        var people: [AnnualLeavePerson] = []
        for booking in holidayStore.bookings where booking.status == .approved && booking.cancellationRequestedAt == nil {
            let start = calendar.startOfDay(for: booking.startDate)
            let end = calendar.startOfDay(for: booking.endDate)
            guard dayStart >= start && dayStart <= end else { continue }
            guard let person = teamPerson(for: booking), seen.insert(person.id).inserted else { continue }
            people.append(person)
        }
        return people
    }

    private func teamPerson(for booking: HolidayBooking) -> AnnualLeavePerson? {
        teamPeople.first { person in
            let email = person.userId.flatMap { uid in
                userStore.organizationUsers.first(where: { $0.id == uid })?.email
            }
            if AnnualLeavePolicy.holidayUserMatches(bookingUserId: booking.userId, profileUserId: person.userId, profileEmail: email) {
                return true
            }
            if let oid = person.operativeId, booking.operativeId == oid { return true }
            return false
        }
    }

    private func teamBalance(for person: AnnualLeavePerson) -> (remaining: Double, allowance: Double, taken: Double)? {
        guard let user = teamUser(for: person) else { return nil }
        let summary = AnnualLeavePolicy.usageSummary(
            bookings: holidayStore.bookings,
            profileUserId: user.id,
            operativeId: person.operativeId,
            profileEmail: user.email,
            daysPerYear: user.annualLeaveDaysPerYear,
            startMonth: user.annualLeaveYearStartMonth,
            endMonth: user.annualLeaveYearEndMonth,
            carriesOver: user.annualLeaveCarriesOver,
            referenceDate: Date(),
            calendar: calendar
        )
        return (summary.remainingDays, summary.entitlementDays, summary.takenDays)
    }

    private func teamUser(for person: AnnualLeavePerson) -> AppUser? {
        if let uid = person.userId {
            return userStore.organizationUsers.first { $0.id == uid }
        }
        if let oid = person.operativeId,
           let operative = operativeStore.allOperatives.first(where: { $0.id == oid }) {
            return userStore.organizationUsers.first { $0.email.lowercased() == operative.email.lowercased() }
        }
        return nil
    }

    private func remainingAfterNote(for request: HolidayBooking, person: AnnualLeavePerson?) -> String? {
        guard let person, let balance = teamBalance(for: person) else { return nil }
        let days = AnnualLeaveDateFormat.consumedDays(from: request.startDate, to: request.endDate, slot: request.timeSlot)
        let after = request.cancellationRequestedAt != nil
            ? balance.allowance - balance.taken + days
            : balance.allowance - balance.taken - days
        return "Remaining after: \(AnnualLeavePolicy.formatAllowanceDays(after)) of \(AnnualLeavePolicy.formatAllowanceDays(balance.allowance))"
    }

    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }
        let text = String(letters).uppercased()
        return text.isEmpty ? "?" : text
    }

    private func monthDays(_ month: Date) -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else { return [] }
        let firstWeekday = (calendar.component(.weekday, from: first) + 5) % 7
        var days: [Date?] = Array(repeating: nil, count: firstWeekday)
        for offset in 0..<range.count {
            if let date = calendar.date(byAdding: .day, value: offset, to: first) {
                days.append(date)
            }
        }
        return days
    }

    private var upcomingLeaveSection: some View {
        let today = calendar.startOfDay(for: Date())
        let upcoming = holidayStore.myBookings(userId: firebaseBackend.currentUser?.uid, operativeId: currentOperative?.id)
            .filter { booking in
                booking.status != .rejected && calendar.startOfDay(for: booking.endDate) >= today
            }
            .sorted { $0.startDate < $1.startDate }
        let spans = AnnualLeaveDateFormat.displaySpans(from: upcoming, calendar: calendar)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming leave")
                .font(.title3.weight(.bold))
            if spans.isEmpty {
                Text("Approved and pending leave from today onwards will show here, grouped by the days you booked.")
                    .font(.subheadline)
                    .foregroundStyle(AnnualLeavePalette.ink3)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AnnualLeavePalette.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                ForEach(spans) { span in
                    HolidayRowView(
                        booking: span.primary,
                        titleOverride: span.title,
                        actionTitle: canShowSelfServeBookedAnnualLeave ? "Remove" : "Request cancellation",
                        onRequestCancellation: leaveRowAction(for: span.primary)
                    )
                }
            }
        }
    }

    private var ownRequestsSection: some View {
        let mine = holidayStore.myBookings(userId: firebaseBackend.currentUser?.uid, operativeId: currentOperative?.id)
            .filter { $0.status == .pending || $0.cancellationRequestedAt != nil }
            .sorted { $0.startDate > $1.startDate }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Your requests")
                .font(.title3.weight(.bold))
            Text("These are waiting on your line manager, including cancellations.")
                .font(.footnote)
                .foregroundStyle(AnnualLeavePalette.ink3)
            if mine.isEmpty {
                Text("Nothing is waiting on a decision. New requests and cancellation requests will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(AnnualLeavePalette.ink3)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AnnualLeavePalette.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                ForEach(mine) { request in
                    HolidayRowView(booking: request)
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
                heroMetric(title: "Pending", value: summary.pendingDays, color: HolidayChrome.pendingMetric)
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
            calendarLegend
            calendarGrid
            submitButton
        }
    }

    private var calendarLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            AnnualLeaveLegend()
            if let error = bankHolidayService.lastErrorMessage, bankHolidayService.holidaysByDayKey.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AnnualLeavePalette.red)
            }
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
            .id(bankHolidayCalendarTick)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ProjectWorksRevampColors.surface)
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
        let dayKind = calendarDayKind(for: day)
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
                    bankHolidayTooltip = "\(name) is a bank holiday. It cannot be booked as annual leave and it is not taken out of your allowance."
                }
                return
            }
            switch dayKind {
            case .approvedFull, .pendingFull:
                bankHolidayAlertTitle = "Already booked"
                bankHolidayTooltip = "This day already has annual leave on it."
            case .approvedHalf(let b), .pendingHalf(let b):
                halfDayBookingEditor = b
            case .none:
                let sod = calendar.startOfDay(for: day)
                if selectedDates.contains(sod) {
                    selectedDates.remove(sod)
                    selectedDaySlots.removeValue(forKey: sod)
                } else {
                    selectedDates.insert(sod)
                    selectedDaySlots[sod] = .fullDay
                }
            }
        } label: {
            AnnualLeaveDayFace(
                dayNumber: calendar.component(.day, from: date),
                visual: faceVisual(dayKind: dayKind, blockReason: blockReason),
                isSelected: isSelected,
                isToday: isToday,
                accessibilityLabel: dayAccessibilityLabel(date: day, dayKind: dayKind, blockReason: blockReason, isSelected: isSelected)
            )
            .opacity(isInMonth ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!isInMonth)
    }

    private func faceVisual(dayKind: CalendarDayKind, blockReason: AnnualLeaveDayBlockReason?) -> AnnualLeaveDayVisual {
        if let blockReason {
            switch blockReason {
            case .bankHoliday: return .bankHoliday
            case .weekend: return .weekend
            }
        }
        switch dayKind {
        case .approvedFull: return .approvedFull
        case .approvedHalf: return .approvedHalf
        case .pendingFull, .pendingHalf: return .pending
        case .none: return .none
        }
    }

    private func dayAccessibilityLabel(date: Date, dayKind: CalendarDayKind, blockReason: AnnualLeaveDayBlockReason?, isSelected: Bool) -> String {
        let spoken = date.formatted(date: .long, time: .omitted)
        if isSelected {
            let slot = selectedDaySlots[date] ?? .fullDay
            return "\(spoken), selected, \(slot.rawValue)"
        }
        if let blockReason {
            switch blockReason {
            case .weekend: return "\(spoken), weekend, not bookable"
            case .bankHoliday(let name): return "\(spoken), \(name), bank holiday, not bookable"
            }
        }
        switch dayKind {
        case .approvedFull: return "\(spoken), approved full day"
        case .approvedHalf: return "\(spoken), approved half day"
        case .pendingFull, .pendingHalf: return "\(spoken), pending"
        case .none: return spoken
        }
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

    private var selectedDatesSorted: [Date] {
        selectedDates.sorted()
    }

    private func hasExistingHoliday(on day: Date, userId: String?, operativeId: UUID?) -> Bool {
        holidayStore.bookings.contains { booking in
            guard booking.status != .rejected else { return false }
            let matchesUser = AnnualLeavePolicy.holidayUserMatches(
                bookingUserId: booking.userId,
                profileUserId: userId,
                profileEmail: holidayProfileUser?.email
            )
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
        return AnnualLeavePolicy.validateProposedDaySlots(
            daySlots: Dictionary(uniqueKeysWithValues: startOfDays.map { day in
                (day, selectedDaySlots[day] ?? selectedHolidayTimeSlot)
            }),
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
        selectedDaySlots.removeAll()
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
                            timeSlot: selectedDaySlots[calendar.startOfDay(for: day)] ?? selectedHolidayTimeSlot
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
                            requesterUserId: uid,
                            excludeUserIdMatchingRequester: uid
                        )
                    }
                    await MainActor.run {
                        successMessage = "Annual leave request submitted for \(selectedDays.count) day\(selectedDays.count == 1 ? "" : "s")."
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
                            timeSlot: selectedDaySlots[calendar.startOfDay(for: day)] ?? selectedHolidayTimeSlot
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
                            successMessage = "Annual leave request submitted for \(selectedDays.count) day\(selectedDays.count == 1 ? "" : "s")."
                        } else {
                            successMessage = "Annual leave booked for \(selectedDays.count) day\(selectedDays.count == 1 ? "" : "s")."
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
        let sorted = selectedDates.sorted()
        let total = sorted.reduce(0.0) { $0 + (selectedDaySlots[$1] ?? .fullDay).dayValue }
        let remainingAfter = (annualLeaveSummary?.remainingDays ?? 0) - total
        return VStack(alignment: .leading, spacing: 12) {
            if !sorted.isEmpty {
                FlowDayChips(
                    days: sorted,
                    slots: selectedDaySlots,
                    onSlot: { day, slot in
                        selectedDaySlots[day] = slot
                    },
                    onRemove: { day in
                        selectedDates.remove(day)
                        selectedDaySlots.removeValue(forKey: day)
                    }
                )
                HStack {
                    Text(AnnualLeaveDateFormat.dayCount(total))
                        .font(.headline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Remaining after")
                            .font(.caption)
                            .foregroundStyle(AnnualLeavePalette.ink3)
                        Text(AnnualLeavePolicy.formatAllowanceDays(remainingAfter))
                            .font(.headline)
                            .foregroundStyle(remainingAfter < -0.001 ? AnnualLeavePalette.red : AnnualLeavePalette.ink)
                    }
                }
                .padding(12)
                .background(AnnualLeavePalette.soft)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                if let allowanceMsg = selectionAllowanceViolationMessage {
                    Text(allowanceMsg)
                        .font(.footnote)
                        .foregroundStyle(AnnualLeavePalette.ink2)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AnnualLeavePalette.redTint)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
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
                .background(!selectedDates.isEmpty ? AnnualLeavePalette.leave : Color.gray.opacity(0.45))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(selectedDates.isEmpty || isSaving)
        }
    }

    private var currentOperative: Operative? {
        guard let email = userStore.currentUser?.email else { return nil }
        return operativeStore.allOperatives.first { $0.email.lowercased() == email.lowercased() }
    }

    private var approverPendingRequests: [HolidayBooking] {
        guard let me = userStore.currentUser else { return [] }
        let all = holidayStore.pendingRequests
            .filter { !isOwnAnnualLeave($0) && !isSelfBookedRequester($0) }
            .sorted { $0.startDate > $1.startDate }
        // Every assigned line manager can approve. Only one decision is required.
        if me.permissions.manager && !me.isSuperAdmin && !me.permissions.adminAccess && me.role != .admin {
            return all.filter { lineManagerIds(for: $0).contains(me.id) }
        }
        if userStore.hasAdminAccess() {
            return all.filter {
                let managers = lineManagerIds(for: $0)
                return managers.isEmpty || managers.contains(me.id)
            }
        }
        return []
    }

    /// Team is other people's requests. Your own leave stays on My leave, even for an admin.
    private func isOwnAnnualLeave(_ request: HolidayBooking) -> Bool {
        let ids = Set([firebaseBackend.currentUser?.uid, userStore.currentUser?.id].compactMap { $0 })
        if let uid = request.userId, ids.contains(uid) { return true }
        if let email = userStore.currentUser?.email.lowercased(),
           let oid = request.operativeId,
           let operative = operativeStore.allOperatives.first(where: { $0.id == oid }),
           operative.email.lowercased() == email {
            return true
        }
        return false
    }

    /// People who book their own leave are not approved from the team queue.
    private func isSelfBookedRequester(_ request: HolidayBooking) -> Bool {
        if let uid = request.userId,
           let requester = userStore.organizationUsers.first(where: { $0.id == uid }) {
            return AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: requester)
        }
        if let oid = request.operativeId,
           let operative = operativeStore.allOperatives.first(where: { $0.id == oid }),
           let requester = userStore.organizationUsers.first(where: { $0.email.lowercased() == operative.email.lowercased() }) {
            return AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: requester)
        }
        return false
    }

    private func lineManagerIds(for request: HolidayBooking) -> [String] {
        if let uid = request.userId,
           let requester = userStore.organizationUsers.first(where: { $0.id == uid }) {
            guard AnnualLeaveSelfBookPolicy.usesAnnualLeaveRequestFlow(for: requester) else { return [] }
            return requester.lineManagerUserIds
        }
        if let oid = request.operativeId,
           let op = operativeStore.allOperatives.first(where: { $0.id == oid }),
           let requester = userStore.organizationUsers.first(where: {
               ($0.permissions.operativeMode || $0.role == .operative) &&
               $0.email.lowercased() == op.email.lowercased()
           }) {
            guard AnnualLeaveSelfBookPolicy.usesAnnualLeaveRequestFlow(for: requester) else { return [] }
            return requester.lineManagerUserIds
        }
        return []
    }

    private func assignedApproverUserId(for request: HolidayBooking) -> String? {
        if let uid = request.userId,
           let requester = userStore.organizationUsers.first(where: { $0.id == uid }) {
            if AnnualLeaveSelfBookPolicy.usesAnnualLeaveRequestFlow(for: requester) {
                return requester.primaryLineManagerUserId
            }
            return nil
        }
        if let oid = request.operativeId,
           let op = operativeStore.allOperatives.first(where: { $0.id == oid }),
           let requester = userStore.organizationUsers.first(where: {
               ($0.permissions.operativeMode || $0.role == .operative) &&
               $0.email.lowercased() == op.email.lowercased()
           }) {
            return requester.primaryLineManagerUserId
        }
        return nil
    }

    private func approveRequest(_ request: HolidayBooking) {
        guard let uid = firebaseBackend.currentUser?.uid else { return }
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
                await notifyPeerLineManagers(
                    for: request,
                    actorUserId: uid,
                    actorName: approverName,
                    actionVerb: "approved"
                )
                return
            } else {
                await holidayStore.approveBooking(request, approvedByUserId: uid)
            }
            let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Admin"
            await notifyDecision(to: request, approved: true, decidedByName: approverName)
            await notifyPeerLineManagers(
                for: request,
                actorUserId: uid,
                actorName: approverName,
                actionVerb: "approved"
            )
        }
    }

    private func peerNotice(for request: HolidayBooking, actorName: String, actionVerb: String) -> String {
        let name = requesterName(for: request)
        let dates = AnnualLeaveDateFormat.bookingTitle(request)
        let subject = request.cancellationRequestedAt != nil ? "annual leave cancellation" : "annual leave request"
        return "\(actorName) \(actionVerb) \(name)'s \(subject). \(dates)"
    }

    private func notifyPeerLineManagers(
        for request: HolidayBooking,
        actorUserId: String,
        actorName: String,
        actionVerb: String
    ) async {
        let requesterUser: AppUser? = {
            if let uid = request.userId {
                return userStore.organizationUsers.first(where: { $0.id == uid })
            }
            if let oid = request.operativeId,
               let op = operativeStore.allOperatives.first(where: { $0.id == oid }) {
                return userStore.organizationUsers.first(where: {
                    $0.email.lowercased() == op.email.lowercased()
                })
            }
            return nil
        }()
        guard let requesterUser else { return }
        let peers = requesterUser.lineManagerUserIds.filter { $0 != actorUserId }
        guard !peers.isEmpty else { return }
        await notificationService.notifyLineManagerPeerAction(
            actorName: actorName,
            actionSummary: peerNotice(for: request, actorName: actorName, actionVerb: actionVerb),
            peerManagerUserIds: peers,
            excludingActorUserId: actorUserId,
            actionVerb: actionVerb,
            message: peerNotice(for: request, actorName: actorName, actionVerb: actionVerb)
        )
    }

    private func declineRequest(_ request: HolidayBooking, reason: String = "") {
        if request.cancellationRequestedAt != nil { return }
        guard let uid = firebaseBackend.currentUser?.uid else { return }
        Task {
            await holidayStore.rejectBooking(request, rejectedByUserId: uid, reason: reason)
            let approverName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Admin"
            await notifyDecision(to: request, approved: false, decidedByName: approverName, reason: reason)
            await notifyPeerLineManagers(
                for: request,
                actorUserId: uid,
                actorName: approverName,
                actionVerb: "declined"
            )
        }
    }

    private func notifyDecision(to request: HolidayBooking, approved: Bool, decidedByName: String, reason: String = "") async {
        if let requesterUserId = request.userId {
            await notificationService.notifyHolidayRequestDecisionToUser(
                userId: requesterUserId,
                bookingId: request.id,
                approved: approved,
                decidedByName: decidedByName,
                reason: reason
            )
            if approved,
               let requester = userStore.organizationUsers.first(where: { $0.id == requesterUserId }),
               AnnualLeaveSelfBookPolicy.usesAnnualLeaveRequestFlow(for: requester),
               requester.permissions.manager {
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
                decidedByName: decidedByName,
                reason: reason
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

    private func leaveRowAction(for booking: HolidayBooking) -> (() -> Void)? {
        guard booking.status == .approved, booking.cancellationRequestedAt == nil else { return nil }
        if canShowSelfServeBookedAnnualLeave {
            return {
                Task {
                    await holidayStore.deleteBooking(booking)
                    successMessage = "Annual leave removed."
                    showSuccess = true
                }
            }
        }
        return { requestCancellation(for: booking) }
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
                requesterUserId: uid,
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
    var titleOverride: String? = nil
    var actionTitle: String = "Request cancellation"
    var onRequestCancellation: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(titleOverride ?? AnnualLeaveDateFormat.bookingTitle(booking))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AnnualLeavePalette.ink)
                Text(booking.timeSlot.rawValue)
                    .font(.footnote)
                    .foregroundStyle(AnnualLeavePalette.ink3)
                Text(statusText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusColor)
                if let onRequestCancellation {
                    Button(actionTitle) {
                        onRequestCancellation()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                } else if booking.cancellationRequestedAt != nil && booking.status == .approved {
                    Text("Cancellation pending manager approval")
                        .font(.caption)
                        .foregroundStyle(AnnualLeavePalette.violet)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AnnualLeavePalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(statusColor)
                .frame(width: 5)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
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
            Text(AnnualLeaveDateFormat.bookingTitle(request))
                .font(.subheadline.weight(.semibold))
            if request.cancellationRequestedAt != nil {
                Text("Cancellation request")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AnnualLeavePalette.violet)
            }
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
