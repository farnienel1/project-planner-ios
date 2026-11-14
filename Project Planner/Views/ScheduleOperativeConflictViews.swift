//
//  ScheduleOperativeConflictViews.swift
//  Project Planner
//

import SwiftUI

/// One scheduling conflict row in the shared booking-conflict style (RULEBOOK 1.16.0, web `BookingConflictRows`):
/// orange double bookings and purple annual leave, ✓ to keep the day and red ✕ to drop it.
struct ScheduleConflictRowView: View {
    let row: ScheduleConflictRow
    let personName: String
    let isAcknowledged: Bool
    let isStruck: Bool
    let onAcknowledge: () -> Void
    let onStrike: () -> Void
    /// RULEBOOK 1.41.0 §5: Replace chosen on this row (it then also counts as acknowledged).
    var isReplaced: Bool = false
    /// Nil where the flow does not save a Replace: the row then shows ✓ and ✕ only.
    var onReplace: (() -> Void)? = nil

    private var isLeave: Bool { row.kind == .approvedAnnualLeave || row.kind == .pendingAnnualLeave }

    private var item: BookingConflictItem {
        let dayKey = OrganizationRulebookContext.dayKey(row.date)
        return BookingConflictItem(
            id: row.id,
            personKey: row.operativeId.uuidString,
            dayKey: dayKey,
            kind: isLeave ? .annualLeave : .doubleBooking,
            personName: personName,
            dayLabel: BookingConflictItem.dayLabel(dayKey),
            detail: row.conflictDetail ?? row.detail,
            pending: row.kind == .pendingAnnualLeave,
            replace: !isLeave && onReplace != nil ? row.replaceRefs : nil
        )
    }

    private var decision: BookingConflictDecision? {
        if isStruck { return .drop }
        if isReplaced { return .replace }
        if isAcknowledged { return .confirm }
        return nil
    }

    var body: some View {
        BookingConflictRowView(row: item, decision: decision) { next in
            switch next {
            case .confirm: onAcknowledge()
            case .drop: onStrike()
            case .replace: onReplace?()
            }
        }
    }
}

struct ScheduleOperativeMainConflictBlock: View {
    let person: ScheduleBookablePerson
    let summary: SchedulePersonConflictSummary
    let isExpanded: Bool
    let acknowledgedIds: Set<String>
    let struckIds: Set<String>
    let onToggleExpand: () -> Void
    let onAcknowledge: (String) -> Void
    let onStrike: (String) -> Void
    /// RULEBOOK 1.41.0 §5: rows where Replace was chosen, and the action (nil: no Replace in this flow).
    var replacedIds: Set<String> = []
    var onReplace: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggleExpand) {
                HStack(spacing: 6) {
                    if summary.triangle != .none {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(summary.triangle == .red ? .red : .orange)
                    }
                    Text(summary.hasUnactionedRows ? "Clashes need acknowledgement" : "Booking days")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(summary.hasUnactionedRows ? .red : ProjectWorksRevampColors.muted)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("scheduleOperativeMainConflictBlock.exclamationmarkTriangleFill")
            .buttonStyle(.plain)

            if isExpanded {
                // RULEBOOK 1.16.0 `BOOKING_CONFLICTS_HEADING` over the orange double bookings and purple leave rows.
                Text(CanonicalBusinessEngine.bookingConflictsHeading)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                BookingConflictLegend()
                ForEach(summary.rows) { row in
                    ScheduleConflictRowView(
                        row: row,
                        personName: person.name,
                        isAcknowledged: acknowledgedIds.contains(row.id),
                        isStruck: struckIds.contains(row.id),
                        onAcknowledge: { onAcknowledge(row.id) },
                        onStrike: { onStrike(row.id) },
                        isReplaced: replacedIds.contains(row.id),
                        onReplace: onReplace.map { action in { action(row.id) } }
                    )
                }
            }
        }
        .padding(.top, 4)
    }
}
