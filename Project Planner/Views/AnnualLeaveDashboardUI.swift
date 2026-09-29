//
//  AnnualLeaveDashboardUI.swift
//  Project Planner
//
//  Shared presentation for annual leave. Booking rules stay in the existing stores.
//

import SwiftUI

enum AnnualLeavePalette {
    static let leave = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.878, 0.271, 0.494),
        dark: AppAdaptiveColor.rgb(0.941, 0.416, 0.604)
    )
    static let leaveTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.988, 0.910, 0.941),
        dark: AppAdaptiveColor.rgb(0.227, 0.082, 0.149)
    )
    static let approved = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.055, 0.663, 0.486),
        dark: AppAdaptiveColor.rgb(0.231, 0.796, 0.596)
    )
    static let approvedTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.882, 0.969, 0.937),
        dark: AppAdaptiveColor.rgb(0.067, 0.196, 0.165)
    )
    static let amber = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.788, 0.518, 0.000),
        dark: AppAdaptiveColor.rgb(0.961, 0.725, 0.227)
    )
    static let amberTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.988, 0.953, 0.855),
        dark: AppAdaptiveColor.rgb(0.227, 0.173, 0.047)
    )
    static let violet = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.478, 0.357, 0.941),
        dark: AppAdaptiveColor.rgb(0.655, 0.545, 1.000)
    )
    static let violetTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.933, 0.918, 0.996),
        dark: AppAdaptiveColor.rgb(0.141, 0.110, 0.290)
    )
    static let blue = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.145, 0.388, 0.788),
        dark: AppAdaptiveColor.rgb(0.298, 0.545, 0.902)
    )
    static let ink = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.055, 0.090, 0.149),
        dark: AppAdaptiveColor.rgb(0.918, 0.941, 0.973)
    )
    static let ink2 = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.275, 0.333, 0.420),
        dark: AppAdaptiveColor.rgb(0.686, 0.733, 0.808)
    )
    static let ink3 = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.478, 0.529, 0.608),
        dark: AppAdaptiveColor.rgb(0.494, 0.549, 0.647)
    )
    static let soft = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.933, 0.953, 0.976),
        dark: AppAdaptiveColor.rgb(0.090, 0.133, 0.220)
    )
    static let card = AppAdaptiveColor.dynamic(
        light: .white,
        dark: AppAdaptiveColor.rgb(0.075, 0.110, 0.180)
    )
    static let line = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.886, 0.910, 0.949),
        dark: AppAdaptiveColor.rgb(0.141, 0.192, 0.294)
    )
    static let red = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.827, 0.271, 0.247),
        dark: AppAdaptiveColor.rgb(1.000, 0.420, 0.420)
    )
    static let redTint = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.984, 0.910, 0.906),
        dark: AppAdaptiveColor.rgb(0.239, 0.090, 0.090)
    )
}

enum AnnualLeaveDayVisual: Equatable {
    case none
    case approvedFull
    case approvedHalf
    case pending
    case bankHoliday
    case weekend
}

enum AnnualLeaveDateFormat {
    static func dayCount(_ value: Double) -> String {
        let formatted = AnnualLeavePolicy.formatAllowanceDays(value)
        let unit = abs(value - 1) < 0.001 ? "day" : "days"
        return "\(formatted) \(unit)"
    }

    static func singleDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }

    static func bookingTitle(_ booking: HolidayBooking, calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: booking.startDate)
        let end = calendar.startOfDay(for: booking.endDate)
        if calendar.isDate(start, inSameDayAs: end) {
            var title = singleDay(start)
            if booking.timeSlot != .fullDay {
                title += " · \(booking.timeSlot.rawValue)"
            }
            return title
        }
        let startText = singleDay(start)
        let endText = singleDay(end)
        let days = consumedDays(from: start, to: end, slot: booking.timeSlot, calendar: calendar)
        return "\(startText) – \(endText) · \(dayCount(days))"
    }

    static func consumedDays(from start: Date, to end: Date, slot: HolidayTimeSlot, calendar: Calendar = .current) -> Double {
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        var count = 0
        while day <= last {
            count += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return Double(count) * slot.dayValue
    }

    /// Collapses consecutive per-day records of the same status and portion for display only.
    static func displaySpans(from bookings: [HolidayBooking], calendar: Calendar = .current) -> [AnnualLeaveDisplaySpan] {
        let sorted = bookings.sorted { $0.startDate < $1.startDate }
        var spans: [AnnualLeaveDisplaySpan] = []
        for booking in sorted {
            if var last = spans.last,
               last.canMerge(booking, calendar: calendar) {
                last.bookings.append(booking)
                spans[spans.count - 1] = last
            } else {
                spans.append(AnnualLeaveDisplaySpan(bookings: [booking]))
            }
        }
        return spans
    }
}

