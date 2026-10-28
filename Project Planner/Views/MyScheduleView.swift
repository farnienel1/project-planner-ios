//
//  MyScheduleView.swift
//  Project Planner
//
//  Admins/Managers: book themselves into a site (project/small work) or office – AM, PM, Full Day.
//  Operatives: view their week-only schedule and "Add to Calendar".
//

import SwiftUI
import FirebaseAuth

// MARK: - Manager schedule booking helpers (fileprivate)

fileprivate struct SecondBookingDialog: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let onConfirm: () -> Void
}

fileprivate struct PendingScheduleOverlapResolution: Identifiable {
    let id = UUID()
    let message: String
    let detailLines: [String]
    let onContinue: () -> Void
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

fileprivate func segmentHoursForManager(_ b: ManagerSiteBooking, day: Date, policy: OrgPayrollTimePolicy) -> (early: Double, mid: Double, late: Double) {
    guard let iv = ManagerScheduleInterval.clashInterval(for: b, policy: policy) else {
        return (0, b.totalBookedHours(policy: policy), 0)
    }
    let sm = iv.0, em = iv.1
    let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: day, policy: policy)
    guard let ds = timeline.standardWindowStartMinutes,
          let de = timeline.standardWindowEndMinutes, de > ds else {
        return (0, Double(em - sm) / 60.0, 0)
    }
    let earlyM = max(0, min(em, ds) - sm)
    let lateM = max(0, em - max(sm, de))
    let midM = max(0, min(em, de) - max(sm, ds))
    return (Double(earlyM) / 60.0, Double(midM) / 60.0, Double(lateM) / 60.0)
}

fileprivate func segmentHoursForOperative(_ b: Booking, day: Date, policy: OrgPayrollTimePolicy) -> (early: Double, mid: Double, late: Double) {
    guard let iv = OperativeBookingInterval.clashInterval(for: b, policy: policy) else {
        return (0, b.totalBookedHours(policy: policy), 0)
    }
    let sm = iv.0, em = iv.1
    let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: day, policy: policy)
    guard let ds = timeline.standardWindowStartMinutes,
          let de = timeline.standardWindowEndMinutes, de > ds else {
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
    day: Date,
    policy: OrgPayrollTimePolicy
) -> DayHoursSegmentTotals {
    var early: Double = 0, mid: Double = 0, late: Double = 0, ot: Double = 0, paidSum: Double = 0
    for b in manager {
        let s = segmentHoursForManager(b, day: day, policy: policy)
        early += s.early
        mid += s.mid
        late += s.late
        paidSum += b.paidBookedHours(policy: policy)
        ot += b.overtimeHoursBeyondPaidStandard(policy: policy)
    }
    for b in operative {
        let s = segmentHoursForOperative(b, day: day, policy: policy)
        early += s.early
        mid += s.mid
        late += s.late
        paidSum += b.paidBookedHours(policy: policy)
        ot += b.overtimeHoursBeyondPaidStandard(policy: policy)
    }
    return DayHoursSegmentTotals(totalPaidHours: paidSum, early: early, mid: mid, late: late, otReported: ot)
}

/// Icon tile colour family per location type (Midnight design). Display only.
fileprivate func myScheduleLocationFamily(_ t: ManagerLocationType) -> PPFamily {
    switch t {
    case .office: return .plan
    case .workingFromHome: return .people
    case .siteSurvey: return .trade
    case .project, .smallWork: return .sites
    case .custom: return .system
    }
}

/// Icon tile symbol per location type (Midnight design). Display only.
fileprivate func myScheduleLocationSymbol(_ t: ManagerLocationType) -> String {
    switch t {
    case .office: return "building.2.fill"
    case .workingFromHome: return "house.fill"
    case .siteSurvey: return "mappin.and.ellipse"
    case .project: return "hammer.fill"
    case .smallWork: return "wrench.and.screwdriver.fill"
    case .custom: return "mappin"
    }
}

/// Small amber pill (OT, Annual Leave) that reads in light and dark mode.
fileprivate struct MyScheduleAmberPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(PPFamily.trade.bottom)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(PPFamily.trade.top.opacity(0.16), in: Capsule())
    }
}

/// Small uppercase caption used above groups of rows on the light sheet.
fileprivate struct MyScheduleCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}

/// Rounded card surface on the light sheet (same look as the Daily overview cards).
fileprivate extension View {
    func myScheduleCard(cornerRadius: CGFloat = PPMetrics.cardRadius) -> some View {
        background(PPColor.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

fileprivate func managerBookingOtChipText(_ b: ManagerSiteBooking, policy: OrgPayrollTimePolicy) -> String? {
    let ot = b.overtimeHoursBeyondPaidStandard(policy: policy)
    guard ot > 0.05 else { return nil }
    let m = PayrollTimePolicyCatalog.effectiveMultiplier(for: b, policy: policy)
    return "OT \(ScheduleCoverageFormat.overtimeEquation(rawHours: ot, multiplier: m))"
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
    return "OT \(ScheduleCoverageFormat.overtimeEquation(rawHours: ot, multiplier: m))"
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
    let family: PPFamily
    let symbol: String
    let title: String
    let subtitle: String
    let otChip: String?
    var showActions: Bool = false
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 13) {
                PPIconTile(symbol: symbol, family: family, size: PPMetrics.menuIcon)
                Button {
                    onEdit?()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle)
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onEdit == nil)
                .accessibilityIdentifier("myScheduleBookingStripe.open")
                if let otChip {
                    MyScheduleAmberPill(text: otChip)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if showActions, onEdit != nil || onDelete != nil {
                Rectangle()
                    .fill(Color(.separator))
                    .frame(height: 0.5)
                    .padding(.leading, 14 + PPMetrics.menuIcon + 13)
                    .accessibilityHidden(true)
                HStack(spacing: 16) {
                    if let onEdit {
                        Button(action: onEdit) {
                            Text("Edit")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PPColor.brand)
                        }
                        .accessibilityIdentifier("myScheduleBookingStripe.edit")
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    if let onDelete {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("myScheduleBookingStripe.delete")
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 14 + PPMetrics.menuIcon + 13)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
            }
        }
        .myScheduleCard(cornerRadius: PPMetrics.rowCardRadius)
    }
}

fileprivate struct MyScheduleDayNavigatorCard: View {
    let day: Date
    let onPrev: () -> Void
    let onNext: () -> Void
    let onSelectDay: () -> Void
    private let cal = Calendar.current

    /// Sits on the navy header (Daily overview style): round ‹ › buttons either side of a big date.
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onPrev) {
                Image(systemName: "chevron.left")
            }
            .accessibilityIdentifier("myScheduleDayNavigatorCard.back")
            .buttonStyle(PPOnNavyCircleButtonStyle())
            Button(action: onSelectDay) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cal.isDateInToday(day) ? "Today · Tap to pick a day" : "Tap to pick a day")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.onNavySecondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(dayTitle)
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
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("myScheduleDayNavigatorCard.todayTapToPickADay")
            .buttonStyle(PPPressableButtonStyle())
            Button(action: onNext) {
                Image(systemName: "chevron.right")
            }
            .accessibilityIdentifier("myScheduleDayNavigatorCard.chevronRight")
            .buttonStyle(PPOnNavyCircleButtonStyle())
        }
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMM"
        return f.string(from: day)
    }
}

