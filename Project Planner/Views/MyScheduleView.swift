//
//  MyScheduleView.swift
//  Project Planner
//
//  Admins/Managers: book themselves into a site (project/small work) or office – AM, PM, Full Day.
//  Operatives: view their week-only schedule and "Add to Calendar".
//

import SwiftUI
import EventKit
import FirebaseAuth

// MARK: - Manager schedule booking helpers (fileprivate)

fileprivate struct SecondBookingDialog: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let onConfirm: () -> Void
}

fileprivate struct CustomHoursEditorContext: Identifiable {
    let id = UUID()
    let days: [Date]
    let locationType: ManagerLocationType
    let locationId: UUID?
    let customLocationName: String?
    /// When replacing an existing manager booking (edit flow).
    var replaceBookingId: UUID?
    var seedStart: String?
    var seedEnd: String?
    var seedBreakRemoved: Bool?
}

// MARK: - Hours / overtime (project_planner_hours_and_overtime_system.html)

fileprivate func segmentHoursForManager(_ b: ManagerSiteBooking, policy: OrgPayrollTimePolicy) -> (early: Double, mid: Double, late: Double) {
    guard let iv = ManagerScheduleInterval.clashInterval(for: b, policy: policy) else {
        return (0, b.totalBookedHours(policy: policy), 0)
    }
    let sm = iv.0, em = iv.1
    guard let ds = ManagerScheduleInterval.parseMinutes(policy.standardDayStart),
          let de = ManagerScheduleInterval.parseMinutes(policy.standardDayEnd), de > ds else {
        return (0, Double(em - sm) / 60.0, 0)
    }
    let earlyM = max(0, min(em, ds) - sm)
    let lateM = max(0, em - max(sm, de))
    let midM = max(0, min(em, de) - max(sm, ds))
    return (Double(earlyM) / 60.0, Double(midM) / 60.0, Double(lateM) / 60.0)
}

fileprivate func segmentHoursForOperative(_ b: Booking, policy: OrgPayrollTimePolicy) -> (early: Double, mid: Double, late: Double) {
    guard let iv = OperativeBookingInterval.clashInterval(for: b, policy: policy) else {
        return (0, b.totalBookedHours(policy: policy), 0)
    }
    let sm = iv.0, em = iv.1
    guard let ds = ManagerScheduleInterval.parseMinutes(policy.standardDayStart),
          let de = ManagerScheduleInterval.parseMinutes(policy.standardDayEnd), de > ds else {
        return (0, Double(em - sm) / 60.0, 0)
    }
    let earlyM = max(0, min(em, ds) - sm)
    let lateM = max(0, em - max(sm, de))
    let midM = max(0, min(em, de) - max(sm, ds))
    return (Double(earlyM) / 60.0, Double(midM) / 60.0, Double(lateM) / 60.0)
}

fileprivate struct DayHoursSegmentTotals {
    /// Sum of paid booked hours shown in the day summary (legacy full day uses org paid hours, not raw clock span).
    var totalPaidHours: Double
    var early: Double
    var mid: Double
    var late: Double
    var otReported: Double
}

fileprivate func mergedDaySegments(
    manager: [ManagerSiteBooking],
    operative: [Booking],
    policy: OrgPayrollTimePolicy
) -> DayHoursSegmentTotals {
    var early: Double = 0, mid: Double = 0, late: Double = 0, ot: Double = 0, paidSum: Double = 0
    for b in manager {
        let s = segmentHoursForManager(b, policy: policy)
        early += s.early
        mid += s.mid
        late += s.late
        paidSum += b.paidBookedHours(policy: policy)
        ot += b.overtimeHoursBeyondPaidStandard(policy: policy)
    }
    for b in operative {
        let s = segmentHoursForOperative(b, policy: policy)
        early += s.early
        mid += s.mid
        late += s.late
        paidSum += b.paidBookedHours(policy: policy)
        ot += b.overtimeHoursBeyondPaidStandard(policy: policy)
    }
    return DayHoursSegmentTotals(totalPaidHours: paidSum, early: early, mid: mid, late: late, otReported: ot)
}

fileprivate func myScheduleLocationStripeColor(_ t: ManagerLocationType) -> Color {
    switch t {
    case .office: return ProjectWorksRevampColors.blue
    case .workingFromHome: return Color(red: 0.325, green: 0.29, blue: 0.718)
    case .siteSurvey: return ProjectWorksRevampColors.upcomingAmber
    case .project, .smallWork: return ProjectWorksRevampColors.activeGreen
    case .custom: return ProjectWorksRevampColors.muted
    }
}

fileprivate func managerBookingOtChipText(_ b: ManagerSiteBooking, policy: OrgPayrollTimePolicy) -> String? {
    let ot = b.overtimeHoursBeyondPaidStandard(policy: policy)
    guard ot > 0.05 else { return nil }
    let m = policy.weekdayOutsideStandardMultiplier
    let s = abs(m - m.rounded()) < 0.05 ? String(format: "%.0f", m) : String(format: "%.1f", m)
    return "OT \(ScheduleCoverageFormat.hours(ot))h × \(s)"
}

/// Clock range plus paid hours (break deducted for standard window bookings).
fileprivate func managerBookingClockSubtitle(_ b: ManagerSiteBooking, day: Date, policy: OrgPayrollTimePolicy) -> String {
    let block = b.calendarBlock(on: day, policy: policy)
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    let start: String
    let end: String
    if let s = b.workStartTime, let e = b.workEndTime, !s.isEmpty, !e.isEmpty {
        start = s
        end = e
    } else {
        start = f.string(from: block.start)
        end = f.string(from: block.end)
    }
    return "\(start) – \(end) · \(ScheduleCoverageFormat.hours(b.paidBookedHours(policy: policy))) hrs"
}

fileprivate func operativeBookingOtChipText(_ b: Booking, policy: OrgPayrollTimePolicy) -> String? {
    let ot = b.overtimeHoursBeyondPaidStandard(policy: policy)
    guard ot > 0.05 else { return nil }
    let m = b.effectiveWeekdayOtMultiplier(policy: policy)
    let s = abs(m - m.rounded()) < 0.05 ? String(format: "%.0f", m) : String(format: "%.1f", m)
    return "OT \(ScheduleCoverageFormat.hours(ot))h × \(s)"
}

