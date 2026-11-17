//
//  Rulebook+HoursBreakdown.swift
//  Project Planner
//
//  RULEBOOK 1.62.0 §4.3 (owner request 17 Nov, docs/design/hours-breakdown/): the simple hours breakdown on every
//  booking screen — "How the hours add up" with Normal hours, Overtime and Total paid hours — and its one summary line,
//  from the packed script's `bookingHoursBreakdownDays` (web `lib/canonical/bookingHoursBreakdown.ts`). Swift maps the
//  inputs and draws the script's text; nothing is priced here, so Normal + Overtime = Total = the Save button.
//

import Foundation
import SwiftUI

/// One `bookingHoursBreakdownRows` row: `kind` is `normal`, `overtime` or `total`.
nonisolated struct RulebookHoursBreakdownRow: Equatable, Hashable, Sendable, Identifiable {
    var id: String { kind }
    let kind: String
    /// "Normal hours", "Overtime" or "Total paid hours".
    let label: String
    /// Muted lines under the label, e.g. ["06:00–07:00 and 16:00–17:30", "2.5h at ×1.5"].
    let details: [String]
    /// e.g. "3.75h".
    let value: String
    let hours: Double
    /// e.g. "Overtime, 06:00 to 07:00 and 16:00 to 17:30, 2.5 hours at 1.5 times, 3.75 hours".
    let accessibilityLabel: String

    init?(json: Any?) {
        guard let row = json as? [String: Any],
              let kind = row["kind"] as? String,
              let label = row["label"] as? String,
              let value = row["value"] as? String else { return nil }
        self.kind = kind
        self.label = label
        self.value = value
        self.details = row["details"] as? [String] ?? []
        self.hours = (row["hours"] as? NSNumber)?.doubleValue ?? 0
        self.accessibilityLabel = row["accessibilityLabel"] as? String ?? label
    }
}

/// One group of `bookingHoursBreakdownDays`: the days that read the same, e.g. "Tuesday/Wednesday, full day".
nonisolated struct RulebookHoursBreakdownGroup: Equatable, Hashable, Sendable, Identifiable {
    var id: String { dayKeys.joined(separator: "|") }
    let dayKeys: [String]
    /// "{Day}, {day type}", e.g. "Tuesday, full day".
    let headerDetail: String
    let rows: [RulebookHoursBreakdownRow]
    let normalPaidHours: Double
    let overtimePaidHours: Double
    /// `payrollHoursResult.totalPaidHours`, rounded to hundredths: the Save button's figure.
    let totalPaidHours: Double

    init?(json: Any?) {
        guard let row = json as? [String: Any],
              let headerDetail = row["headerDetail"] as? String else { return nil }
        self.headerDetail = headerDetail
        self.dayKeys = row["dayKeys"] as? [String] ?? []
        self.rows = (row["rows"] as? [Any] ?? []).compactMap(RulebookHoursBreakdownRow.init(json:))
        func number(_ key: String) -> Double { (row[key] as? NSNumber)?.doubleValue ?? 0 }
        self.normalPaidHours = number("normalPaidHours")
        self.overtimePaidHours = number("overtimePaidHours")
        self.totalPaidHours = number("totalPaidHours")
    }
}

/// `bookingHoursBreakdownDays` → `{ summary, range, summaryHours, groups }`.
nonisolated struct RulebookHoursBreakdown: Equatable, Hashable, Sendable {
    /// "06:00–17:30 · 12.25 paid hours".
    let summary: String
    /// "06:00–17:30" (or the slot, "Full day").
    let range: String
    /// "12.25 paid hours", or "paid hours vary by day".
    let summaryHours: String
    let groups: [RulebookHoursBreakdownGroup]

    init?(json: Any?) {
        guard let row = json as? [String: Any],
              let summary = row["summary"] as? String else { return nil }
        self.summary = summary
        self.range = row["range"] as? String ?? ""
        self.summaryHours = row["summaryHours"] as? String ?? ""
        self.groups = (row["groups"] as? [Any] ?? []).compactMap(RulebookHoursBreakdownGroup.init(json:))
        if groups.isEmpty { return nil }
    }
}

extension CanonicalBusinessEngine {
    // MARK: bookingHoursBreakdownDays (1.62.0 §4.3)

    /// The booking `bookingHoursBreakdownDays` reads (slot, clock times, break toggle, the booking's own overtime rate).
    /// A mapping only.
    nonisolated static func hoursBreakdownBooking(
        timeSlot: String,
        start: String?,
        end: String?,
        isBreakRemoved: Bool,
        otMultiplierOverride: Double?
    ) -> [String: Any] {
        var booking: [String: Any] = [
            "timeSlot": timeSlot,
            "workStartTime": start ?? NSNull(),
            "workEndTime": end ?? NSNull(),
            "isBreakRemoved": isBreakRemoved,
        ]
        if let rate = bookingOwnRate(otMultiplierOverride) { booking["otMultiplierOverride"] = rate }
        return booking
    }

