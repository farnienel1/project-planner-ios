//
//  BookingHoursEditSheet.swift
//  Project Planner
//
//  Shared edit-booking UI (daily overview, project schedule, schedule operative).
//

import SwiftUI

// MARK: - Time helpers

enum BookingHMTimePickerSupport {
    static let minuteChoices = [0, 30]
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

    static func clampToHalfHour(_ hhmm: String, fallbackHour: Int, fallbackMinute: Int) -> (hour: Int, minute: Int) {
        if let p = parse(hhmm) { return p }
        let m = minuteChoices.min(by: { abs($0 - fallbackMinute) < abs($1 - fallbackMinute) }) ?? 0
        return (fallbackHour, m)
    }
}

struct BookingEditHoursBreakdown {
    let totalHours: Double
    let standardRateHours: Double
    let overtimeHours: Double
    let overtimeMultiplier: Double
    let breakDeductionHours: Double
    let showsBreakLine: Bool

    static func compute(
        booking: Booking,
        policy: OrgPayrollTimePolicy,
        breakIncluded: Bool
    ) -> BookingEditHoursBreakdown {
        var probe = booking
        probe.isBreakRemoved = !breakIncluded
        let elapsed = probe.totalBookedHours(policy: policy)
        let total = probe.paidBookedHours(policy: policy)
        let insideStandard = OperativeBookingInterval.hoursInsideStandardClockWindow(booking: probe, policy: policy)
        let outsideStandard = max(0, elapsed - insideStandard)
        let ot = outsideStandard > 0.05 ? outsideStandard : probe.overtimeHoursBeyondPaidStandard(policy: policy)
        let standardRate = outsideStandard > 0.05 ? insideStandard : elapsed
        let breakH = (breakIncluded && policy.standardUnpaidBreakHours > 0.05) ? policy.standardUnpaidBreakHours : 0
        return BookingEditHoursBreakdown(
            totalHours: total,
            standardRateHours: standardRate,
            overtimeHours: ot,
            overtimeMultiplier: probe.effectiveWeekdayOtMultiplier(policy: policy),
            breakDeductionHours: breakH,
            showsBreakLine: breakH > 0.05
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
        startMinutes: Int,
        endMinutes: Int
    ) -> [BookingTimelineSegment] {
        guard endMinutes > startMinutes else { return [] }
        guard let ds = ManagerScheduleInterval.parseMinutes(policy.standardDayStart),
              let de = ManagerScheduleInterval.parseMinutes(policy.standardDayEnd),
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
        startMinutes: Int,
        endMinutes: Int,
        breakIncluded: Bool
    ) -> (Int, Int)? {
        guard breakIncluded,
              let ds = ManagerScheduleInterval.parseMinutes(policy.standardDayStart),
              let de = ManagerScheduleInterval.parseMinutes(policy.standardDayEnd) else { return nil }
        let breakCenter = (ds + de) / 2
        let breakHalf = max(1, Int(policy.standardUnpaidBreakHours * 30))
        let b0 = max(startMinutes, breakCenter - breakHalf)
        let b1 = min(endMinutes, breakCenter + breakHalf)
        guard b1 > b0 else { return nil }
        return (b0, b1)
    }
}

private struct BookingHoursTimelineBar: View {
    let policy: OrgPayrollTimePolicy
    let startMinutes: Int
    let endMinutes: Int
    let breakIncluded: Bool

    private var segments: [BookingTimelineSegment] {
        BookingHoursTimelineLayout.segments(policy: policy, startMinutes: startMinutes, endMinutes: endMinutes)
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 0.949, green: 0.953, blue: 0.961))

