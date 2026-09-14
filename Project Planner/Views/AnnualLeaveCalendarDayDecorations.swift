//
//  AnnualLeaveCalendarDayDecorations.swift
//  Project Planner
//

import SwiftUI

enum AnnualLeaveCalendarChrome {
    static let weekendFill = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.93, 0.93, 0.94),
        dark: AppAdaptiveColor.rgb(0.125, 0.133, 0.165)
    )
    static let weekendStroke = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(0.78, 0.79, 0.82),
        dark: AppAdaptiveColor.rgb(0.310, 0.325, 0.376)
    )
    static let bankHolidayStroke = Color(red: 0.45, green: 0.22, blue: 0.62)
}

struct AnnualLeaveBlockedDayStyle: ViewModifier {
    let blockReason: AnnualLeaveDayBlockReason?
    let isSelected: Bool
    let isInMonth: Bool
    let defaultInk: Color
    let defaultMuted: Color

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foregroundColor)
            .background(background)
            .overlay(overlay)
    }

    private var foregroundColor: Color {
        guard isInMonth else { return defaultMuted }
        if isSelected { return .white }
        switch blockReason {
        case .weekend, .bankHoliday:
            return defaultMuted.opacity(0.72)
        case .none:
            return defaultInk
        }
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            Circle().fill(Color(red: 0.094, green: 0.373, blue: 0.647))
        } else {
            switch blockReason {
            case .weekend:
                Circle().fill(AnnualLeaveCalendarChrome.weekendFill)
            case .bankHoliday:
                Circle().fill(Color.white)
            case .none:
                Circle().fill(Color.clear)
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch blockReason {
        case .weekend:
            Circle().stroke(AnnualLeaveCalendarChrome.weekendStroke, lineWidth: 2)
        case .bankHoliday:
            Circle().stroke(AnnualLeaveCalendarChrome.bankHolidayStroke, lineWidth: 2.5)
        case .none:
            EmptyView()
        }
    }
}

extension View {
    func annualLeaveBlockedDayStyle(
        blockReason: AnnualLeaveDayBlockReason?,
        isSelected: Bool,
        isInMonth: Bool,
        defaultInk: Color,
        defaultMuted: Color
    ) -> some View {
        modifier(
            AnnualLeaveBlockedDayStyle(
                blockReason: blockReason,
                isSelected: isSelected,
                isInMonth: isInMonth,
                defaultInk: defaultInk,
                defaultMuted: defaultMuted
            )
        )
    }
}
