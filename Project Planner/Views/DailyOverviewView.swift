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

    var id: String {
        switch self {
        case .operative(let b, _, _): return "op-\(b.id.uuidString)"
        case .manager(let b, _, _): return "mgr-\(b.id.uuidString)"
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
    @Environment(\.dismiss) private var dismiss
    @State private var showingPastBookings = false
    @State private var showingBookLabour = false
    @State private var bookingEditTarget: DailyOverviewEditTarget?
    /// When `displayDate` is nil, the user can change the day from the strip (today’s overview sheet).
    @State private var selectedCalendarDay: Date = Calendar.current.startOfDay(for: Date())
    
    private var overviewDate: Date {
        let cal = Calendar.current
        if let displayDate {
            return cal.startOfDay(for: displayDate)
        }
        return cal.startOfDay(for: selectedCalendarDay)
    }
    
    private var scheduleOptions: MyScheduleOptions {
        appSettings.settings.myScheduleOptions
    }

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }
    
    private var canBookLabour: Bool {
        userStore.hasAdminAccess() || userStore.displayUser?.permissions.manager == true
    }
    
    private var isHistoric: Bool {
        displayDate != nil
    }
    
    private var dayBookings: [Booking] {
        bookingStore.bookings.filter { booking in
            Calendar.current.isDate(booking.date, inSameDayAs: overviewDate)
        }
    }
    
    private var dayHolidays: [HolidayBooking] {
        holidayStore.approvedBookings(covering: overviewDate)
    }
    
    private var dayOfficeBookings: [ManagerSiteBooking] {
        let p = payrollTimePolicy
        return managerScheduleStore.managerSiteBookings
            .filter { booking in
                Calendar.current.isDate(booking.date, inSameDayAs: overviewDate) &&
                booking.locationType == .office
            }
            .sorted { $0.minutesSortKey(policy: p) < $1.minutesSortKey(policy: p) }
    }
    
    private var dayWorkingFromHomeBookings: [ManagerSiteBooking] {
        let p = payrollTimePolicy
        return managerScheduleStore.managerSiteBookings
            .filter { booking in
                Calendar.current.isDate(booking.date, inSameDayAs: overviewDate) &&
                booking.locationType == .workingFromHome
            }
            .sorted { $0.minutesSortKey(policy: p) < $1.minutesSortKey(policy: p) }
    }
    
    private var daySiteSurveyBookings: [ManagerSiteBooking] {
        let p = payrollTimePolicy
        return managerScheduleStore.managerSiteBookings
            .filter { booking in
                Calendar.current.isDate(booking.date, inSameDayAs: overviewDate) &&
                booking.locationType == .siteSurvey
            }
            .sorted { $0.minutesSortKey(policy: p) < $1.minutesSortKey(policy: p) }
    }
    
    private var dayCustomBookingsByName: [String: [ManagerSiteBooking]] {
        let list = managerScheduleStore.managerSiteBookings.filter { booking in
            Calendar.current.isDate(booking.date, inSameDayAs: overviewDate) &&
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
        let cal = Calendar.current
        var keys = Set<String>()
        for b in dayBookings where b.status == .confirmed || b.status == .tentative {
            keys.insert("op:\(b.operativeId.uuidString)")
        }
        for b in managerScheduleStore.managerSiteBookings {
            guard cal.isDate(b.date, inSameDayAs: overviewDate) else { continue }
            guard b.locationType == .project || b.locationType == .smallWork else { continue }
            keys.insert("u:\(b.userId)")
        }
        for b in subcontractorStore.bookings where cal.isDate(b.date, inSameDayAs: overviewDate) && b.status != .cancelled {
            keys.insert("sub:\(b.subcontractorId.uuidString)")
        }
        return keys.count
    }

    private var officePeopleCount: Int {
        Set(visibleOfficeBookings.map(\.userId)).count
    }

    private var wfhPeopleCount: Int {
        Set(visibleWFHBookings.map(\.userId)).count
    }

    private var unbookedAllNames: [String] {
        (unbookedManagerNames + unbookedOperativeNames).sorted()
    }

    /// Unique people with any same-day booking (operatives on jobs, managers on jobs or “other” locations, subs on jobs).
    private var bookedPeopleCount: Int {
        let cal = Calendar.current
        var keys = Set<String>()
        for b in dayBookings where b.status == .confirmed || b.status == .tentative {
            keys.insert("op:\(b.operativeId.uuidString)")
        }
        for b in managerScheduleStore.managerSiteBookings where cal.isDate(b.date, inSameDayAs: overviewDate) {
            if scheduleOptions.includesManagerScheduleLocation(b) {
                keys.insert("u:\(b.userId)")
            }
        }
        for b in subcontractorStore.bookings where cal.isDate(b.date, inSameDayAs: overviewDate) && b.status != .cancelled {
            keys.insert("sub:\(b.subcontractorId.uuidString)")
        }
        return keys.count
    }

    /// Wall-clock hours on project / small-work sites (operatives + managers on jobs) for the overview day.
    private var dayJobSiteLabourHours: Double {
        let p = payrollTimePolicy
        let cal = Calendar.current
        var t = 0.0
        for b in dayBookings where b.status == .confirmed || b.status == .tentative {
            t += b.totalBookedHours(policy: p)
        }
        for b in managerScheduleStore.managerSiteBookings {
            guard cal.isDate(b.date, inSameDayAs: overviewDate) else { continue }
            guard b.locationType == .project || b.locationType == .smallWork else { continue }
            t += b.totalBookedHours(policy: p)
        }
        for b in subcontractorStore.bookings where cal.isDate(b.date, inSameDayAs: overviewDate) && b.status != .cancelled {
            t += b.payrollMirrorBooking().totalBookedHours(policy: p)
        }
        return t
    }

    private var dayJobSiteOvertimeHours: Double {
        let p = payrollTimePolicy
        let cal = Calendar.current
        var t = 0.0
        for b in dayBookings where b.status == .confirmed || b.status == .tentative {
            t += b.overtimeHoursBeyondPaidStandard(policy: p)
        }
        for b in managerScheduleStore.managerSiteBookings {
            guard cal.isDate(b.date, inSameDayAs: overviewDate) else { continue }
            guard b.locationType == .project || b.locationType == .smallWork else { continue }
            t += b.overtimeHoursBeyondPaidStandard(policy: p)
        }
        for b in subcontractorStore.bookings where cal.isDate(b.date, inSameDayAs: overviewDate) && b.status != .cancelled {
            t += b.payrollMirrorBooking().overtimeHoursBeyondPaidStandard(policy: p)
        }
        return t
    }

    /// Portion of job-site hours counted at standard (elapsed minus per-booking “beyond standard” bucket).
    private var dayJobSiteStandardPortionHours: Double {
        let p = payrollTimePolicy
        let cal = Calendar.current
        var t = 0.0
        for b in dayBookings where b.status == .confirmed || b.status == .tentative {
            let wall = b.totalBookedHours(policy: p)
            t += wall - b.overtimeHoursBeyondPaidStandard(policy: p)
        }
        for b in managerScheduleStore.managerSiteBookings {
            guard cal.isDate(b.date, inSameDayAs: overviewDate) else { continue }
            guard b.locationType == .project || b.locationType == .smallWork else { continue }
            let wall = b.totalBookedHours(policy: p)
            t += wall - b.overtimeHoursBeyondPaidStandard(policy: p)
        }
        for b in subcontractorStore.bookings where cal.isDate(b.date, inSameDayAs: overviewDate) && b.status != .cancelled {
            let m = b.payrollMirrorBooking()
            let wall = m.totalBookedHours(policy: p)
            t += wall - m.overtimeHoursBeyondPaidStandard(policy: p)
        }
        return t
    }

    private func overviewFormatHours(_ hours: Double) -> String {
        let rounded = (hours * 2).rounded() / 2
        if abs(rounded - rounded.rounded(.towardZero)) < 0.01 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }

    private func shiftOverviewDay(_ delta: Int) {
        guard displayDate == nil else { return }
        let cal = Calendar.current
        guard let d = cal.date(byAdding: .day, value: delta, to: overviewDate) else { return }
        selectedCalendarDay = cal.startOfDay(for: d)
    }

    private var isWeekday: Bool {
        let weekday = Calendar.current.component(.weekday, from: overviewDate)
        return weekday >= 2 && weekday <= 6
    }

    private var operativeUsers: [AppUser] {
        userStore.organizationUsers.filter { $0.permissions.operativeMode && $0.isActive }
    }

    private var managerUsers: [AppUser] {
        userStore.organizationUsers.filter {
            !$0.permissions.operativeMode &&
            !$0.isSuperAdmin &&
            !$0.permissions.adminAccess &&
            $0.permissions.manager &&
            $0.isActive
        }
    }

    private func hasApprovedHoliday(userId: String, operativeId: UUID?) -> Bool {
        dayHolidays.contains { holiday in
            if holiday.status != .approved { return false }
            if holiday.userId == userId { return true }
            if let operativeId, holiday.operativeId == operativeId { return true }
            return false
        }
    }

    private func operativeHasFullDayBooking(_ operativeId: UUID) -> Bool {
        let policy = payrollTimePolicy
        let bookings = dayBookings.filter {
            $0.operativeId == operativeId && ($0.status == .confirmed || $0.status == .tentative)
        }
        if bookings.contains(where: { $0.timeSlot == .fullDay }) { return true }
        let hasAM = bookings.contains(where: { $0.timeSlot == .morning })
        let hasPM = bookings.contains(where: { $0.timeSlot == .afternoon })
        if hasAM && hasPM { return true }
        return bookings.contains { OperativeBookingInterval.coversFullStandardDay($0, policy: policy) }
    }

    private func managerHasFullDayProjectBooking(_ userId: String) -> Bool {
        let policy = payrollTimePolicy
        let bookings: [ManagerSiteBooking] = managerScheduleStore.managerSiteBookings.filter { booking in
            let sameDay = Calendar.current.isDate(booking.date, inSameDayAs: overviewDate)
            let sameUser = booking.userId == userId
            let isProjectLocation = booking.locationType == ManagerLocationType.project || booking.locationType == ManagerLocationType.smallWork
            return sameDay && sameUser && isProjectLocation
        }
        if bookings.contains(where: { $0.timeSlot == ManagerTimeSlot.fullDay }) { return true }
        let hasAM = bookings.contains(where: { $0.timeSlot == ManagerTimeSlot.morning })
        let hasPM = bookings.contains(where: { $0.timeSlot == ManagerTimeSlot.afternoon })
        if hasAM && hasPM { return true }
        return bookings.contains { ManagerScheduleInterval.coversFullStandardDay($0, policy: policy) }
    }

    private var unbookedOperativeNames: [String] {
        operativeUsers.compactMap { user in
            let linkedOperative = operativeStore.allOperatives.first { $0.email.lowercased() == user.email.lowercased() }
            if hasApprovedHoliday(userId: user.id, operativeId: linkedOperative?.id) { return nil }
            guard let operativeId = linkedOperative?.id else {
                return user.fullName.isEmpty ? user.email : user.fullName
            }
            return operativeHasFullDayBooking(operativeId) ? nil : linkedOperative?.name
        }
        .sorted()
    }

    private var unbookedManagerNames: [String] {
        managerUsers.compactMap { user in
            if hasApprovedHoliday(userId: user.id, operativeId: nil) { return nil }
            return managerHasFullDayProjectBooking(user.id) ? nil : (user.fullName.isEmpty ? user.email : user.fullName)
        }
        .sorted()
    }
    
    // Group bookings by project
    private var bookingsByProject: [UUID: [Booking]] {
        Dictionary(grouping: dayBookings) { $0.projectId }
    }
    
    private var displayedProjectIds: [UUID] {
        var ids = Set(bookingsByProject.keys)
        let managerIds = managerScheduleStore.managerSiteBookings.compactMap { booking -> UUID? in
            guard Calendar.current.isDate(booking.date, inSameDayAs: overviewDate),
                  (booking.locationType == .project || booking.locationType == .smallWork) else { return nil }
            return booking.locationId
        }
        let subcontractorIds = subcontractorStore.bookings.compactMap { booking -> UUID? in
            guard Calendar.current.isDate(booking.date, inSameDayAs: overviewDate),
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
        return formatter
    }
    
    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !isHistoric {
                    topActionsRow
                }

                if displayDate == nil && !isHistoric {
                    dateDayNavigatorCard
                } else if isHistoric {
                    historicDateCaption
                }

                todayAtAGlanceHeroCard

                if isWeekday && !unbookedAllNames.isEmpty {
                    unbookedLabourRevampCard
                }

                if !dayHolidays.isEmpty {
                    annualLeaveRevampBlock
                }

                otherScheduleRevampSection

                if !visibleSiteSurveyBookings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        revampSectionHeader(title: "Site survey", trailing: nil)
                        managerScheduleRevampCard(
                            sectionIcon: "mappin.and.ellipse",
                            iconBackground: ProjectWorksRevampColors.pinRoseBg,
                            iconForeground: ProjectWorksRevampColors.pinRoseFg,
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
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
    }

    private var topActionsRow: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: { showingPastBookings = true }) {
                Label("View by date", systemImage: "calendar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.blue)
            }
            .buttonStyle(.plain)
        }
    }

    private var historicDateCaption: some View {
        Text(dateFormatter.string(from: overviewDate))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.ink)
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
            )
    }

    private var dateDayNavigatorCard: some View {
        HStack(spacing: 0) {
            Button(action: { shiftOverviewDay(-1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            Button(action: { showingPastBookings = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                    VStack(spacing: 2) {
                        Text(dateFormatter.string(from: overviewDate))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                        Text(Calendar.current.isDateInToday(overviewDate) ? "Today · Tap to change" : "Tap to change")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.blue)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            Button(action: { shiftOverviewDay(1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var glanceHeadlinePeopleCount: Int {
        max(onSitePeopleCount, bookedPeopleCount)
    }

    private var glanceUnbookedCount: Int {
        isWeekday ? unbookedAllNames.count : 0
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

    /// Unified summary hero (`project_planner_daily_overview_unified_hero.html`) — display only, not tappable.
    private var todayAtAGlanceHeroCard: some View {
        let unbooked = glanceUnbookedCount
        let mult = payrollTimePolicy.weekdayOutsideStandardMultiplier
        let multLabel = abs(mult - mult.rounded()) < 0.05 ? String(format: "%.0f", mult) : String(format: "%.1f", mult)
        let jobsCount = displayedProjectIds.count
        let people = glanceHeadlinePeopleCount
        let bar = teamLocationBarFractions
        let isToday = Calendar.current.isDateInToday(overviewDate)
        let glanceTitle = isToday ? "Today at a glance" : "Day at a glance"

        return ZStack(alignment: .topTrailing) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.1), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 65
                    )
                )
                .frame(width: 130, height: 130)
                .offset(x: 28, y: -28)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(glanceTitle.uppercased())
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .tracking(0.4)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(overviewFormatHours(dayJobSiteLabourHours))h")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(Color.white)
                                .tracking(-0.5)
                            Text("· \(people) \(people == 1 ? "person" : "people")")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.85))
                        }
                    }
                    Spacer(minLength: 8)
                    if unbooked > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .medium))
                            Text("\(unbooked) unbooked")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.18))
                        .clipShape(Capsule())
                    }
                }
                .padding(.bottom, 14)

                HStack(spacing: 7) {
                    glanceStatPill(value: overviewFormatHours(dayJobSiteStandardPortionHours), label: "Standard hrs")
                    glanceStatPill(
                        value: overviewFormatHours(dayJobSiteOvertimeHours),
                        label: "OT \(multLabel)×"
                    )
                    glanceStatPill(value: "\(jobsCount)", label: jobsCount == 1 ? "Job active" : "Jobs active")
                }
                .padding(.bottom, 14)

                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 0.5)
                    .padding(.bottom, 12)

                HStack {
                    Text("WHERE THE TEAM IS")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .tracking(0.4)
                    Spacer()
                    Text("\(bookedPeopleCount) booked · \(unbooked) unbooked")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .padding(.bottom, 10)

                teamLocationDistributionBar(office: bar.office, wfh: bar.wfh, onSite: bar.onSite, unbooked: bar.unbooked)
                    .padding(.bottom, 8)

                HStack(spacing: 12) {
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
                                .font(.system(size: 12, weight: .medium))
                            Text("\(unbooked)")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Color.white)
                    }
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(glanceTitle). \(overviewFormatHours(dayJobSiteLabourHours)) hours across \(people) people.")
    }

    private func glanceStatPill(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.white)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func teamLocationDistributionBar(office: CGFloat, wfh: CGFloat, onSite: CGFloat, unbooked: CGFloat) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                if office > 0 {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: max(1, w * office))
                }
                if wfh > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.6))
                        .frame(width: max(1, w * wfh))
                }
                if onSite > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: max(1, w * onSite))
                }
                if unbooked > 0 {
                    glanceUnbookedStripeFill()
                        .frame(width: max(1, w * unbooked))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: 8)
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
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
                .stroke(Color.white.opacity(0.35), lineWidth: 2)
                .background(Color.white.opacity(0.15))
            }
        }
    }

    private func glanceUnbookedStripeFill() -> some View {
        GlanceUnbookedStripeFill()
    }

    private func glanceLocationLegendItem(systemImage: String, count: Int, label: String, dimmed: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(Color.white.opacity(dimmed ? 0.55 : 1))
    }

    private var unbookedLabourRevampCard: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 34, height: 34)
                Image(systemName: "person.fill.questionmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Unbooked labour")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                    Spacer(minLength: 8)
                    Text("\(unbookedAllNames.count) people")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(unbookedAllNames, id: \.self) { name in
                            HStack(spacing: 5) {
                                Text(PlannerUIInitials.from(name))
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(Color.white)
                                    .frame(width: 18, height: 18)
                                    .background(
                                        LinearGradient(
                                            colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .clipShape(Circle())
                                Text(name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.ink)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.white)
                            .clipShape(Capsule())
                        }
                    }
                }
                if canBookLabour {
                    Button(action: { showingBookLabour = true }) {
                        Text("Book labour")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.clear)
                            .overlay(
                                Capsule().stroke(ProjectWorksRevampColors.requiredPillFg, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(ProjectWorksRevampColors.requiredPillBg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var annualLeaveRevampBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            revampSectionHeader(title: "Annual leave", trailing: nil)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(dayHolidays.enumerated()), id: \.element.id) { idx, booking in
                    OnHolidayRowView(booking: booking)
                    if idx < dayHolidays.count - 1 {
                        Divider().overlay(ProjectWorksRevampColors.border)
                    }
                }
            }
            .padding(14)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
            )
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
            VStack(alignment: .leading, spacing: 8) {
                revampSectionHeader(
                    title: "Other",
                    trailing: "\(people.count) person\(people.count == 1 ? "" : "s")"
                )
                VStack(alignment: .leading, spacing: 0) {
                    otherScheduleBlock(
                        needsTopDivider: false,
                        icon: "building.2.fill",
                        iconBg: Color(red: 0.902, green: 0.945, blue: 0.984),
                        iconTint: ProjectWorksRevampColors.blue,
                        title: "Office",
                        bookings: office,
                        locationTitle: "Office"
                    )
                    otherScheduleBlock(
                        needsTopDivider: !office.isEmpty,
                        icon: "house.fill",
                        iconBg: Color(red: 0.882, green: 0.961, blue: 0.933),
                        iconTint: ProjectWorksRevampColors.activeGreen,
                        title: "Working from home",
                        bookings: wfh,
                        locationTitle: "Working from home"
                    )
                    ForEach(Array(customGroups.keys.sorted().enumerated()), id: \.element) { idx, customName in
                        otherScheduleBlock(
                            needsTopDivider: !office.isEmpty || !wfh.isEmpty || idx > 0,
                            icon: "mappin.and.ellipse",
                            iconBg: ProjectWorksRevampColors.jobTypePillBg,
                            iconTint: ProjectWorksRevampColors.jobTypePillInk,
                            title: customName,
                            bookings: customGroups[customName] ?? [],
                            locationTitle: customName
                        )
                    }
                }
                .padding(14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                )
            }
        }
    }

    @ViewBuilder
    private func otherScheduleBlock(
        needsTopDivider: Bool,
        icon: String,
        iconBg: Color,
        iconTint: Color,
        title: String,
        bookings: [ManagerSiteBooking],
        locationTitle: String
    ) -> some View {
        if !bookings.isEmpty {
            if needsTopDivider {
                Divider().padding(.vertical, 6).overlay(ProjectWorksRevampColors.border)
            }
            otherScheduleInnerHeader(icon: icon, iconBg: iconBg, iconTint: iconTint, title: title, caption: "Managers / admins")
            ForEach(Array(bookings.enumerated()), id: \.element.id) { idx, booking in
                managerBookingRevampRow(booking: booking, locationTitle: locationTitle, editable: false)
                if idx < bookings.count - 1 { Divider().overlay(ProjectWorksRevampColors.border) }
            }
        }
    }

    private func otherScheduleInnerHeader(icon: String, iconBg: Color, iconTint: Color, title: String, caption: String) -> some View {
        HStack {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconBg)
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconTint)
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
            }
            Spacer()
            Text(caption)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
        .padding(.bottom, 10)
    }

    private var liveProjectsRevampSection: some View {
        let ids = displayedProjectIds.sorted { id1, id2 in
            let all = projectStore.projects + projectStore.smallWorks
            guard let p1 = all.first(where: { $0.id == id1 }), let p2 = all.first(where: { $0.id == id2 }) else { return false }
            return p1.siteName < p2.siteName
        }
        return Group {
            if !ids.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    revampSectionHeader(title: "By project", trailing: nil)
                    ForEach(ids, id: \.self) { projectId in
                        let all = projectStore.projects + projectStore.smallWorks
                        if let project = all.first(where: { $0.id == projectId }) {
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
                canEditBookings: canBookLabour,
                onEditOperative: { booking in
                    guard let op = operativeStore.operatives.first(where: { $0.id == booking.operativeId }) else { return }
                    bookingEditTarget = .operative(
                        booking: booking,
                        project: project,
                        personName: op.name
                    )
                },
                onEditManager: { booking in
                    bookingEditTarget = .manager(
                        booking: booking,
                        locationTitle: "\(project.jobNumber) \(project.siteName)",
                        personName: managerName(for: booking.userId)
                    )
                }
            )
            .environmentObject(managerScheduleStore)
            .environmentObject(subcontractorStore)

            NavigationLink {
                ProjectDetailView(project: project)
                    .environmentObject(bookingStore)
                    .environmentObject(managerScheduleStore)
                    .environmentObject(operativeStore)
                    .environmentObject(projectStore)
                    .environmentObject(userStore)
                    .environmentObject(holidayStore)
                    .environmentObject(subcontractorStore)
                    .environmentObject(firebaseBackend)
                    .environmentObject(notificationService)
                    .environmentObject(appSettings)
                    .environmentObject(taskStore)
            } label: {
                HStack(spacing: 5) {
                    Text("Open project")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(ProjectWorksRevampColors.blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color(red: 0.969, green: 0.973, blue: 0.980))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                )
            }
            .padding(.top, 8)
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func revampSectionHeader(title: String, trailing: String?) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .tracking(0.4)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
        }
        .padding(.leading, 4)
    }

    private func managerScheduleRevampCard(
        sectionIcon: String,
        iconBackground: Color,
        iconForeground: Color,
        title: String,
        trailingCaption: String,
        bookings: [ManagerSiteBooking]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(iconBackground)
                            .frame(width: 30, height: 30)
                        Image(systemName: sectionIcon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(iconForeground)
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                }
                Spacer()
                Text(trailingCaption)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            .padding(.bottom, 10)

            ForEach(Array(bookings.enumerated()), id: \.element.id) { idx, booking in
                managerBookingRevampRow(booking: booking, locationTitle: title)
                if idx < bookings.count - 1 {
                    Divider().overlay(ProjectWorksRevampColors.border)
                }
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func managerBookingRevampRow(booking: ManagerSiteBooking, locationTitle: String, editable: Bool = true) -> some View {
        let name = managerName(for: booking.userId)
        let canEditRow = canBookLabour && editable
        let row = HStack(spacing: 10) {
            Text(managerTimeSlotDisplayText(for: booking))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.pinRoseFg)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(ProjectWorksRevampColors.pinRoseBg)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            HStack(spacing: 6) {
                Text(PlannerUIInitials.from(name))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white)
                    .frame(width: 22, height: 22)
                    .background(
                        LinearGradient(
                            colors: [ProjectWorksRevampColors.pinRoseFg, Color(red: 0.761, green: 0.345, blue: 0.471)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    Text(booking.scheduleLabel(policy: payrollTimePolicy))
                        .font(.system(size: 10))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if canEditRow {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
            }
        }
        .padding(.vertical, 6)
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
                            }
                        }
                        .appChromeNavigationBarSurface()
                }
            }
        }
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
        .fullScreenCover(isPresented: $showingBookLabour) {
            BookLabourFlowView(bookDate: overviewDate)
                .environmentObject(appSettings)
                .environmentObject(bookingStore)
                .environmentObject(projectStore)
                .environmentObject(operativeStore)
                .environmentObject(userStore)
                .environmentObject(holidayStore)
                .environmentObject(managerScheduleStore)
                .environmentObject(firebaseBackend)
        }
        .sheet(item: $bookingEditTarget) { target in
            dailyOverviewEditSheet(for: target)
        }
    }
    
    private var noBookingsView: some View {
        VStack(spacing: 16) {
            Text("No bookings")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
        .appChromeCardContainer()
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
        if let user = userStore.organizationUsers.first(where: { $0.id == userId }) {
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

    @ViewBuilder
    func dailyOverviewEditSheet(for target: DailyOverviewEditTarget) -> some View {
        switch target {
        case .operative(let booking, let project, let personName):
            OperativeCustomHoursSheet(
                policy: payrollTimePolicy,
                title: "Edit booking",
                subtitle: editSheetSubtitle(date: booking.date, locationTitle: "\(project.jobNumber) \(project.siteName)"),
                headerName: personName,
                headerInitials: PlannerUIInitials.from(personName),
                allowsOtMultiplierOverride: true,
                initialChoice: OperativeDayBookingChoice(from: booking),
                onSave: { start, end, breakRemoved, otMult in
                    bookingEditTarget = nil
                    saveOperativeBookingEdit(
                        booking: booking,
                        start: start,
                        end: end,
                        breakRemoved: breakRemoved,
                        otMultiplierOverride: otMult
                    )
                },
                onCancel: { bookingEditTarget = nil }
            )
        case .manager(let booking, let locationTitle, let personName):
            OperativeCustomHoursSheet(
                policy: payrollTimePolicy,
                title: "Edit booking",
                subtitle: editSheetSubtitle(date: booking.date, locationTitle: locationTitle),
                headerName: personName,
                headerInitials: PlannerUIInitials.from(personName),
                allowsOtMultiplierOverride: false,
                initialChoice: booking.hoursEditChoice(policy: payrollTimePolicy),
                onSave: { start, end, breakRemoved, _ in
                    bookingEditTarget = nil
                    saveManagerBookingEdit(
                        booking: booking,
                        start: start,
                        end: end,
                        breakRemoved: breakRemoved
                    )
                },
                onCancel: { bookingEditTarget = nil }
            )
        }
    }

    func saveOperativeBookingEdit(
        booking: Booking,
        start: String,
        end: String,
        breakRemoved: Bool,
        otMultiplierOverride: Double?
    ) {
        var updated = booking
        updated.timeSlot = .customHours
        updated.workStartTime = start
        updated.workEndTime = end
        updated.isBreakRemoved = breakRemoved
        updated.otMultiplierOverride = otMultiplierOverride
        updated.updatedAt = Date()
        Task {
            await bookingStore.updateBooking(updated)
        }
    }

    func saveManagerBookingEdit(
        booking: ManagerSiteBooking,
        start: String,
        end: String,
        breakRemoved: Bool
    ) {
        var updated = booking
        updated.timeSlot = .customHours
        updated.workStartTime = start
        updated.workEndTime = end
        updated.isBreakRemoved = breakRemoved
        updated.updatedAt = Date()
        Task {
            await managerScheduleStore.saveBooking(updated)
        }
    }
}

struct OnHolidayRowView: View {
    let booking: HolidayBooking
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var operativeStore: OperativeStore
    
    private var displayName: String {
        if let uid = booking.userId,
           let user = userStore.organizationUsers.first(where: { $0.id == uid }) {
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
        let index = abs(hasher.finalize()) % palettes.count
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
                Text("Annual leave")
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
        let cal = Calendar.current
        return cal.startOfDay(for: Date())
    }()
    @Environment(\.dismiss) private var dismiss
    
    private var minDate: Date {
        Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date())
    }

    private var maxDate: Date {
        Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date())
    }
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select date")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    DatePicker("", selection: $selectedDate, in: minDate...maxDate, displayedComponents: .date)
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
        guard let u = userStore.organizationUsers.first(where: { $0.id == booking.userId }) else {
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
    var canEditBookings: Bool = false
    var onEditOperative: ((Booking) -> Void)?
    var onEditManager: ((ManagerSiteBooking) -> Void)?
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
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
                    Calendar.current.isDate(booking.date, inSameDayAs: day)
            }
            .sorted { $0.minutesSortKey(policy: payrollTimePolicy) < $1.minutesSortKey(policy: payrollTimePolicy) }
    }

    private var subcontractorBookingsThisProjectDay: [SubcontractorBooking] {
        subcontractorStore.bookings
            .filter { booking in
                booking.projectId == project.id &&
                    Calendar.current.isDate(booking.date, inSameDayAs: day) &&
                    booking.status != .cancelled
            }
            .sorted { $0.payrollMirrorBooking().minutesSortKey(policy: payrollTimePolicy) < $1.payrollMirrorBooking().minutesSortKey(policy: payrollTimePolicy) }
    }

    private var cardPeopleCount: Int {
        sortedBookings.count + managerBookingsThisProjectDay.count + subcontractorBookingsThisProjectDay.count
    }

    private var cardBookedHours: Double {
        let p = payrollTimePolicy
        var t = sortedBookings.reduce(0.0) { $0 + $1.totalBookedHours(policy: p) }
        t += managerBookingsThisProjectDay.reduce(0.0) { $0 + $1.totalBookedHours(policy: p) }
        t += subcontractorBookingsThisProjectDay.reduce(0.0) { $0 + $1.payrollMirrorBooking().totalBookedHours(policy: p) }
        return t
    }

    private var cardOvertimeHours: Double {
        let p = payrollTimePolicy
        var t = sortedBookings.reduce(0.0) { $0 + $1.overtimeHoursBeyondPaidStandard(policy: p) }
        t += managerBookingsThisProjectDay.reduce(0.0) { $0 + $1.overtimeHoursBeyondPaidStandard(policy: p) }
        t += subcontractorBookingsThisProjectDay.reduce(0.0) { $0 + $1.payrollMirrorBooking().overtimeHoursBeyondPaidStandard(policy: p) }
        return t
    }

    private var mergedPersonRows: [ProjectDayPersonRow] {
        let p = payrollTimePolicy
        var keyed: [(Int, String, ProjectDayPersonRow)] = []
        for b in sortedBookings {
            guard let op = operativeStore.operatives.first(where: { $0.id == b.operativeId }) else { continue }
            let sub = b.scheduleCoverageSubtitle(policy: p)
            let row = ProjectDayPersonRow(
                id: "op-\(b.id.uuidString)",
                name: op.name,
                subtitle: sub.text,
                subtitleOvertime: sub.emphasizedOvertime,
                pillText: b.scheduleCoveragePillHours(policy: p),
                pillOvertime: sub.emphasizedOvertime,
                initials: PlannerUIInitials.from(op.name),
                gradientPair: initialsGradient(for: op.name),
                operativeBooking: b,
                managerBooking: nil
            )
            let tie = op.name
            keyed.append((b.minutesSortKey(policy: p), tie, row))
        }
        for b in managerBookingsThisProjectDay {
            let sub = b.scheduleCoverageSubtitle(policy: p)
            let row = ProjectDayPersonRow(
                id: "mgr-\(b.id.uuidString)",
                name: managerName(userId: b.userId),
                subtitle: sub.text,
                subtitleOvertime: sub.emphasizedOvertime,
                pillText: b.scheduleCoveragePillHours(policy: p),
                pillOvertime: sub.emphasizedOvertime,
                initials: PlannerUIInitials.from(managerName(userId: b.userId)),
                gradientPair: initialsGradient(for: managerName(userId: b.userId)),
                operativeBooking: nil,
                managerBooking: b
            )
            let tie = managerName(userId: b.userId)
            keyed.append((b.minutesSortKey(policy: p), tie, row))
        }
        for b in subcontractorBookingsThisProjectDay {
            let mirror = b.payrollMirrorBooking()
            let sub = mirror.scheduleCoverageSubtitle(policy: p)
            let baseName = subcontractorStore.subcontractors.first(where: { $0.id == b.subcontractorId })?.name ?? "Subcontractor"
            let row = ProjectDayPersonRow(
                id: "sub-\(b.id.uuidString)",
                name: "\(baseName) · Sub",
                subtitle: sub.text,
                subtitleOvertime: sub.emphasizedOvertime,
                pillText: mirror.scheduleCoveragePillHours(policy: p),
                pillOvertime: sub.emphasizedOvertime,
                initials: PlannerUIInitials.from(baseName),
                gradientPair: initialsGradient(for: baseName),
                operativeBooking: nil,
                managerBooking: nil
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
                        .fill(smallWorksFlow ? Color(red: 0.98, green: 0.933, blue: 0.855) : Color(red: 0.882, green: 0.961, blue: 0.933))
                        .frame(width: 32, height: 32)
                    Image(systemName: smallWorksFlow ? "hammer.fill" : "folder.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(smallWorksFlow ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.activeGreen)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(project.jobNumber)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(smallWorksFlow ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.blue)
                        Text(project.siteName)
                            .font(.system(size: 12, weight: .medium))
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
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                        if cardOvertimeHours > 0.05 {
                            Text("· +\(ScheduleCoverageFormat.hours(cardOvertimeHours))h OT")
                                .font(.system(size: 10, weight: .medium))
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
        let isEditable = canEditBookings && (row.operativeBooking != nil || row.managerBooking != nil)
        let content = HStack(alignment: .center, spacing: 9) {
            Text(row.initials)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white)
                .frame(width: 26, height: 26)
                .background(
                    LinearGradient(colors: row.gradientPair, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(row.subtitleOvertime ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.activeGreen)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.pillText)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(row.pillOvertime ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.activeGreen)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(row.pillOvertime ? ProjectWorksRevampColors.upcomingAmber.opacity(0.16) : Color(red: 0.882, green: 0.961, blue: 0.933))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            if isEditable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.773, green: 0.788, blue: 0.824))
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
                }
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func managerName(userId: String) -> String {
        if let user = userStore.organizationUsers.first(where: { $0.id == userId }) {
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
        let idx = abs(hasher.finalize()) % palettes.count
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
    let subtitle: String
    let subtitleOvertime: Bool
    let pillText: String
    let pillOvertime: Bool
    let initials: String
    let gradientPair: [Color]
    let operativeBooking: Booking?
    let managerBooking: ManagerSiteBooking?
}