fileprivate struct MyScheduleTodaysHoursCard: View {
    let day: Date
    let policy: OrgPayrollTimePolicy
    let segments: DayHoursSegmentTotals
    let workIntervals: [ScheduleWorkInterval]
    var annualLeaveLabel: String? = nil
    var annualLeaveTimeSlot: HolidayTimeSlot? = nil

    private var timeline: PayrollTimePolicyCatalog.DayTimelinePolicy {
        PayrollTimePolicyCatalog.timelinePolicy(for: day, policy: policy)
    }

    private static let leaveGradient = LinearGradient(
        colors: [Color(red: 0.60, green: 0.24, blue: 0.11), Color(red: 0.78, green: 0.40, blue: 0.27)],
        startPoint: .leading,
        endPoint: .trailing
    )

    private var hourTicks: some View {
        HStack {
            ForEach(["6:00", "9:00", "12:00", "15:00", "18:00"], id: \.self) { t in
                Text(t)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    var body: some View {
        if let annualLeaveLabel, !annualLeaveLabel.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 13) {
                    PPIconTile(symbol: "sun.max.fill", family: .trade, size: PPMetrics.menuIcon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Total hours")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Standard \(timeline.standardWindowStart ?? policy.standardDayStart)–\(timeline.standardWindowEnd ?? policy.standardDayEnd)")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    MyScheduleAmberPill(text: "Annual Leave")
                }
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(PPColor.well)
                        switch annualLeaveTimeSlot ?? .fullDay {
                        case .fullDay:
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Self.leaveGradient)
                                .frame(width: w)
                        case .morning:
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Self.leaveGradient)
                                .frame(width: w * 0.5)
                        case .afternoon:
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Self.leaveGradient)
                                .frame(width: w * 0.5)
                                .offset(x: w * 0.5)
                        }
                    }
                    .overlay(alignment: .center) {
                        Text(annualLeaveLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(height: 28)
                hourTicks
            }
            .padding(14)
            .myScheduleCard()
        } else {
            let ot = segments.otReported
            let paidSum = segments.totalPaidHours
            let paidStd = policy.standardPaidHours
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 13) {
                    PPIconTile(symbol: "clock.fill", family: .plan, size: PPMetrics.menuIcon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Total hours")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Standard \(timeline.standardWindowStart ?? policy.standardDayStart)–\(timeline.standardWindowEnd ?? policy.standardDayEnd) · \(ScheduleCoverageFormat.hours(paidStd)) hrs")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(ScheduleCoverageFormat.hours(paidSum))
                                .font(.system(.title2, design: .rounded))
                                .fontWeight(.bold)
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                            Text("hrs")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if ot > 0.05 {
                            Text("+\(ScheduleCoverageFormat.hours(ot)) overtime")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PPFamily.trade.bottom)
                        }
                    }
                }
                ScheduleHoursTimelineBar(
                    day: day,
                    policy: policy,
                    workIntervals: workIntervals,
                    centerLabel: paidSum > 0.05 ? "\(ScheduleCoverageFormat.hours(paidSum))h" : nil
                )
                hourTicks
                if policy.unpaidBreakMinutes > 0, !policy.breakPaid, workIntervals.contains(where: { !$0.breakRemoved }) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(red: 0.98, green: 0.65, blue: 0.15))
                            .frame(width: 14, height: 4)
                        Text("\(policy.unpaidBreakMinutes)-minute unpaid break (\(policy.breakWindowStart)–\(policy.breakWindowEnd))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .myScheduleCard()
        }
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
                        .accessibilityIdentifier("managerCustomHours.startHHMm")
                        .keyboardType(.numbersAndPunctuation)
                    TextField("End (HH:mm)", text: $endText)
                        .accessibilityIdentifier("managerCustomHours.endHHMm")
                        .keyboardType(.numbersAndPunctuation)
                    Toggle("No break (on this booking)", isOn: $breakRemoved)
                        .accessibilityIdentifier("managerCustomHours.noBreakOnThisBooking")
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
                        .accessibilityIdentifier("managerCustomHours.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { validateAndSave() }
                        .accessibilityIdentifier("managerCustomHours.save")
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
                        PPIconTile(symbol: "lock.fill", family: .system, size: PPMetrics.quickActionIcon, lifted: true)
                        Text("Office and site attendance booking is only available to administrators and managers.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .myScheduleCard()
                    .padding(.horizontal, PPMetrics.screenGutter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PPColor.page.ignoresSafeArea())
            .navigationTitle("My Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("mySchedule.done")
                        .fontWeight(.semibold)
                        .tint(.white)
                }
            }
            .ppNavyNavigationBar()
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
    @EnvironmentObject var notificationService: NotificationService

    private let calendar = Calendar.current
    @State private var weekStart: Date = Date()
    @State private var selectedDate: Date?
    /// Expanded "Book yourself in" item: true = Office, non-nil UUID = that project/small work (only one expanded at a time).
    @State private var expandedStandardLocation: ManagerLocationType?
    @State private var expandedLocationId: UUID?
    @State private var pendingOverlapResolution: PendingScheduleOverlapResolution?
    @State private var isMultiDaySelectionEnabled = false
    @State private var selectedDates: Set<Date> = []
    @State private var expandedCustomLocationName: String?
    @State private var customHoursContext: CustomHoursEditorContext?
    @State private var managerBookingEditTarget: ManagerSiteBooking?
    @State private var operativeBookingEditTarget: Booking?
    @State private var secondBookingDialog: SecondBookingDialog?
    @State private var isBookYourselfExpanded = false
    @State private var isProjectsExpanded = false
    @State private var isSmallWorksExpanded = false
    @State private var searchText = ""
    @State private var expandedSearchItemId: String?
    @State private var showAddBookingSheet = false
    @State private var addToCalendarMessage: String?
    @State private var showingCalendarDestinationPicker = false
    @State private var showingDayPicker = false

    private struct LocationSearchItem: Identifiable {
        let id: String
        let title: String
        let locationType: ManagerLocationType
        let locationId: UUID?
        let customLocationName: String?
    }

    private var weekDates: [Date] {
        guard let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var liveProjects: [Project] {
        WorkAccess.visibleWorks(
            from: projectStore.projects,
            catalogue: .projects,
            userStore: userStore,
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            managerBookings: managerScheduleStore.managerSiteBookings,
            taskStore: nil,
            deadlineAssignedProjectIds: []
        ).filter(\.isLive)
    }

    private var liveSmallWorks: [Project] {
        WorkAccess.visibleWorks(
            from: projectStore.projects,
            catalogue: .smallWorks,
            userStore: userStore,
            operativeStore: operativeStore,
            bookingStore: bookingStore,
            managerBookings: managerScheduleStore.managerSiteBookings,
            taskStore: nil,
            deadlineAssignedProjectIds: []
        ).filter(\.isLive)
    }

    private var myManagerId: UUID? {
        guard let email = userStore.currentUser?.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return operativeStore.allManagers.first {
            $0.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == email
        }?.id
    }

    private var myManagedProjects: [Project] {
        guard let managerId = myManagerId else { return [] }
        return liveProjects
            .filter { $0.managerId == managerId }
            .sorted { lhs, rhs in
                if lhs.jobNumber != rhs.jobNumber { return lhs.jobNumber < rhs.jobNumber }
                return lhs.siteName.localizedCaseInsensitiveCompare(rhs.siteName) == .orderedAscending
            }
    }

    private var myManagedSmallWorks: [Project] {
        guard let managerId = myManagerId else { return [] }
        return liveSmallWorks
            .filter { $0.managerId == managerId }
            .sorted { lhs, rhs in
                if lhs.jobNumber != rhs.jobNumber { return lhs.jobNumber < rhs.jobNumber }
                return lhs.siteName.localizedCaseInsensitiveCompare(rhs.siteName) == .orderedAscending
            }
    }

    private var searchableLocationItems: [LocationSearchItem] {
        var out: [LocationSearchItem] = []
        if appSettings.settings.myScheduleOptions.showOffice {
            out.append(LocationSearchItem(
                id: "std:office",
                title: "Office",
                locationType: .office,
                locationId: nil,
                customLocationName: nil
            ))
        }
        if appSettings.settings.myScheduleOptions.showWorkingFromHome {
            out.append(LocationSearchItem(
                id: "std:wfh",
                title: "Working From Home",
                locationType: .workingFromHome,
                locationId: nil,
                customLocationName: nil
            ))
        }
        if appSettings.settings.myScheduleOptions.showSiteSurvey {
            out.append(LocationSearchItem(
                id: "std:survey",
                title: "Site Survey",
                locationType: .siteSurvey,
                locationId: nil,
                customLocationName: nil
            ))
        }
        for customItem in appSettings.settings.myScheduleOptions.customItems where (appSettings.settings.myScheduleOptions.customItemEnabled[customItem] ?? true) {
            out.append(LocationSearchItem(
                id: "custom:\(customItem.lowercased())",
                title: customItem,
                locationType: .custom,
                locationId: nil,
                customLocationName: customItem
            ))
        }
        for p in liveProjects {
            out.append(LocationSearchItem(
                id: "project:\(p.id.uuidString)",
                title: "\(p.jobNumber) \(p.siteName)",
                locationType: .project,
                locationId: p.id,
                customLocationName: nil
            ))
        }
        for p in liveSmallWorks {
            out.append(LocationSearchItem(
                id: "small:\(p.id.uuidString)",
                title: "\(p.jobNumber) \(p.siteName)",
                locationType: .smallWork,
                locationId: p.id,
                customLocationName: nil
            ))
        }
        return out
    }

    private var filteredSearchItems: [LocationSearchItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return searchableLocationItems.filter {
            $0.title.localizedCaseInsensitiveContains(q)
        }
    }

    private func payrollPolicy(for day: Date) -> OrgPayrollTimePolicy {
        firebaseBackend.payrollPolicy(for: day)
    }

    /// Some admins/managers also have an operative profile and can be booked onto projects/small works.
    private func myOperativeBookings(on day: Date) -> [Booking] {
        guard let user = userStore.currentUser else { return [] }
        let ids = WorkAccess.signedInOperativeIds(
            email: user.email,
            firstName: user.firstName,
            surname: user.surname,
            operatives: operativeStore.allOperatives,
            users: userStore.organizationUsers + [user]
        )
        guard !ids.isEmpty else { return [] }
        return bookingStore.bookings.filter {
            ids.contains($0.operativeId) &&
            $0.occupiesDay &&
            calendar.isDate($0.date, inSameDayAs: day)
        }
    }

    private var signedInAccountIds: Set<String> {
        WorkAccess.signedInAccountIds(
            authUid: firebaseBackend.currentUser?.uid,
            currentUser: userStore.displayUser ?? userStore.currentUser,
            organizationUsers: userStore.organizationUsers
        )
    }

    private func mySiteBookings(on date: Date) -> [ManagerSiteBooking] {
        managerScheduleStore.myBookings(on: date, matching: signedInAccountIds)
    }

    private func hasScheduleDot(on date: Date) -> Bool {
        !mySiteBookings(on: date).isEmpty || !myOperativeBookings(on: date).isEmpty
    }

    private func myHolidayBookings(on day: Date) -> [HolidayBooking] {
        guard let uid = firebaseBackend.currentUser?.uid else { return [] }
        let targetDay = calendar.startOfDay(for: day)
        return holidayStore.myBookings(userId: uid, operativeId: nil, email: firebaseBackend.currentUser?.email)
            .filter { $0.status != .rejected }
            .filter { booking in
                let start = calendar.startOfDay(for: booking.startDate)
                let end = calendar.startOfDay(for: booking.endDate)
                return targetDay >= start && targetDay <= end
            }
            .sorted { $0.startDate < $1.startDate }
    }

    private func annualLeaveDisplayLabel(on day: Date) -> String? {
        guard let holiday = myHolidayBookings(on: day).first else { return nil }
        switch holiday.timeSlot {
        case .fullDay:
            return "Annual Leave - Full Day"
        case .morning:
            return "Annual Leave - AM"
        case .afternoon:
            return "Annual Leave - PM"
        }
    }

    private func annualLeaveTimeSlot(on day: Date) -> HolidayTimeSlot? {
        myHolidayBookings(on: day).first?.timeSlot
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if let day = selectedDate {
                    dayContent(for: day)
                }
            }
            if let pending = pendingOverlapResolution {
                scheduleOverlapWarningTile(pending)
            }
        }
        .onAppear {
            weekStart = Date()
            selectedDate = calendar.startOfDay(for: Date())
            managerScheduleStore.loadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookingStoreDidChange)) { _ in
            // Operative project bookings refresh via @Published bookingStore; reload manager rows too.
            managerScheduleStore.loadData(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("managerScheduleDidChange"))) { _ in
            managerScheduleStore.loadData(force: true)
        }
        .sheet(item: $customHoursContext) { ctx in
            let policyDay = ctx.days.first ?? selectedDate ?? Date()
            ManagerCustomHoursSheet(
                context: ctx,
                policy: payrollPolicy(for: policyDay),
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
        .sheet(isPresented: $showAddBookingSheet) {
            let bookingDay = selectedDate ?? Date()
            ManagerSelfBookingLocationPickerSheet(
                day: bookingDay,
                policy: payrollPolicy(for: bookingDay),
                companyCustomLocations: appSettings.settings.myScheduleOptions.customItems.filter {
                    appSettings.settings.myScheduleOptions.customItemEnabled[$0] ?? true
                },
                showOffice: appSettings.settings.myScheduleOptions.showOffice,
                showWorkingFromHome: appSettings.settings.myScheduleOptions.showWorkingFromHome,
                showSiteSurvey: appSettings.settings.myScheduleOptions.showSiteSurvey,
                projects: liveProjects,
                smallWorks: liveSmallWorks,
                myManagedProjects: myManagedProjects,
                myManagedSmallWorks: myManagedSmallWorks,
                onBook: { locationType, locationId, customName, slot, customStart, customEnd in
                    showAddBookingSheet = false
                    let daysToBook: [Date] = {
                        if isMultiDaySelectionEnabled, !selectedDates.isEmpty {
                            return selectedDates.map { calendar.startOfDay(for: $0) }.sorted()
                        }
                        return [calendar.startOfDay(for: selectedDate ?? Date())]
                    }()
                    runBookingFlow(
                        days: daysToBook,
                        timeSlot: slot,
                        workStart: customStart,
                        workEnd: customEnd,
                        breakRemoved: false,
                        locationType: locationType,
                        locationId: locationId,
                        customLocationName: customName
                    )
                }
            )
        }
        .sheet(item: $managerBookingEditTarget) { booking in
            let personName = managerBookingPersonName(booking)
            let policy = payrollPolicy(for: booking.date)
            OperativeCustomHoursSheet(
                policy: policy,
                referenceDay: booking.date,
                title: "Edit booking",
                subtitle: myScheduleEditSubtitle(date: booking.date, locationTitle: locationNameString(for: booking)),
                headerName: personName,
                headerInitials: PlannerUIInitials.from(personName),
                allowsOtMultiplierOverride: false,
                initialChoice: booking.hoursEditChoice(policy: policy),
                onSave: { start, end, breakRemoved, _ in
                    managerBookingEditTarget = nil
                    var updated = booking
                    updated.timeSlot = .customHours
                    updated.workStartTime = start
                    updated.workEndTime = end
                    updated.isBreakRemoved = breakRemoved
                    updated.updatedAt = Date()
                    Task { await managerScheduleStore.saveBooking(updated) }
                },
                onCancel: { managerBookingEditTarget = nil },
                onDelete: {
                    managerBookingEditTarget = nil
                    Task { await managerScheduleStore.deleteBooking(booking) }
                }
            )
        }
        .sheet(item: $operativeBookingEditTarget) { booking in
            let p = projectStore.projects.first(where: { $0.id == booking.projectId }) ??
                projectStore.smallWorks.first(where: { $0.id == booking.projectId })
            let personName = operativeStore.allOperatives.first { $0.id == booking.operativeId }?.name ?? "Booking"
            OperativeCustomHoursSheet(
                policy: firebaseBackend.payrollPolicy(for: booking.date),
                referenceDay: booking.date,
                title: "Edit booking",
                subtitle: p.map { "\($0.jobNumber) \($0.siteName)" } ?? "Project booking",
                headerName: personName,
                headerInitials: PlannerUIInitials.from(personName),
                allowsOtMultiplierOverride: true,
                initialChoice: OperativeDayBookingChoice(from: booking),
                onSave: { start, end, isBreakRemoved, otMult in
                    operativeBookingEditTarget = nil
                    var updated = booking
                    updated.timeSlot = .customHours
                    updated.workStartTime = start
                    updated.workEndTime = end
                    updated.isBreakRemoved = isBreakRemoved
                    updated.otMultiplierOverride = otMult
                    updated.updatedAt = Date()
                    Task {
                        await bookingStore.updateBooking(updated)
                        ScheduleChangeNotifier.postBookingStoreDidChange()
                    }
                },
                onCancel: { operativeBookingEditTarget = nil },
                onDelete: {
                    operativeBookingEditTarget = nil
                    Task { await bookingStore.deleteBooking(booking) }
                }
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
                .accessibilityIdentifier("managerScheduleContent.addBooking")
            Button("Cancel", role: .cancel) {
                secondBookingDialog = nil
            }
                .accessibilityIdentifier("managerScheduleContent.cancel")
        } message: {
            if let m = secondBookingDialog?.message {
                Text(m)
            }
        }
        .alert("Calendar", isPresented: .constant(addToCalendarMessage != nil)) {
            Button("OK") { addToCalendarMessage = nil }
                .accessibilityIdentifier("managerScheduleContent.ok")
        } message: {
            if let msg = addToCalendarMessage { Text(msg) }
        }
        .sheet(isPresented: $showingCalendarDestinationPicker) {
            ScheduleCalendarDestinationPicker(
                events: weekExportEvents,
                onResult: { addToCalendarMessage = $0 },
                onDismiss: { showingCalendarDestinationPicker = false }
            )
        }
        .sheet(isPresented: $showingDayPicker) {
            NavigationStack {
                DatePicker(
                    "Day",
                    selection: Binding(
                        get: { selectedDate ?? Date() },
                        set: { applySelectedDay($0) }
                    ),
                    displayedComponents: .date
                )
                .accessibilityIdentifier("managerScheduleContent.day")
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Choose a day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingDayPicker = false }
                            .accessibilityIdentifier("managerScheduleContent.done")
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func applySelectedDay(_ day: Date) {
        let start = calendar.startOfDay(for: day)
        selectedDate = start
        if let week = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: start)) {
            weekStart = week
        }
        coverSchedule(from: start)
    }

    private func scheduleOverlapWarningTile(_ pending: PendingScheduleOverlapResolution) -> some View {
        ScheduleOverlapWarningPanel(
            message: pending.message,
            detailLines: pending.detailLines,
            onCancel: { pendingOverlapResolution = nil },
            onConfirm: {
                let proceed = pending.onContinue
                pendingOverlapResolution = nil
                proceed()
            }
        )
    }

    private func wouldClashWithHoliday(on day: Date) -> Bool {
        !myHolidayBookings(on: day).isEmpty
    }

    private func holidayOverlapLines(on day: Date) -> [String] {
        myHolidayBookings(on: day).map { holiday in
            let slotLabel: String
            switch holiday.timeSlot {
            case .fullDay: slotLabel = "Full Day"
            case .morning: slotLabel = "AM"
            case .afternoon: slotLabel = "PM"
            }
            return holiday.status == .pending ? "Pending annual leave - \(slotLabel)" : "Annual leave - \(slotLabel)"
        }
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
        let policy = payrollPolicy(for: date)
        let existing = mySiteBookings(on: date).filter { $0.id != ignoringBookingId }
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
        mySiteBookings(on: day)
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

    private func newBookingSummaryLabel(timeSlot: ManagerTimeSlot, workStart: String?, workEnd: String?, breakRemoved: Bool, day: Date) -> String {
        let probe = bookingProbe(
            userId: "",
            day: day,
            timeSlot: timeSlot,
            workStart: workStart,
            workEnd: workEnd,
            breakRemoved: breakRemoved,
            locationType: .office,
            locationId: nil,
            customLocationName: nil
        )
        return probe.scheduleLabel(policy: payrollPolicy(for: day))
    }

    private func secondBookingMessage(existing: [ManagerSiteBooking], newLabel: String, day: Date) -> String {
        let policy = payrollPolicy(for: day)
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
        replaceBookingId: UUID? = nil,
        allowOverlap: Bool = false
    ) {
        guard let uid = firebaseBackend.currentUser?.uid else { return }
        let normalizedDays = days.map { calendar.startOfDay(for: $0) }
        if !allowOverlap {
            for day in normalizedDays {
                var detailLines: [String] = []
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
                    detailLines.append("This matches a booking you already have on \(fullDateLabel(day)).")
                    presentOverlapWarning(
                        message: "This booking overlaps something already on your schedule.",
                        detailLines: detailLines,
                        days: normalizedDays,
                        timeSlot: timeSlot,
                        workStart: workStart,
                        workEnd: workEnd,
                        breakRemoved: breakRemoved,
                        locationType: locationType,
                        locationId: locationId,
                        customLocationName: customLocationName,
                        replaceBookingId: replaceBookingId
                    )
                    return
                }
                if wouldClashWithHoliday(on: day) {
                    detailLines = holidayOverlapLines(on: day)
                    let holidayProbe = bookingProbe(
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
                    let newLabel = newBookingSummaryLabel(
                        timeSlot: timeSlot,
                        workStart: workStart,
                        workEnd: workEnd,
                        breakRemoved: breakRemoved,
                        day: day
                    )
                    detailLines.append("New booking: \(newLabel) — \(locationNameString(for: holidayProbe))")
                    presentOverlapWarning(
                        message: "You are on annual leave this day. Booking anyway will create a time overlap.",
                        detailLines: detailLines,
                        days: normalizedDays,
                        timeSlot: timeSlot,
                        workStart: workStart,
                        workEnd: workEnd,
                        breakRemoved: breakRemoved,
                        locationType: locationType,
                        locationId: locationId,
                        customLocationName: customLocationName,
                        replaceBookingId: replaceBookingId
                    )
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
                    let policy = payrollPolicy(for: day)
                    let existing = mySiteBookings(on: day)
                        .filter { $0.id != replaceBookingId }
                        .filter { ManagerScheduleInterval.bookingsOverlap(probe, $0, policy: policy) }
                    detailLines = existing.map {
                        "\($0.scheduleLabel(policy: policy)) — \(locationNameString(for: $0))"
                    }
                    let newLabel = newBookingSummaryLabel(
                        timeSlot: timeSlot,
                        workStart: workStart,
                        workEnd: workEnd,
                        breakRemoved: breakRemoved,
                        day: day
                    )
                    detailLines.append("New booking: \(newLabel) — \(locationNameString(for: probe))")
                    presentOverlapWarning(
                        message: "This booking overlaps another in time on \(fullDateLabel(day)).",
                        detailLines: detailLines,
                        days: normalizedDays,
                        timeSlot: timeSlot,
                        workStart: workStart,
                        workEnd: workEnd,
                        breakRemoved: breakRemoved,
                        locationType: locationType,
                        locationId: locationId,
                        customLocationName: customLocationName,
                        replaceBookingId: replaceBookingId
                    )
                    return
                }
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

        if !allowOverlap, normalizedDays.count == 1, let only = normalizedDays.first {
            let existing = mySiteBookings(on: only).filter { $0.id != replaceBookingId }
            if !existing.isEmpty {
                let newLabel = newBookingSummaryLabel(
                    timeSlot: timeSlot,
                    workStart: workStart,
                    workEnd: workEnd,
                    breakRemoved: breakRemoved,
                    day: only
                )
                secondBookingDialog = SecondBookingDialog(
                    title: "Another booking this day",
                    message: secondBookingMessage(existing: existing, newLabel: newLabel, day: only),
                    onConfirm: commit
                )
                return
            }
        }
        commit()
    }

    private func presentOverlapWarning(
        message: String,
        detailLines: [String],
        days: [Date],
        timeSlot: ManagerTimeSlot,
        workStart: String?,
        workEnd: String?,
        breakRemoved: Bool,
        locationType: ManagerLocationType,
        locationId: UUID?,
        customLocationName: String?,
        replaceBookingId: UUID?
    ) {
        pendingOverlapResolution = PendingScheduleOverlapResolution(
            message: message,
            detailLines: detailLines,
            onContinue: {
                runBookingFlow(
                    days: days,
                    timeSlot: timeSlot,
                    workStart: workStart,
                    workEnd: workEnd,
                    breakRemoved: breakRemoved,
                    locationType: locationType,
                    locationId: locationId,
                    customLocationName: customLocationName,
                    replaceBookingId: replaceBookingId,
                    allowOverlap: true
                )
            }
        )
    }

    private func shiftSelectedDay(by delta: Int) {
        let base = selectedDate ?? weekDates.first ?? Date()
        let sod = calendar.startOfDay(for: base)
        guard let newDay = calendar.date(byAdding: .day, value: delta, to: sod) else { return }
        selectedDate = newDay
        if let ws = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: newDay)) {
            weekStart = ws
        }
        coverSchedule(from: newDay)
    }

    private func coverSchedule(from date: Date) {
        guard firebaseBackend.noteScheduleNeedsDate(date) else { return }
        bookingStore.loadData()
        managerScheduleStore.loadData(force: true)
    }

    private func beginEditManagerBooking(_ b: ManagerSiteBooking) {
        managerBookingEditTarget = b
    }

    private func managerBookingPersonName(_ booking: ManagerSiteBooking) -> String {
        let match = userStore.organizationUsers.first { $0.id == booking.userId }
            ?? ((userStore.displayUser ?? userStore.currentUser)?.id == booking.userId
                ? (userStore.displayUser ?? userStore.currentUser) : nil)
        if let match {
            let name = match.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
            let email = match.email.trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty { return email }
        }
        return "Booking"
    }

    private func myScheduleEditSubtitle(date: Date, locationTitle: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return "\(formatter.string(from: date)) · \(locationTitle)"
    }

    private var dayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(weekDates, id: \.self) { date in
                    dayButton(date: date)
                }
            }
            .padding(.horizontal, PPMetrics.screenGutter)
        }
        .padding(.vertical, 10)
        // Runs edge to edge across the navy header.
        .padding(.horizontal, -PPMetrics.screenGutter)
    }

    private func dayButton(date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate ?? .distantPast)
        let isMultiSelected = selectedDates.contains(calendar.startOfDay(for: date))
        let hasBooking = hasScheduleDot(on: date)
        let hasAnnualLeave = annualLeaveDisplayLabel(on: date) != nil
        let tileShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button(action: { selectedDate = date }) {
            VStack(spacing: 4) {
                Text(dayLabel(date))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? PPColor.navy.opacity(0.65) : PPColor.onNavySecondary)
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(isSelected ? Font.Weight.bold : Font.Weight.semibold)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? PPColor.navy : Color.white)
                HStack(spacing: 3) {
                    if hasAnnualLeave {
                        Circle()
                            .fill(PPFamily.trade.top)
                            .frame(width: 6, height: 6)
                    }
                    if hasBooking {
                        Circle()
                            .fill(PPColor.glow)
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(height: 6)
            }
            .frame(width: 48, height: 64)
            .background(tileShape.fill(isSelected ? Color.white : PPColor.onNavyFill))
            .overlay(
                tileShape.strokeBorder(
                    isMultiSelected ? PPColor.glow : PPColor.onNavyStroke,
                    lineWidth: isMultiSelected ? 2 : 0.5
                )
            )
        }
        .accessibilityIdentifier("managerScheduleContent.day2")
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

    private func dashedAddBookingButton() -> some View {
        Button {
            showAddBookingSheet = true
        } label: {
            Text("+ Add booking")
                .font(.body.weight(.semibold))
                .foregroundStyle(PPColor.brand)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    PPColor.card,
                    in: RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PPMetrics.rowCardRadius, style: .continuous)
                        .strokeBorder(PPColor.brand.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                )
        }
        .accessibilityIdentifier("managerScheduleContent.addBooking2")
        .buttonStyle(PPPressableButtonStyle())
    }

    /// Navy header (Daily overview style): day navigator, the day's numbers, then the multi-day controls.
    private func managerNavyHeader(
        day: Date,
        bookingCount: Int,
        paidHours: Double,
        daysBookedInWeek: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MyScheduleDayNavigatorCard(
                day: day,
                onPrev: { shiftSelectedDay(by: -1) },
                onNext: { shiftSelectedDay(by: 1) },
                onSelectDay: { showingDayPicker = true }
            )

            HStack(alignment: .top, spacing: 12) {
                PPStat(value: "\(bookingCount)", label: bookingCount == 1 ? "Booking" : "Bookings")
                PPStatDivider()
                PPStat(value: ScheduleCoverageFormat.hours(paidHours), label: "Total hrs")
                PPStatDivider()
                PPStat(value: "\(daysBookedInWeek)/\(weekDates.count)", label: "Days booked this week")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)

            HStack(spacing: 8) {
                Button {
                    isMultiDaySelectionEnabled.toggle()
                    if isMultiDaySelectionEnabled {
                        selectedDates = [calendar.startOfDay(for: day)]
                    } else {
                        selectedDates = []
                    }
                } label: {
                    PPOnNavyPill(
                        text: isMultiDaySelectionEnabled ? "Booking \(max(selectedDates.count, 1)) days" : "Book more than one day",
                        symbol: isMultiDaySelectionEnabled ? "checkmark.circle.fill" : "calendar"
                    )
                }
                .accessibilityIdentifier("managerScheduleContent.bookingDays")
                .buttonStyle(PPPressableButtonStyle())
                Spacer()
                if isMultiDaySelectionEnabled {
                    Button {
                        selectedDates = []
                    } label: {
                        PPOnNavyPill(text: "Clear", symbol: "xmark")
                    }
                    .accessibilityIdentifier("managerScheduleContent.clear")
                    .buttonStyle(PPPressableButtonStyle())
                }
            }
            .padding(.top, 18)

            if isMultiDaySelectionEnabled {
                dayStrip
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private func dayContent(for day: Date) -> some View {
        let policy = firebaseBackend.payrollPolicy(for: day)
        let bookings = mySiteBookings(on: day)
        let operativeBookings = myOperativeBookings(on: day)
        let holidayBookings = myHolidayBookings(on: day)
        let annualLeaveLabel = annualLeaveDisplayLabel(on: day)
        let annualLeaveSlotForDay = annualLeaveTimeSlot(on: day)
        let segments = mergedDaySegments(manager: bookings, operative: operativeBookings, day: day, policy: policy)
        let daysBookedInWeek = weekDates.filter { hasScheduleDot(on: $0) }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                managerNavyHeader(
                    day: day,
                    bookingCount: bookings.count + operativeBookings.count,
                    paidHours: segments.totalPaidHours,
                    daysBookedInWeek: daysBookedInWeek
                )

                VStack(alignment: .leading, spacing: 0) {
                    MyScheduleTodaysHoursCard(
                        day: day,
                        policy: policy,
                        segments: segments,
                        workIntervals: ScheduleHoursTimelineSupport.workIntervals(
                            manager: bookings,
                            operative: operativeBookings,
                            policy: policy
                        ),
                        annualLeaveLabel: annualLeaveLabel,
                        annualLeaveTimeSlot: annualLeaveSlotForDay
                    )
                    .padding(.top, 20)

                    if !holidayBookings.isEmpty {
                        PPSectionHeader("Annual leave")
                        PPGroupedCard {
                            ForEach(holidayBookings) { holiday in
                                Button {
                                    NotificationCenter.default.post(name: NSNotification.Name("openHoliday"), object: nil)
                                } label: {
                                    PPMenuRowLabel(
                                        title: "Annual Leave",
                                        symbol: "sun.max.fill",
                                        family: .trade,
                                        detail: holiday.timeSlot == .fullDay ? "Full Day" : holiday.timeSlot.rawValue
                                    )
                                }
                                .accessibilityIdentifier("managerScheduleContent.row.\(holiday.id).openholiday")
                                .buttonStyle(PPMenuRowButtonStyle())
                                if holiday.id != holidayBookings.last?.id {
                                    PPRowDivider()
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: PPMetrics.cardRadius, style: .continuous))
                    }

                    PPSectionHeader("Bookings")
                    VStack(alignment: .leading, spacing: 10) {
                        if bookings.isEmpty && operativeBookings.isEmpty {
                            HStack(spacing: 13) {
                                PPIconTile(symbol: "calendar", family: .system, size: PPMetrics.menuIcon)
                                Text("No bookings for this day.")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .myScheduleCard(cornerRadius: PPMetrics.rowCardRadius)
                        } else if !bookings.isEmpty {
                            ForEach(bookings) { b in
                                bookingRow(b: b)
                            }
                        }
                        dashedAddBookingButton()
                            .padding(.top, 4)
                    }

                    if !operativeBookings.isEmpty {
                        PPSectionHeader("Project / small works")
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(operativeBookings) { b in
                                let p = projectStore.projects.first(where: { $0.id == b.projectId }) ??
                                    projectStore.smallWorks.first(where: { $0.id == b.projectId })
                                MyScheduleBookingStripeRow(
                                    family: .sites,
                                    symbol: "hammer.fill",
                                    title: p.map { "\($0.jobNumber) \($0.siteName)" } ?? "Project booking",
                                    subtitle: operativeBookingClockSubtitle(b, day: day, policy: policy),
                                    otChip: operativeBookingOtChipText(b, policy: policy),
                                    showActions: true,
                                    onEdit: {
                                        operativeBookingEditTarget = b
                                    },
                                    onDelete: {
                                        Task { await bookingStore.deleteBooking(b) }
                                    }
                                )
                            }
                        }
                    }

                    Text("Tap + Add booking to choose company locations, projects, or small works.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.top, 20)
                        .padding(.bottom, 12)
                    addManagerWeekToCalendarButton
                }
                .padding(.bottom, 28)
                .ppContentSheet()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bookingRow(b: ManagerSiteBooking) -> some View {
        let p = payrollPolicy(for: b.date)
        return MyScheduleBookingStripeRow(
            family: myScheduleLocationFamily(b.locationType),
            symbol: myScheduleLocationSymbol(b.locationType),
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
            .background(ProjectWorksRevampColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
            )
        }
        .accessibilityIdentifier("managerScheduleContent.chevronDown")
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
                .background(ProjectWorksRevampColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                )
            }
            .accessibilityIdentifier("managerScheduleContent.chevronDown2")
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
                    .accessibilityIdentifier("managerScheduleContent.row.\(slot).slotButtons")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(ProjectWorksRevampColors.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            HStack(spacing: 14) {
                Button("Custom…") {
                    customHoursContext = CustomHoursEditorContext(
                        days: daysToBook,
                        locationType: locationType,
                        locationId: locationId,
                        customLocationName: customLocationName
                    )
                }
                .accessibilityIdentifier("managerScheduleContent.custom")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(ProjectWorksRevampColors.upcomingAmber.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer(minLength: 0)
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

    private var myManagerBookingsThisWeek: [ManagerSiteBooking] {
        let ids = signedInAccountIds
        guard !ids.isEmpty else { return [] }
        return managerScheduleStore.managerSiteBookings.filter { booking in
            ids.contains(booking.userId) &&
            weekDates.contains { calendar.isDate(booking.date, inSameDayAs: $0) }
        }
    }

    private var myOperativeBookingsThisWeek: [Booking] {
        weekDates.flatMap { myOperativeBookings(on: $0) }
    }

    private var weekExportEvents: [ScheduleCalendarEvent] {
        var events: [ScheduleCalendarEvent] = []
        for b in myManagerBookingsThisWeek {
            let policy = payrollPolicy(for: b.date)
            let block = b.calendarBlock(on: b.date, policy: policy)
            events.append(ScheduleCalendarEvent(
                title: "\(locationNameString(for: b)) – \(b.scheduleLabel(policy: policy))",
                start: block.start,
                end: block.end
            ))
        }
        for b in myOperativeBookingsThisWeek {
            guard let project = projectStore.projects.first(where: { $0.id == b.projectId }) ??
                    projectStore.smallWorks.first(where: { $0.id == b.projectId }) else { continue }
            let policy = payrollPolicy(for: b.date)
            let block = b.calendarBlock(on: b.date, policy: policy)
            events.append(ScheduleCalendarEvent(
                title: "\(project.jobNumber) \(project.siteName) – \(b.scheduleLabel(policy: policy))",
                start: block.start,
                end: block.end
            ))
        }
        return events
    }

    private var addManagerWeekToCalendarButton: some View {
        Button {
            if weekExportEvents.isEmpty {
                addToCalendarMessage = "No bookings this week to add."
            } else {
                showingCalendarDestinationPicker = true
            }
        } label: {
            Label("Add this week to Calendar", systemImage: "calendar.badge.plus")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .accessibilityIdentifier("managerScheduleContent.noBookingsThisWeekToAdd")
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: PPMetrics.rowCardRadius))
        .tint(PPColor.brand)
        .padding(.top, 4)
    }
}

// MARK: - Manager self-booking location picker (from + Add booking)

fileprivate struct ManagerSelfBookingLocationPickerSheet: View {
    let day: Date
    let policy: OrgPayrollTimePolicy
    let companyCustomLocations: [String]
    let showOffice: Bool
    let showWorkingFromHome: Bool
    let showSiteSurvey: Bool
    let projects: [Project]
    let smallWorks: [Project]
    let myManagedProjects: [Project]
    let myManagedSmallWorks: [Project]
    let onBook: (ManagerLocationType, UUID?, String?, ManagerTimeSlot, String?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    fileprivate struct BookingTarget: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String?
        let locationType: ManagerLocationType
        let locationId: UUID?
        let customLocationName: String?
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var companyTargets: [BookingTarget] {
        var rows: [BookingTarget] = []
        if showOffice {
            rows.append(BookingTarget(id: "office", title: "Office", subtitle: nil, locationType: .office, locationId: nil, customLocationName: nil))
        }
        if showWorkingFromHome {
            rows.append(BookingTarget(id: "wfh", title: "Working from home", subtitle: nil, locationType: .workingFromHome, locationId: nil, customLocationName: nil))
        }
        if showSiteSurvey {
            rows.append(BookingTarget(id: "survey", title: "Site survey", subtitle: nil, locationType: .siteSurvey, locationId: nil, customLocationName: nil))
        }
        for custom in companyCustomLocations {
            rows.append(BookingTarget(id: "custom-\(custom)", title: custom, subtitle: "Custom location", locationType: .custom, locationId: nil, customLocationName: custom))
        }
        return rows
    }

    private func projectTargets(_ list: [Project], prefix: String) -> [BookingTarget] {
        list.map { p in
            BookingTarget(
                id: "\(prefix)-\(p.id.uuidString)",
                title: "\(p.jobNumber) \(p.siteName)",
                subtitle: p.client.name.isEmpty ? nil : p.client.name,
                locationType: prefix == "project" ? .project : .smallWork,
                locationId: p.id,
                customLocationName: nil
            )
        }
    }

    private var filteredCompanyTargets: [BookingTarget] {
        guard !normalizedSearch.isEmpty else { return companyTargets }
        return companyTargets.filter { $0.title.lowercased().contains(normalizedSearch) }
    }

    private var filteredProjects: [BookingTarget] {
        let all = projectTargets(projects, prefix: "project")
        guard !normalizedSearch.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(normalizedSearch) }
    }

    private var filteredSmallWorks: [BookingTarget] {
        let all = projectTargets(smallWorks, prefix: "small")
        guard !normalizedSearch.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(normalizedSearch) }
    }

    private var managedTargets: [BookingTarget] {
        projectTargets(myManagedProjects, prefix: "managed-project")
            + projectTargets(myManagedSmallWorks, prefix: "managed-small")
    }

    private var filteredManagedTargets: [BookingTarget] {
        guard !normalizedSearch.isEmpty else { return managedTargets }
        return managedTargets.filter { $0.title.lowercased().contains(normalizedSearch) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Book yourself in")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                        Text(day.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                        TextField("Search office, project, small works...", text: $searchText)
                            .accessibilityIdentifier("managerSelfBookingLocationPicker.searchOfficeProjectSmallWorks")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(ProjectWorksRevampColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                    )

                    sectionTitle("Company locations")
                    cardList(filteredCompanyTargets)

                    sectionTitle("My projects and small works")
                    if filteredManagedTargets.isEmpty {
                        staticInfoRow("No projects or small works assigned to you.")
                    } else {
                        cardList(filteredManagedTargets)
                    }

                    sectionTitle("Jobs")
                    VStack(spacing: 8) {
                        NavigationLink {
                            ManagerSelfBookingJobListView(
                                title: "Projects",
                                day: day,
                                policy: policy,
                                targets: filteredProjects,
                                onBook: onBook
                            )
                        } label: {
                            navRow(title: "Projects", subtitle: "\(filteredProjects.count) active")
                        }
                        .accessibilityIdentifier("managerSelfBookingLocationPicker.projects")
                        .buttonStyle(.plain)
                        NavigationLink {
                            ManagerSelfBookingJobListView(
                                title: "Small works",
                                day: day,
                                policy: policy,
                                targets: filteredSmallWorks,
                                onBook: onBook
                            )
                        } label: {
                            navRow(title: "Small works", subtitle: "\(filteredSmallWorks.count) active")
                        }
                        .accessibilityIdentifier("managerSelfBookingLocationPicker.smallWorks")
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("managerSelfBookingLocationPicker.close")
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .textCase(.uppercase)
            .tracking(0.4)
    }

    private func cardList(_ targets: [BookingTarget]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(targets.enumerated()), id: \.element.id) { idx, target in
                NavigationLink {
                    ManagerSelfBookingEntryView(
                        day: day,
                        policy: policy,
                        target: target,
                        onSave: { slot, customStart, customEnd in
                            onBook(target.locationType, target.locationId, target.customLocationName, slot, customStart, customEnd)
                        }
                    )
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(ProjectWorksRevampColors.ink)
                            if let subtitle = target.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(ProjectWorksRevampColors.muted)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                    .padding(.vertical, 11)
                    .padding(.horizontal, 12)
                }
                .accessibilityIdentifier("managerSelfBookingLocationPicker.row.\(target.id).chevronRight")
                .buttonStyle(.plain)
                if idx < targets.count - 1 {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func staticInfoRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            Spacer()
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func navRow(title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.muted)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }
}

fileprivate struct ManagerSelfBookingEntryView: View {
    let day: Date
    let policy: OrgPayrollTimePolicy
    let target: ManagerSelfBookingLocationPickerSheet.BookingTarget
    let onSave: (ManagerTimeSlot, String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSlot: ManagerTimeSlot = .fullDay
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var errorMessage: String?

    init(
        day: Date,
        policy: OrgPayrollTimePolicy,
        target: ManagerSelfBookingLocationPickerSheet.BookingTarget,
        onSave: @escaping (ManagerTimeSlot, String?, String?) -> Void
    ) {
        self.day = day
        self.policy = policy
        self.target = target
        self.onSave = onSave
        let (start, end) = Self.defaultTimes(for: .fullDay, day: day, policy: policy)
        _startTime = State(initialValue: start)
        _endTime = State(initialValue: end)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    Text("Standard day set: \(policy.standardDayStart)–\(policy.standardDayEnd)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }

                timelineCard

                HStack(spacing: 8) {
                    presetButton("FULL DAY", slot: .fullDay)
                    presetButton("AM", slot: .morning)
                    presetButton("PM", slot: .afternoon)
                }

                VStack(spacing: 10) {
                    DatePicker("Start time", selection: $startTime, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("managerSelfBookingEntry.startTime")
                        .datePickerStyle(.compact)
                    DatePicker("End time", selection: $endTime, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("managerSelfBookingEntry.endTime")
                        .datePickerStyle(.compact)
                }
                .font(.system(size: 14, weight: .medium))
                .padding(12)
                .background(ProjectWorksRevampColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                )
                .onChange(of: startTime) { _, newValue in
                    selectedSlot = .customHours
                    let rounded = BookingHMTimePickerSupport.roundDateToQuarterHour(newValue)
                    if rounded != newValue { startTime = rounded }
                }
                .onChange(of: endTime) { _, newValue in
                    selectedSlot = .customHours
                    let rounded = BookingHMTimePickerSupport.roundDateToQuarterHour(newValue)
                    if rounded != newValue { endTime = rounded }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                }

                Button("Save booking") {
                    validateAndSave()
                }
                .accessibilityIdentifier("managerSelfBookingEntry.saveBooking")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(ProjectWorksRevampColors.blue)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Book yourself in")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedSlot == .customHours ? "Custom hours" : selectedSlot.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
            ScheduleHoursTimelineBar(
                day: day,
                policy: policy,
                workIntervals: [],
                workStart: hhmm(startTime),
                workEnd: hhmm(endTime),
                breakIncluded: selectedSlot != .customHours || !policy.breakPaid
            )
            HStack {
                ForEach(["6:00", "9:00", "12:00", "15:00", "18:00"], id: \.self) { tick in
                    Text(tick)
                        .font(.system(size: 9))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private func presetButton(_ label: String, slot: ManagerTimeSlot) -> some View {
        Button(label) {
            selectedSlot = slot
            let times = Self.defaultTimes(for: slot, day: day, policy: policy)
            startTime = times.start
            endTime = times.end
        }
        .accessibilityIdentifier("managerSelfBookingEntry.\(AccessibilityID.token(label))")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(selectedSlot == slot ? .white : ProjectWorksRevampColors.ink)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(selectedSlot == slot ? ProjectWorksRevampColors.blue : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: selectedSlot == slot ? 0 : 0.5)
        )
    }

    private func validateAndSave() {
        errorMessage = nil
        guard endTime > startTime else {
            errorMessage = "End time must be after start time."
            return
        }
        if selectedSlot == .customHours {
            onSave(.customHours, hhmm(startTime), hhmm(endTime))
        } else {
            onSave(selectedSlot, nil, nil)
        }
        dismiss()
    }

    private func hhmm(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    private func minutesFromMidnight(_ date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private static func defaultTimes(for slot: ManagerTimeSlot, day: Date, policy: OrgPayrollTimePolicy) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: day)
        // The day and its AM/PM halves come from the canonical script.
        let range = CanonicalBusinessEngine.slotInterval(
            timeSlot: slot.rawValue,
            workStartTime: nil,
            workEndTime: nil,
            day: CanonicalStandardDayInput(policy: policy)
        ) ?? CanonicalMinuteInterval(start: 7 * 60 + 30, end: 16 * 60)
        let start = calendar.date(byAdding: .minute, value: range.start, to: base) ?? base
        let end = calendar.date(byAdding: .minute, value: range.end, to: base) ?? start.addingTimeInterval(3600)
        return (start, end)
    }
}

fileprivate struct ManagerSelfBookingJobListView: View {
    let title: String
    let day: Date
    let policy: OrgPayrollTimePolicy
    let targets: [ManagerSelfBookingLocationPickerSheet.BookingTarget]
    let onBook: (ManagerLocationType, UUID?, String?, ManagerTimeSlot, String?, String?) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(targets) { target in
                    NavigationLink {
                        ManagerSelfBookingEntryView(
                            day: day,
                            policy: policy,
                            target: target,
                            onSave: { slot, customStart, customEnd in
                                onBook(target.locationType, target.locationId, target.customLocationName, slot, customStart, customEnd)
                            }
                        )
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(ProjectWorksRevampColors.ink)
                                if let subtitle = target.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(ProjectWorksRevampColors.muted)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ProjectWorksRevampColors.muted)
                        }
                        .padding(.vertical, 11)
                        .padding(.horizontal, 12)
                        .background(ProjectWorksRevampColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                        )
                    }
                    .accessibilityIdentifier("managerSelfBookingJobList.row.\(target.id).chevronRight")
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
                        .accessibilityIdentifier("managerBooking.removeBooking")
                } else {
                    Button("Confirm booking") {
                        onSave()
                        dismiss()
                    }
                    .accessibilityIdentifier("managerBooking.confirmBooking")
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
                        .accessibilityIdentifier("managerBooking.cancel")
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
    @State private var showingCalendarDestinationPicker = false

    private var currentOperative: Operative? {
        guard let user = userStore.currentUser else { return nil }
        return WorkAccess.signedInOperative(
            email: user.email,
            firstName: user.firstName,
            surname: user.surname,
            operatives: operativeStore.allOperatives
        )
    }

    private var weekDates: [Date] {
        guard let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var myBookingsThisWeek: [Booking] {
        guard let user = userStore.currentUser else { return [] }
        let ids = WorkAccess.signedInOperativeIds(
            email: user.email,
            firstName: user.firstName,
            surname: user.surname,
            operatives: operativeStore.allOperatives,
            users: userStore.organizationUsers + [user]
        )
        guard !ids.isEmpty else { return [] }
        return bookingStore.bookings.filter { b in
            ids.contains(b.operativeId) &&
            b.occupiesDay &&
            weekDates.contains { calendar.isDate(b.date, inSameDayAs: $0) }
        }
    }

    /// Office / site self-bookings from when this account was a manager or admin (same Firebase Auth uid).
    private var myManagerAttendanceThisWeek: [ManagerSiteBooking] {
        let ids = WorkAccess.signedInAccountIds(
            authUid: firebaseBackend.currentUser?.uid,
            currentUser: userStore.displayUser ?? userStore.currentUser,
            organizationUsers: userStore.organizationUsers
        )
        guard !ids.isEmpty else { return [] }
        return managerScheduleStore.managerSiteBookings.filter { booking in
            ids.contains(booking.userId) &&
            weekDates.contains { calendar.isDate(booking.date, inSameDayAs: $0) }
        }
    }

    private func payrollPolicy(for day: Date) -> OrgPayrollTimePolicy {
        firebaseBackend.payrollPolicy(for: day)
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

    private func approvedHolidayLabel(on date: Date) -> String? {
        let day = calendar.startOfDay(for: date)
        guard let holiday = myApprovedHolidays.first(where: { booking in
            let start = calendar.startOfDay(for: booking.startDate)
            let end = calendar.startOfDay(for: booking.endDate)
            return day >= start && day <= end
        }) else { return nil }
        switch holiday.timeSlot {
        case .fullDay: return "Annual Leave - Full Day"
        case .morning: return "Annual Leave - AM"
        case .afternoon: return "Annual Leave - PM"
        }
    }

    private func approvedHolidayTimeSlot(on date: Date) -> HolidayTimeSlot? {
        let day = calendar.startOfDay(for: date)
        return myApprovedHolidays.first(where: { booking in
            let start = calendar.startOfDay(for: booking.startDate)
            let end = calendar.startOfDay(for: booking.endDate)
            return day >= start && day <= end
        })?.timeSlot
    }

    var body: some View {
        VStack(spacing: 0) {
            weekContent
            addToCalendarButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PPColor.page.ignoresSafeArea())
        .alert("Calendar", isPresented: .constant(addToCalendarMessage != nil)) {
            Button("OK") { addToCalendarMessage = nil }
                .accessibilityIdentifier("operativeScheduleContent.ok")
        } message: {
            if let msg = addToCalendarMessage { Text(msg) }
        }
        .sheet(isPresented: $showingCalendarDestinationPicker) {
            ScheduleCalendarDestinationPicker(
                events: weekExportEvents,
                onResult: { addToCalendarMessage = $0 },
                onDismiss: { showingCalendarDestinationPicker = false }
            )
        }
    }

    /// Sits on the navy header (Daily overview style): round ‹ › buttons either side of the week range.
    private var weekNavigation: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: { moveWeek(-1) }) {
                Image(systemName: "chevron.left")
            }
            .accessibilityIdentifier("operativeScheduleContent.back")
            .buttonStyle(PPOnNavyCircleButtonStyle())
            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.isDate(weekStart, equalTo: Date(), toGranularity: .weekOfYear) ? "This week" : "Week")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.onNavySecondary)
                Text(weekRangeText)
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: { moveWeek(1) }) {
                Image(systemName: "chevron.right")
            }
            .accessibilityIdentifier("operativeScheduleContent.chevronRight")
            .buttonStyle(PPOnNavyCircleButtonStyle())
        }
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
            guard firebaseBackend.noteScheduleNeedsDate(newStart) else { return }
            bookingStore.loadData()
            managerScheduleStore.loadData(force: true)
        }
    }

    private var weekContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                operativeNavyHeader

                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(weekDates, id: \.self) { date in
                        dayRow(date: date)
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 20)
                .ppContentSheet()
            }
        }
    }

    /// Navy header (Daily overview style): week navigator, then the week's numbers from the rows already loaded.
    private var operativeNavyHeader: some View {
        let bookings = myBookingsThisWeek
        let attendance = myManagerAttendanceThisWeek
        let bookingCount = bookings.count + attendance.count
        let daysBooked = weekDates.filter { date in
            bookings.contains { calendar.isDate($0.date, inSameDayAs: date) } ||
                attendance.contains { calendar.isDate($0.date, inSameDayAs: date) }
        }.count
        let leaveDays = weekDates.filter { holidayCoversDay($0) }.count
        return VStack(alignment: .leading, spacing: 0) {
            weekNavigation

            HStack(alignment: .top, spacing: 12) {
                PPStat(value: "\(daysBooked)/\(weekDates.count)", label: "Days booked")
                PPStatDivider()
                PPStat(value: "\(bookingCount)", label: bookingCount == 1 ? "Booking" : "Bookings")
                PPStatDivider()
                PPStat(value: "\(leaveDays)", label: leaveDays == 1 ? "Day on leave" : "Days on leave")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    private func dayRow(date: Date) -> some View {
        let policy = firebaseBackend.payrollPolicy(for: date)
        let dayBookings = myBookingsThisWeek.filter { calendar.isDate($0.date, inSameDayAs: date) }
        let dayManagerBookings = myManagerAttendanceThisWeek.filter { calendar.isDate($0.date, inSameDayAs: date) }
        let isOnHoliday = holidayCoversDay(date)
        let annualLeaveLabel = approvedHolidayLabel(on: date)
        let annualLeaveSlotForDay = approvedHolidayTimeSlot(on: date)
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMM"
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEE"
        let isToday = calendar.isDateInToday(date)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PPCalendarStub(
                    weekday: weekdayFormatter.string(from: date),
                    day: "\(calendar.component(.day, from: date))"
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.string(from: date))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if isToday {
                        Text("Today")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(PPColor.brand)
                    }
                }
                Spacer(minLength: 0)
            }
            if isOnHoliday {
                HStack(spacing: 13) {
                    PPIconTile(symbol: "sun.max.fill", family: .trade, size: PPMetrics.menuIcon)
                    Text("Annual Leave")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .myScheduleCard(cornerRadius: PPMetrics.rowCardRadius)
            }
            if dayBookings.isEmpty && dayManagerBookings.isEmpty && !isOnHoliday {
                Text("No bookings")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .myScheduleCard(cornerRadius: PPMetrics.rowCardRadius)
            } else {
                if !dayBookings.isEmpty || !dayManagerBookings.isEmpty {
                    MyScheduleTodaysHoursCard(
                        day: date,
                        policy: policy,
                        segments: mergedDaySegments(manager: dayManagerBookings, operative: dayBookings, day: date, policy: policy),
                        workIntervals: ScheduleHoursTimelineSupport.workIntervals(
                            manager: dayManagerBookings,
                            operative: dayBookings,
                            policy: policy
                        ),
                        annualLeaveLabel: annualLeaveLabel,
                        annualLeaveTimeSlot: annualLeaveSlotForDay
                    )
                }
                if !dayManagerBookings.isEmpty {
                    MyScheduleCaption(text: "Your attendance")
                        .padding(.top, 4)
                }
                ForEach(dayManagerBookings) { b in
                    let title = managerSelfBookingTitle(b)
                    MyScheduleBookingStripeRow(
                        family: myScheduleLocationFamily(b.locationType),
                        symbol: myScheduleLocationSymbol(b.locationType),
                        title: title,
                        subtitle: managerBookingClockSubtitle(b, day: date, policy: policy),
                        otChip: managerBookingOtChipText(b, policy: policy),
                        showActions: false
                    )
                }
                if !dayBookings.isEmpty {
                    if !dayManagerBookings.isEmpty {
                        MyScheduleCaption(text: "On-site bookings")
                            .padding(.top, 6)
                    }
                    ForEach(dayBookings) { b in
                        let project = projectStore.projects.first(where: { $0.id == b.projectId }) ??
                            projectStore.smallWorks.first(where: { $0.id == b.projectId })
                        let title = project.map { "\($0.jobNumber) \($0.siteName)" } ?? "Scheduled work"
                        MyScheduleBookingStripeRow(
                            family: .sites,
                            symbol: "hammer.fill",
                            title: title,
                            subtitle: operativeBookingClockSubtitle(b, day: date, policy: policy),
                            otChip: operativeBookingOtChipText(b, policy: policy),
                            showActions: false
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var weekExportEvents: [ScheduleCalendarEvent] {
        var events: [ScheduleCalendarEvent] = []
        for b in myBookingsThisWeek {
            guard let project = projectStore.projects.first(where: { $0.id == b.projectId }) ??
                    projectStore.smallWorks.first(where: { $0.id == b.projectId }) else { continue }
            let policy = payrollPolicy(for: b.date)
            let block = b.calendarBlock(on: b.date, policy: policy)
            events.append(ScheduleCalendarEvent(
                title: "\(project.jobNumber) \(project.siteName) – \(b.scheduleLabel(policy: policy))",
                start: block.start,
                end: block.end
            ))
        }
        for b in myManagerAttendanceThisWeek {
            let policy = payrollPolicy(for: b.date)
            let block = b.calendarBlock(on: b.date, policy: policy)
            events.append(ScheduleCalendarEvent(
                title: "\(managerSelfBookingTitle(b)) – \(b.scheduleLabel(policy: policy))",
                start: block.start,
                end: block.end
            ))
        }
        return events
    }

    private var addToCalendarButton: some View {
        Button {
            if weekExportEvents.isEmpty {
                addToCalendarMessage = "No bookings this week to add."
            } else {
                showingCalendarDestinationPicker = true
            }
        } label: {
            Label("Add this week to Calendar", systemImage: "calendar.badge.plus")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .accessibilityIdentifier("operativeScheduleContent.noBookingsThisWeekToAdd")
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: PPMetrics.rowCardRadius))
        .tint(PPColor.brand)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