    /// RULEBOOK 1.62.0 §4.3 `bookingHoursBreakdownDays(policyState, dayKeys, booking, timeZone)`: the summary line and
    /// the Normal / Overtime / Total rows for one pair of times (or a named slot) on `dates`, each day under the
    /// working hours in effect on it. Uses the open organisation's policy state when loaded, else `fallbackPolicy`.
    /// Nil when the script did not answer or the times are not valid.
    nonisolated static func hoursBreakdown(
        on dates: [Date],
        timeSlot: String = "CUSTOM_HOURS",
        start: String?,
        end: String?,
        isBreakRemoved: Bool,
        fallbackPolicy: OrgPayrollTimePolicy,
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier,
        otMultiplierOverride: Double? = nil
    ) -> RulebookHoursBreakdown? {
        guard !dates.isEmpty else { return nil }
        let keys = dates.map { bookingDayKey($0) }
        let booking = hoursBreakdownBooking(
            timeSlot: timeSlot, start: start, end: end, isBreakRemoved: isBreakRemoved, otMultiplierOverride: otMultiplierOverride
        )
        if let document = OrganizationRulebookContext.payrollPolicyDocument,
           let state = payrollPolicyState(document: document, timeZone: timeZone),
           let answer = RulebookHoursBreakdown(json: memoCallJSON("bookingHoursBreakdownDays", arguments: [state, keys, booking, timeZone])) {
            return answer
        }
        return hoursBreakdown(policy: fallbackPolicy, dayKeys: keys, booking: booking, timeZone: timeZone)
    }

    /// `bookingHoursBreakdownDays(policy, dayKeys, booking, timeZone)` with one policy (no policy state).
    nonisolated static func hoursBreakdown(
        policy: OrgPayrollTimePolicy,
        dayKeys: [String],
        booking: [String: Any],
        timeZone: String = OrganizationRulebookContext.timeZoneIdentifier
    ) -> RulebookHoursBreakdown? {
        guard let policyJSON = payrollPolicyJSON(policy) else { return nil }
        return RulebookHoursBreakdown(json: memoCallJSON("bookingHoursBreakdownDays", arguments: [policyJSON, dayKeys, booking, timeZone]))
    }
}

/// "06:00–17:30 · **12.25 paid hours**" — the one line under the timeline (RULEBOOK 1.62.0). Text only.
struct HoursBreakdownSummaryText: View {
    let breakdown: RulebookHoursBreakdown

    var body: some View {
        (Text("\(breakdown.range) · ").foregroundStyle(ProjectWorksRevampColors.muted)
            + Text(breakdown.summaryHours).bold().foregroundStyle(ProjectWorksRevampColors.ink))
            .font(.footnote)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("booking.hoursBreakdownSummary")
    }
}

/// RULEBOOK 1.62.0 §4.3: "How the hours add up" — one card per group of days (the script's groups), each with the
/// header detail and the Normal hours / Overtime / Total paid hours rows. Same text as web `HoursBreakdownBox`.
/// Colours are the app's adaptive tokens (light and dark): the card is `canvas`, text `ink` / `muted`; the overtime row
/// is tinted with `upcomingAmber` and its text is `upcomingAmber` (5.3:1 light, 8.9:1 dark on the tint — muted grey
/// would be 3.8:1 there in light mode). Dynamic Type: every font is a text style, detail lines wrap, figures never
/// truncate. VoiceOver reads each row as one element (the script's `accessibilityLabel`).
struct HoursBreakdownCardView: View {
    let breakdown: RulebookHoursBreakdown
    var title: String = "How the hours add up"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(breakdown.groups) { group in
                card(group)
            }
        }
    }

    private func card(_ group: RulebookHoursBreakdownGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text(title.uppercased()).font(.caption.weight(.bold)).tracking(0.8)
                + Text("  \(group.headerDetail)").font(.footnote))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 && row.kind != "overtime" && group.rows[index - 1].kind != "overtime" {
                    Rectangle()
                        .fill(row.kind == "total" ? ProjectWorksRevampColors.searchBorder : ProjectWorksRevampColors.border)
                        .frame(height: row.kind == "total" ? 1.5 : 1)
                }
                rowView(row)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ProjectWorksRevampColors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("booking.hoursBreakdownCard")
    }

    @ViewBuilder
    private func rowView(_ row: RulebookHoursBreakdownRow) -> some View {
        let overtime = row.kind == "overtime"
        let total = row.kind == "total"
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(total ? .body.weight(.bold) : .subheadline.weight(.semibold))
                    .foregroundStyle(overtime ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.ink)
                ForEach(row.details, id: \.self) { detail in
                    Text(detail)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(overtime ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.value)
                .font(total ? .title3.weight(.bold) : .subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(overtime ? ProjectWorksRevampColors.upcomingAmber : ProjectWorksRevampColors.ink)
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.vertical, overtime ? 10 : 9)
        .padding(.horizontal, overtime ? 12 : 0)
        .background {
            if overtime {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ProjectWorksRevampColors.upcomingAmber.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(ProjectWorksRevampColors.upcomingAmber.opacity(0.35), lineWidth: 1)
                    )
            }
        }
        .padding(.vertical, overtime ? 4 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityIdentifier("booking.hoursBreakdownRow.\(row.kind)")
    }
}
