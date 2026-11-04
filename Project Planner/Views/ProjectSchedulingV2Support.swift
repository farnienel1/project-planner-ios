//
//  ProjectSchedulingV2Support.swift
//  Project Planner
//
//  Visual language for project / small-works Scheduling (person × day grid).
//  Design refs: SchedulingView.tsx, scheduling_v2.html
//

import SwiftUI

enum SchedulingV2Palette {
    static let pageBg = ProjectWorksRevampColors.canvas
    static let ink = ProjectWorksRevampColors.ink
    static let muted = ProjectWorksRevampColors.muted
    static let softMuted = ProjectWorksRevampColors.placeholderInk
    static let weekendMute = ProjectWorksRevampColors.placeholderInk
    static let projectCode = ProjectWorksRevampColors.blue
    static let today = ProjectWorksRevampColors.blue
    static let std = Color(red: 0x3B / 255, green: 0x6B / 255, blue: 0xBF / 255)
    static let ot = Color(red: 0x1E / 255, green: 0x3A / 255, blue: 0x7A / 255)
    static let al = Color(red: 0x9A / 255, green: 0x5B / 255, blue: 0x27 / 255)
    static let half = Color(red: 0x5B / 255, green: 0x82 / 255, blue: 0xC7 / 255)
    static let opsBtn = ProjectWorksRevampColors.blue
    static let subsBtn = Color(red: 0x5B / 255, green: 0x3F / 255, blue: 0xA8 / 255)
    static let opsPillBg = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0xEE / 255, 0xF0 / 255, 0xF8 / 255),
        dark: AppAdaptiveColor.rgb(0.145, 0.157, 0.216)
    )
    static let opsPillText = ProjectWorksRevampColors.blue
    static let subsPillBg = ProjectWorksRevampColors.jobTypePillBg
    static let subsPillText = ProjectWorksRevampColors.jobTypePillInk
    static let countHasBg = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0xEE / 255, 0xF3 / 255, 0xFF / 255),
        dark: AppAdaptiveColor.rgb(0.110, 0.173, 0.247)
    )
    static let countTodayBg = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0xD8 / 255, 0xE4 / 255, 0xFF / 255),
        dark: AppAdaptiveColor.rgb(0.133, 0.188, 0.290)
    )
    static let cardBorder = ProjectWorksRevampColors.border
}

enum SchedulingV2CellKind: Equatable {
    case empty
    case standard(hours: Double)
    case overtimeOnly(hours: Double)
    case split(stdHours: Double, otHours: Double)
    case annualLeave
    case halfDay(hours: Double, label: String)
}

enum SchedulingV2CellKindBuilder {
    /// Maps existing booking hours / slot into a display cell. Display-only — does not change booking logic.
    /// `paidHours` is `payrollHoursResult.totalPaidHours` and `overtimeHours` the paid hours of its multiplied segments
    /// (`PayrollHoursResult.paidOvertimeHours`), so a cell shows the pay rule's hours for the day, never the clock
    /// duration (Sunday 07:30–14:00 every hour ×2 → 13h OT; a Saturday window counting 8h → 8h).
    static func fromBooking(
        paidHours: Double,
        overtimeHours: Double,
        timeSlot: TimeSlot?
    ) -> SchedulingV2CellKind {
        let ot = max(0, overtimeHours)
        let total = max(0, paidHours)
        let std = max(0, total - ot)

        if let slot = timeSlot {
            switch slot {
            case .morning:
                return .halfDay(hours: total > 0 ? total : 4, label: "AM")
            case .afternoon:
                return .halfDay(hours: total > 0 ? total : 4, label: "PM")
            case .overtime:
                return .overtimeOnly(hours: total > 0 ? total : ot)
            default:
                break
            }
        }

        if ot > 0.05 && std > 0.05 {
            return .split(stdHours: roundHalf(std), otHours: roundHalf(ot))
        }
        if ot > 0.05 && std <= 0.05 {
            return .overtimeOnly(hours: roundHalf(ot > 0 ? ot : total))
        }
        if total > 0.05 {
            return .standard(hours: roundHalf(total))
        }
        return .empty
    }

    /// RULEBOOK 1.20.0: hours as the pay rule gives them (to the hundredth), never snapped to a half hour — a derived
    /// weekday day is often a quarter hour (owner example 7.25h).
    private static func roundHalf(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    static func hoursLabel(_ value: Double) -> String {
        ScheduleCoverageFormat.hours(value) + "h"
    }
}

/// One person-day chip on the Scheduling week (docs/design/booking-ui 3.1): Standard (blue), Std + OT (blue STD top,
/// amber striped OT bottom), OT only (amber stripes), Annual leave, Half day (split), empty (dashed). Display only;
/// the tap is the caller's existing action.
struct SchedulingV2BookingCell: View {
    let kind: SchedulingV2CellKind
    let isToday: Bool
    let isWeekend: Bool
    var accessibilityDay: String = ""
    var accessibilityPerson: String = ""
    let action: () -> Void

