//
//  ScheduleOperativeConflictViews.swift
//  Project Planner
//

import SwiftUI

struct ScheduleConflictRowView: View {
    let row: ScheduleConflictRow
    let isAcknowledged: Bool
    let isStruck: Bool
    let onAcknowledge: () -> Void
    let onStrike: () -> Void

    private var isApprovedAL: Bool { row.kind == .approvedAnnualLeave }
    private var isPendingAL: Bool { row.kind == .pendingAnnualLeave }
    private var needsActions: Bool { row.requiresAcknowledgement }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if isApprovedAL {
                        Image(systemName: "beach.umbrella.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(row.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isApprovedAL ? .orange : (isStruck ? .secondary : .primary))
                        .strikethrough(isStruck)
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .strikethrough(isStruck)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isPendingAL && !isAcknowledged && !isStruck ? 0.72 : 1)

            if needsActions {
                Button(action: onStrike) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.red)
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                Button(action: onAcknowledge) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(isAcknowledged ? Color.blue : Color.blue.opacity(0.35))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var rowBackground: Color {
        if isApprovedAL { return Color.orange.opacity(0.1) }
        if isAcknowledged { return Color.blue.opacity(0.08) }
        if isStruck { return Color(.systemGray6) }
        return Color(.systemGray6)
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
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(summary.rows) { row in
                    ScheduleConflictRowView(
                        row: row,
                        isAcknowledged: acknowledgedIds.contains(row.id),
                        isStruck: struckIds.contains(row.id),
                        onAcknowledge: { onAcknowledge(row.id) },
                        onStrike: { onStrike(row.id) }
                    )
                }
            }
        }
        .padding(.top, 4)
    }
}
