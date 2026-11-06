//
//  ScheduleOverlapWarningViews.swift
//  Project Planner
//
//  The Schedule screen's double-booking review, in the shared conflict-row style (`BookingConflictRowView`).
//

import SwiftUI

struct OperativeClashReviewPanel: View {
    let clashesByOperative: [(operative: Operative, clashes: [ScheduleOperativeView.BookingClash])]
    let onApprove: (UUID) -> Void
    let onDismissOperative: (UUID) -> Void
    let onCancelAll: () -> Void
    let onConfirmBooking: () -> Void
    var canConfirmBooking: Bool
    /// People already ticked (book anyway), shown as confirmed.
    var approvedOperativeIds: Set<UUID> = []

    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // RULEBOOK 1.16.0 `BOOKING_CONFLICTS_HEADING`: double bookings are orange rows in the same list style as
            // the purple annual-leave rows (web `BookingConflictRows`), ✓ to book anyway, ✕ to drop the person.
            Text(CanonicalBusinessEngine.bookingConflictsHeading)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.ink)
                .fixedSize(horizontal: false, vertical: true)
            BookingConflictLegend()

            ForEach(clashesByOperative, id: \.operative.id) { group in
                operativeClashRow(group.operative, clashes: group.clashes)
            }

            HStack(spacing: 10) {
                Button(action: onCancelAll) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                        Text("Don't book")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(ProjectWorksRevampColors.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                    )
                }
                .accessibilityIdentifier("operativeClashReviewPanel.close")
                .buttonStyle(.plain)
                Button(action: onConfirmBooking) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                        Text("Confirm booking")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(canConfirmBooking ? ProjectWorksRevampColors.blueFill : ProjectWorksRevampColors.muted.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .accessibilityIdentifier("operativeClashReviewPanel.checkmark")
                .buttonStyle(.plain)
                .disabled(!canConfirmBooking)
            }
        }
        .padding(14)
        .background(ProjectWorksRevampColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ProjectWorksRevampColors.upcomingAmber.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func operativeClashRow(_ operative: Operative, clashes: [ScheduleOperativeView.BookingClash]) -> some View {
        let policy = payrollTimePolicy
        let lines = clashes.prefix(3).map { clash -> String in
            let proj = clash.existingProject.map { "\($0.jobNumber) \($0.siteName)" } ?? "Another job"
            return "\(clash.existingBooking.scheduleLabel(policy: policy)) · \(proj)"
        }
        let days = Array(Set(clashes.map { OrganizationRulebookContext.dayKey($0.date) })).sorted()
        let dayKey = days.first ?? ""
        let base = BookingConflictItem.doubleBooking(
            personKey: operative.id.uuidString,
            dayKey: dayKey,
            personName: operative.name,
            detail: (["Already booked"] + lines).joined(separator: " · ")
        )
        let item = BookingConflictItem(
            id: base.id,
            personKey: base.personKey,
            dayKey: base.dayKey,
            kind: .doubleBooking,
            personName: base.personName,
            dayLabel: days.count > 1 ? "\(base.dayLabel) +\(days.count - 1) more" : base.dayLabel,
            detail: base.detail,
            pending: false
        )
        return BookingConflictRowView(row: item, decision: approvedOperativeIds.contains(operative.id) ? .confirm : nil) { decision in
            switch decision {
            case .confirm: onApprove(operative.id)
            case .drop: onDismissOperative(operative.id)
            }
        }
    }
}