                    if let ds = ManagerScheduleInterval.parseMinutes(policy.standardDayStart),
                       let de = ManagerScheduleInterval.parseMinutes(policy.standardDayEnd), de > ds {
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
                            if seg.kind == .overtime, barW > 22 {
                                Text("OT")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                                    .padding(.leading, 5)
                            } else if seg.kind == .standard, barW > 44 {
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
                    Color(red: 0.98, green: 0.933, blue: 0.855),
                    Color(red: 0.96, green: 0.88, blue: 0.72),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

// MARK: - Wheel time picker

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
                Picker("", selection: $hour) {
                    ForEach(Array(BookingHMTimePickerSupport.hourRange), id: \.self) { h in
                        Text(String(format: "%02d", h)).tag(h)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()

                Text(":")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)

                Picker("", selection: $minute) {
                    ForEach(BookingHMTimePickerSupport.minuteChoices, id: \.self) { m in
                        Text(String(format: "%02d", m)).tag(m)
                    }
                }
                .pickerStyle(.wheel)
                .frame(width: 56)
                .clipped()
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
    var title: String
    var subtitle: String?
    var headerName: String?
    var headerInitials: String?
    var allowsOtMultiplierOverride: Bool
    let initialChoice: OperativeDayBookingChoice?
    let onSave: (String, String, Bool, Double?) -> Void
    let onCancel: () -> Void

    @State private var startHour: Int
    @State private var startMinute: Int
    @State private var endHour: Int
    @State private var endMinute: Int
    @State private var lastValidStartHour: Int
    @State private var lastValidStartMinute: Int
    @State private var lastValidEndHour: Int
    @State private var lastValidEndMinute: Int
    @State private var breakIncluded: Bool
    @State private var otMultText: String
    @State private var errorMessage: String?
    @State private var timeValidationBanner: String?
    @State private var bannerDismissTask: Task<Void, Never>?

    init(
        policy: OrgPayrollTimePolicy,
        title: String = "Edit booking",
        subtitle: String? = nil,
        headerName: String? = nil,
        headerInitials: String? = nil,
        allowsOtMultiplierOverride: Bool = false,
        initialChoice: OperativeDayBookingChoice?,
        onSave: @escaping (String, String, Bool, Double?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.policy = policy
        self.title = title
        self.subtitle = subtitle
        self.headerName = headerName
        self.headerInitials = headerInitials
        self.allowsOtMultiplierOverride = allowsOtMultiplierOverride
        self.initialChoice = initialChoice
        self.onSave = onSave
        self.onCancel = onCancel

        let ic = initialChoice
        let startHM: (Int, Int)
        let endHM: (Int, Int)
        let included: Bool
        var otm = ""

        if let ic {
            let s = ic.workStartTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let e = ic.workEndTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !s.isEmpty, !e.isEmpty {
                startHM = BookingHMTimePickerSupport.clampToHalfHour(s, fallbackHour: 8, fallbackMinute: 0)
                endHM = BookingHMTimePickerSupport.clampToHalfHour(e, fallbackHour: 16, fallbackMinute: 30)
            } else {
                startHM = BookingHMTimePickerSupport.clampToHalfHour(
                    policy.standardDayStart,
                    fallbackHour: 8,
                    fallbackMinute: 0
                )
                endHM = BookingHMTimePickerSupport.clampToHalfHour(
                    policy.standardDayEnd,
                    fallbackHour: 16,
                    fallbackMinute: 30
                )
            }
            included = !ic.isBreakRemoved
            if let m = ic.otMultiplierOverride {
                otm = abs(m - m.rounded()) < 0.05 ? String(format: "%.0f", m) : String(format: "%.1f", m)
            }
        } else {
            startHM = BookingHMTimePickerSupport.clampToHalfHour(
                policy.standardDayStart,
                fallbackHour: 8,
                fallbackMinute: 0
            )
            endHM = BookingHMTimePickerSupport.clampToHalfHour(
                policy.standardDayEnd,
                fallbackHour: 16,
                fallbackMinute: 30
            )
            included = true
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
        _otMultText = State(initialValue: otm)
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
        let t = otMultText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        return Double(t.replacingOccurrences(of: ",", with: "."))
    }

    private var probeBooking: Booking {
        OperativeDayBookingChoice(
            timeSlot: .customHours,
            workStartTime: startText,
            workEndTime: endText,
            isBreakRemoved: !breakIncluded,
            otMultiplierOverride: resolvedOtMultiplierOverride
        ).bookingProbe(operativeId: UUID(), projectId: UUID(), date: Date(), bookedBy: "")
    }

    private var breakdown: BookingEditHoursBreakdown {
        BookingEditHoursBreakdown.compute(
            booking: probeBooking,
            policy: policy,
            breakIncluded: breakIncluded
        )
    }

    private func formatHours(_ h: Double) -> String {
        ScheduleCoverageFormat.hours(h)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if timeValidationBanner != nil {
                            Color.clear.frame(height: 44)
                        }
                        headerSection
                        hoursCard
                        breakToggleCard
                        breakdownCard
                        footerNoteCard
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                }
                .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())

                if let timeValidationBanner {
                    timeValidationBannerView(timeValidationBanner)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: timeValidationBanner)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { validateAndSave() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        if let headerName, !headerName.isEmpty {
            HStack(spacing: 10) {
                Text(headerInitials ?? PlannerUIInitials.from(headerName))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white)
                    .frame(width: 32, height: 32)
                    .background(
                        LinearGradient(
                            colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
            )
        } else if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .padding(.horizontal, 4)
        }
    }

    private func timeValidationBannerView(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 2)
    }

    private var hoursCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOURS")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .tracking(0.4)
                .padding(.leading, 4)

            HStack(spacing: 8) {
                BookingHMTimePickerColumn(
                    title: "START",
                    hour: startHourBinding,
                    minute: startMinuteBinding
                )
                BookingHMTimePickerColumn(
                    title: "END",
                    hour: endHourBinding,
                    minute: endMinuteBinding
                )
            }

            if endMinutes > startMinutes {
                BookingHoursTimelineBar(
                    policy: policy,
                    startMinutes: startMinutes,
                    endMinutes: endMinutes,
                    breakIncluded: breakIncluded
                )
            }
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(breakIncluded ? Color(red: 0.98, green: 0.933, blue: 0.855) : Color(red: 0.949, green: 0.953, blue: 0.961))
                        .frame(width: 32, height: 32)
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(breakIncluded ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.muted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unpaid break")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    Text(
                        breakIncluded
                            ? "\(policy.unpaidBreakMinutes) mins deducted around midday"
                            : "Removed · full hours in total"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(breakIncluded ? ProjectWorksRevampColors.muted : ProjectWorksRevampColors.endDateFg)
                }
                Spacer()
                Toggle("", isOn: $breakIncluded)
                    .labelsHidden()
            }

            if allowsOtMultiplierOverride {
                Divider().overlay(ProjectWorksRevampColors.border)
                VStack(alignment: .leading, spacing: 4) {
                    Text("OVERTIME MULTIPLIER")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .tracking(0.4)
                    TextField(
                        "Optional — e.g. \(String(format: "%.1f", policy.weekdayOutsideStandardMultiplier))",
                        text: $otMultText
                    )
                    .font(.system(size: 15, weight: .medium))
                    .keyboardType(.decimalPad)
                    Text("Hours outside \(policy.standardDayStart)–\(policy.standardDayEnd). Leave blank for org default.")
                        .font(.system(size: 10))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }
            }
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    private var breakdownCard: some View {
        let bd = breakdown
        let multStr = abs(bd.overtimeMultiplier - bd.overtimeMultiplier.rounded()) < 0.05
            ? String(format: "%.0f", bd.overtimeMultiplier)
            : String(format: "%.1f", bd.overtimeMultiplier)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Breakdown")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    Text("\(formatHours(bd.totalHours))h")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                }
            }

            Divider().overlay(ProjectWorksRevampColors.border)

            HStack {
                Text("Standard rate")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.blue)
                Spacer()
                Text("\(formatHours(bd.standardRateHours))h · 1×")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.blue)
            }

