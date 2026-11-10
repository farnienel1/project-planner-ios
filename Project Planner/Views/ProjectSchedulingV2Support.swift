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
    /// RULEBOOK 1.37.0 `jobScheduleLeaveMarks`: a day of annual leave with no booking on the job ("AL", "AL AM",
    /// "AL PM"; pending "AL?" paler).
    case annualLeave(RulebookScheduleLeaveMark)
    case halfDay(hours: Double, label: String)
}

enum SchedulingV2CellKindBuilder {
    /// RULEBOOK 1.37.0 §21 `scheduleCellKind`: maps existing booking hours / slot into a display cell — the rule both
    /// apps call (no Swift thresholds). `paidHours` is `payrollHoursResult.totalPaidHours` and `overtimeHours` the paid
    /// hours of its multiplied segments (`PayrollHoursResult.paidOvertimeHours`, the script's `scheduleCellHours`), so a
    /// cell shows the pay rule's hours for the day, never the clock duration. A 0h booking is a Standard 0h chip, never
    /// the empty one. Display only — does not change booking logic.
    static func fromBooking(
        paidHours: Double,
        overtimeHours: Double,
        timeSlot: TimeSlot?
    ) -> SchedulingV2CellKind {
        guard let cell = CanonicalBusinessEngine.scheduleCellKind(
            paidHours: paidHours,
            overtimeHours: overtimeHours,
            timeSlot: timeSlot?.rawValue
        ) else {
            // The script did not answer: show the booking (its hours unclassified) rather than hide it.
            return .standard(hours: max(0, paidHours))
        }
        switch cell.tone {
        case "split": return .split(stdHours: cell.standardHours, otHours: cell.overtimeHours)
        case "otOnly": return .overtimeOnly(hours: cell.overtimeHours)
        case "halfDay": return .halfDay(hours: cell.standardHours, label: cell.halfLabel ?? "Half day")
        default: return .standard(hours: cell.standardHours)
        }
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
    /// RULEBOOK 1.37.0: annual leave on a day that also has a booking — the booking chip stays and a thin brown band
    /// with the label sits across the top (overtime keeps its own marking underneath). Ignored for a leave cell.
    var leaveBand: RulebookScheduleLeaveMark? = nil
    let isToday: Bool
    let isWeekend: Bool
    var accessibilityDay: String = ""
    var accessibilityPerson: String = ""
    let action: () -> Void

    private static let otInk = Color(red: 0.36, green: 0.22, blue: 0.0)

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .top) {
                cellBackground
                cellContent
                    .frame(maxHeight: .infinity)
                    .padding(.top, bandMark == nil ? 0 : 10)
                if let band = bandMark {
                    Text(band.label)
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 10)
                        .background(Self.leaveColor(band))
                        .accessibilityIdentifier("schedulingV2BookingCell.leaveBand")
                }
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

    /// The band is drawn only over a booking chip, never over an empty or leave cell.
    private var bandMark: RulebookScheduleLeaveMark? {
        switch kind {
        case .empty, .annualLeave: return nil
        default: return leaveBand
        }
    }

    static func leaveColor(_ mark: RulebookScheduleLeaveMark) -> Color {
        mark.pending ? PPBookingColor.leave.opacity(0.45) : PPBookingColor.leave
    }

    static func halfColor(_ state: String?) -> Color {
        switch state {
        case "approved": return PPBookingColor.leave
        case "pending": return PPBookingColor.leave.opacity(0.45)
        default: return PPBookingColor.field.opacity(0.7)
        }
    }

    private var accessibilityText: String {
        let what: String
        switch kind {
        case .empty: what = "Not booked"
        case .standard(let h): what = "\(SchedulingV2CellKindBuilder.hoursLabel(h)) standard"
        case .overtimeOnly(let h): what = "\(SchedulingV2CellKindBuilder.hoursLabel(h)) overtime"
        case .split(let std, let ot):
            what = "\(SchedulingV2CellKindBuilder.hoursLabel(std)) standard, \(SchedulingV2CellKindBuilder.hoursLabel(ot)) overtime"
        case .annualLeave(let mark): what = mark.title
        case .halfDay(let h, let label): what = "\(label) half day, \(SchedulingV2CellKindBuilder.hoursLabel(h))"
        }
        let band = bandMark.map { $0.title } ?? ""
        return [accessibilityPerson, accessibilityDay, what, band].filter { !$0.isEmpty }.joined(separator: ", ")
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
        case .annualLeave(let mark):
            if mark.isHalfDay {
                // Each half in its own style (the "Half day" split): approved brown, pending paler, not leave open.
                HStack(spacing: 0) {
                    Self.halfColor(mark.am)
                    Self.halfColor(mark.pm)
                }
            } else {
                Self.leaveColor(mark)
            }
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
        case .annualLeave(let mark):
            Text(mark.label)
                .font(.caption.weight(.heavy))
                .foregroundStyle(mark.isHalfDay ? Color.primary : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .shadow(color: mark.isHalfDay ? .clear : .black.opacity(0.2), radius: 1)
                .accessibilityIdentifier("schedulingV2BookingCell.leaveLabel")
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
            // RULEBOOK 1.37.0: pending leave requests are shown paler, "AL?" (web shows the same swatch).
            legendItem("AL? = leave requested") { PPBookingColor.leave.opacity(0.45) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Legend: Standard, Standard plus overtime, Overtime only, Annual leave, Half day, AL question mark means leave requested")
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
