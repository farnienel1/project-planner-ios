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
    @EnvironmentObject private var smartCache: SmartCacheService

    var showRequests: Bool = false
    /// When `true`, the back chevron calls `dismiss()` (sheet from home / notifications). When `false`, posts `goBackToPreviousTab` (bottom-bar Holiday tab).
    var presentedAsSheet: Bool = false

    private var isOperativeMode: Bool { userStore.isOperativeMode() }
    private var isManagerRequestMode: Bool {
        guard let u = userStore.displayUser else { return false }
        return AnnualLeaveSelfBookPolicy.usesAnnualLeaveRequestFlow(for: u, users: userStore.organizationUsers)
    }
    private var isRequestMode: Bool { isOperativeMode || isManagerRequestMode }
    /// Shown while `lineManagerRequiredError` says this person is missing a current line manager, so
    /// `leaveApproverIds` routes their requests to the admins.
    private var showsNoLineManagerNotice: Bool {
        guard isRequestMode, let user = holidayProfileUser ?? userStore.displayUser else { return false }
        return AnnualLeaveApproval.showsNoLineManagerNotice(for: user, users: userStore.organizationUsers)
    }
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
    /// RULEBOOK 1.40.0 §4.4: manual adjustments of the signed-in person and their Team list (live while open).
    @StateObject private var adjustmentsModel = AnnualLeaveAdjustmentsModel()
    /// Answers for the Team page kept while their inputs are unchanged (the calendar asks for every day cell).
    @State private var teamCache = HolidayTeamCache()
    /// A notification (`annualLeavePerson`) opens one person's page.
    @State private var deepLinkedTeamPerson: AnnualLeavePerson?

    enum HolidaySection: String, CaseIterable {
        case calendar = "Book"
        case myHoliday = "My Annual Leave"
        case requests = "Pending"
    }

    enum AnnualLeavePage {
        case mine
        case team
    }

    /// RULEBOOK 1.40.0 `annualLeaveTeamTabVisible`: admins, and anyone who line-manages at least one current person —
    /// the Operatives toggle plays no part.
    private var showsTeamTab: Bool {
        AnnualLeavePersonBuilder.teamTabVisible(
            viewer: holidayProfileUser,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )
    }

    /// Leave days are organisation business days (§1): organisation zone, Monday-first.
    private var calendar: Calendar { OrganizationRulebookContext.calendar }

    private var holidayProfileUser: AppUser? {
        guard let uid = firebaseBackend.currentUser?.uid else { return nil }
        return userStore.organizationUsers.first(where: { $0.id == uid }) ?? userStore.currentUser
    }

    private var annualLeaveSummary: AnnualLeaveUsageSummary? {
        guard let u = holidayProfileUser else { return nil }
        let oid = currentOperative?.id
        let org = firebaseBackend.currentOrganization?.settings.annualLeaveDefaults ?? .default
        return AnnualLeavePolicy.usageSummary(
            bookings: holidayStore.myBookings(account: u, operatives: operativeStore.allOperatives, operativeId: oid),
            daysPerYear: u.annualLeaveDaysPerYear,
            startMonth: u.annualLeaveYearStartMonth,
            endMonth: u.annualLeaveYearEndMonth,
            carriesOver: u.annualLeaveCarriesOver,
            referenceDate: Date(),
            calendar: calendar,
            annualLeaveEnabled: u.annualLeaveEnabled,
            orgDaysPerYear: org.daysPerYear,
            orgStartMonth: org.startMonth,
            orgEndMonth: org.endMonth,
            yearAllowance: u.annualLeaveYearAllowance,
            yearAllowanceKey: u.annualLeaveYearAllowanceKey,
            employmentStartDayKey: u.employmentStartDate,
            // RULEBOOK 1.40.0 §4.4: the allowance applies only on PAYE days; this year's adjustments on top.
            employment: AnnualLeaveEmployment(u),
            adjustments: adjustmentsModel.rows(for: RulebookPeople.ownerIds(for: u, users: userStore.organizationUsers))
        )
    }

    /// RULEBOOK §9: `CanonicalBusinessEngine.leaveSubmitLabel(user, roster)` — "Submit" when the leave saves approved, else "Submit request".
    private var leaveSubmitButtonTitle: String {
        if let u = userStore.displayUser,
           let label = RulebookPeople.leaveSubmitLabel(u, users: userStore.organizationUsers) {
            return label
        }
        return isRequestMode ? "Submit request" : "Submit"
    }

    /// `canSelfBookAnnualLeave(user, roster)` (RULEBOOK 1.28.0): Annual Leave Management, or the organisation's Super Admin.
    private var canShowSelfServeBookedAnnualLeave: Bool {
        guard let u = userStore.displayUser else { return false }
        return AnnualLeaveSelfBookPolicy.canSelfBookAnnualLeave(for: u, users: userStore.organizationUsers)
    }

    /// `BANK_HOLIDAY_REGIONS` row for the saved region (rulebook §4.4). Nil only when the script did not answer.
    private var bankHolidayRegion: BankHolidayRegion? {
        CanonicalBusinessEngine.resolvedBankHolidayRegion(for: firebaseBackend.currentOrganization)
    }

    private func reloadBankHolidays(referenceDate: Date = Date(), forceRefresh: Bool = false) async {
        guard let region = bankHolidayRegion else { return }
        await bankHolidayService.ensureLoaded(
            region: region,
            referenceDate: referenceDate,
            forceRefresh: forceRefresh,
            // RULEBOOK 1.35.0 `myProfileBankHolidayRange`: the previous leave year's bank holidays too (carry-over).
            alsoYears: CanonicalBusinessEngine.leaveBalanceBankHolidayYears(for: holidayProfileUser)
        )
        bankHolidayCalendarTick += 1
    }

    private var selfBookedApprovedHolidayBookings: [HolidayBooking] {
        guard canShowSelfServeBookedAnnualLeave, firebaseBackend.currentUser?.uid != nil else { return [] }
        return signedInLeave
            .filter {
                $0.status == .approved &&
                $0.cancellationRequestedAt == nil &&
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

    /// RULEBOOK 1.9.0 §9, §10: the signed-in person's leave by every id of their account (`leaveRecordsForAccount`
    /// through `HolidayStore.myBookings`), never by the uid or the email alone.
    private var signedInLeave: [HolidayBooking] {
        holidayStore.myBookings(
            account: holidayProfileUser,
            operatives: operativeStore.allOperatives,
            operativeId: currentOperative?.id,
            userId: firebaseBackend.currentUser?.uid
        )
    }

    /// RULEBOOK 1.23.0 §9 `CanonicalBusinessEngine.leaveDayKind`: the signed-in person's leave on the organisation day —
    /// leave days only, rejected never, approved with a pending cancellation still approved, fixed order.
    private func calendarDayKind(for day: Date) -> CalendarDayKind {
        guard firebaseBackend.currentUser?.uid != nil else { return .none }
        let mine = signedInLeave
        guard let answer = CanonicalBusinessEngine.leaveDayAnswer(
            records: mine.map(\.rulebookLeaveRecord),
            dayKey: OrganizationRulebookContext.dayKey(day),
            nonWorkingDayKeys: OrganizationBankHolidays.dayKeys
        ) else { return .none }
        let record = mine.first { $0.documentId == answer.recordId }
        switch answer.kind {
        case .pendingFull: return .pendingFull
        case .approvedFull: return .approvedFull
        case .pendingHalf: return record.map { CalendarDayKind.pendingHalf($0) } ?? CalendarDayKind.none
        case .approvedHalf: return record.map { CalendarDayKind.approvedHalf($0) } ?? CalendarDayKind.none
        case .none: return .none
        }
    }

    var body: some View {
        NavigationStack {
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
                        .accessibilityIdentifier("leave.retry")
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 18) {
                                PPNavyPageTitle(title: "Annual leave")
                                if showsTeamTab {
                                    leavePageTabs
                                }
                            }
                            .padding(.horizontal, PPMetrics.screenGutter)
                            .padding(.top, 16)
                            .padding(.bottom, PPMetrics.headerBottomPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .ppNavyHeader()

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
                                        .accessibilityIdentifier("leave.retry2")
                                        .buttonStyle(.bordered)
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
                                }

                                if leavePage == .team && showsTeamTab {
                                    teamLeavePage
                                } else {
                                    myLeavePage
                                }
                            }
                            .padding(.top, 20)
                            .padding(.bottom, 28)
                            .ppContentSheet()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PPColor.page)
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
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("Annual leave")
            .navigationBarTitleDisplayMode(.inline)
            .ppNavyNavigationBar()
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
                                .foregroundStyle(.white)
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityIdentifier("leave.back")
                        .accessibilityLabel("Back")
                    }
                }
            }
        }
        .task(id: bankHolidayRegion?.id) {
            await reloadBankHolidays(forceRefresh: false)
        }
        .task(id: displayedMonth) {
            await reloadBankHolidays(referenceDate: displayedMonth)
        }
        .task(id: teamDisplayedMonth) {
            await reloadBankHolidays(referenceDate: teamDisplayedMonth)
        }
        .task(id: adjustmentUserIds.joined(separator: "|")) {
            // RULEBOOK 1.40.0 §4.4: the adjustments of the people this page shows (each under their users id).
            adjustmentsModel.listen(backend: firebaseBackend, userIds: adjustmentUserIds)
        }
        .onAppear {
            if showRequests, showsTeamTab { leavePage = .team }
            // RULEBOOK 1.40.0: `annual_leave_adjusted` opens that person's page on Team.
            if let personUserId = AnnualLeaveDeepLinkContext.takePendingPersonUserId(),
               let target = teamPeople.first(where: { $0.userId == personUserId }) {
                leavePage = .team
                deepLinkedTeamPerson = target
            }
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
                // The whole pill is the button: the padding and fill sit inside the label, so a tap anywhere on it
                // closes the sheet. Before, they were outside the Button and only the word "Close" took the tap.
                Button {
                    bankHolidayTooltip = nil
                } label: {
                    Text("Close")
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AnnualLeavePalette.soft)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("leave.close")
            }
            .padding(20)
            // `.medium` lets the sheet grow when larger text pushes the button past 220 points.
            .presentationDetents([.height(220), .medium])
        }
        .onChange(of: userStore.currentUser?.id) { _, _ in
            if !(isRequestMode || canApproveRequests), activeSection != .calendar {
                activeSection = .calendar
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { showError = false }
                .accessibilityIdentifier("leave.ok")
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
                        .accessibilityIdentifier("leave.reason")
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
                            .accessibilityIdentifier("leave.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Decline") {
                            let reason = declineReason
                            declineDraft = nil
                            declineReason = ""
                            declineRequest(request, reason: reason)
                        }
                        .accessibilityIdentifier("leave.decline")
                        .foregroundStyle(AnnualLeavePalette.red)
                        // RULEBOOK §2: annual leave approval is online only.
                        .disabled(!smartCache.isOnline)
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
                                bookings: holidayStore.myBookings(account: u, operatives: operativeStore.allOperatives, operativeId: currentOperative?.id),
                                daysPerYear: u.annualLeaveDaysPerYear,
                                startMonth: u.annualLeaveYearStartMonth,
                                endMonth: u.annualLeaveYearEndMonth,
                                carriesOver: u.annualLeaveCarriesOver,
                                employmentStartDayKey: u.employmentStartDate,
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
                                .accessibilityIdentifier("leave.row.\(booking.id).removeBooking")
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove booking")
                            }
                            .listRowBackground(PPColor.card)
                        }
                    }
                } footer: {
                    Text("These days are already approved. Remove a row to delete that booking without a separate approval step.")
                        .font(.caption)
                        .foregroundStyle(HolidayChrome.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(PPColor.page)
            .navigationTitle("Booked annual leave")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showSelfServeBookedAnnualLeaveSheet = false }
                        .accessibilityIdentifier("leave.done")
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
        .background(Capsule().fill(PPColor.onNavyFill))
        .overlay(Capsule().strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5))
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
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(leavePage == page ? PPColor.navy : Color.white.opacity(0.75))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Capsule().fill(leavePage == page ? Color.white : Color.clear))
        }
        .accessibilityIdentifier("leave.\(AccessibilityID.token(title))")
        .buttonStyle(.plain)
    }

    private var myLeavePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = annualLeaveSummary {
                AnnualLeaveBalanceHero(summary: summary, pendingCaption: "Yours awaiting")
                // RULEBOOK 1.40.0 §4.4: the person sees their adjustments (amount, reason, date), not who made them.
                if let me = holidayProfileUser {
                    AnnualLeaveAdjustmentsCard(
                        adjustments: adjustmentsModel.rows(for: RulebookPeople.ownerIds(for: me, users: userStore.organizationUsers)),
                        yearKey: summary.yearKey,
                        showAuthor: false,
                        hasAllowance: summary.hasAllowance
                    )
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Book time off")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Text(isRequestMode
                     ? "Tap the days you want. Each day can be a full day, morning, or afternoon. Your line manager approves the request."
                     : "Tap the days you want. Each day can be a full day, morning, or afternoon. These book straight onto your allowance.")
                    .font(.footnote)
                    .foregroundStyle(AnnualLeavePalette.ink3)
                if showsNoLineManagerNotice {
                    Text("Your requests go to the company admins until a line manager is set.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AnnualLeavePalette.ink2)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AnnualLeavePalette.soft)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityIdentifier("leave.noLineManagerNotice")
                }
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
        .navigationDestination(item: $deepLinkedTeamPerson) { person in
            OperativeAnnualLeaveCalendarView(person: person)
                .environmentObject(holidayStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
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
            Text("TEAM · \(teamLeaveYearLabel)")
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(PPColor.onNavyFill))
                .overlay(Capsule().strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5))
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(away)")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    Text("Away today")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PPColor.onNavySecondary)
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
                ZStack {
                    Circle().stroke(PPColor.onNavyFill, lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: ring)
                        .stroke(style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .foregroundStyle(
                            LinearGradient(colors: [PPColor.glow, .white], startPoint: .top, endPoint: .bottom)
                        )
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
        .background(PPNavyBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func teamHeroTile(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(title)
                .font(.caption)
                .foregroundStyle(PPColor.onNavyCaption)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(PPColor.onNavyFill))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5))
    }

    private var teamWaitingSection: some View {
        let requests = approverPendingRequests
        return VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for you")
                .font(.system(.title3, design: .rounded).weight(.bold))
            if requests.isEmpty {
                Text("Nothing is waiting for you. New leave requests and cancellation requests from your team will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(AnnualLeavePalette.ink3)
                    .multilineTextAlignment(.center)
                    .padding(22)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous)
                            .strokeBorder(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
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
        let days = AnnualLeaveDateFormat.leaveDays(request)
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
                if isCancellation {
                    // Refuse the cancellation: the leave stays booked.
                    Button("Keep Booking") { declineRequest(request) }
                        .accessibilityIdentifier("leave.keepBooking")
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AnnualLeavePalette.soft)
                        .foregroundStyle(AnnualLeavePalette.ink2)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                } else {
                    Button("Decline") { declineDraft = request }
                        .accessibilityIdentifier("leave.decline2")
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AnnualLeavePalette.soft)
                        .foregroundStyle(AnnualLeavePalette.ink2)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                Button(isCancellation ? "Approve Cancellation" : "Approve") { approveRequest(request) }
                    .accessibilityIdentifier("leave.approve")
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(AnnualLeavePalette.approved)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            // RULEBOOK §2: annual leave approval is online only.
            .onlineOnly(isOnline: smartCache.isOnline)
        }
        .padding(14)
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isCancellation ? AnnualLeavePalette.violet : AnnualLeavePalette.amber)
                .frame(width: 5)
        }
    }

    private var teamAwayCalendarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who is off, and when")
                .font(.system(.title3, design: .rounded).weight(.bold))
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
                    .accessibilityIdentifier("leave.back2")
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
                    .accessibilityIdentifier("leave.chevronRight")
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
            .background(PPColor.card)
            .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
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
        let awayInitials = away.prefix(2).map { initials(from: $0.displayName) }.joined(separator: " ")
        return AnnualLeaveDayFace(
            dayNumber: calendar.component(.day, from: date),
            visual: away.count >= 2 ? .none : visual,
            isToday: calendar.isDateInToday(day),
            initials: awayInitials.isEmpty ? nil : awayInitials,
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
                .font(.system(.title3, design: .rounded).weight(.bold))
            TextField("Search name or trade", text: $teamSearch)
                .accessibilityIdentifier("leave.searchNameOrTrade")
                .padding(12)
                .background(PPColor.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack {
                Picker("Sort by", selection: $teamSort) {
                    ForEach(AnnualLeavePersonSort.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .accessibilityIdentifier("leave.sortBy")
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
                    .accessibilityIdentifier("leave.trade")
                    .pickerStyle(.menu)
                }
            }
            if filteredTeamPeople.isEmpty {
                Text(teamPeople.isEmpty ? teamEmptyMessage : "No one on the team matches those filters. Clear the trade or search to see your team.")
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
                    .accessibilityIdentifier("leave.row.\(person.id)")
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func teamPersonRow(_ person: AnnualLeavePerson) -> some View {
        let balance = teamBalance(for: person)
        return HStack(spacing: 11) {
            Text(initials(from: person.displayName))
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(PPFamily.people.gradient, in: Circle())
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
                    if balance.hasAllowance {
                        Text(AnnualLeavePolicy.formatAllowanceDays(balance.remaining ?? 0))
                            .font(.headline)
                            .foregroundStyle((balance.remaining ?? 0) < -0.001 ? AnnualLeavePalette.red : AnnualLeavePalette.ink)
                        Text("of \(AnnualLeavePolicy.formatAllowanceDays(balance.allowance)) left")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AnnualLeavePalette.ink3)
                    } else {
                        Text(AnnualLeavePolicy.formatAllowanceDays(balance.used))
                            .font(.headline)
                            .foregroundStyle(AnnualLeavePalette.ink)
                        Text("Days taken this leave year")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AnnualLeavePalette.ink3)
                    }
                }
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AnnualLeavePalette.ink3)
        }
        .padding(12)
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
    }

    private var teamPeople: [AnnualLeavePerson] {
        // RULEBOOK 1.40.0 `annualLeaveTeamPeople`: admins every current person (self-bookers included, never
        // themselves), anyone else the people they line-manage; never deleted, inactive or pending people.
        var hasher = Hasher()
        hasher.combine(holidayProfileUser)
        hasher.combine(userStore.organizationUsers)
        for op in operativeStore.allOperatives {
            hasher.combine(op.documentId)
            hasher.combine(op.email)
            hasher.combine(op.isActive)
        }
        let key = hasher.finalize()
        if let cached = teamCache.people, teamCache.peopleKey == key { return cached }
        let people = AnnualLeavePersonBuilder.teamPeople(
            viewer: holidayProfileUser,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )
        teamCache.peopleKey = key
        teamCache.people = people
        return people
    }

    /// RULEBOOK 1.40.0 `annualLeaveTeamEmptyMessage`.
    private var teamEmptyMessage: String {
        guard let viewer = holidayProfileUser else { return "Nobody reports to you yet. People you line-manage appear here." }
        return CanonicalBusinessEngine.annualLeaveTeamEmptyMessage(viewer: RulebookPeople.person(viewer))
            ?? "Nobody reports to you yet. People you line-manage appear here."
    }

    /// RULEBOOK 1.40.0 §9: the Team header names the organisation's leave year, never the viewer's own.
    private var teamLeaveYearLabel: String {
        let org = firebaseBackend.currentOrganization?.settings.annualLeaveDefaults ?? .default
        return AnnualLeavePolicy.organizationLeaveYearLabel(startMonth: org.startMonth, endMonth: org.endMonth) ?? "This leave year"
    }

    /// The users ids whose adjustments this page reads: the signed-in person and every listed person.
    private var adjustmentUserIds: [String] {
        ([holidayProfileUser?.id] + teamPeople.map(\.userId)).compactMap { $0 }
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

    /// RULEBOOK 1.40.0: away on a day is `leaveDayKind` over each listed person's records (every id they go by) —
    /// approved leave, half days included; a pending cancellation still counts; weekends and bank holidays inside a
    /// multi-day record are not leave days.
    private func teamAway(on day: Date) -> [AnnualLeavePerson] {
        let key = OrganizationRulebookContext.dayKey(day)
        let byPerson = teamLeaveRecords
        return teamPeople.filter { person in
            let records = byPerson[person.id] ?? []
            let kind = CanonicalBusinessEngine.leaveDayKind(
                records: records,
                dayKey: key,
                nonWorkingDayKeys: OrganizationBankHolidays.dayKeys
            ) ?? RulebookLeaveDayKind.none
            return kind == .approvedFull || kind == .approvedHalf
        }
    }

    /// Every listed person's leave records (`teamPersonBookings`), worked out once per change of the leave or the list.
    private var teamLeaveRecords: [String: [RulebookLeaveReportRecord]] {
        let people = teamPeople
        var hasher = Hasher()
        hasher.combine(holidayStore.bookings)
        hasher.combine(people)
        let key = hasher.finalize()
        if let cached = teamCache.records, teamCache.recordsKey == key { return cached }
        var map: [String: [RulebookLeaveReportRecord]] = [:]
        for person in people {
            map[person.id] = teamPersonBookings(person).map(\.rulebookLeaveRecord)
        }
        teamCache.recordsKey = key
        teamCache.records = map
        return map
    }

    /// One listed person's leave records under every id they go by (`leaveRecordsForAccount`).
    private func teamPersonBookings(_ person: AnnualLeavePerson) -> [HolidayBooking] {
        holidayStore.myBookings(
            account: teamUser(for: person),
            operatives: operativeStore.allOperatives,
            operativeId: person.operativeId,
            userId: person.userId
        )
    }

    /// The team row a leave record belongs to: the requester account the rulebook resolves (`resolveBookingPerson`
    /// through `AnnualLeaveApproval.requester`), else the catalogue row on the record's `operativeId`.
    private func teamPerson(for booking: HolidayBooking) -> AnnualLeavePerson? {
        if let requester = AnnualLeaveApproval.requester(
            for: booking,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        ), let person = teamPeople.first(where: { $0.userId == requester.id }) {
            return person
        }
        guard let oid = booking.operativeId else { return nil }
        return teamPeople.first { $0.operativeId == oid }
    }

    private func teamBalance(for person: AnnualLeavePerson) -> (remaining: Double?, allowance: Double, taken: Double, hasAllowance: Bool, used: Double)? {
        guard let user = teamUser(for: person) else { return nil }
        let org = firebaseBackend.currentOrganization?.settings.annualLeaveDefaults ?? .default
        let summary = AnnualLeavePolicy.usageSummary(
            bookings: holidayStore.myBookings(account: user, operatives: operativeStore.allOperatives, operativeId: person.operativeId),
            daysPerYear: user.annualLeaveDaysPerYear,
            startMonth: user.annualLeaveYearStartMonth,
            endMonth: user.annualLeaveYearEndMonth,
            carriesOver: user.annualLeaveCarriesOver,
            referenceDate: Date(),
            calendar: calendar,
            annualLeaveEnabled: user.annualLeaveEnabled,
            orgDaysPerYear: org.daysPerYear,
            orgStartMonth: org.startMonth,
            orgEndMonth: org.endMonth,
            yearAllowance: user.annualLeaveYearAllowance,
            yearAllowanceKey: user.annualLeaveYearAllowanceKey,
            employmentStartDayKey: user.employmentStartDate,
            // RULEBOOK 1.40.0 §4.4: PAYE days only, with this year's adjustments.
            employment: AnnualLeaveEmployment(user),
            adjustments: adjustmentsModel.rows(for: RulebookPeople.ownerIds(for: user, users: userStore.organizationUsers))
        )
        return (summary.remainingDays, summary.entitlementDays, summary.takenDays, summary.hasAllowance, summary.usedThisYear)
    }

    private func teamUser(for person: AnnualLeavePerson) -> AppUser? {
        if let uid = person.userId {
            return userStore.organizationUsers.first { $0.id == uid }
        }
        if let oid = person.operativeId {
            // `resolveBookingPerson`: the account behind the catalogue row (same email, former or alias ids).
            return LabourBookingPeople(operatives: operativeStore.allOperatives, users: userStore.organizationUsers)
                .person(for: oid).user
        }
        return nil
    }

    private func remainingAfterNote(for request: HolidayBooking, person: AnnualLeavePerson?) -> String? {
        guard let person, let balance = teamBalance(for: person), balance.hasAllowance else { return nil }
        let days = AnnualLeaveDateFormat.leaveDays(request)
        // RULEBOOK 1.40.0: from `annualLeaveBalance.remaining`, which already takes pending requests off — approving a
        // pending request leaves it unchanged; accepting a cancellation gives the days back.
        let remaining = balance.remaining ?? (balance.allowance - balance.taken)
        let after = request.cancellationRequestedAt != nil ? remaining + days : remaining
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
        let upcoming = holidayStore.myBookings(account: userStore.currentUser, operatives: operativeStore.allOperatives, operativeId: currentOperative?.id)
            .filter { booking in
                booking.status != .rejected && calendar.startOfDay(for: booking.endDate) >= today
            }
            .sorted { $0.startDate < $1.startDate }
        let spans = AnnualLeaveDateFormat.displaySpans(from: upcoming, calendar: calendar)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming leave")
                .font(.system(.title3, design: .rounded).weight(.bold))
            if spans.isEmpty {
                Text("Approved and pending leave from today onwards will show here, grouped by the days you booked.")
                    .font(.subheadline)
                    .foregroundStyle(AnnualLeavePalette.ink3)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PPColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
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
        let today = calendar.startOfDay(for: Date())
        let mine = holidayStore.myBookings(account: userStore.currentUser, operatives: operativeStore.allOperatives, operativeId: currentOperative?.id)
            .filter {
                $0.status == .pending || $0.cancellationRequestedAt != nil ||
                    ($0.status == .rejected && calendar.startOfDay(for: $0.endDate) >= today)
            }
            .sorted { $0.startDate > $1.startDate }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Your requests")
                .font(.system(.title3, design: .rounded).weight(.bold))
            Text("These are waiting on your line manager, including cancellations.")
                .font(.footnote)
                .foregroundStyle(AnnualLeavePalette.ink3)
            if mine.isEmpty {
                Text("Nothing is waiting on a decision. New requests and cancellation requests will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(AnnualLeavePalette.ink3)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PPColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
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
            if summary.hasAllowance {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remaining")
                            .font(.caption2)
                            .foregroundStyle(HolidayChrome.muted)
                        Text(formatLeaveDays(summary.remainingDays ?? 0))
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
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Days taken this leave year")
                        .font(.caption2)
                        .foregroundStyle(HolidayChrome.muted)
                    Text(formatLeaveDays(summary.usedThisYear))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(HolidayChrome.ink)
                }
            }
            HStack(spacing: 0) {
                heroMetric(title: "Taken", value: summary.takenDays, color: HolidayChrome.taken)
                heroMetric(title: "Pending", value: summary.pendingDays, color: HolidayChrome.pendingMetric)
            }
            if summary.hasAllowance {
                ProgressView(value: usedPortion, total: 1)
                    .tint(HolidayChrome.accent)
            }
            if summary.hasAllowance && summary.carryOverDays > 0.001 {
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
                            ProjectWorksRevampColors.leaveHeroWarm,
                            ProjectWorksRevampColors.leaveHeroCool,
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
                .accessibilityIdentifier("leave.back3")
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
                .accessibilityIdentifier("leave.chevronRight2")
        }
        .foregroundStyle(HolidayChrome.accent)
    }

    private func monthYearString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
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
            RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous)
                .fill(PPColor.card)
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
        .accessibilityIdentifier("leave.weekend")
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

    /// The signed-in person already has leave (not rejected) on `day`: their records (`leaveRecordsForAccount`) whose
    /// leave days (`leaveRecordDayKeys`) include it.
    private func hasExistingHoliday(on day: Date) -> Bool {
        signedInLeave.contains { booking in
            booking.status != .rejected && LeaveRecordDays.covers(booking, day: day)
        }
    }

    /// Validates selected calendar days + duration against current/pending usage (per leave year).
    private func allowanceViolationForProposedSelection(_ startOfDays: Set<Date>) -> String? {
        guard let u = holidayProfileUser else { return nil }
        let sorted = startOfDays.sorted()
        guard !sorted.isEmpty else { return nil }
        return AnnualLeavePolicy.validateProposedDaySlots(
            daySlots: Dictionary(startOfDays.map { day in
                (day, selectedDaySlots[day] ?? selectedHolidayTimeSlot)
            }, uniquingKeysWith: { first, _ in first }),
            bookings: holidayStore.myBookings(account: u, operatives: operativeStore.allOperatives, operativeId: currentOperative?.id),
            daysPerYear: u.annualLeaveDaysPerYear,
            startMonth: u.annualLeaveYearStartMonth,
            endMonth: u.annualLeaveYearEndMonth,
            carriesOver: u.annualLeaveCarriesOver,
            employmentStartDayKey: u.employmentStartDate,
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
                        if hasExistingHoliday(on: day) {
                            throw NSError(domain: "Holiday", code: 409, userInfo: [NSLocalizedDescriptionKey: "One or more selected days already have a holiday booking/request."])
                        }
                    }
                    // One document per request range (`holidayRequestRanges`), pending for `leaveApproverIds`.
                    let created = try await holidayStore.createRequests(
                        picks: selectedDays.map { day in
                            (day: day, timeSlot: selectedDaySlots[calendar.startOfDay(for: day)] ?? selectedHolidayTimeSlot)
                        },
                        userId: uid,
                        operativeId: operativeId,
                        status: .pending,
                        approvedByUserId: nil
                    )
                    // Approvers are told now, or once the outbox confirms a request made offline (§2).
                    for request in created {
                        await notificationService.notifyHolidayRequestSubmittedWhenSynced(
                            leaveNotice(for: request, requesterUserId: uid, requesterName: operativeDisplayName),
                            pendingSync: holidayStore.isPendingSync(request)
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
                        if hasExistingHoliday(on: day) {
                            throw NSError(domain: "Holiday", code: 409, userInfo: [NSLocalizedDescriptionKey: "One or more selected days already have a holiday booking/request."])
                        }
                    }
                    // D5: approved only with the `annualLeaveSelfBook` permission; otherwise a pending request
                    // for `leaveApproverIds`. One document per request range (`holidayRequestRanges`).
                    let selfBooks = !isManagerRequestMode
                    let created = try await holidayStore.createRequests(
                        picks: selectedDays.map { day in
                            (day: day, timeSlot: selectedDaySlots[calendar.startOfDay(for: day)] ?? selectedHolidayTimeSlot)
                        },
                        userId: uid,
                        operativeId: nil,
                        status: selfBooks ? .approved : .pending,
                        approvedByUserId: selfBooks ? uid : nil
                    )
                    if !selfBooks {
                        let requesterName = userStore.currentUser?.fullName ?? userStore.currentUser?.email ?? "Manager"
                        for request in created {
                            await notificationService.notifyHolidayRequestSubmittedWhenSynced(
                                leaveNotice(for: request, requesterUserId: uid, requesterName: requesterName),
                                pendingSync: holidayStore.isPendingSync(request)
                            )
                        }
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
        let showsRemaining = annualLeaveSummary?.hasAllowance == true
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
                    if showsRemaining {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Remaining after")
                                .font(.caption)
                                .foregroundStyle(AnnualLeavePalette.ink3)
                            Text(AnnualLeavePolicy.formatAllowanceDays(remainingAfter))
                                .font(.headline)
                                .foregroundStyle(remainingAfter < -0.001 ? AnnualLeavePalette.red : AnnualLeavePalette.ink)
                        }
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
                        Text(leaveSubmitButtonTitle)
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(!selectedDates.isEmpty ? AnnualLeavePalette.leave : Color.gray.opacity(0.45))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .accessibilityIdentifier("leave.paperplaneFill")
            .disabled(selectedDates.isEmpty || isSaving)
        }
    }

    private var currentOperative: Operative? {
        guard let email = userStore.currentUser?.email else { return nil }
        return operativeStore.allOperatives.first { $0.email.lowercased() == email.lowercased() }
    }

    /// D6: admins and super admins see every pending request in the organisation; anyone else only the
    /// requests whose `leaveApproverIds` names them. Nobody sees their own.
    private var approverPendingRequests: [HolidayBooking] {
        guard userStore.currentUser != nil else { return [] }
        return AnnualLeaveApproval.decidableRequests(
            holidayStore.pendingRequests,
            viewer: approvalViewer,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )
        .sorted { $0.startDate > $1.startDate }
    }

    /// The signed-in account as the roster has it (fresh line-manager and role flags), else the session user.
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

    private func assignedApproverUserId(for request: HolidayBooking) -> String? {
        // The requester is `resolveBookingPerson` (`AnnualLeaveApproval.requester`), never an email match.
        guard let requester = AnnualLeaveApproval.requester(
            for: request,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        ) else { return nil }
        if request.userId != nil,
           !AnnualLeaveSelfBookPolicy.usesAnnualLeaveRequestFlow(for: requester, users: userStore.organizationUsers) {
            return nil
        }
        return requester.primaryLineManagerUserId
    }

    private func approveRequest(_ request: HolidayBooking) {
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

    /// Web `buildLeaveDecisionPeerNotifications` copy: "{decider} {verb} {name}'s annual leave request|cancellation.
    /// {dates}" with `annualLeaveDecisionDateText`.
    private func peerNotice(for request: HolidayBooking, requester: AppUser, actorName: String, actionVerb: String) -> String {
        let name = requester.fullName.isEmpty ? requester.email : requester.fullName
        let dates = AnnualLeaveNoticeText.decisionDateText(request)
        let subject = request.cancellationRequestedAt != nil ? "annual leave cancellation" : "annual leave request"
        return "\(actorName) \(actionVerb) \(name)'s \(subject). \(dates)"
    }

    private func notifyPeerLineManagers(
        for request: HolidayBooking,
        actorUserId: String,
        actorName: String,
        actionVerb: String
    ) async {
        let requesterUser = AnnualLeaveApproval.requester(
            for: request,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives
        )
        guard let requesterUser else { return }
        // `lineManagerPeerRecipients(subject, actor, roster)` picks the other line managers.
        await notificationService.notifyLineManagerPeerAction(
            actorName: actorName,
            actionSummary: AnnualLeaveNoticeText.decisionDateText(request),
            subject: requesterUser,
            actionVerb: actionVerb,
            message: peerNotice(for: request, requester: requesterUser, actorName: actorName, actionVerb: actionVerb),
            relatedId: request.id
        )
    }

    private func declineRequest(_ request: HolidayBooking, reason: String = "") {
        guard let uid = firebaseBackend.currentUser?.uid, canDecide(request) else { return }
        if request.cancellationRequestedAt != nil {
            refuseCancellation(request, actorUserId: uid)
            return
        }
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

    /// Refuse a cancellation request (§9): the leave stays approved; the requester (`holidayDecisionRecipients`) and
    /// the other line managers (`lineManagerPeerRecipients`) are told.
    private func refuseCancellation(_ request: HolidayBooking, actorUserId: String) {
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
            await notifyPeerLineManagers(
                for: request,
                actorUserId: actorUserId,
                actorName: approverName,
                actionVerb: "declined"
            )
        }
    }

    private func notifyDecision(to request: HolidayBooking, approved: Bool, decidedByName: String, reason: String = "") async {
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
            decidedByName: decidedByName,
                reason: reason
        )
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
            holidayStore.errorMessage = nil
            await holidayStore.requestCancellation(booking, by: uid)
            guard holidayStore.errorMessage == nil else { return }
            // Approvers are told now, or once the outbox confirms a request made offline (§2).
            await notificationService.notifyHolidayRequestSubmittedWhenSynced(
                leaveNotice(for: booking, requesterUserId: uid, requesterName: requesterName(for: booking), cancellation: true),
                pendingSync: holidayStore.isPendingSync(booking)
            )
        }
    }

    private func leaveNotice(
        for request: HolidayBooking,
        requesterUserId: String,
        requesterName: String,
        cancellation: Bool = false
    ) -> DeferredLeaveNotice {
        // The request's organisation is the one its outbox entry was queued under.
        DeferredLeaveNotice(
            entityId: request.documentId,
            organizationId: request.organizationId,
            bookingId: request.id,
            requesterUserId: requesterUserId,
            requesterName: requesterName,
            startDate: request.startDate,
            endDate: request.endDate,
            assignedManagerUserId: effectiveAssignedManagerUserIdForCurrentUser(),
            cancellation: cancellation
        )
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
                    .accessibilityIdentifier("halfDayHolidayBookingEditor.duration")
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
                        .accessibilityIdentifier("halfDayHolidayBookingEditor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = booking
                        updated.timeSlot = draftSlot
                        onSave(updated)
                    }
                    .accessibilityIdentifier("halfDayHolidayBookingEditor.save")
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
                // RULEBOOK §2: a request made offline shows Pending sync until the server confirms it.
                PendingSyncIndicator(leave: booking)
                if booking.status != .pending,
                   let note = CanonicalBusinessEngine.parseHolidayDecisionNote(booking.decisionNote) {
                    Text("Note: \(note)")
                        .font(.caption)
                        .foregroundStyle(AnnualLeavePalette.ink2)
                }
                if let onRequestCancellation {
                    Button(actionTitle) {
                        onRequestCancellation()
                    }
                    .accessibilityIdentifier("holidayRow.\(AccessibilityID.token(actionTitle))")
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
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
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
    @EnvironmentObject private var smartCache: SmartCacheService
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
                        .accessibilityIdentifier("holidayRequestRow.exclamationmarkTriangleFill")
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
                        .accessibilityIdentifier("holidayRequestRow.approve")
                    // A cancellation request can be refused too ("Keep Booking": the leave stays approved).
                    Button(action: onDecline) {
                        Label(request.cancellationRequestedAt == nil ? "Decline" : "Keep Booking", systemImage: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red)
                            .cornerRadius(10)
                    }
                        .accessibilityIdentifier("holidayRequestRow.decline")
                }
                // RULEBOOK §2: annual leave approval is online only.
                .onlineOnly(isOnline: smartCache.isOnline)
            } else {
                Text("Pending approval")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(12)
        .background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous))
        .alert("Annual Leave Overlap", isPresented: $showConflicts) {
            Button("OK", role: .cancel) {}
                .accessibilityIdentifier("holidayRequestRow.ok")
        } message: {
            Text(conflictingApprovedOperatives.joined(separator: "\n"))
        }
    }
}

#Preview {
    HolidayView()
        .environmentObject(SmartCacheService())
        .environmentObject(HolidayStore())
        .environmentObject(UserStore())
        .environmentObject(OperativeStore())
        .environmentObject(FirebaseBackend())
        .environmentObject(NotificationService())
        .environmentObject(AppSettingsStore())
}

/// Team-page answers kept between redraws while their inputs (the hash of the roster, the viewer, the operatives and
/// the leave records) are unchanged. Holds script answers only; decides nothing.
final class HolidayTeamCache {
    var peopleKey = 0
    var people: [AnnualLeavePerson]?
    var recordsKey = 0
    var records: [String: [RulebookLeaveReportRecord]]?
}
