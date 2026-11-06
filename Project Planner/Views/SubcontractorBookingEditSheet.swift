//
//  SubcontractorBookingEditSheet.swift
//  Project Planner
//

import SwiftUI

struct SubcontractorBookingEditSheet: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var subcontractorStore: SubcontractorStore
    let booking: SubcontractorBooking
    /// RULEBOOK 1.33.0 §2: deleting a subcontractor booking is online only (`booking.delete_subcontractor`); the
    /// presenter passes the offline message, nil when online.
    var deleteDisabledReason: String?
    let onDismiss: () -> Void

    @State private var isSaving = false
    @State private var selectedContactIds: Set<UUID>

    init(booking: SubcontractorBooking, deleteDisabledReason: String? = nil, onDismiss: @escaping () -> Void) {
        self.booking = booking
        self.deleteDisabledReason = deleteDisabledReason
        self.onDismiss = onDismiss
        _selectedContactIds = State(initialValue: Set(booking.bookedContactIds))
    }

    /// RULEBOOK 1.33.0 §2 `bookingRemoveAction`: Delete only for the people who may delete this booking.
    private var removeAction: (() -> Void)? {
        guard JobAccessContext.bookingRemoveAction(collection: "subcontractorBookings", projectId: booking.storedProjectId) == "delete" else {
            return nil
        }
        return { deleteBooking() }
    }

    private var payrollTimePolicy: OrgPayrollTimePolicy {
        firebaseBackend.currentOrganization?.settings.payrollTimePolicy ?? .default
    }

    private var subcontractor: Subcontractor? {
        subcontractorStore.subcontractors.first { $0.id == booking.subcontractorId }
    }

    private var subName: String {
        subcontractor?.name ?? "Subcontractor"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let subcontractor, !subcontractor.contacts.isEmpty {
                bookedOperativesSection(subcontractor: subcontractor)
                Divider()
            }
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
                    saveBooking(start: start, end: end, breakRemoved: breakRemoved)
                },
                onCancel: onDismiss,
                onDelete: removeAction,
                deleteDisabledReason: deleteDisabledReason
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func bookedOperativesSection(subcontractor: Subcontractor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Operatives on site")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Select who from \(subcontractor.name) is booked. Leave none selected for firm-wide attendance.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(subcontractor.contacts) { contact in
                Button {
                    if selectedContactIds.contains(contact.id) {
                        selectedContactIds.remove(contact.id)
                    } else {
                        selectedContactIds.insert(contact.id)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contact.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                            if !contact.email.isEmpty {
                                Text(contact.email)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: selectedContactIds.contains(contact.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedContactIds.contains(contact.id) ? Color.purple : Color.secondary)
                    }
                    .padding(10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .accessibilityIdentifier("subcontractorBookingEdit.row.\(contact.id).bookedOperativesSection")
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGroupedBackground))
    }

    private func saveBooking(start: String, end: String, breakRemoved: Bool) {
        if isSaving { return }
        isSaving = true
        var updated = booking
        updated.timeSlot = .customHours
        updated.workStartTime = start
        updated.workEndTime = end
        updated.isBreakRemoved = breakRemoved
        updated.bookedContactIds = Array(selectedContactIds)
        updated.updatedAt = Date()
        Task {
            await subcontractorStore.saveBooking(updated)
            await MainActor.run {
                isSaving = false
                onDismiss()
            }
        }
    }

    private func deleteBooking() {
        if isSaving { return }
        isSaving = true
        Task {
            await subcontractorStore.deleteBooking(booking)
            await MainActor.run {
                isSaving = false
                if !subcontractorStore.bookings.contains(where: { $0.id == booking.id }) {
                    onDismiss()
                }
            }
        }
    }
}