struct AnnualLeaveDisplaySpan: Identifiable {
    var bookings: [HolidayBooking]

    var id: String { bookings.map(\.id.uuidString).joined(separator: "-") }

    var primary: HolidayBooking { bookings[0] }

    var dayTotal: Double {
        bookings.reduce(0) { partial, booking in
            partial + AnnualLeaveDateFormat.consumedDays(from: booking.startDate, to: booking.endDate, slot: booking.timeSlot)
        }
    }

    var title: String {
        let calendar = Calendar.current
        guard let first = bookings.first, let last = bookings.last else { return "" }
        if bookings.count == 1 {
            return AnnualLeaveDateFormat.bookingTitle(first, calendar: calendar)
        }
        let sameSlot = bookings.allSatisfy { $0.timeSlot == first.timeSlot }
        let start = AnnualLeaveDateFormat.singleDay(first.startDate)
        let end = AnnualLeaveDateFormat.singleDay(last.endDate)
        var title = "\(start) – \(end) · \(AnnualLeaveDateFormat.dayCount(dayTotal))"
        if sameSlot, first.timeSlot != .fullDay {
            title += " · \(first.timeSlot.rawValue)"
        }
        return title
    }

    func canMerge(_ next: HolidayBooking, calendar: Calendar) -> Bool {
        guard let last = bookings.last else { return false }
        guard last.status == next.status,
              last.timeSlot == next.timeSlot,
              (last.cancellationRequestedAt == nil) == (next.cancellationRequestedAt == nil) else { return false }
        let lastEnd = calendar.startOfDay(for: last.endDate)
        let nextStart = calendar.startOfDay(for: next.startDate)
        guard let following = calendar.date(byAdding: .day, value: 1, to: lastEnd) else { return false }
        return calendar.isDate(following, inSameDayAs: nextStart)
    }
}

struct AnnualLeaveLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            item(AnnualLeavePalette.approved, "Approved")
            halfItem("Half day")
            item(AnnualLeavePalette.amber, "Pending", bordered: true)
            item(AnnualLeavePalette.violet, "Bank holiday")
            item(AnnualLeavePalette.soft, "Weekend")
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(AnnualLeavePalette.ink2)
    }

    private func item(_ color: Color, _ title: String, bordered: Bool = false) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color)
                .frame(width: 13, height: 13)
                .overlay {
                    if bordered {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(AnnualLeavePalette.amber, lineWidth: 1.5)
                    }
                }
            Text(title)
        }
    }

    private func halfItem(_ title: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AnnualLeavePalette.approved, AnnualLeavePalette.approvedTint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 13, height: 13)
            Text(title)
        }
    }
}

struct AnnualLeaveDayFace: View {
    let dayNumber: Int
    let visual: AnnualLeaveDayVisual
    var isSelected: Bool = false
    var isToday: Bool = false
    var initials: String? = nil
    var accessibilityLabel: String = ""