fileprivate func operativeBookingClockSubtitle(_ b: Booking, day: Date, policy: OrgPayrollTimePolicy) -> String {
    let block = b.calendarBlock(on: day, policy: policy)
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    let start: String
    let end: String
    if let s = b.workStartTime, let e = b.workEndTime, !s.isEmpty, !e.isEmpty {
        start = s
        end = e
    } else {
        start = f.string(from: block.start)
        end = f.string(from: block.end)
    }
    return "\(start) – \(end) · \(ScheduleCoverageFormat.hours(b.paidBookedHours(policy: policy))) hrs"
}

fileprivate struct MyScheduleBookingStripeRow: View {
    let stripeColor: Color
    let title: String
    let subtitle: String
    let otChip: String?
    var showActions: Bool = false
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(stripeColor)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let otChip {
                        Text(otChip)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(red: 0.522, green: 0.310, blue: 0.043))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(red: 0.98, green: 0.933, blue: 0.855))
                            .clipShape(Capsule())
                    }
                }
                if showActions, onEdit != nil || onDelete != nil {
                    HStack(spacing: 16) {
                        if let onEdit {
                            Button("Edit", action: onEdit)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(ProjectWorksRevampColors.blue)
                                .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                        if let onDelete {
                            Button(action: onDelete) {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(ProjectWorksRevampColors.muted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }
}

fileprivate struct MyScheduleDayNavigatorCard: View {
    let day: Date
    let onPrev: () -> Void
    let onNext: () -> Void
    private let cal = Calendar.current

    var body: some View {
        HStack {
            Button(action: onPrev) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            .buttonStyle(.plain)
            VStack(spacing: 2) {
                Text(dayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(cal.isDateInToday(day) ? "Today · Tap to change" : "Tap week strip to jump")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.blue)
            }
            .frame(maxWidth: .infinity)
            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMM"
        return f.string(from: day)
    }
}

fileprivate struct MyScheduleTodaysHoursCard: View {
    let policy: OrgPayrollTimePolicy
    let segments: DayHoursSegmentTotals

    var body: some View {
        let ttl = max(0.01, segments.early + segments.mid + segments.late)
        let eF = CGFloat(segments.early / ttl)
        let mF = CGFloat(segments.mid / ttl)
        let lF = CGFloat(segments.late / ttl)
        let ot = segments.otReported
        let paidSum = segments.totalPaidHours
        let paidStd = policy.standardPaidHours
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today's hours")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    Text("Standard \(policy.standardDayStart)–\(policy.standardDayEnd) · \(ScheduleCoverageFormat.hours(paidStd)) hrs")
                        .font(.system(size: 11))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ScheduleCoverageFormat.hours(paidSum))
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                        Text("hrs")
                            .font(.system(size: 11))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                    if ot > 0.05 {
                        Text("+\(ScheduleCoverageFormat.hours(ot)) overtime")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(red: 0.522, green: 0.310, blue: 0.043))
                    }
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let hatchEarly = Color(red: 0.902, green: 0.945, blue: 0.984)
                let hatchLate = Color(red: 0.98, green: 0.933, blue: 0.855)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.949, green: 0.953, blue: 0.961))
                    if eF > 0.02 {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hatchEarly)
                            .frame(width: max(6, w * eF), height: h)
                    }
                    if mF > 0.02 {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(8, w * mF), height: h)
                            .offset(x: w * eF)
                            .overlay(alignment: .leading) {
                                if w * mF > 72 {
                                    Text("\(ScheduleCoverageFormat.hours(segments.mid)) hrs standard")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.leading, 8)
                                }
                            }
                    }
                    if lF > 0.02 {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hatchLate)
                            .frame(width: max(6, w * lF), height: h)
                            .offset(x: w * (eF + mF))
                        if lF * w > 40 {
                            Text(multCaption)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color(red: 0.522, green: 0.310, blue: 0.043))
                                .frame(width: w * lF, alignment: .trailing)
                                .offset(x: w * (eF + mF))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .frame(height: 28)
            HStack {
                ForEach(["6:00", "9:00", "12:00", "15:00", "18:00"], id: \.self) { t in
                    Text(t)
                        .font(.system(size: 9))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .frame(maxWidth: .infinity)
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

    private var multCaption: String {
        let m = policy.weekdayOutsideStandardMultiplier
        let s = abs(m - m.rounded()) < 0.05 ? String(format: "%.0f", m) : String(format: "%.1f", m)
        return "\(s)×"
    }
}

fileprivate struct ManagerCustomHoursSheet: View {
    let context: CustomHoursEditorContext
    let policy: OrgPayrollTimePolicy
    let onSave: (String, String, Bool) -> Void
    let onCancel: () -> Void

    @State private var startText: String
    @State private var endText: String
    @State private var breakRemoved = false
    @State private var errorMessage: String?

    init(context: CustomHoursEditorContext, policy: OrgPayrollTimePolicy, onSave: @escaping (String, String, Bool) -> Void, onCancel: @escaping () -> Void) {
        self.context = context
        self.policy = policy
        self.onSave = onSave
        self.onCancel = onCancel
        let seedS = context.seedStart?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let seedE = context.seedEnd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _startText = State(initialValue: seedS.isEmpty ? policy.standardDayStart : seedS)
        _endText = State(initialValue: seedE.isEmpty ? policy.standardDayEnd : seedE)
        _breakRemoved = State(initialValue: context.seedBreakRemoved ?? false)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Start (HH:mm)", text: $startText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("End (HH:mm)", text: $endText)
                        .keyboardType(.numbersAndPunctuation)
                    Toggle("No break (on this booking)", isOn: $breakRemoved)
                } footer: {
                    Text("Uses your organisation standard day (\(policy.standardDayStart)–\(policy.standardDayEnd)) as the default. Touching times (e.g. one job ends when the next starts) are allowed.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Custom hours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { validateAndSave() }
                }
            }
        }
    }

    private func validateAndSave() {
        errorMessage = nil
        let s = startText.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = endText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sm = ManagerScheduleInterval.parseMinutes(s),
              let em = ManagerScheduleInterval.parseMinutes(e),
              em > sm else {
            errorMessage = "Enter valid times (HH:mm) with end after start."
            return
        }
        onSave(s, e, breakRemoved)
    }
}

