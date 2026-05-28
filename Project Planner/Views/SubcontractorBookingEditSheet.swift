//
//  SubcontractorBookingEditSheet.swift
//  Project Planner
//

import SwiftUI

struct SubcontractorBookingEditSheet: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    let booking: SubcontractorBooking
    let onDismiss: () -> Void

    @State private var isSaving = false

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }

    private var subName: String {
        subcontractorStore.subcontractors.first { $0.id == booking.subcontractorId }?.name ?? "Subcontractor"
    }

    var body: some View {
        OperativeCustomHoursSheet(
            policy: payrollTimePolicy,
            title: "Edit booking",
            subtitle: booking.date.formatted(date: .abbreviated, time: .omitted),
            headerName: subName,
            headerInitials: PlannerUIInitials.from(subName),
            allowsOtMultiplierOverride: false,
            showsBreakControls: false,
            showsBreakdown: false,
            showsFooterNote: false,
            forceSolidBlueTimeline: true,
            initialChoice: OperativeDayBookingChoice(
                timeSlot: booking.timeSlot,
                workStartTime: booking.workStartTime,
                workEndTime: booking.workEndTime,
                isBreakRemoved: true,
                otMultiplierOverride: nil
            ),
            onSave: { start, end, breakRemoved, _ in
                if isSaving { return }
                isSaving = true
                var updated = booking
                updated.timeSlot = .customHours
                updated.workStartTime = start
                updated.workEndTime = end
                updated.isBreakRemoved = breakRemoved
                updated.updatedAt = Date()
                Task {
                    await subcontractorStore.saveBooking(updated)
                    await MainActor.run {
                        isSaving = false
                        onDismiss()
                    }
                }
            },
            onCancel: onDismiss
        )
    }
}
