//
//  BookingHoursEditSheet.swift
//  Project Planner
//
//  Shared edit-booking UI (daily overview, project schedule, schedule operative).
//

import SwiftUI
import UIKit

// MARK: - Time helpers

enum BookingHMTimePickerSupport {
    static let minuteChoices = [0, 15, 30, 45]
    static let hourRange = 0...23
    static let dayMinutes = 24 * 60

    static func parse(_ hhmm: String) -> (hour: Int, minute: Int)? {
        let t = hhmm.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = t.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              h >= 0, h < 24, minuteChoices.contains(m) else { return nil }
        return (h, m)
    }

    static func format(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    static func minutes(hour: Int, minute: Int) -> Int {
        hour * 60 + minute
    }

    static func clampToQuarterHour(_ hhmm: String, fallbackHour: Int, fallbackMinute: Int) -> (hour: Int, minute: Int) {
        if let p = parse(hhmm) { return p }
        let m = minuteChoices.min(by: { abs($0 - fallbackMinute) < abs($1 - fallbackMinute) }) ?? 0
        return (fallbackHour, m)
    }

    static func roundDateToQuarterHour(_ date: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let rounded = minuteChoices.min(by: { abs($0 - minute) < abs($1 - minute) }) ?? 0
        return calendar.date(bySettingHour: hour, minute: rounded, second: 0, of: date) ?? date
    }
}

struct BookingEditHoursBreakdown {
    let totalHours: Double
    let standardRateHours: Double
    let overtimeHours: Double
    let overtimeMultiplier: Double
    let breakDeductionHours: Double
    let showsBreakLine: Bool
    /// RULEBOOK 1.20.4 `multipliedHoursText` over `payrollMultipliedHours`: "2h × 1.5 = 3h", or with an unpaid break in
    /// the multiplied hours "6.5h × 2 − 0.5h break = 12.5h". Empty when no hours are at a multiplier.
    let overtimeText: String
    /// The `payrollHoursResult` these figures were read from (standard hours, `multipliedHours`, unpaid break), so the
    /// Edit booking header binds to the rulebook's own values. Display only.
    let result: PayrollHoursResult

    static func compute(
        booking: Booking,
        policy: OrgPayrollTimePolicy,
        day: Date,
        breakIncluded: Bool
    ) -> BookingEditHoursBreakdown {
        var probe = booking
        probe.isBreakRemoved = !breakIncluded
        let total = probe.paidBookedHours(policy: policy)
        let result = PayrollHoursEngine.compute(booking: probe, day: day, policy: policy)
        let standardRate = result.segments
            .filter { $0.kind == .standardWindow }
            .reduce(0.0) { $0 + $1.paidHours }
        let ot = max(0, result.segments
            .filter { $0.kind == .outsideWindow || $0.kind == .allHoursMultiplier }
            .reduce(0.0) { $0 + $1.baseHours })
        // RULEBOOK 1.19.0: the break exactly as pay takes it (`payrollHoursResult.unpaidBreakHours`) — weekdays and,
        // when that day's break is unpaid, Saturday / Sunday — never a Swift weekday check.
        let breakH = breakIncluded ? result.unpaidBreakHours : 0
        let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: day, policy: policy)
        let otMult = timeline.allHoursAtMultiplier
            ? timeline.outsideMultiplier
            : probe.effectiveWeekdayOtMultiplier(policy: policy)
        return BookingEditHoursBreakdown(
            totalHours: total,
            standardRateHours: standardRate,
            overtimeHours: ot,
            overtimeMultiplier: otMult,
            breakDeductionHours: breakH,
            showsBreakLine: breakH > 0.05,
            overtimeText: result.multipliedHours?.text ?? "",
            result: result
        )
    }
}

// MARK: - Timeline (00–24 axis)

private struct BookingTimelineSegment: Identifiable {
    enum Kind { case standard, overtime }
    let id = UUID()
    let kind: Kind
    let startMinute: Int
    let endMinute: Int

    var duration: Int { max(0, endMinute - startMinute) }
}

private enum BookingHoursTimelineLayout {
    static let axisStart = 0
    static let axisEnd = BookingHMTimePickerSupport.dayMinutes

    static func fraction(_ minutes: Int) -> CGFloat {
        let span = CGFloat(axisEnd - axisStart)
        guard span > 0 else { return 0 }
        return CGFloat(minutes - axisStart) / span
    }

    static func segments(
        policy: OrgPayrollTimePolicy,
        day: Date,
        startMinutes: Int,
        endMinutes: Int
    ) -> [BookingTimelineSegment] {
        guard endMinutes > startMinutes else { return [] }
        let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: day, policy: policy)
        if timeline.allHoursAtMultiplier {
            return [BookingTimelineSegment(kind: .overtime, startMinute: startMinutes, endMinute: endMinutes)]
        }
        guard let ds = timeline.standardWindowStartMinutes,
              let de = timeline.standardWindowEndMinutes,
              de > ds else {
            return [BookingTimelineSegment(kind: .standard, startMinute: startMinutes, endMinute: endMinutes)]
        }
        var out: [BookingTimelineSegment] = []
        if startMinutes < ds {
            out.append(BookingTimelineSegment(kind: .overtime, startMinute: startMinutes, endMinute: min(endMinutes, ds)))
        }
        let stdLo = max(startMinutes, ds)
        let stdHi = min(endMinutes, de)
        if stdHi > stdLo {
            out.append(BookingTimelineSegment(kind: .standard, startMinute: stdLo, endMinute: stdHi))
        }
        if endMinutes > de {
            out.append(BookingTimelineSegment(kind: .overtime, startMinute: max(startMinutes, de), endMinute: endMinutes))
        }
        return out
    }

    static func breakStripeRange(
        policy: OrgPayrollTimePolicy,
        day: Date,
        startMinutes: Int,
        endMinutes: Int,
        breakIncluded: Bool
    ) -> (Int, Int)? {
        ScheduleHoursTimelineSupport.breakRange(
            policy: policy,
            day: day,
            workStart: startMinutes,
            workEnd: endMinutes,
            breakIncluded: breakIncluded
        )
    }
}

private struct BookingHoursTimelineBar: View {
    let policy: OrgPayrollTimePolicy
    let referenceDay: Date
    let startMinutes: Int
    let endMinutes: Int
    let breakIncluded: Bool
    let forceSolidBlue: Bool

    private var timeline: PayrollTimePolicyCatalog.DayTimelinePolicy {
        PayrollTimePolicyCatalog.timelinePolicy(for: referenceDay, policy: policy)
    }