            if bd.overtimeHours > 0.05 {
                HStack {
                    Text("Overtime")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                    Spacer()
                    Text("\(formatHours(bd.overtimeHours))h × \(multStr)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                }
            }

            if bd.showsBreakLine {
                HStack {
                    Text("Break")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.82, green: 0.24, blue: 0.24))
                    Spacer()
                    Text("−\(formatHours(bd.breakDeductionHours))h")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.82, green: 0.24, blue: 0.24))
                }
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var footerNoteCard: some View {
        if breakIncluded {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                Text("The break is included within this booking.")
                    .font(.system(size: 10))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProjectWorksRevampColors.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                Text("Operative will be paid for the full elapsed hours. This time will be included within the weekly report and invoicing.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.98, green: 0.933, blue: 0.855))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func validateAndSave() {
        errorMessage = nil
        guard endMinutes > startMinutes else {
            errorMessage = "Choose an end time after the start time."
            return
        }
        var otOut: Double? = nil
        if allowsOtMultiplierOverride {
            let raw = otMultText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                let normalized = raw.replacingOccurrences(of: ",", with: ".")
                guard let v = Double(normalized), v >= 1.0, v <= 10.0 else {
                    errorMessage = "OT multiplier must be between 1 and 10 (or leave blank for org default)."
                    return
                }
                otOut = v
            }
        }
        onSave(startText, endText, !breakIncluded, otOut)
    }
}