    private static let otInk = Color(red: 0.36, green: 0.22, blue: 0.0)

    var body: some View {
        Button(action: action) {
            ZStack {
                cellBackground
                cellContent
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(todayOverlay)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .accessibilityIdentifier("schedulingV2BookingCell.button")
        .accessibilityLabel(accessibilityText)
        .buttonStyle(.plain)
    }

    private var accessibilityText: String {
        let what: String
        switch kind {
        case .empty: what = "Not booked"
        case .standard(let h): what = "\(SchedulingV2CellKindBuilder.hoursLabel(h)) standard"
        case .overtimeOnly(let h): what = "\(SchedulingV2CellKindBuilder.hoursLabel(h)) overtime"
        case .split(let std, let ot):
            what = "\(SchedulingV2CellKindBuilder.hoursLabel(std)) standard, \(SchedulingV2CellKindBuilder.hoursLabel(ot)) overtime"
        case .annualLeave: what = "Annual leave"
        case .halfDay(let h, let label): what = "\(label) half day, \(SchedulingV2CellKindBuilder.hoursLabel(h))"
        }
        return [accessibilityPerson, accessibilityDay, what].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    @ViewBuilder
    private var cellBackground: some View {
        switch kind {
        case .empty:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isWeekend ? PPBookingColor.field.opacity(0.4) : PPBookingColor.field.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isToday ? PPColor.brand.opacity(0.5) : Color(.separator),
                            style: StrokeStyle(lineWidth: isToday ? 1.5 : 1, dash: [4, 3])
                        )
                )
        case .standard:
            PPBookingColor.standard
        case .overtimeOnly:
            PPOvertimeFill()
        case .annualLeave:
            PPBookingColor.leave
        case .halfDay:
            HStack(spacing: 0) {
                PPBookingColor.standard
                PPBookingColor.halfDayLight
            }
        case .split:
            VStack(spacing: 0) {
                PPBookingColor.standard
                PPOvertimeFill()
            }
        }
    }

    @ViewBuilder
    private var cellContent: some View {
        switch kind {
        case .empty:
            EmptyView()
        case .standard(let hours):
            cellLabel(SchedulingV2CellKindBuilder.hoursLabel(hours), "Std", ink: .white)
        case .overtimeOnly(let hours):
            cellLabel(SchedulingV2CellKindBuilder.hoursLabel(hours), "OT", ink: Self.otInk)
        case .annualLeave:
            Text("AL")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white)
        case .halfDay(let hours, let label):
            cellLabel(SchedulingV2CellKindBuilder.hoursLabel(hours), label, ink: .white)
                .shadow(color: .black.opacity(0.25), radius: 1)
        case .split(let stdHours, let otHours):
            VStack(spacing: 0) {
                cellLabel(SchedulingV2CellKindBuilder.hoursLabel(stdHours), "Std", ink: .white, compact: true)
                    .frame(maxHeight: .infinity)
                cellLabel(SchedulingV2CellKindBuilder.hoursLabel(otHours), "OT", ink: Self.otInk, compact: true)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func cellLabel(_ hours: String, _ caption: String, ink: Color, compact: Bool = false) -> some View {
        VStack(spacing: 0) {
            Text(hours)
                .font(.system(size: compact ? 9.5 : 11, weight: .heavy))
                .monospacedDigit()
            Text(caption)
                .font(.system(size: compact ? 6.5 : 7.5, weight: .bold))
                .textCase(.uppercase)
                .opacity(0.85)
        }
        .foregroundStyle(ink)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 1)
    }

    @ViewBuilder
    private var todayOverlay: some View {
        if isToday, kind != .empty {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PPBookingColor.selected, lineWidth: 2)
        }
    }
}

struct SchedulingV2Legend: View {
    var body: some View {
        FlexWrapLegend()
    }
}

/// Standard, Std + OT, OT only, Ann. leave, Half day.
private struct FlexWrapLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                legendItem("Standard") { PPBookingColor.standard }
                legendItem("Std + OT") {
                    VStack(spacing: 0) {
                        PPBookingColor.standard
                        PPOvertimeFill()
                    }
                }
                legendItem("OT only") { PPOvertimeFill() }
            }
            HStack(spacing: 12) {
                legendItem("Ann. leave") { PPBookingColor.leave }
                legendItem("Half day") {
                    HStack(spacing: 0) {
                        PPBookingColor.standard
                        PPBookingColor.halfDayLight
                    }
                }
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Legend: Standard, Standard plus overtime, Overtime only, Annual leave, Half day")
    }

    private func legendItem<Swatch: View>(_ label: String, @ViewBuilder swatch: () -> Swatch) -> some View {
        HStack(spacing: 5) {
            swatch()
                .frame(width: 12, height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(label)
        }
    }
}