    private var segments: [BookingTimelineSegment] {
        if forceSolidBlue {
            return [BookingTimelineSegment(kind: .standard, startMinute: startMinutes, endMinute: endMinutes)]
        }
        return BookingHoursTimelineLayout.segments(
            policy: policy,
            day: referenceDay,
            startMinutes: startMinutes,
            endMinutes: endMinutes
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ProjectWorksRevampColors.grayTint)

                    if !timeline.allHoursAtMultiplier,
                       let ds = timeline.standardWindowStartMinutes,
                       let de = timeline.standardWindowEndMinutes, de > ds {
                        let l = BookingHoursTimelineLayout.fraction(ds)
                        let ww = BookingHoursTimelineLayout.fraction(de) - l
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.45))
                            .frame(width: max(0, ww * w), height: h)
                            .offset(x: l * w)
                    }

                    ForEach(segments) { seg in
                        let left = BookingHoursTimelineLayout.fraction(seg.startMinute)
                        let width = BookingHoursTimelineLayout.fraction(seg.endMinute) - left
                        let barW = max(2, width * w)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(segmentFill(seg.kind))
                            if !forceSolidBlue, seg.kind == .overtime, barW > 22 {
                                Text("OT")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                                    .padding(.leading, 5)
                            } else if !forceSolidBlue, seg.kind == .standard, barW > 44 {
                                Text("Standard")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.leading, 6)
                            }
                        }
                        .frame(width: barW, height: h)
                        .offset(x: left * w)
                    }

                    if let br = BookingHoursTimelineLayout.breakStripeRange(
                        policy: policy,
                        day: referenceDay,
                        startMinutes: startMinutes,
                        endMinutes: endMinutes,
                        breakIncluded: breakIncluded
                    ) {
                        let bl = BookingHoursTimelineLayout.fraction(br.0)
                        let bw = BookingHoursTimelineLayout.fraction(br.1) - bl
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.55), Color.white.opacity(0.2)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: max(2, bw * w), height: h)
                            .offset(x: bl * w)
                    }
                }
            }
            .frame(height: 28)

            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { label in
                    Text(label == 24 ? "24" : String(format: "%02d", label))
                        .font(.system(size: 9))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    if label != 24 { Spacer(minLength: 0) }
                }
            }
        }
    }

    private func segmentFill(_ kind: BookingTimelineSegment.Kind) -> LinearGradient {
        switch kind {
        case .standard:
            return LinearGradient(
                colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .overtime:
            return LinearGradient(
                colors: [
                    ProjectWorksRevampColors.amberTint,
                    ProjectWorksRevampColors.amberTintStrong,
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

// MARK: - Wheel time picker

/// UIKit wheel so a finger on the time does not scroll the page, and Save reads the row on screen.
private struct QuarterHourWheel: UIViewRepresentable {
    @Binding var selection: Int
    let values: [Int]

    func makeCoordinator() -> Coordinator {
        Coordinator(values: values)
    }

    func makeUIView(context: Context) -> WheelHost {
        let host = WheelHost()
        host.picker.dataSource = context.coordinator
        host.picker.delegate = context.coordinator
        context.coordinator.picker = host.picker
        host.picker.onVisibleRow = { [weak coordinator = context.coordinator] row in
            coordinator?.publish(row: row)
        }
        return host
    }

    func updateUIView(_ host: WheelHost, context: Context) {
        context.coordinator.values = values
        context.coordinator.selection = $selection
        defer { context.coordinator.acceptsLiveChanges = true }
        guard !host.isUserSpinning, let idx = values.firstIndex(of: selection) else { return }
        if host.picker.selectedRow(inComponent: 0) != idx {
            host.picker.suppressVisibleRowCallback = true
            host.picker.selectRow(idx, inComponent: 0, animated: false)
            host.picker.suppressVisibleRowCallback = false
        }
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var values: [Int]
        var selection: Binding<Int>?
        weak var picker: LiveQuarterPicker?
        /// False until `updateUIView` has applied the bound row, so the first layout cannot publish row 0.
        var acceptsLiveChanges = false
        private var lastPublished: Int?

        init(values: [Int]) {
            self.values = values
        }

        func publish(row: Int) {
            guard acceptsLiveChanges else { return }
            guard values.indices.contains(row) else { return }
            let next = values[row]
            guard lastPublished != next else { return }
            lastPublished = next
            if selection?.wrappedValue != next {
                selection?.wrappedValue = next
            }
        }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
            values.count
        }

        func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
            guard values.indices.contains(row) else { return nil }
            return String(format: "%02d", values[row])
        }

        func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat { 28 }

        /// The whole wheel is the row, so a narrow minutes column (00 / 15 / 30 / 45) is never cut to "…".
        func pickerView(_ pickerView: UIPickerView, widthForComponent component: Int) -> CGFloat {
            max(pickerView.bounds.width, 40)
        }

        /// A label that shrinks to fit instead of the system title, which truncates in a 56pt column.
        func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int, reusing view: UIView?) -> UIView {
            let label = (view as? UILabel) ?? UILabel()
            label.text = values.indices.contains(row) ? String(format: "%02d", values[row]) : nil
            label.font = .monospacedDigitSystemFont(ofSize: 20, weight: .regular)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.lineBreakMode = .byClipping
            return label
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            publish(row: row)
        }
    }
}

private final class LiveQuarterPicker: UIPickerView {
    var onVisibleRow: ((Int) -> Void)?
    /// True while SwiftUI calls `selectRow` so that layout does not write `@State` during the update.
    var suppressVisibleRowCallback = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !suppressVisibleRowCallback else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onVisibleRow?(self.selectedRow(inComponent: 0))
        }
    }
}

private final class WheelHost: UIView, UIGestureRecognizerDelegate {
    let picker = LiveQuarterPicker()
    var isUserSpinning = false
    private weak var pageScroll: UIScrollView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        picker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: trailingAnchor),
            picker.topAnchor.constraint(equalTo: topAnchor),
            picker.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(holdPageScroll))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { return nil }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func holdPageScroll(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            isUserSpinning = true
            pageScroll?.isScrollEnabled = false
        default:
            isUserSpinning = false
            pageScroll?.isScrollEnabled = true
            picker.onVisibleRow?(picker.selectedRow(inComponent: 0))
        }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        var view = superview
        while let current = view {
            if let scroll = current as? UIScrollView {
                pageScroll = scroll
                break
            }
            view = current.superview
        }
    }
}

private struct BookingHMTimePickerColumn: View {
    let title: String
    @Binding var hour: Int
    @Binding var minute: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            HStack(spacing: 2) {
                QuarterHourWheel(selection: $hour, values: Array(BookingHMTimePickerSupport.hourRange))
                    .accessibilityIdentifier("bookingHMTimePickerColumn.picker")
                    .frame(maxWidth: .infinity)

                Text(":")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)

