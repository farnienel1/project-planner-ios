//
//  AnnualLeaveUsageHeroView.swift
//  Project Planner
//
//  Remaining / taken / pending leave infographic used on personal and managed leave pages.
//

import SwiftUI

struct AnnualLeaveUsageHeroView: View {
    let summary: AnnualLeaveUsageSummary

    var body: some View {
        let usedPortion = summary.entitlementDays > 0
            ? min(1, (summary.takenDays + summary.pendingDays) / summary.entitlementDays)
            : 0
        return VStack(alignment: .leading, spacing: 12) {
            Text("Current leave year")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HolidayChrome.muted)
            Text(summary.leaveYearLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HolidayChrome.ink)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remaining")
                        .font(.caption2)
                        .foregroundStyle(HolidayChrome.muted)
                    Text(Self.formatLeaveDays(summary.remainingDays))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(HolidayChrome.ink)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Allowance")
                        .font(.caption2)
                        .foregroundStyle(HolidayChrome.muted)
                    Text(Self.formatLeaveDays(summary.entitlementDays))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(HolidayChrome.accent)
                }
            }
            HStack(spacing: 0) {
                heroMetric(title: "Taken", value: summary.takenDays, color: HolidayChrome.taken)
                heroMetric(title: "Pending", value: summary.pendingDays, color: HolidayChrome.pendingMetric)
            }
            ProgressView(value: usedPortion, total: 1)
                .tint(HolidayChrome.accent)
            if summary.carryOverDays > 0.001 {
                Text("Includes \(Self.formatLeaveDays(summary.carryOverDays)) carried forward")
                    .font(.caption2)
                    .foregroundStyle(HolidayChrome.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.94, blue: 0.90),
                            Color(red: 0.96, green: 0.97, blue: 0.99),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(HolidayChrome.border, lineWidth: 1)
        )
    }

    private func heroMetric(title: String, value: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(HolidayChrome.muted)
            Text(Self.formatLeaveDays(value))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    static func formatLeaveDays(_ d: Double) -> String {
        if abs(d - floor(d + 0.0001)) < 0.02 {
            return String(Int((d * 2).rounded() / 2))
        }
        return String(format: "%.1f", d)
    }
}
