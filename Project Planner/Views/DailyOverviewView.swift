//
//  DailyOverviewView.swift
//  Project Planner
//
//  Created by Assistant on 27/10/2025.
//

import SwiftUI

// MARK: - Daily overview booking edit

enum DailyOverviewEditTarget: Identifiable {
    case operative(booking: Booking, project: Project, personName: String)
    case manager(booking: ManagerSiteBooking, locationTitle: String, personName: String)
    case subcontractor(booking: SubcontractorBooking, project: Project, personName: String)

    var id: String {
        switch self {
        case .operative(let b, _, _): return "op-\(b.id.uuidString)"
        case .manager(let b, _, _): return "mgr-\(b.id.uuidString)"
        case .subcontractor(let b, _, _): return "sub-\(b.id.uuidString)"
        }
    }
}

struct DailyOverviewView: View {
    /// When nil, shows today. When set, shows that day (for historic overview).
    var displayDate: Date? = nil
    
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    @EnvironmentObject var appSettings: AppSettingsStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var taskStore: ProjectTaskStore
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject private var smartCache: SmartCacheService
    @Environment(\.dismiss) private var dismiss
    @State private var showingPastBookings = false
    @State private var showingBookLabour = false
    @State private var bookingEditTarget: DailyOverviewEditTarget?
    /// Why a labour booking delete did not happen (refused or offline), shown once the edit sheet has closed.
    @State private var labourDeleteRefusalMessage: String?
    /// RULEBOOK 1.16.0 `bookingLeaveConflicts`: leave on a changed booking's day is ticked or dropped first.
    @StateObject private var leaveGate = BookingConflictGate()
    @State private var scheduleRefreshTask: Task<Void, Never>?
    /// When `displayDate` is nil, the user can change the day from the strip (today’s overview sheet).
    @State private var selectedCalendarDay: Date = OrganizationRulebookContext.calendar.startOfDay(for: Date())
    
    /// Organisation-zone midnight of the day shown. Bookings are stored at that instant, so a phone in
    /// another zone lists the same day's bookings as the web app. Callers pass organisation-zone days
    /// (`date(fromDayKey:)`, warning days, the org-zone pickers below).
    private var overviewDate: Date {
        let picked = displayDate ?? selectedCalendarDay
        let key = OrganizationRulebookContext.dayKey(picked)
        return OrganizationRulebookContext.date(fromDayKey: key)
            ?? CanonicalBusinessEngine.businessCalendar.startOfDay(for: picked)
    }

    /// A day before the launch query window (the warning window / current week) is loaded on demand,
    /// so a historic date does not show everyone as not booked.
    private func coverOverviewDay() {
        guard firebaseBackend.noteScheduleNeedsDate(overviewDate) else { return }
        bookingStore.loadData()
        managerScheduleStore.loadData(force: true)
    }
    