struct MyScheduleView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var holidayStore: HolidayStore

    private var isOperativeMode: Bool { userStore.isOperativeMode() }
    /// Office / site attendance booking is only for organisation admins and managers — not operatives or basic users.
    private var canBookManagerSiteAttendance: Bool {
        if isOperativeMode { return false }
        guard let u = userStore.displayUser else { return false }
        return userStore.hasAdminAccess() || u.permissions.manager
    }

    var body: some View {
        NavigationStack {
            Group {
                if isOperativeMode {
                    OperativeScheduleContentView()
                        .environmentObject(bookingStore)
                        .environmentObject(projectStore)
                        .environmentObject(operativeStore)
                        .environmentObject(userStore)
                        .environmentObject(holidayStore)
                        .environmentObject(managerScheduleStore)
                        .environmentObject(firebaseBackend)
                } else if canBookManagerSiteAttendance {
                    ManagerScheduleContentView()
                        .environmentObject(firebaseBackend)
                        .environmentObject(managerScheduleStore)
                        .environmentObject(projectStore)
                        .environmentObject(bookingStore)
                        .environmentObject(operativeStore)
                        .environmentObject(userStore)
                        .environmentObject(holidayStore)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.fill")
                            .font(.largeTitle)
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                        Text("Office and site attendance booking is only available to administrators and managers.")
                            .font(.system(size: 15, weight: .regular))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .padding(.horizontal)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .appChromeCardContainer()
                    .padding(.horizontal, 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationTitle("My Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .appChromeNavigationBarSurface()
        }
        .onAppear {
            managerScheduleStore.loadData()
        }
    }
}

// MARK: - Manager / Admin: book into site or office (AM, PM, Full Day)

struct ManagerScheduleContentView: View {
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var appSettings: AppSettingsStore

    private let calendar = Calendar.current
    @State private var weekStart: Date = Date()
    @State private var selectedDate: Date?
    /// Expanded "Book yourself in" item: true = Office, non-nil UUID = that project/small work (only one expanded at a time).
    @State private var expandedStandardLocation: ManagerLocationType?
    @State private var expandedLocationId: UUID?
    @State private var clashWarning: String?
    @State private var clashWarningFading = false
    @State private var clashWarningWorkItem: DispatchWorkItem?
    @State private var isMultiDaySelectionEnabled = false
    @State private var selectedDates: Set<Date> = []
    @State private var expandedCustomLocationName: String?
    @State private var customHoursContext: CustomHoursEditorContext?
    @State private var secondBookingDialog: SecondBookingDialog?

    private var weekDates: [Date] {
        guard let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var liveProjects: [Project] {
        projectStore.projects.filter { $0.isLive && $0.jobType != .smallWorks }
    }

    private var liveSmallWorks: [Project] {
        projectStore.projects.filter { $0.isLive && $0.jobType == .smallWorks }
    }

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }

    /// Standard day button requires a parseable org window.
    private var canBookStandardDayWindow: Bool {
        let p = payrollTimePolicy
        guard let s = ManagerScheduleInterval.parseMinutes(p.standardDayStart),
              let e = ManagerScheduleInterval.parseMinutes(p.standardDayEnd) else { return false }
        return e > s
    }

    /// Some admins/managers also have an operative profile and can be booked onto projects/small works.
    private func myOperativeBookings(on day: Date) -> [Booking] {
        guard let email = userStore.currentUser.map({ $0.email.lowercased() }),
              let op = operativeStore.allOperatives.first(where: { $0.email.lowercased() == email }) else { return [] }
        return bookingStore.bookings.filter {
            $0.operativeId == op.id &&
            ($0.status == .confirmed || $0.status == .tentative) &&
            calendar.isDate($0.date, inSameDayAs: day)
        }
    }

    private func myHolidayBookings(on day: Date) -> [HolidayBooking] {
        guard let uid = firebaseBackend.currentUser?.uid else { return [] }
        let targetDay = calendar.startOfDay(for: day)
        return holidayStore.myBookings(userId: uid, operativeId: nil)
            .filter { $0.status != .rejected }
            .filter { booking in
                let start = calendar.startOfDay(for: booking.startDate)
                let end = calendar.startOfDay(for: booking.endDate)
                return targetDay >= start && targetDay <= end
            }
            .sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                weekSelector
                dayStrip
                Rectangle()
                    .fill(ProjectWorksRevampColors.border)
                    .frame(height: 0.5)
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                if let day = selectedDate ?? weekDates.first {
                    dayContent(for: day)
                }
            }
            if clashWarning != nil {
                clashWarningTile
                    .opacity(clashWarningFading ? 0 : 1)
                    .animation(.easeOut(duration: 0.4), value: clashWarningFading)
            }
        }
        .sheet(item: $customHoursContext) { ctx in
            ManagerCustomHoursSheet(
                context: ctx,
                policy: payrollTimePolicy,
                onSave: { start, end, breakRemoved in
                    let captured = ctx
                    customHoursContext = nil
                    let daysToBook = captured.days.map { calendar.startOfDay(for: $0) }.sorted()
                    runBookingFlow(
                        days: daysToBook,
                        timeSlot: .customHours,
                        workStart: start,
                        workEnd: end,
                        breakRemoved: breakRemoved,
                        locationType: captured.locationType,
                        locationId: captured.locationId,
                        customLocationName: captured.customLocationName,
                        replaceBookingId: captured.replaceBookingId
                    )
                },
                onCancel: { customHoursContext = nil }
            )
        }
        .confirmationDialog(
            secondBookingDialog?.title ?? "",
            isPresented: Binding(
                get: { secondBookingDialog != nil },
                set: { if !$0 { secondBookingDialog = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Add booking") {
                let run = secondBookingDialog?.onConfirm
                secondBookingDialog = nil
                run?()
            }
            Button("Cancel", role: .cancel) {
                secondBookingDialog = nil
            }
        } message: {
            if let m = secondBookingDialog?.message {
                Text(m)
            }
        }
    }

    private var clashWarningTile: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                .font(.body)
            Text("Warning — time overlap")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Spacer(minLength: 8)
            Button {
                clearClashWarning()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ProjectWorksRevampColors.upcomingAmber.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private func clearClashWarning() {
        clashWarningWorkItem?.cancel()
        clashWarningWorkItem = nil
        withAnimation(.easeOut(duration: 0.4)) {
            clashWarningFading = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            clashWarning = nil
            clashWarningFading = false
        }
    }

    private func showClashWarning() {
        clashWarningWorkItem?.cancel()
        clashWarningFading = false
        clashWarning = "shown"
        let work = DispatchWorkItem { [self] in
            clearClashWarning()
        }
        clashWarningWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func bookingProbe(
        userId: String,
        day: Date,
        timeSlot: ManagerTimeSlot,
        workStart: String?,
        workEnd: String?,
        breakRemoved: Bool,
        locationType: ManagerLocationType,
        locationId: UUID?,
        customLocationName: String?
    ) -> ManagerSiteBooking {
        ManagerSiteBooking(
            userId: userId,
            date: calendar.startOfDay(for: day),
            timeSlot: timeSlot,
            locationType: locationType,
            locationId: locationId,
            customLocationName: customLocationName,
            workStartTime: workStart,
            workEndTime: workEnd,
            isBreakRemoved: breakRemoved
        )
    }

    private func wouldClashProbe(on date: Date, probe: ManagerSiteBooking, ignoringBookingId: UUID? = nil) -> Bool {
        let policy = payrollTimePolicy
        let existing = managerScheduleStore.myBookings(on: date).filter { $0.id != ignoringBookingId }
        return existing.contains { ManagerScheduleInterval.bookingsOverlap(probe, $0, policy: policy) }
    }

    private func isDuplicateBooking(
        on day: Date,
        timeSlot: ManagerTimeSlot,
        workStart: String?,
        workEnd: String?,
        breakRemoved: Bool,
        locationType: ManagerLocationType,
        locationId: UUID?,
        customLocationName: String?,
        ignoringBookingId: UUID? = nil
    ) -> Bool {
        managerScheduleStore.myBookings(on: day)
            .filter { $0.id != ignoringBookingId }
            .contains { existing in
                existing.timeSlot == timeSlot &&
                    existing.locationType == locationType &&
                    existing.locationId == locationId &&
                    (existing.customLocationName ?? "") == (customLocationName ?? "") &&
                    existing.workStartTime == workStart &&
                    existing.workEndTime == workEnd &&
                    existing.isBreakRemoved == breakRemoved
            }
    }

    private func locationNameString(for b: ManagerSiteBooking) -> String {
        if b.locationType == .office || b.locationType == .workingFromHome || b.locationType == .siteSurvey {
            return b.locationType.displayName
        }
        if b.locationType == .custom {
            let n = b.customLocationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return n.isEmpty ? "Custom" : n
        }
        if let id = b.locationId,
           let p = projectStore.projects.first(where: { $0.id == id }) ?? projectStore.smallWorks.first(where: { $0.id == id }) {
            return "\(p.jobNumber) \(p.siteName)"
        }
        return "Site"
    }

    private func newBookingSummaryLabel(timeSlot: ManagerTimeSlot, workStart: String?, workEnd: String?, breakRemoved: Bool) -> String {
        let probe = bookingProbe(
            userId: "",
            day: Date(),
            timeSlot: timeSlot,
            workStart: workStart,
            workEnd: workEnd,
            breakRemoved: breakRemoved,
            locationType: .office,
            locationId: nil,
            customLocationName: nil
        )
        return probe.scheduleLabel(policy: payrollTimePolicy)
    }

    private func secondBookingMessage(existing: [ManagerSiteBooking], newLabel: String) -> String {
        let policy = payrollTimePolicy
        let lines = existing.map { "• \($0.scheduleLabel(policy: policy)) — \(locationNameString(for: $0))" }.joined(separator: "\n")
        return "You already have:\n\(lines)\n\nAdd: \(newLabel)?"
    }

    private func runBookingFlow(
        days: [Date],
        timeSlot: ManagerTimeSlot,
        workStart: String?,
        workEnd: String?,
        breakRemoved: Bool,
        locationType: ManagerLocationType,
        locationId: UUID?,
        customLocationName: String?,
        replaceBookingId: UUID? = nil
    ) {
        guard let uid = firebaseBackend.currentUser?.uid else { return }
        let normalizedDays = days.map { calendar.startOfDay(for: $0) }
        for day in normalizedDays {
            if isDuplicateBooking(
                on: day,
                timeSlot: timeSlot,
                workStart: workStart,
                workEnd: workEnd,
                breakRemoved: breakRemoved,
                locationType: locationType,
                locationId: locationId,
                customLocationName: customLocationName,
                ignoringBookingId: replaceBookingId
            ) {
                showClashWarning()
                return
            }
            let probe = bookingProbe(
                userId: uid,
                day: day,
                timeSlot: timeSlot,
                workStart: workStart,
                workEnd: workEnd,
                breakRemoved: breakRemoved,
                locationType: locationType,
                locationId: locationId,
                customLocationName: customLocationName
            )
            if wouldClashProbe(on: day, probe: probe, ignoringBookingId: replaceBookingId) {
                showClashWarning()
                return
            }
        }

        let commit: () -> Void = {
            Task { @MainActor in
                if let rid = replaceBookingId,
                   let existing = self.managerScheduleStore.managerSiteBookings.first(where: { $0.id == rid }) {
                    await self.managerScheduleStore.deleteBooking(existing)
                }
                for day in normalizedDays {
                    self.saveBooking(
                        date: day,
                        timeSlot: timeSlot,
                        locationType: locationType,
                        locationId: locationId,
                        customLocationName: customLocationName,
                        workStartTime: workStart,
                        workEndTime: workEnd,
                        isBreakRemoved: breakRemoved
                    )
                }
            }
        }

        if normalizedDays.count == 1, let only = normalizedDays.first {
            let existing = managerScheduleStore.myBookings(on: only).filter { $0.id != replaceBookingId }
            if !existing.isEmpty {
                let newLabel = newBookingSummaryLabel(
                    timeSlot: timeSlot,
                    workStart: workStart,
                    workEnd: workEnd,
                    breakRemoved: breakRemoved
                )
                secondBookingDialog = SecondBookingDialog(
                    title: "Another booking this day",
                    message: secondBookingMessage(existing: existing, newLabel: newLabel),
                    onConfirm: commit
                )
                return
            }
        }
        commit()
    }

    private var weekSelector: some View {
        HStack {
            Button(action: { moveWeek(by: -1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            if isMultiDaySelectionEnabled {
                Button("Clear") {
                    selectedDates = []
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.bordered)
            }
            Spacer()
            Text(weekRangeText)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Spacer()
            Button(isMultiDaySelectionEnabled ? "Multiday Select: On" : "Multiday Select") {
                isMultiDaySelectionEnabled.toggle()
                if isMultiDaySelectionEnabled {
                    if let day = selectedDate ?? weekDates.first {
                        selectedDates = [calendar.startOfDay(for: day)]
                    }
                } else {
                    selectedDates = []
                }
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.bordered)
            Button(action: { moveWeek(by: 1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .appChromeCardContainer()
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var weekRangeText: String {
        guard let start = weekDates.first, let end = weekDates.last else { return "" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    private func moveWeek(by delta: Int) {
        if let newStart = calendar.date(byAdding: .weekOfYear, value: delta, to: weekStart) {
            weekStart = newStart
            if let first = weekDates.first {
                selectedDate = first
            }
        }
    }

    private func shiftSelectedDay(by delta: Int) {
        let base = selectedDate ?? weekDates.first ?? Date()
        let sod = calendar.startOfDay(for: base)
        guard let newDay = calendar.date(byAdding: .day, value: delta, to: sod) else { return }
        selectedDate = newDay
        if let ws = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: newDay)) {
            weekStart = ws
        }
    }

    private func beginEditManagerBooking(_ b: ManagerSiteBooking) {
        let day = calendar.startOfDay(for: b.date)
        let p = payrollTimePolicy
        let ws: String
        let we: String
        if let s = b.workStartTime, let e = b.workEndTime, !s.isEmpty, !e.isEmpty {
            ws = s
            we = e
        } else {
            let block = b.calendarBlock(on: b.date, policy: p)
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            ws = f.string(from: block.start)
            we = f.string(from: block.end)
        }
        customHoursContext = CustomHoursEditorContext(
            days: [day],
            locationType: b.locationType,
            locationId: b.locationId,
            customLocationName: b.customLocationName,
            replaceBookingId: b.id,
            seedStart: ws,
            seedEnd: we,
            seedBreakRemoved: b.isBreakRemoved
        )
    }

    private var dayStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(weekDates, id: \.self) { date in
                        dayButton(date: date)
                    }
                }
                .padding(.horizontal, 16)
            }
            if let selected = selectedDate {
                HStack {
                    Text("Selected: \(fullDateLabel(selected))")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 10)
    }

    private func dayButton(date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate ?? .distantPast)
        let isMultiSelected = selectedDates.contains(calendar.startOfDay(for: date))
        let hasBooking = !managerScheduleStore.myBookings(on: date).isEmpty
        return Button(action: { selectedDate = date }) {
            VStack(spacing: 4) {
                Text(dayLabel(date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : ProjectWorksRevampColors.muted)
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 22, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.white : ProjectWorksRevampColors.ink)
                if hasBooking {
                    Circle()
                        .fill(isSelected ? Color.white : ProjectWorksRevampColors.blue)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 48, height: 64)
            .background(isSelected ? ProjectWorksRevampColors.blue : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? ProjectWorksRevampColors.blue : (isMultiSelected ? ProjectWorksRevampColors.jobTypePillInk : ProjectWorksRevampColors.border),
                        lineWidth: isSelected ? 2 : (isMultiSelected ? 2 : 0.5)
                    )
            )
            .shadow(color: isSelected ? ProjectWorksRevampColors.blue.opacity(0.28) : .clear, radius: 4, x: 0, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(TapGesture().onEnded {
            guard isMultiDaySelectionEnabled else { return }
            let key = calendar.startOfDay(for: date)
            if selectedDates.contains(key) {
                selectedDates.remove(key)
            } else {
                selectedDates.insert(key)
            }
        })
    }

    private func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }
    
    private func fullDateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f.string(from: date)
    }

    private func expandBookYourselfForAddBooking() {
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedLocationId = nil
            if appSettings.settings.myScheduleOptions.showOffice {
                expandedCustomLocationName = nil
                expandedStandardLocation = .office
            } else if appSettings.settings.myScheduleOptions.showWorkingFromHome {
                expandedCustomLocationName = nil
                expandedStandardLocation = .workingFromHome
            } else if appSettings.settings.myScheduleOptions.showSiteSurvey {
                expandedCustomLocationName = nil
                expandedStandardLocation = .siteSurvey
            } else if let first = appSettings.settings.myScheduleOptions.customItems.first {
                expandedStandardLocation = nil
                expandedCustomLocationName = first
            } else {
                expandedCustomLocationName = nil
                expandedStandardLocation = .office
            }
        }
    }

    private func dashedAddBookingButton(scrollToBookYourself: @escaping () -> Void) -> some View {
        Button {
            expandBookYourselfForAddBooking()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                scrollToBookYourself()
            }
        } label: {
            Text("+ Add booking")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        .foregroundStyle(ProjectWorksRevampColors.border)
                )
        }
        .buttonStyle(.plain)
    }

    private func dayContent(for day: Date) -> some View {
        let policy = payrollTimePolicy
        let bookings = managerScheduleStore.myBookings(on: day)
        let operativeBookings = myOperativeBookings(on: day)
        let holidayBookings = myHolidayBookings(on: day)
        let isExpandedOffice = expandedStandardLocation == .office
        let isExpandedWorkingFromHome = expandedStandardLocation == .workingFromHome
        let isExpandedSiteSurvey = expandedStandardLocation == .siteSurvey
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MyScheduleDayNavigatorCard(
                        day: day,
                        onPrev: { shiftSelectedDay(by: -1) },
                        onNext: { shiftSelectedDay(by: 1) }
                    )
                    MyScheduleTodaysHoursCard(
                        policy: policy,
                        segments: mergedDaySegments(manager: bookings, operative: operativeBookings, policy: policy)
                    )

                if !holidayBookings.isEmpty {
                    Section {
                        ForEach(holidayBookings) { holiday in
                            HStack {
                                Label("Holiday", systemImage: "sun.max.fill")
                                    .font(.subheadline)
                                    .foregroundColor(.orange)
                                Spacer()
                                Text(holiday.status == .pending ? "Pending" : "Approved")
                                    .font(.caption)
                                    .foregroundColor(holiday.status == .pending ? .orange : .green)
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Your holiday")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                    }
                }

                Section {
                    if bookings.isEmpty {
                        Text("No bookings for this day.")
                            .font(.system(size: 15))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(bookings) { b in
                            bookingRow(b: b)
                        }
                    }
                    dashedAddBookingButton {
                        proxy.scrollTo("book-yourself-anchor", anchor: .top)
                    }
                    .padding(.top, 4)
                } header: {
                    Text("Bookings")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .textCase(.uppercase)
                        .tracking(0.4)
                }

                if !operativeBookings.isEmpty {
                    Section {
                        ForEach(operativeBookings) { b in
                            let p = projectStore.projects.first(where: { $0.id == b.projectId }) ??
                                projectStore.smallWorks.first(where: { $0.id == b.projectId })
                            MyScheduleBookingStripeRow(
                                stripeColor: ProjectWorksRevampColors.activeGreen,
                                title: p.map { "\($0.jobNumber) \($0.siteName)" } ?? "Project booking",
                                subtitle: operativeBookingClockSubtitle(b, day: day, policy: policy),
                                otChip: operativeBookingOtChipText(b, policy: policy),
                                showActions: false
                            )
                        }
                    } header: {
                        Text("Project / small works")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .textCase(.uppercase)
                            .tracking(0.4)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Book yourself in")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .id("book-yourself-anchor")
                        if appSettings.settings.myScheduleOptions.showOffice {
                            standardLocationRow(
                                title: "Office",
                                type: .office,
                                isExpanded: isExpandedOffice,
                                day: day
                            )
                        }
                        if appSettings.settings.myScheduleOptions.showWorkingFromHome {
                            standardLocationRow(
                                title: "Working From Home",
                                type: .workingFromHome,
                                isExpanded: isExpandedWorkingFromHome,
                                day: day
                            )
                        }
                        if appSettings.settings.myScheduleOptions.showSiteSurvey {
                            standardLocationRow(
                                title: "Site Survey",
                                type: .siteSurvey,
                                isExpanded: isExpandedSiteSurvey,
                                day: day
                            )
                        }
                        ForEach(appSettings.settings.myScheduleOptions.customItems, id: \.self) { customItem in
                            standardLocationRow(
                                title: customItem,
                                type: .custom,
                                customName: customItem,
                                isExpanded: expandedCustomLocationName == customItem,
                                day: day
                            )
                        }

                        Text("Projects")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .padding(.top, 8)
                        ForEach(liveProjects, id: \.id) { p in
                            expandableLocationRow(
                                title: "\(p.jobNumber) \(p.siteName)",
                                isExpanded: expandedLocationId == p.id && expandedStandardLocation == nil
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedStandardLocation = nil
                                    expandedCustomLocationName = nil
                                    if expandedLocationId == p.id {
                                        expandedLocationId = nil
                                    } else {
                                        expandedLocationId = p.id
                                    }
                                }
                            }
                            if expandedLocationId == p.id, expandedStandardLocation == nil {
                                slotButtons(day: day, locationType: .project, locationId: p.id)
                            }
                        }

                        Text("Small Works")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .padding(.top, 8)
                        ForEach(liveSmallWorks, id: \.id) { p in
                            expandableLocationRow(
                                title: "\(p.jobNumber) \(p.siteName)",
                                isExpanded: expandedLocationId == p.id && expandedStandardLocation == nil
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedStandardLocation = nil
                                    expandedCustomLocationName = nil
                                    if expandedLocationId == p.id {
                                        expandedLocationId = nil
                                    } else {
                                        expandedLocationId = p.id
                                    }
                                }
                            }
                            if expandedLocationId == p.id, expandedStandardLocation == nil {
                                slotButtons(day: day, locationType: .smallWork, locationId: p.id)
                            }
                        }
                    }
                }
                }
                .padding()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bookingRow(b: ManagerSiteBooking) -> some View {
        let p = payrollTimePolicy
        return MyScheduleBookingStripeRow(
            stripeColor: myScheduleLocationStripeColor(b.locationType),
            title: locationNameString(for: b),
            subtitle: managerBookingClockSubtitle(b, day: b.date, policy: p),
            otChip: managerBookingOtChipText(b, policy: p),
            showActions: true,
            onEdit: { beginEditManagerBooking(b) },
            onDelete: {
                Task { await managerScheduleStore.deleteBooking(b) }
            }
        )
    }

    private func expandableLocationRow(title: String, isExpanded: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .lineLimit(1)
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
    
    private func standardLocationRow(
        title: String,
        type: ManagerLocationType,
        customName: String? = nil,
        isExpanded: Bool,
        day: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedLocationId = nil
                    if type == .custom {
                        expandedStandardLocation = nil
                        if expandedCustomLocationName == customName {
                            expandedCustomLocationName = nil
                        } else {
                            expandedCustomLocationName = customName
                        }
                    } else {
                        expandedCustomLocationName = nil
                        if expandedStandardLocation == type {
                            expandedStandardLocation = nil
                        } else {
                            expandedStandardLocation = type
                        }
                    }
                }
            } label: {
                HStack {
                    Text(title)
                        .font(.system(size: 15))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            if isExpanded {
                slotButtons(day: day, locationType: type, locationId: nil, customLocationName: customName)
            }
        }
    }

    private func slotButtons(day: Date, locationType: ManagerLocationType, locationId: UUID?, customLocationName: String? = nil) -> some View {
        let daysToBook: [Date] = {
            if isMultiDaySelectionEnabled, !selectedDates.isEmpty {
                return selectedDates.map { calendar.startOfDay(for: $0) }.sorted()
            }
            return [calendar.startOfDay(for: day)]
        }()
        let p = payrollTimePolicy
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ForEach([ManagerTimeSlot.fullDay, ManagerTimeSlot.morning, ManagerTimeSlot.afternoon], id: \.self) { slot in
                    Button(slot.displayName) {
                        runBookingFlow(
                            days: daysToBook,
                            timeSlot: slot,
                            workStart: nil,
                            workEnd: nil,
                            breakRemoved: false,
                            locationType: locationType,
                            locationId: locationId,
                            customLocationName: customLocationName
                        )
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(ProjectWorksRevampColors.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            HStack(spacing: 14) {
                Button("Standard day") {
                    runBookingFlow(
                        days: daysToBook,
                        timeSlot: .customHours,
                        workStart: p.standardDayStart,
                        workEnd: p.standardDayEnd,
                        breakRemoved: false,
                        locationType: locationType,
                        locationId: locationId,
                        customLocationName: customLocationName
                    )
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.activeGreen)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(ProjectWorksRevampColors.activeGreen.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(!canBookStandardDayWindow)

                Button("Custom…") {
                    customHoursContext = CustomHoursEditorContext(
                        days: daysToBook,
                        locationType: locationType,
                        locationId: locationId,
                        customLocationName: customLocationName
                    )
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(ProjectWorksRevampColors.upcomingAmber.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.leading, 14)
        .padding(.bottom, 12)
    }

    private func saveBooking(
        date: Date,
        timeSlot: ManagerTimeSlot,
        locationType: ManagerLocationType,
        locationId: UUID?,
        customLocationName: String? = nil,
        workStartTime: String? = nil,
        workEndTime: String? = nil,
        isBreakRemoved: Bool = false
    ) {
        guard let uid = firebaseBackend.currentUser?.uid else { return }
        let b = ManagerSiteBooking(
            userId: uid,
            date: date,
            timeSlot: timeSlot,
            locationType: locationType,
            locationId: locationId,
            customLocationName: customLocationName,
            workStartTime: workStartTime,
            workEndTime: workEndTime,
            isBreakRemoved: isBreakRemoved
        )
        Task {
            await managerScheduleStore.saveBooking(b)
        }
    }
}

// MARK: - Manager booking sheet (confirm or pick location)

struct ManagerBookingSheet: View {
    let date: Date
    let timeSlot: ManagerTimeSlot
    let locationType: ManagerLocationType
    let locationId: UUID?
    let existingBookings: [ManagerSiteBooking]
    let onSave: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @Environment(\.dismiss) private var dismiss

    private var locationTitle: String {
        if locationType == .office || locationType == .workingFromHome || locationType == .siteSurvey {
            return locationType.displayName
        }
        if locationType == .custom {
            return (existingBookings.first?.customLocationName?.isEmpty == false) ? (existingBookings.first?.customLocationName ?? "Custom") : "Custom"
        }
        guard let id = locationId, let p = projectStore.projects.first(where: { $0.id == id }) else { return "Site" }
        return "\(p.jobNumber) \(p.siteName)"
    }

    private var alreadyBooked: Bool {
        existingBookings.contains { $0.timeSlot == timeSlot && $0.locationType == locationType && $0.locationId == locationId }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text(locationTitle)
                    .font(.title2)
                Text("\(date, style: .date) · \(timeSlot.displayName)")
                    .foregroundColor(.secondary)
                if alreadyBooked {
                    Text("You're already booked here for this slot.")
                        .foregroundColor(.secondary)
                    Button("Remove booking", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                } else {
                    Button("Confirm booking") {
                        onSave()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Operative: read-only week, swipe weeks, Add to Calendar

struct OperativeScheduleContentView: View {
    @EnvironmentObject var bookingStore: BookingStore
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var operativeStore: OperativeStore
    @EnvironmentObject var userStore: UserStore
    @EnvironmentObject var holidayStore: HolidayStore
    @EnvironmentObject var managerScheduleStore: ManagerScheduleStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    private let calendar = Calendar.current
    @State private var weekStart: Date = Date()
    @State private var addToCalendarMessage: String?

    private var currentOperative: Operative? {
        guard let email = userStore.currentUser?.email else { return nil }
        return operativeStore.allOperatives.first { $0.email.lowercased() == email.lowercased() }
    }

    private var weekDates: [Date] {
        guard let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var myBookingsThisWeek: [Booking] {
        guard let op = currentOperative else { return [] }
        return bookingStore.bookings.filter { b in
            b.operativeId == op.id &&
            (b.status == .confirmed || b.status == .tentative) &&
            weekDates.contains { calendar.isDate(b.date, inSameDayAs: $0) }
        }
    }

    /// Office / site self-bookings from when this account was a manager or admin (same Firebase Auth uid).
    private var myManagerAttendanceThisWeek: [ManagerSiteBooking] {
        guard let uid = userStore.currentUser?.id else { return [] }
        return managerScheduleStore.managerSiteBookings.filter { booking in
            booking.userId == uid &&
            weekDates.contains { calendar.isDate(booking.date, inSameDayAs: $0) }
        }
    }

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }

    private func managerSelfBookingTitle(_ b: ManagerSiteBooking) -> String {
        if b.locationType == .office || b.locationType == .workingFromHome || b.locationType == .siteSurvey {
            return b.locationType.displayName
        }
        if b.locationType == .custom {
            return (b.customLocationName?.isEmpty == false) ? (b.customLocationName ?? "Custom") : "Custom"
        }
        if let id = b.locationId,
           let p = projectStore.projects.first(where: { $0.id == id }) ?? projectStore.smallWorks.first(where: { $0.id == id }) {
            return "\(p.jobNumber) \(p.siteName)"
        }
        return "Site"
    }

    private var myApprovedHolidays: [HolidayBooking] {
        guard let userId = userStore.currentUser?.id else { return [] }
        let operativeId = currentOperative?.id
        return holidayStore.myBookings(userId: userId, operativeId: operativeId)
            .filter { $0.status == .approved }
    }

    private func holidayCoversDay(_ date: Date) -> Bool {
        let day = calendar.startOfDay(for: date)
        return myApprovedHolidays.contains { holiday in
            let start = calendar.startOfDay(for: holiday.startDate)
            let end = calendar.startOfDay(for: holiday.endDate)
            return day >= start && day <= end
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            weekNavigation
            weekContent
            addToCalendarButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .alert("Calendar", isPresented: .constant(addToCalendarMessage != nil)) {
            Button("OK") { addToCalendarMessage = nil }
        } message: {
            if let msg = addToCalendarMessage { Text(msg) }
        }
        .onAppear {
            managerScheduleStore.loadData()
        }
    }

    private var weekNavigation: some View {
        HStack {
            Button(action: { moveWeek(-1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(weekRangeText)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            Spacer()
            Button(action: { moveWeek(1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .appChromeCardContainer()
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var weekRangeText: String {
        guard let start = weekDates.first, let end = weekDates.last else { return "" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    private func moveWeek(_ delta: Int) {
        if let newStart = calendar.date(byAdding: .weekOfYear, value: delta, to: weekStart) {
            weekStart = newStart
        }
    }

    private var weekContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(weekDates, id: \.self) { date in
                    dayRow(date: date)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func dayRow(date: Date) -> some View {
        let policy = payrollTimePolicy
        let dayBookings = myBookingsThisWeek.filter { calendar.isDate($0.date, inSameDayAs: date) }
        let dayManagerBookings = myManagerAttendanceThisWeek.filter { calendar.isDate($0.date, inSameDayAs: date) }
        let isOnHoliday = holidayCoversDay(date)
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMM"
        return VStack(alignment: .leading, spacing: 8) {
            Text(f.string(from: date))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            if isOnHoliday {
                Label("Holiday", systemImage: "sun.max.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.endDateFg)
            }
            if dayBookings.isEmpty && dayManagerBookings.isEmpty && !isOnHoliday {
                Text("No bookings")
                    .font(.system(size: 14))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            } else {
                if !dayBookings.isEmpty || !dayManagerBookings.isEmpty {
                    MyScheduleTodaysHoursCard(
                        policy: policy,
                        segments: mergedDaySegments(manager: dayManagerBookings, operative: dayBookings, policy: policy)
                    )
                }
                if !dayManagerBookings.isEmpty {
                    Text("Your attendance")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .tracking(0.35)
                        .textCase(.uppercase)
                        .padding(.top, 4)
                }
                ForEach(dayManagerBookings) { b in
                    let title = managerSelfBookingTitle(b)
                    MyScheduleBookingStripeRow(
                        stripeColor: myScheduleLocationStripeColor(b.locationType),
                        title: title,
                        subtitle: managerBookingClockSubtitle(b, day: date, policy: policy),
                        otChip: managerBookingOtChipText(b, policy: policy),
                        showActions: false
                    )
                }
                if !dayBookings.isEmpty {
                    if !dayManagerBookings.isEmpty {
                        Text("On-site bookings")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .tracking(0.35)
                            .textCase(.uppercase)
                            .padding(.top, 6)
                    }
                    ForEach(dayBookings) { b in
                        if let project = projectStore.projects.first(where: { $0.id == b.projectId }) ??
                            projectStore.smallWorks.first(where: { $0.id == b.projectId }) {
                            let title = "\(project.jobNumber) \(project.siteName)"
                            MyScheduleBookingStripeRow(
                                stripeColor: ProjectWorksRevampColors.activeGreen,
                                title: title,
                                subtitle: operativeBookingClockSubtitle(b, day: date, policy: policy),
                                otChip: operativeBookingOtChipText(b, policy: policy),
                                showActions: false
                            )
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appChromeCardContainer()
    }

    private var addToCalendarButton: some View {
        Button(action: addCurrentWeekToCalendar) {
            Label("Add this week to Calendar", systemImage: "calendar.badge.plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(ProjectWorksRevampColors.blue)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func addCurrentWeekToCalendar() {
        let eventStore = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .denied {
            addToCalendarMessage = "Calendar access was denied. You can enable it in Settings."
            return
        }
        if status == .notDetermined {
            if #available(iOS 17.0, *) {
                Task {
                    let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
                    await MainActor.run {
                        if granted {
                            performAddToCalendar(eventStore: eventStore)
                        } else {
                            addToCalendarMessage = "Calendar access is needed to add events. Enable it in Settings."
                        }
                    }
                }
            } else {
                eventStore.requestAccess(to: .event) { [self] granted, _ in
                    DispatchQueue.main.async {
                        if granted {
                            performAddToCalendar(eventStore: eventStore)
                        } else {
                            addToCalendarMessage = "Calendar access is needed to add events. Enable it in Settings."
                        }
                    }
                }
            }
            return
        }
        performAddToCalendar(eventStore: eventStore)
    }

    private func performAddToCalendar(eventStore: EKEventStore) {
        guard currentOperative != nil else {
            addToCalendarMessage = "Could not find your operative profile."
            return
        }
        guard !weekDates.isEmpty else { return }
        var added = 0
        for b in myBookingsThisWeek {
            guard let project = projectStore.projects.first(where: { $0.id == b.projectId }) else { continue }
            let event = EKEvent(eventStore: eventStore)
            event.title = "\(project.jobNumber) \(project.siteName) – \(b.scheduleLabel(policy: payrollTimePolicy))"
            let block = b.calendarBlock(on: b.date, policy: payrollTimePolicy)
            event.startDate = block.start
            event.endDate = block.end
            event.calendar = eventStore.defaultCalendarForNewEvents
            do {
                try eventStore.save(event, span: .thisEvent)
                added += 1
            } catch {
                addToCalendarMessage = "Could not add some events: \(error.localizedDescription)"
                return
            }
        }
        for b in myManagerAttendanceThisWeek {
            let event = EKEvent(eventStore: eventStore)
            event.title = "\(managerSelfBookingTitle(b)) – \(b.scheduleLabel(policy: payrollTimePolicy))"
            let block = b.calendarBlock(on: b.date, policy: payrollTimePolicy)
            event.startDate = block.start
            event.endDate = block.end
            event.calendar = eventStore.defaultCalendarForNewEvents
            do {
                try eventStore.save(event, span: .thisEvent)
                added += 1
            } catch {
                addToCalendarMessage = "Could not add some events: \(error.localizedDescription)"
                return
            }
        }
        addToCalendarMessage = added > 0 ? "Added \(added) event(s) to your calendar." : "No bookings this week to add."
    }
}

