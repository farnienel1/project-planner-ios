//
//  ScheduleOverlapWarningViews.swift
//  Project Planner
//
//  Shared “Warning — time overlap” UI for My Schedule and project booking flows.
//

import SwiftUI

struct ScheduleOverlapWarningPanel: View {
    let message: String
    var detailLines: [String] = []
    var cancelTitle: String = "Cancel booking"
    var confirmTitle: String = "Confirm booking"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                    .font(.body)
                Text("Warning — time overlap")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(ProjectWorksRevampColors.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !detailLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(detailLines, id: \.self) { line in
                        Text("• \(line)")
                            .font(.system(size: 12))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                    }
                }
            }
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                        Text(cancelTitle)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.96, green: 0.97, blue: 0.98))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                Button(action: onConfirm) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                        Text(confirmTitle)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(ProjectWorksRevampColors.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ProjectWorksRevampColors.upcomingAmber.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }
}

struct OperativeClashReviewPanel: View {
    let clashesByOperative: [(operative: Operative, clashes: [ScheduleOperativeView.BookingClash])]
    let onApprove: (UUID) -> Void
    let onDismissOperative: (UUID) -> Void
    let onCancelAll: () -> Void
    let onConfirmBooking: () -> Void
    var canConfirmBooking: Bool

    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var firebaseBackend: FirebaseBackend

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ProjectWorksRevampColors.upcomingAmber)
                Text("Warning — time overlap")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
            }
            Text("These people already have a booking that overlaps this time. Approve with ✓ to add them, or ✕ to remove.")
                .font(.system(size: 12))
                .foregroundStyle(ProjectWorksRevampColors.muted)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(clashesByOperative, id: \.operative.id) { group in
                operativeClashRow(group.operative, clashes: group.clashes)
            }

            HStack(spacing: 10) {
                Button(action: onCancelAll) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                        Text("Cancel booking")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.96, green: 0.97, blue: 0.98))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                    )
                }
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
                    .background(canConfirmBooking ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.muted.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canConfirmBooking)
            }
        }
        .padding(14)
        .background(Color.white)
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
        let summary = clashes.prefix(2).map { clash -> String in
            let proj = clash.existingProject.map { "\($0.jobNumber) \($0.siteName)" } ?? "Another job"
            return "\(clash.date.formatted(date: .abbreviated, time: .omitted)) · \(clash.existingBooking.scheduleLabel(policy: policy)) · \(proj)"
        }.joined(separator: "\n")
        return HStack(alignment: .top, spacing: 10) {
            Text(PlannerUIInitials.from(operative.name))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    LinearGradient(
                        colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(operative.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { onDismissOperative(operative.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .frame(width: 36, height: 36)
                    .background(Color(red: 0.96, green: 0.97, blue: 0.98))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            Button { onApprove(operative.id) } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(ProjectWorksRevampColors.blue)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(red: 0.98, green: 0.99, blue: 1.0))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
        )
    }
}