    var body: some View {
        ZStack {
            background
            Text("\(dayNumber)")
                .font(.body.weight(.semibold))
                .foregroundStyle(numberColor)
            if visual == .bankHoliday && !isSelected {
                Circle()
                    .fill(AnnualLeavePalette.violet)
                    .frame(width: 5, height: 5)
                    .offset(y: 14)
            }
            if let initials, !initials.isEmpty, !isSelected {
                Text(initials)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(AnnualLeavePalette.ink2)
                    .offset(y: 14)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44)
        .overlay {
            if isToday && !isSelected {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(AnnualLeavePalette.ink3, lineWidth: 2.5)
            }
            if visual == .pending && !isSelected {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(AnnualLeavePalette.amber, lineWidth: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(AnnualLeavePalette.blue)
                .shadow(color: AnnualLeavePalette.blue.opacity(0.35), radius: 6, y: 3)
        } else {
            switch visual {
            case .approvedFull:
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(AnnualLeavePalette.approved)
            case .approvedHalf:
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: AnnualLeavePalette.approved, location: 0.5),
                                .init(color: AnnualLeavePalette.approvedTint, location: 0.5)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            case .pending:
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(AnnualLeavePalette.amberTint)
            case .bankHoliday:
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(AnnualLeavePalette.violetTint)
            case .weekend:
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(AnnualLeavePalette.soft)
            case .none:
                Color.clear
            }
        }
    }

    private var numberColor: Color {
        if isSelected { return .white }
        switch visual {
        case .approvedFull, .approvedHalf: return .white
        case .pending: return AnnualLeavePalette.amber
        case .bankHoliday: return AnnualLeavePalette.violet
        case .weekend: return AnnualLeavePalette.ink3
        case .none: return AnnualLeavePalette.ink
        }
    }
}

struct AnnualLeaveBalanceHero: View {
    let summary: AnnualLeaveUsageSummary
    var pendingCaption: String = "Yours awaiting approval"

    private var remainingIsOver: Bool { summary.remainingDays < -0.001 }

    private var ringFraction: Double {
        guard summary.entitlementDays > 0 else { return 0 }
        return min(1, max(0, (summary.takenDays + summary.pendingDays) / summary.entitlementDays))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary.leaveYearLabel)
                .font(.footnote.weight(.heavy))
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.2))
                .clipShape(Capsule())
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AnnualLeavePolicy.formatAllowanceDays(summary.remainingDays))
                        .font(.largeTitle.weight(.heavy))
                        .foregroundStyle(remainingIsOver ? AnnualLeavePalette.redTint : .white)
                    Text(remainingIsOver ? "day over" : "days left")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.28), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: ringFraction)
                        .stroke(style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .foregroundStyle(.white)
                    Text(AnnualLeavePolicy.formatAllowanceDays(summary.takenDays))
                        .font(.subheadline.weight(.heavy))
                        .dynamicTypeSize(.xSmall ... .accessibility1)
                }
                .frame(width: 86, height: 86)
                .accessibilityLabel("\(AnnualLeavePolicy.formatAllowanceDays(summary.takenDays)) days taken")
            }
            HStack(spacing: 8) {
                tile("Taken", summary.takenDays)
                tile(pendingCaption, summary.pendingDays)
                tile("Allowance", summary.entitlementDays)
            }
            if summary.carryOverDays > 0.001 {
                Text("Includes \(AnnualLeavePolicy.formatAllowanceDays(summary.carryOverDays)) carried forward")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [AnnualLeavePalette.leave, AnnualLeavePalette.leave.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func tile(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AnnualLeavePolicy.formatAllowanceDays(value))
                .font(.title3.weight(.heavy))
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.17))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

struct FlowDayChips: View {
    let days: [Date]
    let slots: [Date: HolidayTimeSlot]
    let onSlot: (Date, HolidayTimeSlot) -> Void
    let onRemove: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(days, id: \.self) { day in
                HStack(spacing: 8) {
                    Text(AnnualLeaveDateFormat.singleDay(day))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AnnualLeavePalette.blue)
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        slotButton(day, .fullDay, "Full")
                        slotButton(day, .morning, "AM")
                        slotButton(day, .afternoon, "PM")
                    }
                    .padding(2)
                    .background(AnnualLeavePalette.card)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Button {
                        onRemove(day)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(AnnualLeavePalette.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
    }

    private func slotButton(_ day: Date, _ slot: HolidayTimeSlot, _ title: String) -> some View {
        let on = (slots[day] ?? .fullDay) == slot
        return Button {
            onSlot(day, slot)
        } label: {
            Text(title)
                .font(.caption2.weight(.heavy))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(on ? AnnualLeavePalette.blue : Color.clear)
                .foregroundStyle(on ? Color.white : AnnualLeavePalette.ink3)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

func notifyAnnualLeavePeerManagers(
    request: HolidayBooking,
    actorUserId: String,
    actorName: String,
    actionVerb: String,
    users: [AppUser],
    operatives: [Operative],
    notificationService: NotificationService
) async {
    let requester: AppUser? = {
        if let uid = request.userId {
            return users.first(where: { $0.id == uid })
        }
        if let oid = request.operativeId,
           let op = operatives.first(where: { $0.id == oid }) {
            return users.first(where: { $0.email.lowercased() == op.email.lowercased() })
        }
        return nil
    }()
    guard let requester else { return }
    let peers = requester.lineManagerUserIds.filter { $0 != actorUserId }
    guard !peers.isEmpty else { return }
    let name = requester.fullName.isEmpty ? requester.email : requester.fullName
    let dates = AnnualLeaveDateFormat.bookingTitle(request)
    let subject = request.cancellationRequestedAt != nil ? "annual leave cancellation" : "annual leave request"
    await notificationService.notifyLineManagerPeerAction(
        actorName: actorName,
        actionSummary: dates,
        peerManagerUserIds: peers,
        excludingActorUserId: actorUserId,
        actionVerb: actionVerb,
        message: "\(actorName) \(actionVerb) \(name)'s \(subject). \(dates)"
    )
}

struct AnnualLeaveBankHolidayNote: View {
    let regionName: String
    let loadedCount: Int

    var body: some View {
        Text("Bank holidays: \(regionName). \(loadedCount) dates loaded for this leave year. They never come out of your allowance and cannot be booked.")
            .font(.footnote)
            .foregroundStyle(AnnualLeavePalette.ink2)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AnnualLeavePalette.violetTint)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