    private var scheduleOptions: MyScheduleOptions {
        appSettings.settings.myScheduleOptions
    }

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.payrollPolicy(for: overviewDate)
    }
    
    /// Staff open Book Labour; which jobs they may book onto is `canWriteBooking` per job (RULEBOOK 1.10.0 §16).
    private var canBookLabour: Bool {
        userStore.hasAdminAccess() || userStore.displayUser?.permissions.manager == true
    }
    
    private var isHistoric: Bool {
        displayDate != nil
    }
    
    /// Bookings that fill this day. `bookingOccupiesDay` decides the status (Completed counts; Cancelled does not),
    /// so the project cards and every row below use the same list as web.
    private var dayBookings: [Booking] {
        let scope = overviewScope
        return bookingStore.bookings.filter { booking in
            CanonicalBusinessEngine.businessCalendar.isDate(booking.date, inSameDayAs: overviewDate)
                && CanonicalBusinessEngine.bookingOccupiesDay(booking.status.rawValue) == true
                && labourBookingInScope(booking, scope: scope)
        }
    }
    
    private var dayHolidays: [HolidayBooking] {
        let scope = overviewScope
        return holidayStore.approvedBookings(covering: overviewDate).filter { holidayInScope($0, scope: scope) }
    }

    // MARK: Team scope (RULEBOOK 1.33.0 §6)

    /// The viewer's Daily Overview scope (`dailyOverviewScopeFor`, owner decision 5 Nov / Q-D1 6 Nov): admins see
    /// everyone and every subcontractor booking; a manager only themselves and their reports. Booked people, leave,
    /// unbooked people and the day's hours all follow it (`isDailyOverviewRowInScope`). Nil is everything.
    private var overviewScope: [String: Any]? {
        DailyOverviewScopeSupport.scope(users: userStore.organizationUsers, operatives: operativeStore.allOperatives)
    }

    private func labourBookingInScope(_ booking: Booking, scope: [String: Any]?) -> Bool {
        guard scope != nil else { return true }
        let email = emailForLabourBooking(
            operativeId: booking.operativeId,
            operatives: operativeStore.allOperatives,
            users: userStore.organizationUsers
        )
        return DailyOverviewScopeSupport.isRowInScope(scope, personIds: [booking.storedOperativeId], email: email)
    }

    private func managerBookingInScope(_ booking: ManagerSiteBooking, scope: [String: Any]?) -> Bool {
        guard scope != nil else { return true }
        let email = StaffEmailIdentity.account(forUserId: booking.userId, in: userStore.organizationUsers)?.email
        return DailyOverviewScopeSupport.isRowInScope(scope, personIds: [booking.userId], email: email)
    }

    private func holidayInScope(_ holiday: HolidayBooking, scope: [String: Any]?) -> Bool {
        guard scope != nil else { return true }
        let ids = [holiday.userId, holiday.operativeIdRaw].compactMap { $0 }.filter { !$0.isEmpty }
        let email = holiday.userId.flatMap { StaffEmailIdentity.account(forUserId: $0, in: userStore.organizationUsers)?.email }
            ?? holiday.operativeIdRaw.flatMap { raw in
                operativeStore.allOperatives.first { $0.documentId.caseInsensitiveCompare(raw) == .orderedSame }?.email
            }
        return DailyOverviewScopeSupport.isRowInScope(scope, personIds: ids, email: email)
    }

    /// Manager schedule bookings of the people in scope.
    private var scopedManagerBookings: [ManagerSiteBooking] {
        let scope = overviewScope
        guard scope != nil else { return managerScheduleStore.managerSiteBookings }
        return managerScheduleStore.managerSiteBookings.filter { managerBookingInScope($0, scope: scope) }
    }

    /// Subcontractor bookings: admins only (`isDailyOverviewRowInScope` with `subcontractor`).
    private var scopedSubcontractorBookings: [SubcontractorBooking] {
        DailyOverviewScopeSupport.isRowInScope(overviewScope, personIds: [], email: nil, subcontractor: true)
            ? subcontractorStore.bookings
            : []
    }
    
    private var dayOfficeBookings: [ManagerSiteBooking] {
        let p = payrollTimePolicy
        return scopedManagerBookings
            .filter { booking in
                CanonicalBusinessEngine.businessCalendar.isDate(booking.date, inSameDayAs: overviewDate) &&
                booking.locationType == .office
            }
            .sorted { $0.minutesSortKey(policy: p) < $1.minutesSortKey(policy: p) }
    }
    
    private var dayWorkingFromHomeBookings: [ManagerSiteBooking] {
        let p = payrollTimePolicy
        return scopedManagerBookings
            .filter { booking in
                CanonicalBusinessEngine.businessCalendar.isDate(booking.date, inSameDayAs: overviewDate) &&
                booking.locationType == .workingFromHome
            }
            .sorted { $0.minutesSortKey(policy: p) < $1.minutesSortKey(policy: p) }
    }
    
    private var daySiteSurveyBookings: [ManagerSiteBooking] {
        let p = payrollTimePolicy
        return scopedManagerBookings
            .filter { booking in
                CanonicalBusinessEngine.businessCalendar.isDate(booking.date, inSameDayAs: overviewDate) &&
                booking.locationType == .siteSurvey
            }
            .sorted { $0.minutesSortKey(policy: p) < $1.minutesSortKey(policy: p) }
    }
    
    private var dayCustomBookingsByName: [String: [ManagerSiteBooking]] {
        let list = scopedManagerBookings.filter { booking in
            CanonicalBusinessEngine.businessCalendar.isDate(booking.date, inSameDayAs: overviewDate) &&
                booking.locationType == .custom
        }
        return Dictionary(grouping: list) { booking in
            let name = booking.customLocationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "Custom" : name
        }
    }

    /// Custom location sections respect General → My schedule custom list and toggles.
    private var filteredCustomBookingsByName: [String: [ManagerSiteBooking]] {
        dayCustomBookingsByName.filter { _, bookings in
            bookings.contains { scheduleOptions.includesManagerScheduleLocation($0) }
        }
    }

    private var visibleOfficeBookings: [ManagerSiteBooking] {
        scheduleOptions.showOffice ? dayOfficeBookings : []
    }

    private var visibleWFHBookings: [ManagerSiteBooking] {
        scheduleOptions.showWorkingFromHome ? dayWorkingFromHomeBookings : []
    }

    private var visibleSiteSurveyBookings: [ManagerSiteBooking] {
        scheduleOptions.showSiteSurvey ? daySiteSurveyBookings : []
    }

    /// Distinct people with a project or small-work booking on this day (operative bookings + manager site bookings).
    private var onSitePeopleCount: Int {
        let cal = CanonicalBusinessEngine.businessCalendar
        var keys = Set<String>()
        for b in dayBookings {
            keys.insert(overviewPersonKey(operativeId: b.operativeId))
        }
        for b in scopedManagerBookings {
            guard cal.isDate(b.date, inSameDayAs: overviewDate) else { continue }
            guard b.locationType == .project || b.locationType == .smallWork else { continue }
            keys.insert(overviewPersonKey(userId: b.userId))
        }
        for b in scopedSubcontractorBookings where cal.isDate(b.date, inSameDayAs: overviewDate) && b.status != .cancelled {
            keys.insert("sub:\(b.subcontractorId.uuidString)")
        }
        return keys.count
    }

    private var officePeopleCount: Int {
        Set(visibleOfficeBookings.map { overviewPersonKey(userId: $0.userId) }).count
    }

    private var wfhPeopleCount: Int {
        Set(visibleWFHBookings.map { overviewPersonKey(userId: $0.userId) }).count
    }

    private var unbookedLabourRows: [CanonicalUnbookedLabourRow] {
        let detection = firebaseBackend.currentOrganization?.settings.warningDetection ?? .default
        return WarningsComputation.unbookedLabourRowsOnDay(
            day: overviewDate,
            users: userStore.organizationUsers,
            operatives: operativeStore.allOperatives,
            operativeBookings: bookingStore.bookings,
            managerBookings: managerScheduleStore.managerSiteBookings,
            holidays: holidayStore.bookings,
            policy: payrollTimePolicy,
            includeWeekends: detection.includeWeekendsForUnbookedLabour,
            excludedUserIds: detection.excludedUserIdsFromUnbookedWarnings,
            weekendCoverage: detection.weekendCoverage,
            // RULEBOOK 1.33.0 §6: a manager's unbooked people are their own team (`dailyOverviewScopeFor`).
            scope: .dailyOverview
        )
    }

    private var unbookedAllNames: [String] {
        unbookedAllRows.map(\.name)
    }

    /// Each unbooked person once, keyed by the rulebook row id (two people can share a name).
    private var unbookedAllRows: [DailyOverviewUnbookedRow] {
        unbookedLabourRows.map { row in
            DailyOverviewUnbookedRow(id: row.id, name: "\(row.operativeName) (missing \(ScheduleCoverageFormat.hours(row.missingHours))h)")
        }
    }

    /// Unique people with any same-day booking (operatives on jobs, managers on jobs or “other” locations, subs on jobs).
    private var bookedPeopleCount: Int {
        let cal = CanonicalBusinessEngine.businessCalendar
        var keys = Set<String>()
        for b in dayBookings {
            keys.insert(overviewPersonKey(operativeId: b.operativeId))
        }
        for b in scopedManagerBookings where cal.isDate(b.date, inSameDayAs: overviewDate) {
            if scheduleOptions.includesManagerScheduleLocation(b) {
                keys.insert(overviewPersonKey(userId: b.userId))
            }
        }
        for b in scopedSubcontractorBookings where cal.isDate(b.date, inSameDayAs: overviewDate) && b.status != .cancelled {
            keys.insert("sub:\(b.subcontractorId.uuidString)")
        }
        return keys.count
    }

    /// `workedHoursSplit(payrollHoursResult)` for every job-site booking on the overview day:
    /// operatives on jobs, managers on project / small-work sites, and subcontractors. Web's
    /// Daily Overview (lib/daily-overview/buildDailyOverview.ts) sums exactly these.
    private var dayJobSiteHourSplits: [CanonicalWorkedHoursSplit] {
        let p = payrollTimePolicy
        let cal = CanonicalBusinessEngine.businessCalendar
        var splits: [CanonicalWorkedHoursSplit] = []
        for b in dayBookings {
            if let split = b.workedHoursSplit(policy: p) { splits.append(split) }
        }
        for b in scopedManagerBookings {
            guard cal.isDate(b.date, inSameDayAs: overviewDate) else { continue }
            guard b.locationType == .project || b.locationType == .smallWork else { continue }
            if let split = b.workedHoursSplit(policy: p) { splits.append(split) }
        }
        for b in scopedSubcontractorBookings where cal.isDate(b.date, inSameDayAs: overviewDate) && b.status != .cancelled {
            if let split = b.payrollMirrorBooking().workedHoursSplit(policy: p) { splits.append(split) }
        }
        return splits
    }

    /// Hours on job sites from the pay rule (`payrollHoursResult.totalPaidHours` for each booking under the policy in
    /// effect that day), never the clock duration: a Saturday window counting 8h adds 8h, Sunday every hour ×2 adds 13h.
    private var dayJobSiteLabourHours: Double {
        dayJobSitePayResults.reduce(0) { $0 + $1.totalPaidHours }
    }

    /// `payrollHoursResult` for every job-site booking on the overview day (memoised answers), the source of the
    /// headline total, the standard hours and the hours at the multiplier (web `buildDailyOverview`).
    private var dayJobSitePayResults: [PayrollHoursResult] {
        let p = payrollTimePolicy
        let cal = CanonicalBusinessEngine.businessCalendar
        var results = dayBookings.map { $0.payrollHoursResult(policy: p) }
        for b in scopedManagerBookings
        where cal.isDate(b.date, inSameDayAs: overviewDate) && (b.locationType == .project || b.locationType == .smallWork) {
            results.append(b.payrollHoursResult(policy: p))
        }
        for b in scopedSubcontractorBookings where cal.isDate(b.date, inSameDayAs: overviewDate) && b.status != .cancelled {
            results.append(b.payrollMirrorBooking().payrollHoursResult(policy: p))
        }
        return results
    }

    /// RULEBOOK 1.20.4 (web `buildDailyOverview`): the day's hours at the multiplier as clock hours, with the unpaid
    /// break as plain hours — "6.5h × 2 − 0.5h break = 12.5h" (`multipliedHoursText`) when a break came off and one
    /// multiplier applies; otherwise the clock hours.
    private var dayJobSiteOvertimeText: String {
        var clock = 0.0
        var breakHours = 0.0
        var multipliers = Set<Double>()
        for result in dayJobSitePayResults {
            let multiplied = result.multipliedHours
            clock += multiplied?.clockHours ?? result.outsideHours
            breakHours += multiplied?.breakHours ?? 0
            if result.outsideHours > 0 { multipliers.insert(result.outsideMultiplier) }
        }
        if breakHours > 0.0001, clock > 0.0001, multipliers.count <= 1 {
            return CanonicalBusinessEngine.multipliedHoursText(
                clockHours: clock, multiplier: dayJobSiteOvertimeMultiplier, breakHours: breakHours
            )
        }
        return overviewFormatHours(clock)
    }

    /// Hours worked outside the standard window (`workedHoursSplit.outsideWorkedHours`).
    private var dayJobSiteOvertimeHours: Double {
        dayJobSiteHourSplits.reduce(0) { $0 + $1.outsideWorkedHours }
    }

    /// Hours worked inside the standard window (`workedHoursSplit.standardWorkedHours`).
    private var dayJobSiteStandardPortionHours: Double {
        // RULEBOOK 1.20.2 §6: the standard hours of the pay rule (`payrollHoursResult.standardHours`).
        dayJobSitePayResults.reduce(0) { $0 + $1.standardHours }
    }

    /// The overtime multiplier label: the highest `outsideMultiplier` among bookings with outside
    /// hours, else the day's own (web `overtimeMultiplier`).
    private var dayJobSiteOvertimeMultiplier: Double {
        let fromBookings = dayJobSiteHourSplits
            .filter { $0.outsideHours > 0 }
            .reduce(0) { max($0, $1.outsideMultiplier) }
        if fromBookings > 0 { return fromBookings }
        return PayrollTimePolicyCatalog.timelinePolicy(for: overviewDate, policy: payrollTimePolicy).outsideMultiplier
    }

    private func overviewFormatHours(_ hours: Double) -> String {
        ScheduleCoverageFormat.hours(hours)
    }

    private func shiftOverviewDay(_ delta: Int) {
        guard displayDate == nil else { return }
        // `selectedCalendarDay` is an organisation-zone day; `overviewDate` reads its day key.
        let cal = OrganizationRulebookContext.calendar
        guard let d = cal.date(byAdding: .day, value: delta, to: selectedCalendarDay) else { return }
        selectedCalendarDay = cal.startOfDay(for: d)
    }

    private func overviewPersonKey(operativeId: UUID) -> String {
        let email = emailForLabourBooking(
            operativeId: operativeId,
            operatives: operativeStore.allOperatives,
            users: userStore.organizationUsers
        )
        return StaffEmailIdentity.personKey(email: email, fallbackId: "op:\(operativeId.uuidString)")
    }

    private func overviewPersonKey(userId: String) -> String {
        let email = StaffEmailIdentity.account(forUserId: userId, in: userStore.organizationUsers)?.email
        return StaffEmailIdentity.personKey(email: email, fallbackId: "u:\(userId)")
    }

    // Group bookings by project
    private var bookingsByProject: [UUID: [Booking]] {
        Dictionary(grouping: dayBookings) { $0.projectId }
    }
    
    private var displayedProjectIds: [UUID] {
        var ids = Set(bookingsByProject.keys)
        let managerIds = scopedManagerBookings.compactMap { booking -> UUID? in
            guard CanonicalBusinessEngine.businessCalendar.isDate(booking.date, inSameDayAs: overviewDate),
                  (booking.locationType == .project || booking.locationType == .smallWork) else { return nil }
            return booking.locationId
        }
        let subcontractorIds = scopedSubcontractorBookings.compactMap { booking -> UUID? in
            guard CanonicalBusinessEngine.businessCalendar.isDate(booking.date, inSameDayAs: overviewDate),
                  booking.status != .cancelled else { return nil }
            return booking.projectId
        }
        ids.formUnion(managerIds)
        ids.formUnion(subcontractorIds)
        return Array(ids)
    }
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        formatter.timeZone = CanonicalBusinessEngine.businessCalendar.timeZone
        return formatter
    }
    
    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                overviewNavyHeader

                VStack(alignment: .leading, spacing: 0) {
                    if !smartCache.isOnline {
                        // RULEBOOK §2: Daily Overview is read-only offline data, labelled "Last updated".
                        LastUpdatedOfflineLabel()
                            .padding(.top, 14)
                    }
                    if !unbookedAllNames.isEmpty {
                        unbookedLabourRevampCard
                            .padding(.top, 20)
                    }

                    if !dayHolidays.isEmpty {
                        annualLeaveRevampBlock
                    }

                    otherScheduleRevampSection

                    if !visibleSiteSurveyBookings.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            revampSectionHeader(title: "Site survey", trailing: nil)
                            managerScheduleRevampCard(
                                sectionIcon: "mappin.and.ellipse",
                                family: .people,
                                title: "Site survey",
                                trailingCaption: "Managers / admins",
                                bookings: visibleSiteSurveyBookings
                            )
                        }
                    }

                    liveProjectsRevampSection

                    if displayedProjectIds.isEmpty &&
                        dayHolidays.isEmpty &&
                        !hasOtherScheduleContent &&
                        visibleSiteSurveyBookings.isEmpty {
                        noBookingsView
                            .padding(.top, 20)
                    }
                }
                .padding(.bottom, 28)
                .ppContentSheet()
            }
        }
        .background(PPColor.page.ignoresSafeArea())
        .navigationDestination(isPresented: $showingBookLabour) {
            BookLabourFlowView(bookDate: overviewDate, embedsNavigationStack: false)
                .environmentObject(appSettings)
                .environmentObject(bookingStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(holidayStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(firebaseBackend)
                .environmentObject(notificationService)
        }
    }

    /// Home-style navy header: day picker (or the fixed date), then the day at a glance.
    private var overviewNavyHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isHistoric {
                topActionsRow
                    .padding(.bottom, 12)
            }
            if displayDate == nil && !isHistoric {
                dateDayNavigatorCard
            } else if isHistoric {
                historicDateCaption
            }
            todayAtAGlanceHeroCard
                .padding(.top, 18)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A fixed date sits under other content (date picker, warnings), so its navy must not reach above it.
        .modifier(PPNavyHeaderBackground(bleed: isHistoric ? 0 : 900))
    }

    private var topActionsRow: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: { showingPastBookings = true }) {
                PPOnNavyPill(text: "View by date", symbol: "calendar")
            }
            .accessibilityIdentifier("dailyOverview.viewByDate")
            .buttonStyle(PPPressableButtonStyle())
        }
    }

    private var historicDateCaption: some View {
        PPNavyPageTitle(
            eyebrow: CanonicalBusinessEngine.businessCalendar.isDateInToday(overviewDate) ? "Today" : "Daily overview",
            title: dateFormatter.string(from: overviewDate)
        )
    }

    private var dateDayNavigatorCard: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: { shiftOverviewDay(-1) }) {
                Image(systemName: "chevron.left")
            }
            .accessibilityIdentifier("dailyOverview.back")
            .buttonStyle(PPOnNavyCircleButtonStyle())
            Button(action: { showingPastBookings = true }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CanonicalBusinessEngine.businessCalendar.isDateInToday(overviewDate) ? "TODAY · TAP TO CHANGE" : "TAP TO CHANGE")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(PPColor.onNavySecondary)
                    HStack(spacing: 6) {
                        Text(dateFormatter.string(from: overviewDate))
                            .font(.system(.title2, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "calendar")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.onNavySecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("dailyOverview.calendar")
            .buttonStyle(PPPressableButtonStyle())
            Button(action: { shiftOverviewDay(1) }) {
                Image(systemName: "chevron.right")
            }
            .accessibilityIdentifier("dailyOverview.chevronRight")
            .buttonStyle(PPOnNavyCircleButtonStyle())
        }
    }

    private var glanceHeadlinePeopleCount: Int {
        max(onSitePeopleCount, bookedPeopleCount)
    }

    private var glanceUnbookedCount: Int {
        unbookedAllNames.count
    }

    private var teamLocationBarFractions: (office: CGFloat, wfh: CGFloat, onSite: CGFloat, unbooked: CGFloat) {
        let office = CGFloat(officePeopleCount)
        let wfh = CGFloat(wfhPeopleCount)
        let onSite = CGFloat(onSitePeopleCount)
        let unbooked = CGFloat(glanceUnbookedCount)
        let total = office + wfh + onSite + unbooked
        guard total > 0 else { return (0, 0, 0, 0) }
        return (office / total, wfh / total, onSite / total, unbooked / total)
    }

    /// Day at a glance on the navy header (Home overview style) — display only, not tappable.
    private var todayAtAGlanceHeroCard: some View {
        let unbooked = glanceUnbookedCount
        let mult = dayJobSiteOvertimeMultiplier
        let multLabel = abs(mult - mult.rounded()) < 0.05 ? String(format: "%.0f", mult) : String(format: "%.1f", mult)
        let jobsCount = displayedProjectIds.count
        let people = glanceHeadlinePeopleCount
        let bar = teamLocationBarFractions
        let isToday = CanonicalBusinessEngine.businessCalendar.isDateInToday(overviewDate)
        let glanceTitle = isToday ? "Today at a glance" : "Day at a glance"

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                PPOverviewTitle(
                    eyebrow: glanceTitle,
                    count: "\(overviewFormatHours(dayJobSiteLabourHours))h",
                    countLabel: "· \(people) \(people == 1 ? "person" : "people")"
                )
                Spacer(minLength: 8)
                if unbooked > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                        Text("\(unbooked) unbooked")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(PPColor.warningAmber)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(PPColor.warningAmber.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(PPColor.warningAmber.opacity(0.4), lineWidth: 0.5))
                }
            }

            HStack(alignment: .top, spacing: 12) {
                PPStat(value: overviewFormatHours(dayJobSiteStandardPortionHours), label: "Standard hrs")
                PPStatDivider()
                PPStat(value: dayJobSiteOvertimeText, label: "OT \(multLabel)×")
                PPStatDivider()
                PPStat(value: "\(jobsCount)", label: jobsCount == 1 ? "Job active" : "Jobs active")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("WHERE THE TEAM IS")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(PPColor.onNavySecondary)
                    Spacer()
                    Text("\(bookedPeopleCount) booked · \(unbooked) unbooked")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(PPColor.onNavyCaption)
                }

                teamLocationDistributionBar(office: bar.office, wfh: bar.wfh, onSite: bar.onSite, unbooked: bar.unbooked)

                HStack(spacing: 14) {
                    glanceLocationLegendItem(
                        systemImage: "building.2.fill",
                        count: officePeopleCount,
                        label: "Office",
                        dimmed: officePeopleCount == 0
                    )
                    glanceLocationLegendItem(
                        systemImage: "house.fill",
                        count: wfhPeopleCount,
                        label: "WFH",
                        dimmed: wfhPeopleCount == 0
                    )
                    glanceLocationLegendItem(
                        systemImage: "hammer.fill",
                        count: onSitePeopleCount,
                        label: "On site",
                        dimmed: onSitePeopleCount == 0
                    )
                    Spacer(minLength: 0)
                    if unbooked > 0 {
                        HStack(spacing: 5) {
                            Image(systemName: "person.fill.questionmark")
                                .font(.caption.weight(.semibold))
                            Text("\(unbooked)")
                                .font(.footnote.weight(.semibold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(PPColor.warningAmber)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(PPColor.onNavyFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5)
            )
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(glanceTitle). \(overviewFormatHours(dayJobSiteLabourHours)) hours across \(people) people.")
    }

    /// Location colours shared by the bar and its legend (Home icon families).
    private static let officeTint = PPFamily.plan.top
    private static let wfhTint = PPFamily.sites.top
    private static let onSiteTint = PPFamily.trade.top

    private func teamLocationDistributionBar(office: CGFloat, wfh: CGFloat, onSite: CGFloat, unbooked: CGFloat) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 2) {
                if office > 0 {
                    Capsule()
                        .fill(Self.officeTint)
                        .frame(width: max(4, w * office))
                }
                if wfh > 0 {
                    Capsule()
                        .fill(Self.wfhTint)
                        .frame(width: max(4, w * wfh))
                }
                if onSite > 0 {
                    Capsule()
                        .fill(Self.onSiteTint)
                        .frame(width: max(4, w * onSite))
                }
                if unbooked > 0 {
                    glanceUnbookedStripeFill()
                        .frame(width: max(4, w * unbooked))
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: 10)
        .background(Capsule().fill(Color.black.opacity(0.25)))
        .clipShape(Capsule())
    }

    private struct GlanceUnbookedStripeFill: View {
        var body: some View {
            GeometryReader { geo in
                Path { path in
                    let step: CGFloat = 6
                    var x: CGFloat = -geo.size.height
                    while x < geo.size.width + geo.size.height {
                        path.move(to: CGPoint(x: x, y: geo.size.height))
                        path.addLine(to: CGPoint(x: x + geo.size.height, y: 0))
                        x += step
                    }
                }
                .stroke(PPColor.warningAmber.opacity(0.7), lineWidth: 2)
                .background(PPColor.warningAmber.opacity(0.2))
            }
        }
    }

    private func glanceUnbookedStripeFill() -> some View {
        GlanceUnbookedStripeFill()
    }

    private func glanceLocationLegendItem(systemImage: String, count: Int, label: String, dimmed: Bool) -> some View {
        let tint: Color = {
            switch label {
            case "Office": return Self.officeTint
            case "WFH": return Self.wfhTint
            default: return Self.onSiteTint
            }
        }()
        return HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text("\(count)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(PPColor.onNavyCaption)
        }
        .opacity(dimmed ? 0.5 : 1)
    }

    private var unbookedLabourRevampCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                PPIconTile(symbol: "person.fill.questionmark", family: .alert, size: PPMetrics.menuIcon)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Unbooked labour")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("\(unbookedAllNames.count) \(unbookedAllNames.count == 1 ? "person" : "people") with nothing booked")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if canBookLabour {
                    Button(action: { showingBookLabour = true }) {
                        Text("Book labour")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Capsule().fill(PPColor.danger))
                    }
                    .accessibilityIdentifier("dailyOverview.bookLabour")
                    .buttonStyle(PPPressableButtonStyle())
                }
            }
            .padding(14)

            ForEach(unbookedAllRows) { entry in
                let name = entry.name
                PPRowDivider()
                HStack(spacing: 13) {
                    Text(PlannerUIInitials.from(name))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: PPMetrics.menuIcon, height: PPMetrics.menuIcon)
                        .background(PPFamily.people.gradient, in: Circle())
                    Text(name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
            }
        }
        .background(PPColor.card)
        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous)
                .strokeBorder(PPColor.danger.opacity(0.35), lineWidth: 1)
        )
    }

    /// RULEBOOK 1.20.0 §9: the leave row's slot from `leaveHalfDayLabel` under the working day in effect (memoised in the
    /// wrapper), e.g. "Annual leave · AM 06:30–10:30".
    static func leaveRowSlotLabel(_ booking: HolidayBooking, policy: OrgPayrollTimePolicy) -> String? {
        CanonicalBusinessEngine.leaveHalfDayLabel(timeSlot: booking.timeSlot.rawValue, policy: policy)
    }

    private var annualLeaveRevampBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            revampSectionHeader(title: "Annual leave", trailing: nil)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(dayHolidays.enumerated()), id: \.element.id) { idx, booking in
                    OnHolidayRowView(booking: booking, slotLabel: Self.leaveRowSlotLabel(booking, policy: payrollTimePolicy))
                    if idx < dayHolidays.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(14)
            .ppDailyOverviewCard()
        }
    }

    private var hasOtherScheduleContent: Bool {
        !visibleOfficeBookings.isEmpty ||
            !visibleWFHBookings.isEmpty ||
            !filteredCustomBookingsByName.isEmpty
    }

    @ViewBuilder
    private var otherScheduleRevampSection: some View {
        let office = visibleOfficeBookings
        let wfh = visibleWFHBookings
        let customGroups = filteredCustomBookingsByName
        let customBookings = customGroups.values.flatMap { $0 }
        let people = Set(office.map(\.userId))
            .union(Set(wfh.map(\.userId)))
            .union(Set(customBookings.map(\.userId)))
        if hasOtherScheduleContent {
            VStack(alignment: .leading, spacing: 0) {
                revampSectionHeader(
                    title: "Other",
                    trailing: "\(people.count) person\(people.count == 1 ? "" : "s")"
                )
                VStack(alignment: .leading, spacing: 0) {
                    otherScheduleBlock(
                        needsTopDivider: false,
                        icon: "building.2.fill",
                        family: .plan,
                        title: "Office",
                        bookings: office,
                        locationTitle: "Office"
                    )
                    otherScheduleBlock(
                        needsTopDivider: !office.isEmpty,
                        icon: "house.fill",
                        family: .sites,
                        title: "Working from home",
                        bookings: wfh,
                        locationTitle: "Working from home"
                    )
                    ForEach(Array(customGroups.keys.sorted().enumerated()), id: \.element) { idx, customName in
                        otherScheduleBlock(
                            needsTopDivider: !office.isEmpty || !wfh.isEmpty || idx > 0,
                            icon: "mappin.and.ellipse",
                            family: .people,
                            title: customName,
                            bookings: customGroups[customName] ?? [],
                            locationTitle: customName
                        )
                    }
                }
                .padding(14)
                .ppDailyOverviewCard()
            }
        }
    }

    @ViewBuilder
    private func otherScheduleBlock(
        needsTopDivider: Bool,
        icon: String,
        family: PPFamily,
        title: String,
        bookings: [ManagerSiteBooking],
        locationTitle: String
    ) -> some View {
        if !bookings.isEmpty {
            if needsTopDivider {
                Divider().padding(.vertical, 8)
            }
            otherScheduleInnerHeader(icon: icon, family: family, title: title, caption: "Managers / admins")
            ForEach(Array(bookings.enumerated()), id: \.element.id) { idx, booking in
                managerBookingRevampRow(booking: booking, locationTitle: locationTitle, editable: false)
                if idx < bookings.count - 1 { Divider() }
            }
        }
    }

    private func otherScheduleInnerHeader(icon: String, family: PPFamily, title: String, caption: String) -> some View {
        HStack {
            HStack(spacing: 13) {
                PPIconTile(symbol: icon, family: family, size: PPMetrics.menuIcon)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            Spacer()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 10)
    }

    private var liveProjectsRevampSection: some View {
        let ids = displayedProjectIds.sorted { id1, id2 in
            let all = projectStore.projects
            guard let p1 = all.first(where: { $0.id == id1 }), let p2 = all.first(where: { $0.id == id2 }) else { return false }
            return p1.siteName < p2.siteName
        }
        return Group {
            if !ids.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    revampSectionHeader(title: "By project", trailing: nil)
                        .padding(.bottom, -12)
                    ForEach(ids, id: \.self) { projectId in
                        if let project = projectStore.projects.first(where: { $0.id == projectId }) {
                            liveProjectRevampCard(
                                project: project,
                                bookings: bookingsByProject[projectId] ?? []
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func liveProjectRevampCard(project: Project, bookings: [Booking]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectBookingCard(
                project: project,
                bookings: bookings,
                day: overviewDate,
                scope: overviewScope,
                // RULEBOOK 1.10.0 §16: `canWriteBooking` — admins, or a manager of this job.
                canEditBookings: canBookLabour && userStore.canWriteBooking(on: project),
                onEditOperative: { booking in
                    let name = rosterNameForLabourBooking(
                        operativeId: booking.operativeId,
                        operatives: operativeStore.allOperatives,
                        users: userStore.organizationUsers
                    )
                    bookingEditTarget = .operative(
                        booking: booking,
                        project: project,
                        personName: name
                    )
                },
                onEditManager: { booking in
                    bookingEditTarget = .manager(
                        booking: booking,
                        locationTitle: "\(project.jobNumber) \(project.siteName)",
                        personName: managerName(for: booking.userId)
                    )
                },
                onEditSubcontractor: { booking in
                    let name = subcontractorStore.subcontractors.first(where: { $0.id == booking.subcontractorId })?.name ?? "Subcontractor"
                    bookingEditTarget = .subcontractor(
                        booking: booking,
                        project: project,
                        personName: name
                    )
                }
            )
            .environmentObject(managerScheduleStore)
            .environmentObject(subcontractorStore)

            Button {
                openCataloguePage(for: project)
            } label: {
                HStack(spacing: 6) {
                    Text(project.jobType == .smallWorks ? "Open small works" : "Open project")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(PPColor.brand)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(Capsule().fill(PPColor.brand.opacity(0.1)))
            }
            .accessibilityIdentifier("dailyOverview.row.\(project.id).openSmallWorks")
            .padding(.top, 10)
            .buttonStyle(PPPressableButtonStyle())
        }
        .padding(14)
        .ppDailyOverviewCard()
    }

    private func revampSectionHeader(title: String, trailing: String?) -> some View {
        PPSectionHeader(title) {
            if let trailing {
                Text(trailing)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func managerScheduleRevampCard(
        sectionIcon: String,
        family: PPFamily,
        title: String,
        trailingCaption: String,
        bookings: [ManagerSiteBooking]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            otherScheduleInnerHeader(icon: sectionIcon, family: family, title: title, caption: trailingCaption)

            ForEach(Array(bookings.enumerated()), id: \.element.id) { idx, booking in
                managerBookingRevampRow(booking: booking, locationTitle: title)
                if idx < bookings.count - 1 {
                    Divider()
                }
            }
        }
        .padding(14)
        .ppDailyOverviewCard()
    }

    @ViewBuilder
    private func managerBookingRevampRow(booking: ManagerSiteBooking, locationTitle: String, editable: Bool = true) -> some View {
        let name = managerName(for: booking.userId)
        let canEditRow = canBookLabour && editable
        let row = HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(PlannerUIInitials.from(name))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 30, height: 30)
                    .background(PPFamily.people.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(booking.scheduleLabel(policy: payrollTimePolicy))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // RULEBOOK §2: queued offline change not yet confirmed by the server.
                    PendingSyncIndicator(entityId: booking.id.uuidString)
                }
            }
            Spacer(minLength: 0)
            Text(managerTimeSlotDisplayText(for: booking))
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.brand)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(PPColor.brand.opacity(0.1)))
            if canEditRow {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())

        if canEditRow {
            Button {
                bookingEditTarget = .manager(
                    booking: booking,
                    locationTitle: locationTitle,
                    personName: name
                )
            } label: {
                row
            }
            .accessibilityIdentifier("dailyOverview.managerBookingRevampRow")
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    var body: some View {
        Group {
            if isHistoric {
                overviewContent
            } else {
                NavigationStack {
                    overviewContent
                        .navigationTitle("Daily overview")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Done") { dismiss() }
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .accessibilityIdentifier("dailyOverview.done")
                            }
                        }
                        .ppNavyNavigationBar()
                }
            }
        }
        .onAppear { coverOverviewDay() }
        .onChange(of: selectedCalendarDay) { _, _ in coverOverviewDay() }
        .onChange(of: displayDate) { _, _ in coverOverviewDay() }
        .sheet(isPresented: $showingPastBookings) {
            HistoricDailyOverviewView()
                .environmentObject(bookingStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(holidayStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(subcontractorStore)
                .environmentObject(appSettings)
                .environmentObject(firebaseBackend)
                .environmentObject(taskStore)
                .environmentObject(notificationService)
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookingStoreDidChange)) { _ in
            scheduleCoalescedWarningsRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("managerScheduleDidChange"))) { _ in
            scheduleCoalescedWarningsRefresh()
        }
        .sheet(item: $bookingEditTarget) { target in
            dailyOverviewEditSheet(for: target)
        }
        .alert(
            "Booking not deleted",
            isPresented: Binding(
                get: { labourDeleteRefusalMessage != nil },
                set: { if !$0 { labourDeleteRefusalMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { labourDeleteRefusalMessage = nil }
                .accessibilityIdentifier("dailyOverview.deleteRefused.ok")
        } message: {
            Text(labourDeleteRefusalMessage ?? "")
        }
        .bookingConflictSheet(leaveGate)
    }

    private func openCataloguePage(for project: Project) {
        let isSmallWorks = project.jobType == .smallWorks
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(
                name: .openWorkCatalogueDetail,
                object: nil,
                userInfo: [
                    "projectId": project.id,
                    "isSmallWorks": isSmallWorks
                ]
            )
        }
    }
    
    private var noBookingsView: some View {
        VStack(spacing: 12) {
            PPIconTile(symbol: "calendar", family: .system, size: PPMetrics.quickActionIcon)
            Text("No bookings")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .ppDailyOverviewCard()
    }
    
    @ViewBuilder
    private func managerScheduleSection(title: String, bookings: [ManagerSiteBooking]) -> some View {
        if !bookings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 20)
                VStack(spacing: 8) {
                    ForEach(bookings, id: \.id) { booking in
                        HStack(spacing: 8) {
                            Text(managerTimeSlotDisplayText(for: booking))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.purple)
                                .cornerRadius(8)
                            Text(managerName(for: booking.userId))
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.purple.opacity(0.12))
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

private extension DailyOverviewView {
    func managerTimeSlotDisplayText(for booking: ManagerSiteBooking) -> String {
        booking.scheduleLabel(policy: payrollTimePolicy)
    }
    
    func managerName(for userId: String) -> String {
        if let user = StaffEmailIdentity.account(forUserId: userId, in: userStore.organizationUsers) {
            return user.fullName.isEmpty ? user.email : user.fullName
        }
        return userId
    }

    private static let editDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    func editSheetSubtitle(date: Date, locationTitle: String) -> String {
        "\(Self.editDateFormatter.string(from: date)) · \(locationTitle)"
    }

    /// Delete on a labour booking only when the rulebook allows it (`canDeleteBooking` via
    /// `BookingStore.canDeleteBooking`: admins on any job, managers on jobs they manage, never operatives). A refused
    /// delete is reported, not hidden.
    private func labourBookingDeleteAction(_ booking: Booking) -> (() -> Void)? {
        guard bookingStore.canDeleteBooking(booking) else { return nil }
        return {
            bookingEditTarget = nil
            Task {
                if let message = await bookingStore.deleteBookingReportingRefusal(booking) {
                    labourDeleteRefusalMessage = message
                }
            }
        }
    }

    /// RULEBOOK 1.33.0 §2 `offlineAvailability(bookingDeleteOfflineAction("bookings"))`: allowed offline (queued with
    /// its tombstone, "Pending sync"); nil while the action is usable.
    private var labourBookingDeleteDisabledReason: String? {
        OfflinePolicy.isEnabled(OfflinePolicy.deleteAction(collection: "bookings"), isOnline: smartCache.isOnline)
            ? nil : OfflinePolicy.onlineOnlyMessage
    }

    @ViewBuilder
    func dailyOverviewEditSheet(for target: DailyOverviewEditTarget) -> some View {
        switch target {
        case .operative(let booking, let project, let personName):
            // Same options as Scheduling (`LabourBookingEditOptions`): every control for everyone, plus the PAYE line.
            let options = LabourBookingEditOptions.forOperative(
                booking: booking,
                operatives: operativeStore.allOperatives,
                users: userStore.organizationUsers
            )
            OperativeCustomHoursSheet(
                policy: firebaseBackend.payrollPolicy(for: booking.date),
                referenceDay: booking.date,
                title: "Edit booking",
                subtitle: editSheetSubtitle(date: booking.date, locationTitle: "\(project.jobNumber) \(project.siteName)"),
                headerName: personName,
                headerInitials: PlannerUIInitials.from(personName),
                allowsOtMultiplierOverride: options.allowsOtMultiplierOverride,
                showsBreakControls: options.showsBreakControls,
                showsBreakdown: options.showsBreakdown,
                showsFooterNote: options.showsFooterNote,
                showsPayeNote: options.showsPayeNote,
                initialChoice: OperativeDayBookingChoice(from: booking),
                onSave: { start, end, breakRemoved, otMult in
                    bookingEditTarget = nil
                    saveOperativeBookingEdit(
                        booking: booking,
                        start: start,
                        end: end,
                        breakRemoved: breakRemoved,
                        otMultiplierOverride: otMult,
                        rateShown: options.allowsOtMultiplierOverride
                    )
                },
                onCancel: { bookingEditTarget = nil },
                onDelete: labourBookingDeleteAction(booking),
                deleteDisabledReason: labourBookingDeleteDisabledReason
            )
        case .manager(let booking, let locationTitle, let personName):
            OperativeCustomHoursSheet(
                policy: firebaseBackend.payrollPolicy(for: booking.date),
                referenceDay: booking.date,
                title: "Edit booking",
                subtitle: editSheetSubtitle(date: booking.date, locationTitle: locationTitle),
                headerName: personName,
                headerInitials: PlannerUIInitials.from(personName),
                // RULEBOOK 1.29.0 §25: Edit Booking's overtime rate on manager site bookings too (web Daily Overview;
                // CanonicalBusinessEngine.overtimeRateControl in the sheet).
                allowsOtMultiplierOverride: true,
                initialChoice: booking.hoursEditChoice(policy: firebaseBackend.payrollPolicy(for: booking.date)),
                onSave: { start, end, breakRemoved, otMult in
                    bookingEditTarget = nil
                    saveManagerBookingEdit(
                        booking: booking,
                        start: start,
                        end: end,
                        breakRemoved: breakRemoved,
                        otMultiplierOverride: otMult
                    )
                },
                onCancel: { bookingEditTarget = nil },
                // RULEBOOK 1.33.0 §2 `bookingRemoveAction`: Delete only for the people who may delete it.
                onDelete: managerScheduleStore.canDeleteBooking(booking) ? {
                    bookingEditTarget = nil
                    Task { await managerScheduleStore.deleteBooking(booking) }
                } : nil
            )
        case .subcontractor(let booking, _, _):
            SubcontractorBookingEditSheet(
                booking: booking,
                // RULEBOOK 1.33.0 §2: deleting a subcontractor booking is online only (`booking.delete_subcontractor`).
                deleteDisabledReason: OfflinePolicy.isEnabled(.deleteSubcontractorBooking, isOnline: smartCache.isOnline)
                    ? nil : OfflinePolicy.onlineOnlyMessage
            ) {
                bookingEditTarget = nil
            }
            .environmentObject(firebaseBackend)
            .environmentObject(subcontractorStore)
        }
    }

    /// Bookings already live on the observable stores, so the list updates without a new view identity.
    /// Replacing this screen's identity while a finger is down leaves the gesture system with a nil target
    /// ("cannot add handler to 0 from 0") after the app has been idle and Firestore reconnects.
    private func scheduleCoalescedWarningsRefresh() {
        scheduleRefreshTask?.cancel()
        scheduleRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, !showingBookLabour else { return }
            await refreshScheduleAfterExternalBooking()
        }
    }

    private func refreshScheduleAfterExternalBooking() async {
        _ = await WarningsRefreshHelper.refreshSharedWarnings(
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            projectStore: projectStore,
            userStore: userStore,
            managerScheduleStore: managerScheduleStore,
            holidayStore: holidayStore,
            firebaseBackend: firebaseBackend,
            appSettings: appSettings
        )
    }

    func saveOperativeBookingEdit(
        booking: Booking,
        start: String,
        end: String,
        breakRemoved: Bool,
        otMultiplierOverride: Double?,
        rateShown: Bool = true
    ) {
        var updated = booking
        updated.timeSlot = .customHours
        updated.workStartTime = start
        updated.workEndTime = end
        updated.isBreakRemoved = breakRemoved
        // RULEBOOK 1.32.0 §25 (review fix r274) `overtimeMultiplierMoveFields`: the rate on screen is kept on every
        // save (a rate equal to the organisation's is removed, never stored); a rate not on screen keeps the stored one.
        updated.otMultiplierOverride = CanonicalBusinessEngine.savedOtMultiplierOverride(
            stored: booking.otMultiplierOverride,
            chosen: otMultiplierOverride,
            rateShown: rateShown,
            on: booking.date
        )
        updated.updatedAt = Date()
        // RULEBOOK 1.16.0 §5, §9: when the slot or times change, leave on that day is ticked or dropped first.
        let timesChanged = updated.timeSlot != booking.timeSlot
            || updated.workStartTime != booking.workStartTime
            || updated.workEndTime != booking.workEndTime
        let rows = timesChanged ? BookingLeaveConflictItems.items(
            for: updated,
            personName: rosterNameForLabourBooking(
                operativeId: booking.operativeId,
                operatives: operativeStore.allOperatives,
                users: userStore.organizationUsers
            ),
            holidays: holidayStore.bookings,
            operatives: operativeStore.allOperatives,
            users: userStore.organizationUsers,
            policy: firebaseBackend.payrollPolicy(for: updated.date)
        ) : []
        leaveGate.runSingle(rows: rows, afterDismiss: true) {
            Task {
                await bookingStore.updateBooking(updated)
            }
        }
    }

    func saveManagerBookingEdit(
        booking: ManagerSiteBooking,
        start: String,
        end: String,
        breakRemoved: Bool,
        otMultiplierOverride: Double? = nil
    ) {
        var updated = booking
        updated.timeSlot = .customHours
        updated.workStartTime = start
        updated.workEndTime = end
        updated.isBreakRemoved = breakRemoved
        // RULEBOOK 1.32.0 §25 (review fix r274) `overtimeMultiplierMoveFields`: the manager site booking's rate on
        // screen is kept on every save; a rate equal to the organisation's is removed, never stored.
        updated.otMultiplierOverride = CanonicalBusinessEngine.savedOtMultiplierOverride(
            stored: booking.otMultiplierOverride,
            chosen: otMultiplierOverride,
            rateShown: true,
            on: booking.date
        )
        updated.updatedAt = Date()
        let timesChanged = updated.timeSlot != booking.timeSlot
            || updated.workStartTime != booking.workStartTime
            || updated.workEndTime != booking.workEndTime
        let personName = userStore.organizationUsers.first { $0.id == booking.userId }?.fullName ?? "This person"
        let rows = timesChanged ? BookingLeaveConflictItems.items(
            for: updated,
            personName: personName,
            holidays: holidayStore.bookings,
            users: userStore.organizationUsers,
            policy: firebaseBackend.payrollPolicy(for: updated.date)
        ) : []
        leaveGate.runSingle(rows: rows, afterDismiss: true) {
            Task {
                await managerScheduleStore.saveBooking(updated)
            }
        }
    }
}

struct OnHolidayRowView: View {
    let booking: HolidayBooking
    /// RULEBOOK 1.20.0 §9 `leaveHalfDayLabel`: "Full day", "AM 06:30–10:30", "PM 10:30–14:30". Nil shows only
    /// "Annual leave".
    var slotLabel: String? = nil
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    
    private var displayName: String {
        if let uid = booking.userId,
           // Stored ids keep their case and compare without it (§1); a web record may store a lower-case id.
           let user = userStore.organizationUsers.first(where: { $0.id.caseInsensitiveCompare(uid) == .orderedSame }) {
            return user.fullName.isEmpty ? user.email : user.fullName
        }
        if let oid = booking.operativeId,
           let operative = operativeStore.operatives.first(where: { $0.id == oid }) {
            return operative.name
        }
        return "On holiday"
    }

    private var initialsGradient: [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.094, green: 0.373, blue: 0.651), Color(red: 0.216, green: 0.541, blue: 0.867)],
            [Color(red: 0.6, green: 0.208, blue: 0.337), Color(red: 0.761, green: 0.333, blue: 0.471)],
            [Color(red: 0.325, green: 0.29, blue: 0.718), Color(red: 0.498, green: 0.467, blue: 0.867)],
            [Color(red: 0.2, green: 0.55, blue: 0.42), Color(red: 0.35, green: 0.72, blue: 0.55)],
        ]
        var hasher = Hasher()
        hasher.combine(displayName)
        let hash = hasher.finalize()
        let index = ((hash % palettes.count) + palettes.count) % palettes.count
        return palettes[index]
    }
    
    var body: some View {
        HStack(spacing: 10) {
            Text(PlannerUIInitials.from(displayName))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .background(
                    LinearGradient(colors: initialsGradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(slotLabel.map { "Annual leave · \($0)" } ?? "Annual leave")
                    .font(.system(size: 10))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

/// Date Overview: pick any date (past or future) and see that day's bookings and holidays.
struct HistoricDailyOverviewView: View {
    @State private var selectedDate: Date = {
        let cal = OrganizationRulebookContext.calendar
        return cal.startOfDay(for: Date())
    }()
    @Environment(\.dismiss) private var dismiss
    
    private var minDate: Date {
        OrganizationRulebookContext.calendar.startOfDay(for: OrganizationRulebookContext.calendar.date(byAdding: .year, value: -1, to: Date()) ?? Date())
    }

    private var maxDate: Date {
        OrganizationRulebookContext.calendar.startOfDay(for: OrganizationRulebookContext.calendar.date(byAdding: .year, value: 1, to: Date()) ?? Date())
    }
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select date")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    DatePicker("", selection: $selectedDate, in: minDate...maxDate, displayedComponents: .date)
                        .accessibilityIdentifier("historicDailyOverview.datePicker")
                        .environment(\.timeZone, OrganizationRulebookContext.timeZone)
                        .datePickerStyle(.graphical)
                        .tint(ProjectWorksRevampColors.blue)
                }
                .padding(16)
                .appChromeCardContainer()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                
                DailyOverviewView(displayDate: selectedDate)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationTitle("Date Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("historicDailyOverview.done")
                }
            }
            .appChromeNavigationBarSurface()
        }
    }
}

struct ManagerScheduleRowView: View {
    let booking: ManagerSiteBooking
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var userStore: UserStore

    private var locationTitle: String {
        if booking.locationType == .office || booking.locationType == .workingFromHome || booking.locationType == .siteSurvey {
            return booking.locationType.displayName
        }
        guard let id = booking.locationId,
              let p = projectStore.projects.first(where: { $0.id == id }) else { return "Site" }
        return "\(p.jobNumber) \(p.siteName)"
    }

    private var userName: String {
        guard let u = StaffEmailIdentity.account(forUserId: booking.userId, in: userStore.organizationUsers) else {
            return booking.userId
        }
        return u.fullName
    }

    var body: some View {
        HStack {
            Text(booking.scheduleLabel(policy: .default))
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
        .appChromeCardContainer(cornerRadius: 12)
    }
}

struct ProjectBookingCard: View {
    let project: Project
    let bookings: [Booking]
    let day: Date
    /// RULEBOOK 1.33.0 §6: the viewer's Daily Overview scope (`dailyOverviewScopeFor`); nil is everything.
    var scope: [String: Any]? = nil
    var canEditBookings: Bool = false
    var onEditOperative: ((Booking) -> Void)?
    var onEditManager: ((ManagerSiteBooking) -> Void)?
    var onEditSubcontractor: ((SubcontractorBooking) -> Void)?
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.payrollPolicy(for: day)
    }

    private var smallWorksFlow: Bool { project.jobType == .smallWorks }

    private var sortedBookings: [Booking] {
        bookings.sorted { booking1, booking2 in
            let order1 = timeSlotOrder(booking1.timeSlot)
            let order2 = timeSlotOrder(booking2.timeSlot)
            if order1 != order2 {
                return order1 < order2
            }
            let k1 = booking1.minutesSortKey(policy: payrollTimePolicy)
            let k2 = booking2.minutesSortKey(policy: payrollTimePolicy)
            if k1 != k2 {
                return k1 < k2
            }
            if let operative1 = operativeStore.operatives.first(where: { $0.id == booking1.operativeId }),
               let operative2 = operativeStore.operatives.first(where: { $0.id == booking2.operativeId }) {
                return operative1.name < operative2.name
            }
            return false
        }
    }

    private var managerBookingsThisProjectDay: [ManagerSiteBooking] {
        managerScheduleStore.managerSiteBookings
            .filter { booking in
                booking.locationId == project.id &&
                    (booking.locationType == .project || booking.locationType == .smallWork) &&
                    CanonicalBusinessEngine.businessCalendar.isDate(booking.date, inSameDayAs: day) &&
                    (scope == nil || DailyOverviewScopeSupport.isRowInScope(
                        scope,
                        personIds: [booking.userId],
                        email: StaffEmailIdentity.account(forUserId: booking.userId, in: userStore.organizationUsers)?.email
                    ))
            }
            .sorted { $0.minutesSortKey(policy: payrollTimePolicy) < $1.minutesSortKey(policy: payrollTimePolicy) }
    }

    private var subcontractorBookingsThisProjectDay: [SubcontractorBooking] {
        // RULEBOOK 1.33.0 §6: subcontractor bookings only for admins (`isDailyOverviewRowInScope` with `subcontractor`).
        guard DailyOverviewScopeSupport.isRowInScope(scope, personIds: [], email: nil, subcontractor: true) else { return [] }
        return subcontractorStore.bookings
            .filter { booking in
                booking.projectId == project.id &&
                    CanonicalBusinessEngine.businessCalendar.isDate(booking.date, inSameDayAs: day) &&
                    booking.status != .cancelled
            }
            .sorted { $0.payrollMirrorBooking().minutesSortKey(policy: payrollTimePolicy) < $1.payrollMirrorBooking().minutesSortKey(policy: payrollTimePolicy) }
    }

    private var cardPeopleCount: Int {
        var keys = Set<String>()
        for booking in sortedBookings {
            let email = emailForLabourBooking(
                operativeId: booking.operativeId,
                operatives: operativeStore.allOperatives,
                users: userStore.organizationUsers
            )
            keys.insert(StaffEmailIdentity.personKey(email: email, fallbackId: "op:\(booking.operativeId.uuidString)"))
        }
        for booking in managerBookingsThisProjectDay {
            let email = StaffEmailIdentity.account(forUserId: booking.userId, in: userStore.organizationUsers)?.email
            keys.insert(StaffEmailIdentity.personKey(email: email, fallbackId: "u:\(booking.userId)"))
        }
        for booking in subcontractorBookingsThisProjectDay {
            keys.insert("sub:\(booking.subcontractorId.uuidString)")
        }
        return keys.count
    }

    private var cardBookedHours: Double {
        let p = payrollTimePolicy
        var t = sortedBookings.reduce(0.0) { $0 + $1.paidBookedHours(policy: p) }
        t += managerBookingsThisProjectDay.reduce(0.0) { $0 + $1.paidBookedHours(policy: p) }
        t += subcontractorBookingsThisProjectDay.reduce(0.0) { $0 + $1.payrollMirrorBooking().paidBookedHours(policy: p) }
        return t
    }

    private var cardOvertimeHours: Double {
        let p = payrollTimePolicy
        // Hours worked outside the standard window (`workedHoursSplit`), as the day headline.
        var t = sortedBookings.reduce(0.0) { $0 + ($1.workedHoursSplit(policy: p)?.outsideWorkedHours ?? 0) }
        t += managerBookingsThisProjectDay.reduce(0.0) { $0 + ($1.workedHoursSplit(policy: p)?.outsideWorkedHours ?? 0) }
        t += subcontractorBookingsThisProjectDay.reduce(0.0) { $0 + ($1.payrollMirrorBooking().workedHoursSplit(policy: p)?.outsideWorkedHours ?? 0) }
        return t
    }

    /// Per-person pill: the pay rule's hours for that day (`payrollHoursResult`), never the clock duration —
    /// "8h" for a Saturday window counting 8h, "13h (6.5h × 2)" for Sunday every hour ×2.
    private static func paidHoursPill(_ result: PayrollHoursResult) -> String {
        result.paidHoursLabel
    }

    private var mergedPersonRows: [ProjectDayPersonRow] {
        let p = payrollTimePolicy
        var keyed: [(Int, String, ProjectDayPersonRow)] = []
        for b in sortedBookings {
            let personName = rosterNameForLabourBooking(
                operativeId: b.operativeId,
                operatives: operativeStore.allOperatives,
                users: userStore.organizationUsers
            )
            let sub = b.scheduleCoverageSubtitle(policy: p)
            let row = ProjectDayPersonRow(
                id: "op-\(b.id.uuidString)",
                name: personName,
                subtitle: sub.text,
                subtitleOvertime: sub.emphasizedOvertime,
                pillText: Self.paidHoursPill(b.payrollHoursResult(policy: p)),
                pillOvertime: sub.emphasizedOvertime,
                initials: PlannerUIInitials.from(personName),
                gradientPair: initialsGradient(for: personName),
                operativeBooking: b,
                managerBooking: nil,
                subcontractorBooking: nil
            )
            keyed.append((b.minutesSortKey(policy: p), personName, row))
        }
        for b in managerBookingsThisProjectDay {
            let sub = b.scheduleCoverageSubtitle(policy: p)
            let row = ProjectDayPersonRow(
                id: "mgr-\(b.id.uuidString)",
                name: managerName(userId: b.userId),
                subtitle: sub.text,
                subtitleOvertime: sub.emphasizedOvertime,
                pillText: Self.paidHoursPill(b.payrollHoursResult(policy: p)),
                pillOvertime: sub.emphasizedOvertime,
                initials: PlannerUIInitials.from(managerName(userId: b.userId)),
                gradientPair: initialsGradient(for: managerName(userId: b.userId)),
                operativeBooking: nil,
                managerBooking: b,
                subcontractorBooking: nil
            )
            let tie = managerName(userId: b.userId)
            keyed.append((b.minutesSortKey(policy: p), tie, row))
        }
        for b in subcontractorBookingsThisProjectDay {
            let mirror = b.payrollMirrorBooking()
            let sub = mirror.scheduleCoverageSubtitle(policy: p)
            let firm = subcontractorStore.subcontractors.first(where: { $0.id == b.subcontractorId })
            let baseName = firm?.name ?? "Subcontractor"
            let row = ProjectDayPersonRow(
                id: "sub-\(b.id.uuidString)",
                name: baseName,
                bookedOperativeNames: b.bookedOperativeNames(subcontractor: firm),
                subtitle: sub.text,
                subtitleOvertime: sub.emphasizedOvertime,
                pillText: Self.paidHoursPill(mirror.payrollHoursResult(policy: p)),
                pillOvertime: sub.emphasizedOvertime,
                initials: PlannerUIInitials.from(baseName),
                gradientPair: initialsGradient(for: baseName),
                operativeBooking: nil,
                managerBooking: nil,
                subcontractorBooking: b
            )
            keyed.append((mirror.minutesSortKey(policy: p), baseName, row))
        }
        return keyed.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            return $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending
        }.map(\.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(smallWorksFlow ? ProjectWorksRevampColors.amberTint : ProjectWorksRevampColors.greenTint)
                        .frame(width: 32, height: 32)
                    Image(systemName: smallWorksFlow ? "hammer.fill" : "folder.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(smallWorksFlow ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.activeGreen)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(project.jobNumber)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(smallWorksFlow ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.blue)
                        Text(project.siteName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                        if smallWorksFlow {
                            Text("SMALL WORKS")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(ProjectWorksRevampColors.upcomingAmber.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 4) {
                        Text("\(cardPeopleCount) \(cardPeopleCount == 1 ? "person" : "people") · \(ScheduleCoverageFormat.hours(cardBookedHours))h booked")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                        if cardOvertimeHours > 0.05 {
                            Text("· +\(ScheduleCoverageFormat.hours(cardOvertimeHours))h OT")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                        }
                    }
                }
            }
            .padding(.bottom, 10)
            Divider().overlay(ProjectWorksRevampColors.border)
                .padding(.bottom, 8)
            ForEach(Array(mergedPersonRows.enumerated()), id: \.1.id) { idx, row in
                projectPersonRowView(row)
                if idx < mergedPersonRows.count - 1 {
                    Divider().overlay(ProjectWorksRevampColors.border)
                }
            }
        }
    }

    @ViewBuilder
    private func projectPersonRowView(_ row: ProjectDayPersonRow) -> some View {
        let isEditable = canEditBookings && (row.operativeBooking != nil || row.managerBooking != nil || row.subcontractorBooking != nil)
        let content = HStack(alignment: .center, spacing: 9) {
            Text(row.initials)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white)
                .frame(width: 26, height: 26)
                .background(
                    LinearGradient(colors: row.gradientPair, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .lineLimit(1)
                if !row.bookedOperativeNames.isEmpty {
                    ForEach(Array(row.bookedOperativeNames.enumerated()), id: \.offset) { _, opName in
                        Text(opName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .lineLimit(1)
                    }
                }
                Text(row.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(row.subtitleOvertime ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.activeGreen)
                    .lineLimit(2)
                // RULEBOOK §2: queued offline change not yet confirmed by the server.
                if let b = row.operativeBooking {
                    PendingSyncIndicator(entityId: b.id.uuidString)
                } else if let b = row.managerBooking {
                    PendingSyncIndicator(entityId: b.id.uuidString)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.pillText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(row.pillOvertime ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.activeGreen)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(row.pillOvertime ? ProjectWorksRevampColors.upcomingAmber.opacity(0.16) : ProjectWorksRevampColors.greenTint)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            if isEditable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.placeholderInk)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())

        if isEditable {
            Button {
                if let b = row.operativeBooking {
                    onEditOperative?(b)
                } else if let b = row.managerBooking {
                    onEditManager?(b)
                } else if let b = row.subcontractorBooking {
                    onEditSubcontractor?(b)
                }
            } label: {
                content
            }
            .accessibilityIdentifier("projectBookingCard.projectPersonRow")
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func managerName(userId: String) -> String {
        if let user = StaffEmailIdentity.account(forUserId: userId, in: userStore.organizationUsers) {
            return user.fullName.isEmpty ? user.email : user.fullName
        }
        return userId
    }

    private func initialsGradient(for name: String) -> [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.094, green: 0.373, blue: 0.651), Color(red: 0.216, green: 0.541, blue: 0.867)],
            [Color(red: 0.6, green: 0.208, blue: 0.337), Color(red: 0.761, green: 0.333, blue: 0.471)],
            [Color(red: 0.325, green: 0.29, blue: 0.718), Color(red: 0.498, green: 0.467, blue: 0.867)],
            [Color(red: 0.2, green: 0.55, blue: 0.42), Color(red: 0.35, green: 0.72, blue: 0.55)],
        ]
        var hasher = Hasher()
        hasher.combine(name)
        let hash = hasher.finalize()
        let idx = ((hash % palettes.count) + palettes.count) % palettes.count
        return palettes[idx]
    }

    private func timeSlotOrder(_ timeSlot: TimeSlot) -> Int {
        switch timeSlot {
        case .morning: return 1
        case .afternoon: return 2
        case .fullDay: return 3
        case .customHours: return 3
        case .evening: return 4
        case .overtime: return 5
        }
    }
}

private struct ProjectDayPersonRow: Identifiable {
    let id: String
    let name: String
    var bookedOperativeNames: [String] = []
    let subtitle: String
    let subtitleOvertime: Bool
    let pillText: String
    let pillOvertime: Bool
    let initials: String
    let gradientPair: [Color]
    let operativeBooking: Booking?
    let managerBooking: ManagerSiteBooking?
    let subcontractorBooking: SubcontractorBooking?
}

private extension View {
    /// White (dark: raised grey) rounded card on the Daily overview's light sheet.
    func ppDailyOverviewCard() -> some View {
        background(PPColor.card, in: RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
    }
}


/// One unbooked person on Daily Overview, keyed by the rulebook row id (`unbookedLabourRowsOnDay`), not the name.
struct DailyOverviewUnbookedRow: Identifiable, Hashable {
    let id: String
    let name: String
}