                QuarterHourWheel(selection: $minute, values: BookingHMTimePickerSupport.minuteChoices)
                    .accessibilityIdentifier("bookingHMTimePickerColumn.picker2")
                    .frame(width: 64)
            }
            .frame(height: 100)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(ProjectWorksRevampColors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Main sheet

struct OperativeCustomHoursSheet: View {
    let policy: OrgPayrollTimePolicy
    let referenceDay: Date
    /// The day as the caller passed it (an organisation-zone midnight), for the rulebook's day key. `referenceDay` is
    /// the device-calendar start of day the timeline drawing uses.
    private let rulebookDay: Date
    /// Every day this one pair of times is booked on, for the weekend notes (`weekendBookingNotes`, 1.17.0). Defaults
    /// to the reference day alone.
    private let noteDays: [Date]
    var title: String
    var subtitle: String?
    var headerName: String?
    var headerInitials: String?
    var allowsOtMultiplierOverride: Bool
    var showsBreakControls: Bool
    var showsBreakdown: Bool
    var showsFooterNote: Bool
    var forceSolidBlueTimeline: Bool
    /// When false, content is shown in the parent `NavigationStack` (avoids nested covers).
    var embedsNavigation: Bool
    let initialChoice: OperativeDayBookingChoice?
    let onSave: (String, String, Bool, Double?) -> Void
    let onCancel: () -> Void
    /// Set when this sheet is editing a booking that already exists. Create flows leave it nil.
    var onDelete: (() -> Void)?

    @State private var startHour: Int
    @State private var startMinute: Int
    @State private var endHour: Int
    @State private var endMinute: Int
    @State private var lastValidStartHour: Int
    @State private var lastValidStartMinute: Int
    @State private var lastValidEndHour: Int
    @State private var lastValidEndMinute: Int
    @State private var breakIncluded: Bool
    /// RULEBOOK 1.29.0 §25: the booking's own overtime rate (`otMultiplierOverride`); nil = the organisation's.
    @State private var otRate: Double?
    /// The rate the sheet opened with, so an untouched older rate outside the 1–3 steps is never refused or rewritten.
    private let initialOtRate: Double?
    @State private var errorMessage: String?
    @State private var timeValidationBanner: String?
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var confirmDelete = false
    /// RULEBOOK 1.19.0 §4.3 `unpaidBreakAppliesOnDay`: any booked day takes an unpaid break off (Mon–Fri the organisation
    /// break, Saturday / Sunday that day's own). The "Unpaid break" toggle and `customHoursBreakWarning` only then.
    private let breakApplies: Bool
    /// That day's break length in minutes (`payrollBreakOnDay`), for the toggle's caption.
    private let dayBreakMinutes: Int
    /// `customHoursBreakWarning` (RULEBOOK 1.13.0 §8): shown before saving hours that cover the unpaid break.
    @State private var breakWarningMessage: String?
    /// RULEBOOK 1.18.0 `weekendBookingBreakdown` lines for `noteDays` at the times on screen; empty on weekdays. Worked
    /// out when the times change, never per redraw.
    @State private var weekendBreakdownLines: [String] = []
    /// Which time tile has its wheel open (none until a tile is tapped).
    @State private var expandedTimeField: TimeField? = nil
    @State private var showingRateSheet = false
    /// The Unpaid break warning button pressed; run once that sheet has gone.
    @State private var breakWarningChoice: BreakWarningChoice? = nil
    /// Per-rate figures from re-running the probe at each offered rate (`refreshRateFigures`), keyed by rate
    /// (nil = the organisation's).
    @State private var rateFigures: [Double?: OvertimeRateFigure] = [:]

    init(
        policy callerPolicy: OrgPayrollTimePolicy,
        referenceDay: Date = Date(),
        noteDays: [Date]? = nil,
        title: String = "Edit booking",
        subtitle: String? = nil,
        headerName: String? = nil,
        headerInitials: String? = nil,
        allowsOtMultiplierOverride: Bool = false,
        showsBreakControls: Bool = true,
        showsBreakdown: Bool = true,
        showsFooterNote: Bool = true,
        forceSolidBlueTimeline: Bool = false,
        embedsNavigation: Bool = true,
        initialChoice: OperativeDayBookingChoice?,
        onSave: @escaping (String, String, Bool, Double?) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        // RULEBOOK 1.19.0 §4.3: the working hours in effect on the booking day (history first), whatever policy the
        // caller had at hand; `policy` is the fallback before an organisation is loaded.
        let policy = CanonicalBusinessEngine.payrollPolicyInEffect(on: referenceDay, fallback: callerPolicy)
        self.policy = policy
        self.referenceDay = Calendar.current.startOfDay(for: referenceDay)
        self.rulebookDay = referenceDay
        if let noteDays, !noteDays.isEmpty {
            self.noteDays = noteDays
        } else {
            self.noteDays = [referenceDay]
        }
        self.title = title
        self.subtitle = subtitle
        self.headerName = headerName
        self.headerInitials = headerInitials
        self.allowsOtMultiplierOverride = allowsOtMultiplierOverride
        self.showsBreakControls = showsBreakControls
        self.showsBreakdown = showsBreakdown
        self.showsFooterNote = showsFooterNote
        self.forceSolidBlueTimeline = forceSolidBlueTimeline
        self.embedsNavigation = embedsNavigation
        self.initialChoice = initialChoice
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete

        let bookedDays = (noteDays?.isEmpty == false ? noteDays : nil) ?? [referenceDay]
        let applies = bookedDays.contains { day in
            CanonicalBusinessEngine.unpaidBreakAppliesOnDay(
                policy: CanonicalBusinessEngine.payrollPolicyInEffect(on: day, fallback: policy),
                dayKey: CanonicalBusinessEngine.bookingDayKey(day)
            )
        }
        self.breakApplies = applies
        self.dayBreakMinutes = CanonicalBusinessEngine.payrollBreakOnDay(
            policy: policy,
            dayKey: CanonicalBusinessEngine.bookingDayKey(referenceDay)
        )?.minutes ?? policy.unpaidBreakMinutes

        let ic = initialChoice
        let startHM: (Int, Int)
        let endHM: (Int, Int)
        let included: Bool
        var otm: Double? = nil

        let timeline = PayrollTimePolicyCatalog.timelinePolicy(for: referenceDay, policy: policy)
        // RULEBOOK 1.13.1 §4.3 `weekendCustomHoursDefault`: a set-window Saturday or Sunday opens on that day's window.
        let weekendPrefill = CanonicalBusinessEngine.weekendCustomHoursDefault(
            policy: policy,
            dayKey: CanonicalBusinessEngine.bookingDayKey(referenceDay)
        )
        // RULEBOOK 1.18.0 §4.3 `customHoursPrefillForDays`: one pair of times for every day this sheet books — the first
        // selected Saturday's window (Sunday's when Saturday is all hours at N×) for a weekend selection, the standard
        // day in effect on the first day for weekdays. A refused weekday + weekend mix keeps the day's own default.
        let selectionPrefill = CanonicalBusinessEngine.customHoursPrefill(
            on: (noteDays?.isEmpty == false ? noteDays : nil) ?? [referenceDay],
            fallbackPolicy: policy
        ).flatMap { $0.kind == .mixed ? nil : $0 }
        let defaultStart = selectionPrefill?.start ?? weekendPrefill?.start ?? timeline.standardWindowStart ?? policy.standardDayStart
        let defaultEnd = selectionPrefill?.end ?? weekendPrefill?.end ?? timeline.standardWindowEnd ?? policy.standardDayEnd

        if let ic {
            let s = ic.workStartTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let e = ic.workEndTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !s.isEmpty, !e.isEmpty {
                startHM = BookingHMTimePickerSupport.clampToQuarterHour(s, fallbackHour: 8, fallbackMinute: 0)
                endHM = BookingHMTimePickerSupport.clampToQuarterHour(e, fallbackHour: 16, fallbackMinute: 30)
            } else {
                startHM = BookingHMTimePickerSupport.clampToQuarterHour(
                    defaultStart,
                    fallbackHour: 8,
                    fallbackMinute: 0
                )
                endHM = BookingHMTimePickerSupport.clampToQuarterHour(
                    defaultEnd,
                    fallbackHour: 16,
                    fallbackMinute: 30
                )
            }
            included = showsBreakControls ? !ic.isBreakRemoved : false
            if let m = ic.otMultiplierOverride {
                otm = m
            }
        } else {
            startHM = BookingHMTimePickerSupport.clampToQuarterHour(
                defaultStart,
                fallbackHour: 8,
                fallbackMinute: 0
            )
            endHM = BookingHMTimePickerSupport.clampToQuarterHour(
                defaultEnd,
                fallbackHour: 16,
                fallbackMinute: 30
            )
            // A new booking starts with the unpaid break on, as web (`breakRemoved` false); it only matters on a day whose
            // break is unpaid (`unpaidBreakAppliesOnDay`).
            included = showsBreakControls
        }

        _startHour = State(initialValue: startHM.0)
        _startMinute = State(initialValue: startHM.1)
        _endHour = State(initialValue: endHM.0)
        _endMinute = State(initialValue: endHM.1)
        _lastValidStartHour = State(initialValue: startHM.0)
        _lastValidStartMinute = State(initialValue: startHM.1)
        _lastValidEndHour = State(initialValue: endHM.0)
        _lastValidEndMinute = State(initialValue: endHM.1)
        _breakIncluded = State(initialValue: included)
        _otRate = State(initialValue: otm)
        initialOtRate = otm
    }

    private var startMinutes: Int {
        BookingHMTimePickerSupport.minutes(hour: startHour, minute: startMinute)
    }

    private var endMinutes: Int {
        BookingHMTimePickerSupport.minutes(hour: endHour, minute: endMinute)
    }

    private var startText: String {
        BookingHMTimePickerSupport.format(hour: startHour, minute: startMinute)
    }

    private var endText: String {
        BookingHMTimePickerSupport.format(hour: endHour, minute: endMinute)
    }

    private var resolvedOtMultiplierOverride: Double? {
        guard allowsOtMultiplierOverride else { return nil }
        return otRate
    }

    /// `overtimeRateControl` for the times on screen (the booking's day, custom hours).
    private var overtimeRateControl: OvertimeRateControl? {
        CanonicalBusinessEngine.overtimeRateControl(
            OvertimeBookingInput(
                id: "edit",
                collection: "bookings",
                personId: "",
                dayKey: CanonicalBusinessEngine.bookingDayKey(rulebookDay),
                timeSlot: "CUSTOM_HOURS",
                workStartTime: startText,
                workEndTime: endText,
                isBreakRemoved: !breakIncluded,
                otMultiplierOverride: otRate
            ),
            organization: OrganizationRulebookContext.payrollPolicyDocument ?? [:]
        )
    }

    /// The control's steps, plus an older stored rate outside them so it is shown as it is.
    private func overtimeRateChoices(_ control: OvertimeRateControl) -> [Double] {
        var steps = control.steps
        if let initialOtRate, !steps.contains(where: { abs($0 - initialOtRate) < 0.0001 }) { steps.append(initialOtRate) }
        return steps
    }

    private var probeBooking: Booking {
        OperativeDayBookingChoice(
            timeSlot: .customHours,
            workStartTime: startText,
            workEndTime: endText,
            isBreakRemoved: !breakIncluded,
            otMultiplierOverride: resolvedOtMultiplierOverride
        ).bookingProbe(operativeId: UUID(), projectId: UUID(), date: referenceDay, bookedBy: "")
    }

    private var breakdown: BookingEditHoursBreakdown {
        BookingEditHoursBreakdown.compute(
            booking: probeBooking,
            policy: policy,
            day: referenceDay,
            breakIncluded: breakIncluded
        )
    }

    private func formatHours(_ h: Double) -> String {
        ScheduleCoverageFormat.hours(h)
    }

    var body: some View {
        Group {
            if embedsNavigation {
                NavigationStack { customHoursForm }
            } else {
                customHoursForm
            }
        }
    }

    // MARK: Layout (docs/design/booking-ui 3.5 Edit booking; the Hours sheet is the same layout without a person row)

    /// The breakdown figures move into the navy header ("AT A GLANCE" + stat row) when there is one breakdown for the
    /// day on screen. A weekend selection keeps its per-day rows (`weekendBookingBreakdown`) in the sheet instead.
    private var showsGlance: Bool {
        showsBreakdown && weekendBreakdownLines.isEmpty && endMinutes > startMinutes
    }

    /// "· break included" in THE DAY card: the old footer "The break is included within this booking." (same condition).
    private var showsBreakIncludedNote: Bool {
        showsFooterNote && breakApplies && breakIncluded
    }

    /// On site = finish − start, clock time (owner decision 2). Display arithmetic on the times on screen.
    private var onSiteHours: Double {
        Double(max(0, endMinutes - startMinutes)) / 60.0
    }

    private var paidPerDaySuffix: String {
        noteDays.count > 1 ? " per day" : ""
    }

    private var saveButtonTitle: String {
        showsGlance ? "Save · \(formatHours(breakdown.totalHours))h paid" : "Save"
    }

    private var customHoursForm: some View {
        let bd = breakdown
        return ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    navyHeader(bd)
                    sheetContent(bd)
                        .padding(.bottom, 24)
                        .ppContentSheet()
                }
            }
            .background(PPColor.page.ignoresSafeArea())

            if let timeValidationBanner {
                timeValidationBannerView(timeValidationBanner)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom) {
            PPBottomActionBar(
                title: saveButtonTitle,
                isEnabled: true,
                accessibilityIdentifier: "operativeCustomHours.save",
                action: { validateAndSave() }
            )
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: timeValidationBanner)
        .onChange(of: weekendBreakdownInput, initial: true) { _, _ in
            refreshWeekendBreakdown()
        }
        .onChange(of: rateFiguresInput, initial: true) { _, _ in
            refreshRateFigures()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .ppNavyNavigationBar()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(PPOnNavyPillButtonStyle())
                    .accessibilityIdentifier("operativeCustomHours.cancel")
            }
            if onDelete != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(PPOnNavyPillButtonStyle(tint: Color(ppHex: 0xFF6B70)))
                    .accessibilityIdentifier("operativeCustomHours.deleteBooking")
                    .accessibilityLabel("Delete booking")
                }
            } else {
                // Hours sheet and other create / no-delete callers (3.5 "Hours sheet"): Cancel and Save in the header,
                // no delete. Same validateAndSave as the bottom bar.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { validateAndSave() }
                        .buttonStyle(PPOnNavyPillButtonStyle())
                        .accessibilityIdentifier("operativeCustomHours.saveTop")
                }
            }
        }
        .confirmationDialog(
            "Delete this booking?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete booking", role: .destructive) {
                onDelete?()
            }
                .accessibilityIdentifier("operativeCustomHours.deleteBooking2")
            Button("Keep booking", role: .cancel) {}
                .accessibilityIdentifier("operativeCustomHours.keepBooking")
        } message: {
            Text("This removes it from the schedule, daily overview, warnings, weekly report, timesheets, and My Schedule.")
        }
        .sheet(isPresented: $showingRateSheet) {
            overtimeRateSheet(bd)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(
            isPresented: Binding(
                get: { breakWarningMessage != nil },
                set: { if !$0 { breakWarningMessage = nil } }
            ),
            onDismiss: runBreakWarningChoice
        ) {
            breakWarningSheet(bd)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Navy header

    private func navyHeader(_ bd: BookingEditHoursBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if timeValidationBanner != nil {
                Color.clear.frame(height: 36)
            }
            headerSection
            if showsGlance {
                PPGlanceHeadline(
                    eyebrow: onDelete != nil || headerName != nil ? "This booking at a glance" : "At a glance",
                    primary: "\(formatHours(bd.totalHours))h paid\(paidPerDaySuffix)",
                    secondary: "\(formatHours(onSiteHours))h on site"
                )
                PPStatRow(items: glanceStats(bd))
            }
            theDayCard
        }
        .padding(.horizontal, PPMetrics.screenGutter)
        .padding(.top, 12)
        .padding(.bottom, PPMetrics.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ppNavyHeader()
    }

    /// Standard `payrollHoursResult.standardHours`; OT `payrollMultipliedHours` (clock hours, and its "× rate = paid"
    /// text); unpaid break `payrollHoursResult.unpaidBreakHours`. Bound, never recalculated here.
    private func glanceStats(_ bd: BookingEditHoursBreakdown) -> [PPStatItem] {
        let multiplied = bd.result.multipliedHours
        let breakHours = bd.result.unpaidBreakHours
        return [
            PPStatItem(id: "standard", value: formatHours(bd.result.standardHours), label: "Standard hrs"),
            PPStatItem(
                id: "overtime",
                value: formatHours(multiplied?.clockHours ?? 0),
                label: "OT",
                detail: multiplied?.text,
                tint: PPColor.warningAmber
            ),
            PPStatItem(
                id: "break",
                value: breakHours > 0.005 ? "−\(formatHours(breakHours))" : "0",
                label: "Unpaid break"
            ),
        ]
    }

    @ViewBuilder
    private var headerSection: some View {
        if let headerName, !headerName.isEmpty {
            HStack(spacing: 12) {
                PPInitialsAvatar(
                    initials: headerInitials ?? PlannerUIInitials.from(headerName),
                    family: .plan,
                    size: 44
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerName)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(PPColor.onNavySecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        } else if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(PPColor.onNavySecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// THE DAY: the times, "· break included", and the existing 24h timeline with its legend.
    private var theDayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            PPOnNavyEyebrow(text: "The day")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(startText) – \(endText)")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if showsBreakIncludedNote {
                    Text("· break included")
                        .font(.subheadline)
                        .foregroundStyle(PPColor.onNavySecondary)
                }
            }
            if endMinutes > startMinutes {
                BookingHoursTimelineBar(
                    policy: policy,
                    referenceDay: referenceDay,
                    startMinutes: startMinutes,
                    endMinutes: endMinutes,
                    breakIncluded: breakIncluded,
                    forceSolidBlue: forceSolidBlueTimeline
                )
                if !forceSolidBlueTimeline {
                    PPTimelineLegend(
                        showsBreak: showsBreakControls && breakApplies && breakIncluded,
                        textColor: PPColor.onNavySecondary
                    )
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(PPColor.onNavyStroke, lineWidth: 0.5)
        )
    }

    private func timeValidationBannerView(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.body)
                .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
    }

    // MARK: Sheet

    private func sheetContent(_ bd: BookingEditHoursBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WeekendBookingNoteView(days: noteDays, policy: policy)
                .padding(.top, 14)
            if !showsBreakControls {
                Label("This user is PAYE and is not paid hourly.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            PPSheetSectionTitle("Hours")
            hoursCard
            if showsBreakControls && breakApplies {
                breakToggleCard
                if showsFooterNote && !breakIncluded {
                    breakRemovedNote
                }
            }
            if showsBreakControls, allowsOtMultiplierOverride, let control = overtimeRateControl, control.show || otRate != nil {
                overtimeRateCard(control)
            }
            if showsBreakdown && !weekendBreakdownLines.isEmpty {
                weekendBreakdownCard
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(PPColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private enum TimeField: Hashable {
        case start, end
    }

    private func toggleTimeField(_ field: TimeField) {
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedTimeField = expandedTimeField == field ? nil : field
        }
    }

    /// Start / End tiles open the existing quarter-hour wheel (same bindings, same start-before-end guard).
    private var hoursCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { toggleTimeField(.start) } label: {
                    PPTimeTileLabel(title: "Start", value: startText, isActive: expandedTimeField == .start)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("operativeCustomHours.startTile")
                .accessibilityHint("Opens the start time picker")
                Button { toggleTimeField(.end) } label: {
                    PPTimeTileLabel(title: "End", value: endText, isActive: expandedTimeField == .end)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("operativeCustomHours.endTile")
                .accessibilityHint("Opens the end time picker")
            }
            if let field = expandedTimeField {
                BookingHMTimePickerColumn(
                    title: field == .start ? "START" : "END",
                    hour: field == .start ? startHourBinding : endHourBinding,
                    minute: field == .start ? startMinuteBinding : endMinuteBinding
                )
                .id(field)
                .transition(.opacity)
            }
        }
        .ppBookingCard(padding: 12)
    }

    private var startHourBinding: Binding<Int> {
        Binding(
            get: { startHour },
            set: { applyStartChange(hour: $0, minute: startMinute) }
        )
    }

    private var startMinuteBinding: Binding<Int> {
        Binding(
            get: { startMinute },
            set: { applyStartChange(hour: startHour, minute: $0) }
        )
    }

    private var endHourBinding: Binding<Int> {
        Binding(
            get: { endHour },
            set: { applyEndChange(hour: $0, minute: endMinute) }
        )
    }

    private var endMinuteBinding: Binding<Int> {
        Binding(
            get: { endMinute },
            set: { applyEndChange(hour: endHour, minute: $0) }
        )
    }

    private func applyStartChange(hour: Int, minute: Int) {
        let candidate = BookingHMTimePickerSupport.minutes(hour: hour, minute: minute)
        if candidate >= endMinutes {
            revertStartToLastValid()
            showTimeBanner("The start time cannot be later than the end time.")
            return
        }
        startHour = hour
        startMinute = minute
        lastValidStartHour = hour
        lastValidStartMinute = minute
    }

    private func applyEndChange(hour: Int, minute: Int) {
        let candidate = BookingHMTimePickerSupport.minutes(hour: hour, minute: minute)
        if candidate <= startMinutes {
            revertEndToLastValid()
            showTimeBanner("The end time cannot be earlier than the start time.")
            return
        }
        endHour = hour
        endMinute = minute
        lastValidEndHour = hour
        lastValidEndMinute = minute
    }

    private func revertStartToLastValid() {
        startHour = lastValidStartHour
        startMinute = lastValidStartMinute
    }

    private func revertEndToLastValid() {
        endHour = lastValidEndHour
        endMinute = lastValidEndMinute
    }

    private func showTimeBanner(_ message: String) {
        timeValidationBanner = message
        bannerDismissTask?.cancel()
        bannerDismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            await MainActor.run {
                if timeValidationBanner == message {
                    timeValidationBanner = nil
                }
            }
        }
    }

    private var breakToggleCard: some View {
        HStack(spacing: 12) {
            PPIconTile(symbol: "cup.and.saucer.fill", family: breakIncluded ? .trade : .system, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unpaid break")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(
                    breakIncluded
                        ? "\(dayBreakMinutes) mins deducted around midday"
                        : "Removed · full hours in total"
                )
                .font(.footnote)
                .foregroundStyle(breakIncluded ? Color.secondary : PPChipTone.amber.ink)
            }
            Spacer(minLength: 8)
            Toggle("Unpaid break", isOn: $breakIncluded)
                .accessibilityIdentifier("operativeCustomHours.toggle")
                .labelsHidden()
        }
        .ppBookingCard(padding: 12)
    }

    /// The old footer's amber note when the unpaid break is removed (same condition, same text).
    private var breakRemovedNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PPBookingColor.overtimeDeep)
            Text("Operative will be paid for the full elapsed hours. This time will be included within the weekly report and invoicing.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(PPChipTone.amber.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPChipTone.amber.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Overtime rate (RULEBOOK 1.29.0 §25 `overtimeRateControl`)

    /// One rate the booking can take: nil = the organisation's (follows a later Org settings change), else a custom
    /// value. The figures come from re-running the existing probe at that rate (`refreshRateFigures`).
    private func rateOption(_ value: Double?, control: OvertimeRateControl) -> OvertimeRateOption {
        OvertimeRateOption(
            value: value,
            title: "×\(ScheduleCoverageFormat.hours(value ?? control.organizationMultiplier))",
            figure: rateFigures[value]
        )
    }

    /// ×1, Org, ×2, ×3 (owner decision 5), plus the booking's own rate when it is none of those.
    private func quickRateOptions(_ control: OvertimeRateControl) -> [OvertimeRateOption] {
        let choices = overtimeRateChoices(control)
        func offered(_ v: Double) -> Bool { choices.contains { abs($0 - v) < 0.0001 } }
        var out: [OvertimeRateOption] = []
        if offered(1) { out.append(rateOption(1, control: control)) }
        out.append(rateOption(nil, control: control))
        if offered(2) { out.append(rateOption(2, control: control)) }
        if offered(3) { out.append(rateOption(3, control: control)) }
        if let current = otRate, !out.contains(where: { $0.matches(current) }) {
            out.append(rateOption(current, control: control))
        }
        return out
    }

    private func overtimeRateCard(_ control: OvertimeRateControl) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Overtime rate")
                    .font(.headline)
                Spacer(minLength: 8)
                Button("More rates") { showingRateSheet = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.brand)
                    .accessibilityIdentifier("operativeCustomHours.overtimeRate")
                    .accessibilityHint("Shows every overtime rate for this booking")
            }
            HStack(spacing: 8) {
                ForEach(quickRateOptions(control)) { option in
                    rateChip(option, isSelected: option.isSelected(otRate))
                }
            }
            Text("Only prices this booking's overtime. Signed timesheets keep their figures.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .ppBookingCard(padding: 12)
    }

    private func rateChip(_ option: OvertimeRateOption, isSelected: Bool) -> some View {
        let caption = rateChipCaption(option)
        return Button {
            otRate = option.value
        } label: {
            VStack(spacing: 2) {
                Text(option.title)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .opacity(0.85)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                isSelected ? PPBookingColor.selected : PPBookingColor.field,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("operativeCustomHours.overtimeRate.\(option.id)")
        .accessibilityLabel(option.value == nil ? "Organisation rate \(option.title)" : "Rate \(option.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The chip's second line: the paid overtime hours at that rate ("6h"), "Org · 6h" on the organisation chip.
    private func rateChipCaption(_ option: OvertimeRateOption) -> String {
        var paid: String? = nil
        if let figure = option.figure, let multiplied = figure.multiplied {
            paid = "\(formatHours(multiplied.paidHours))h"
        }
        if option.value == nil {
            if let paid { return "Org · \(paid)" }
            return "Org default"
        }
        return paid ?? "–"
    }

    /// What the per-rate figures depend on; they are re-run only when it changes (memoised, never per redraw).
    private var rateFiguresInput: String {
        "\(startText)|\(endText)|\(breakIncluded)|\(allowsOtMultiplierOverride)"
    }

    /// Re-runs the existing probe (`OperativeDayBookingChoice.bookingProbe` → `PayrollHoursEngine.compute`, the
    /// rulebook's `payrollHoursResult`) once per offered rate. Nothing is multiplied in the view.
    private func refreshRateFigures() {
        guard allowsOtMultiplierOverride, endMinutes > startMinutes, let control = overtimeRateControl else {
            rateFigures = [:]
            return
        }
        var rates: [Double?] = [nil]
        rates.append(contentsOf: overtimeRateChoices(control).map { Optional($0) })
        var out: [Double?: OvertimeRateFigure] = [:]
        for rate in rates {
            let probe = OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: startText,
                workEndTime: endText,
                isBreakRemoved: !breakIncluded,
                otMultiplierOverride: rate
            ).bookingProbe(operativeId: UUID(), projectId: UUID(), date: referenceDay, bookedBy: "")
            let result = PayrollHoursEngine.compute(booking: probe, day: referenceDay, policy: policy)
            out[rate] = OvertimeRateFigure(
                multiplied: result.multipliedHours,
                totalPaidHours: probe.paidBookedHours(policy: policy)
            )
        }
        rateFigures = out
    }

    /// "This booking has 4h of overtime (16:00 – 20:00)", from the result's multiplied segments.
    private func overtimeSummary(_ bd: BookingEditHoursBreakdown) -> String {
        guard let multiplied = bd.result.multipliedHours, multiplied.clockHours > 0.005 else {
            return "This booking has no overtime at these times."
        }
        let spans = bd.result.segments
            .filter { $0.kind != .standardWindow }
            .compactMap { segment -> String? in
                guard let s = segment.clockStart, let e = segment.clockEnd else { return nil }
                return "\(s) – \(e)"
            }
            .joined(separator: ", ")
        let base = "This booking has \(formatHours(multiplied.clockHours))h of overtime"
        return spans.isEmpty ? base : "\(base) (\(spans))"
    }

    @ViewBuilder
    private func overtimeRateSheet(_ bd: BookingEditHoursBreakdown) -> some View {
        if let control = overtimeRateControl {
            OvertimeRateSheet(
                organization: rateOption(nil, control: control),
                organizationLabel: control.organizationLabel,
                customOptions: overtimeRateChoices(control).map { rateOption($0, control: control) },
                overtimeSummary: overtimeSummary(bd),
                initial: otRate,
                onUse: { picked in
                    otRate = picked
                    showingRateSheet = false
                },
                onClose: { showingRateSheet = false }
            )
        } else {
            Text("Overtime rates are not available for this booking.")
                .padding()
        }
    }

    // MARK: Unpaid break warning (3.7; RULEBOOK 1.13.0 §8 `customHoursBreakWarning`)

    private enum BreakWarningChoice {
        case payFullDay
        case keepBreak
    }

    private func breakWarningSheet(_ bd: BookingEditHoursBreakdown) -> some View {
        // "Pay the full day": the same probe with the unpaid break off (`BookingEditHoursBreakdown.compute`).
        let fullDay = BookingEditHoursBreakdown.compute(
            booking: probeBooking,
            policy: policy,
            day: referenceDay,
            breakIncluded: false
        )
        let range = ScheduleHoursTimelineSupport.breakRange(
            policy: policy,
            day: referenceDay,
            workStart: startMinutes,
            workEnd: endMinutes,
            breakIncluded: true
        )
        let deductedMinutes = Int((bd.result.unpaidBreakHours * 60).rounded())
        return UnpaidBreakWarningSheet(
            message: breakWarningMessage ?? "",
            startText: startText,
            endText: endText,
            workStart: startMinutes,
            workEnd: endMinutes,
            breakStart: range?.0,
            breakEnd: range?.1,
            breakMinutes: deductedMinutes > 0 ? deductedMinutes : dayBreakMinutes,
            payFullDayHours: fullDay.totalHours,
            keepBreakHours: bd.totalHours,
            onPayFullDay: {
                breakWarningChoice = .payFullDay
                breakWarningMessage = nil
            },
            onKeepBreak: {
                breakWarningChoice = .keepBreak
                breakWarningMessage = nil
            },
            onGoBack: {
                breakWarningChoice = nil
                breakWarningMessage = nil
            }
        )
    }

    /// Runs after the warning has gone, as the old alert's buttons did. "Keep the break" is the old "Save anyway";
    /// "Pay the full day" is the Unpaid break toggle switched off and then that same save (both view state only).
    private func runBreakWarningChoice() {
        guard let choice = breakWarningChoice else { return }
        breakWarningChoice = nil
        switch choice {
        case .payFullDay:
            breakIncluded = false
            validateAndSave(breakWarningConfirmed: true)
        case .keepBreak:
            validateAndSave(breakWarningConfirmed: true)
        }
    }

    /// What the weekend rows depend on; they are recomputed only when it changes.
    private var weekendBreakdownInput: String {
        "\(startText)|\(endText)|\(breakIncluded)|\(otRate.map { String($0) } ?? "org")"
    }

    /// RULEBOOK 1.18.0 §4.3 `weekendBookingBreakdown`: per-day rows for a selection with a Saturday or Sunday (not when
    /// the times are not a valid same-day window). `weekendBookingBreakdown` takes no overtime multiplier override, so
    /// with one typed the rows stay (priced at the organisation's multiplier) and `overrideNote` says so.
    private func refreshWeekendBreakdown() {
        guard endMinutes > startMinutes else {
            weekendBreakdownLines = []
            return
        }
        weekendBreakdownLines = CanonicalBusinessEngine.collapsedBreakdownLines(
            CanonicalBusinessEngine.weekendBookingBreakdown(
                on: noteDays,
                start: startText,
                end: endText,
                isBreakRemoved: !breakIncluded,
                fallbackPolicy: policy
            )
        )
    }

    private var weekendBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            WeekendBookingBreakdownView(lines: weekendBreakdownLines, title: "Breakdown")
            if let override = resolvedOtMultiplierOverride {
                // 1.18 gap: the per-day rows are the organisation's rule; the typed rate applies to this booking.
                Text("Rows show the organisation rate. This booking's overtime hours are paid at ×\(ScheduleCoverageFormat.hours(override)) instead.")
                    .font(.footnote)
                    .foregroundStyle(PPChipTone.amber.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("operativeCustomHours.overrideNote")
            }
        }
    }

    private func validateAndSave(breakWarningConfirmed: Bool = false) {
        errorMessage = nil
        guard endMinutes > startMinutes else {
            errorMessage = "Choose an end time after the start time."
            return
        }
        // RULEBOOK 1.13.0 §8 `customHoursBreakWarning`: confirm before saving custom hours that cover the unpaid break
        // while Unpaid break is on. Pay is unchanged either way.
        if showsBreakControls && breakApplies && !breakWarningConfirmed,
           let warning = CanonicalBusinessEngine.customHoursBreakWarning(
               on: rulebookDay,
               policy: policy,
               workStartTime: startText,
               workEndTime: endText,
               isBreakRemoved: !breakIncluded
           ) {
            breakWarningMessage = warning
            return
        }
        var otOut: Double? = nil
        if allowsOtMultiplierOverride {
            // RULEBOOK 1.29.0 §25 `overtimeMultiplierValidationError`: 1–3 in 0.25 steps, or the organisation's (nil).
            if otRate != initialOtRate, let message = CanonicalBusinessEngine.overtimeMultiplierValidationError(otRate) {
                errorMessage = message
                return
            }
            otOut = otRate
        }
        onSave(startText, endText, !breakIncluded, otOut)
    }
}

// MARK: - Overtime rate sheet (docs/design/booking-ui 3.6)

/// The figures of one rate, read from the probe re-run at that rate: `payrollMultipliedHours` (clock hours → paid
/// hours) and the booking's paid total.
private struct OvertimeRateFigure: Equatable {
    let multiplied: RulebookMultipliedHours?
    let totalPaidHours: Double
}

/// One overtime rate: nil `value` is the organisation's rate (stored as no override), anything else a custom rate.
/// The organisation rate and an equal custom value stay two different options.
private struct OvertimeRateOption: Identifiable {
    let value: Double?
    let title: String
    let figure: OvertimeRateFigure?

    var id: String { value.map { "custom-\($0)" } ?? "org" }

    func matches(_ rate: Double) -> Bool {
        guard let value else { return false }
        return abs(value - rate) < 0.0001
    }

    func isSelected(_ current: Double?) -> Bool {
        guard let current else { return value == nil }
        return matches(current)
    }

    /// "4h → 6h" (overtime clock hours → paid hours at this rate).
    var figureLine: String {
        guard let figure, let multiplied = figure.multiplied, multiplied.clockHours > 0.005 else { return "No overtime" }
        return "\(ScheduleCoverageFormat.hours(multiplied.clockHours))h → \(ScheduleCoverageFormat.hours(multiplied.paidHours))h"
    }
}

/// Every rate the old menu offered: the organisation rate, then each custom step (and an older stored rate).
/// "Use" sets the same `otMultiplierOverride` value the old Picker set.
private struct OvertimeRateSheet: View {
    let organization: OvertimeRateOption
    let organizationLabel: String
    let customOptions: [OvertimeRateOption]
    let overtimeSummary: String
    let onUse: (Double?) -> Void
    let onClose: () -> Void

    @State private var picked: Double?

    init(
        organization: OvertimeRateOption,
        organizationLabel: String,
        customOptions: [OvertimeRateOption],
        overtimeSummary: String,
        initial: Double?,
        onUse: @escaping (Double?) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.organization = organization
        self.organizationLabel = organizationLabel
        self.customOptions = customOptions
        self.overtimeSummary = overtimeSummary
        self.onUse = onUse
        self.onClose = onClose
        _picked = State(initialValue: initial)
    }

    private var pickedOption: OvertimeRateOption {
        guard let picked else { return organization }
        return customOptions.first { $0.matches(picked) } ?? organization
    }

    private var useTitle: String {
        let option = pickedOption
        if let total = option.figure?.totalPaidHours {
            return "Use \(option.title) · \(ScheduleCoverageFormat.hours(total))h paid"
        }
        return "Use \(option.title)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        PPIconTile(symbol: "bolt.fill", family: .trade, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Overtime rate")
                                .font(.system(.title3, design: .rounded))
                                .fontWeight(.bold)
                            Text(overtimeSummary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, height: 30)
                                .background(PPColor.well, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("operativeCustomHours.rateSheet.close")
                    }

                    organisationCard

                    Text("OR A CUSTOM RATE FOR THIS BOOKING")
                        .font(.footnote.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(customOptions) { option in
                            customCell(option)
                        }
                    }

                    Label("Signed timesheets keep their figures. Only this booking is re-priced.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PPMetrics.screenGutter)
                .padding(.top, 8)
            }
            PPBottomActionBar(
                title: useTitle,
                isEnabled: true,
                accessibilityIdentifier: "operativeCustomHours.rateSheet.use",
                action: { onUse(picked) }
            )
        }
        .background(PPColor.page.ignoresSafeArea())
    }

    private var organisationCard: some View {
        let selected = picked == nil
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            picked = nil
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(organizationLabel)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("From Org settings · follows any future change")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(organization.figureLine)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(PPChipTone.amber.ink)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? PPColor.brand : Color.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PPColor.card, in: shape)
            .overlay(shape.strokeBorder(selected ? PPColor.brand : PPBookingColor.cardBorder, lineWidth: selected ? 1.5 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("operativeCustomHours.rateSheet.org")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func customCell(_ option: OvertimeRateOption) -> some View {
        let selected = option.isSelected(picked) && picked != nil
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            picked = option.value
        } label: {
            VStack(spacing: 3) {
                Text(option.title)
                    .font(.headline)
                    .monospacedDigit()
                Text(option.figureLine)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .opacity(0.85)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(selected ? PPBookingColor.selected : PPColor.card, in: shape)
            .overlay(shape.strokeBorder(PPBookingColor.cardBorder, lineWidth: selected ? 0 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("operativeCustomHours.rateSheet.\(option.id)")
        .accessibilityLabel("Rate \(option.title), \(option.figureLine)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Unpaid break warning sheet (docs/design/booking-ui 3.7)

/// Replaces the "Unpaid break" alert. The body is the rulebook's `customHoursBreakWarning` text; the buttons only
/// report the choice, and the sheet's owner runs it once this sheet has gone (as the old alert did).
private struct UnpaidBreakWarningSheet: View {
    let message: String
    let startText: String
    let endText: String
    let workStart: Int
    let workEnd: Int
    let breakStart: Int?
    let breakEnd: Int?
    let breakMinutes: Int
    let payFullDayHours: Double
    let keepBreakHours: Double
    let onPayFullDay: () -> Void
    let onKeepBreak: () -> Void
    let onGoBack: () -> Void

    private func clock(_ minutes: Int) -> String {
        BookingHMTimePickerSupport.format(hour: minutes / 60, minute: minutes % 60)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PPIconTile(symbol: "exclamationmark.triangle.fill", family: .alert, size: 44, lifted: true)
                Text("HEADS UP")
                    .font(.caption.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(PPColor.danger)
                Text("This booking runs through lunch")
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.bold)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                miniTimeline

                Button(action: onPayFullDay) {
                    choiceLabel(
                        title: "Pay the full day",
                        subtitle: "Turns off the unpaid break for this booking",
                        hours: payFullDayHours,
                        prominent: true
                    )
                }
                .buttonStyle(PPPressableButtonStyle())
                .accessibilityIdentifier("operativeCustomHours.breakWarning.payFullDay")

                Button(action: onKeepBreak) {
                    choiceLabel(
                        title: "Keep the break",
                        subtitle: "\(breakMinutes) mins deducted, as set",
                        hours: keepBreakHours,
                        prominent: false
                    )
                }
                .buttonStyle(PPPressableButtonStyle())
                .accessibilityIdentifier("operativeCustomHours.breakWarning.save")

                Button(action: onGoBack) {
                    Text("Go back and change the hours")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PPColor.brand)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("operativeCustomHours.breakWarning.back")
            }
            .padding(PPMetrics.screenGutter)
            .padding(.top, 10)
        }
        .background(PPColor.page.ignoresSafeArea())
    }

    /// Navy strip: the booked span with the unpaid-break span (`ScheduleHoursTimelineSupport.breakRange`) in red.
    private var miniTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            PPOnNavyEyebrow(text: "The day")
            GeometryReader { geo in
                let width = geo.size.width
                let span = CGFloat(max(1, workEnd - workStart))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    if let breakStart, let breakEnd, breakEnd > breakStart {
                        let left = CGFloat(breakStart - workStart) / span * width
                        let w = max(4, CGFloat(breakEnd - breakStart) / span * width)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(ppHex: 0xFF5A60))
                            .frame(width: w)
                            .offset(x: left)
                    }
                }
            }
            .frame(height: 12)
            HStack {
                Text(startText)
                Spacer(minLength: 8)
                if let breakStart, let breakEnd {
                    Text("\(clock(breakStart)) – \(clock(breakEnd)) unpaid")
                        .foregroundStyle(Color(ppHex: 0xFF8A8F))
                }
                Spacer(minLength: 8)
                Text(endText)
            }
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
        }
        .padding(14)
        .background(PPNavyBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func choiceLabel(title: String, subtitle: String, hours: Double, prominent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.footnote)
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text("\(ScheduleCoverageFormat.hours(hours))h")
                .font(.headline)
                .monospacedDigit()
        }
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background {
            if prominent {
                shape.fill(PPBookingColor.primaryGradient)
            } else {
                shape.fill(PPColor.card)
            }
        }
        .overlay(shape.strokeBorder(prominent ? Color.clear : PPBookingColor.cardBorder, lineWidth: 0.5))
        .contentShape(shape)
    }
}
