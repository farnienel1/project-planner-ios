//
//  ProjectSchedulingV2Support.swift
//  Project Planner
//
//  Visual language for project / small-works Scheduling (person × day grid).
//  Design refs: SchedulingView.tsx, scheduling_v2.html
//

import SwiftUI

enum SchedulingV2Palette {
    static let pageBg = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255)
    static let ink = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
    static let muted = Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)
    static let softMuted = Color(red: 0x9C / 255, green: 0xA3 / 255, blue: 0xAF / 255)
    static let weekendMute = Color(red: 0xC7 / 255, green: 0xCA / 255, blue: 0xD0 / 255)
    static let projectCode = Color(red: 0x3B / 255, green: 0x5F / 255, blue: 0xA3 / 255)
    static let today = Color(red: 0x2C / 255, green: 0x5B / 255, blue: 0xBF / 255)
    static let std = Color(red: 0x3B / 255, green: 0x6B / 255, blue: 0xBF / 255)
    static let ot = Color(red: 0x1E / 255, green: 0x3A / 255, blue: 0x7A / 255)
    static let al = Color(red: 0x9A / 255, green: 0x5B / 255, blue: 0x27 / 255)
    static let half = Color(red: 0x5B / 255, green: 0x82 / 255, blue: 0xC7 / 255)
    static let opsBtn = Color(red: 0x2C / 255, green: 0x5B / 255, blue: 0xBF / 255)
    static let subsBtn = Color(red: 0x5B / 255, green: 0x3F / 255, blue: 0xA8 / 255)
    static let opsPillBg = Color(red: 0xEE / 255, green: 0xF0 / 255, blue: 0xF8 / 255)
    static let opsPillText = Color(red: 0x3B / 255, green: 0x5F / 255, blue: 0xA3 / 255)
    static let subsPillBg = Color(red: 0xF0 / 255, green: 0xED / 255, blue: 0xF8 / 255)
    static let subsPillText = Color(red: 0x6B / 255, green: 0x48 / 255, blue: 0xB5 / 255)
    static let countHasBg = Color(red: 0xEE / 255, green: 0xF3 / 255, blue: 0xFF / 255)
    static let countTodayBg = Color(red: 0xD8 / 255, green: 0xE4 / 255, blue: 0xFF / 255)
    static let cardBorder = Color.black.opacity(0.08)
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

    private static func roundHalf(_ value: Double) -> Double {
        (value * 2).rounded() / 2
    }

    static func hoursLabel(_ value: Double) -> String {
        let rounded = roundHalf(value)
        if abs(rounded - rounded.rounded(.towardZero)) < 0.01 {
            return String(format: "%.0fh", rounded)
        }
        return String(format: "%.1fh", rounded)
    }
}

struct SchedulingV2BookingCell: View {
    let kind: SchedulingV2CellKind
    let isToday: Bool
    let isWeekend: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                cellBackground
                cellContent
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(todayOverlay)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cellBackground: some View {
        switch kind {
        case .empty:
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isWeekend ? Color.black.opacity(0.015) : Color.black.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            isToday
                                ? SchedulingV2Palette.today.opacity(0.4)
                                : Color.black.opacity(isWeekend ? 0.05 : 0.08),
                            style: StrokeStyle(lineWidth: isToday ? 1.5 : 1, dash: [4, 3])
                        )
                )
        case .standard:
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SchedulingV2Palette.std)
        case .overtimeOnly:
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SchedulingV2Palette.ot)
        case .annualLeave:
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SchedulingV2Palette.al)
        case .halfDay:
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SchedulingV2Palette.half)
        case .split:
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: SchedulingV2Palette.std, location: 0),
                            .init(color: SchedulingV2Palette.std, location: 0.5),
                            .init(color: SchedulingV2Palette.ot, location: 0.5),
                            .init(color: SchedulingV2Palette.ot, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    @ViewBuilder
    private var cellContent: some View {
        switch kind {
        case .empty:
            EmptyView()
        case .standard(let hours):
            VStack(spacing: 1) {
                Text(SchedulingV2CellKindBuilder.hoursLabel(hours))
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                Text("Std")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .textCase(.uppercase)
            }
        case .overtimeOnly(let hours):
            VStack(spacing: 1) {
                Text(SchedulingV2CellKindBuilder.hoursLabel(hours))
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                Text("OT")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .textCase(.uppercase)
            }
        case .annualLeave:
            Text("AL")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
        case .halfDay(let hours, let label):
            VStack(spacing: 1) {
                Text(SchedulingV2CellKindBuilder.hoursLabel(hours))
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .textCase(.uppercase)
            }
        case .split(let stdHours, let otHours):
            VStack(spacing: 2) {
                VStack(spacing: 0) {
                    Text(SchedulingV2CellKindBuilder.hoursLabel(stdHours))
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                    Text("Std")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .textCase(.uppercase)
                }
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 18, height: 0.5)
                VStack(spacing: 0) {
                    Text(SchedulingV2CellKindBuilder.hoursLabel(otHours))
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                    Text("OT")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .textCase(.uppercase)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var todayOverlay: some View {
        if isToday, kind != .empty {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(SchedulingV2Palette.today.opacity(0.65), lineWidth: 2)
        }
    }
}

struct SchedulingV2AvatarColor {
    static func color(for key: String) -> Color {
        let palette: [Color] = [
            Color(red: 0x2C / 255, green: 0x5B / 255, blue: 0xBF / 255),
            Color(red: 0x4B / 255, green: 0x7A / 255, blue: 0x5C / 255),
            Color(red: 0x7A / 255, green: 0x4B / 255, blue: 0x8C / 255),
            Color(red: 0x8C / 255, green: 0x4B / 255, blue: 0x4B / 255),
            Color(red: 0x4B / 255, green: 0x6B / 255, blue: 0x8C / 255),
            Color(red: 0x5C / 255, green: 0x7A / 255, blue: 0x4B / 255),
            Color(red: 0x5C / 255, green: 0x5C / 255, blue: 0x8C / 255),
            Color(red: 0x8C / 255, green: 0x6B / 255, blue: 0x4B / 255),
        ]
        var hash = 0
        for u in key.unicodeScalars {
            hash = (hash &* 31 &+ Int(u.value)) & 0x7fffffff
        }
        return palette[hash % palette.count]
    }
}

struct SchedulingV2Legend: View {
    var body: some View {
        FlexWrapLegend()
    }
}

/// Simple wrapping legend without UIKit dependency.
private struct FlexWrapLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                legendItem(label: "Standard", color: SchedulingV2Palette.std)
                legendSplit
                legendItem(label: "OT only", color: SchedulingV2Palette.ot)
            }
            HStack(spacing: 10) {
                legendItem(label: "Ann. Leave", color: SchedulingV2Palette.al)
                legendItem(label: "Half day", color: SchedulingV2Palette.half)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color(red: 0x6B / 255, green: 0x72 / 255, blue: 0x80 / 255))
        .padding(.top, 8)
    }

    private func legendItem(label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
        }
    }

    private var legendSplit: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: SchedulingV2Palette.std, location: 0),
                            .init(color: SchedulingV2Palette.std, location: 0.5),
                            .init(color: SchedulingV2Palette.ot, location: 0.5),
                            .init(color: SchedulingV2Palette.ot, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 10, height: 10)
            Text("Std + OT")
        }
    }
}
