//
//  ScheduleQuickAddSheet.swift
//  Project Planner
//
//  Empty week-overview cell: Full day / AM / PM / Custom, clocks from the shared halves.
//

import SwiftUI

struct ScheduleQuickAddSheet: View {
    let personName: String
    let day: Date
    let policy: OrgPayrollTimePolicy
    let clocks: ScheduleQuickAddClocks?
    let existingPaidHours: Double
    let showsNotes: Bool
    let onSave: (ScheduleQuickAddDraft) async -> String?
    let onCancel: () -> Void

    @State private var slot: Slot = .fullDay
    @State private var customStart: Int
    @State private var customEnd: Int
    @State private var notes = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        personName: String,
        day: Date,
        policy: OrgPayrollTimePolicy,
        clocks: ScheduleQuickAddClocks?,
        existingPaidHours: Double,
        showsNotes: Bool,
        onSave: @escaping (ScheduleQuickAddDraft) async -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.personName = personName
        self.day = day
        self.policy = policy
        self.clocks = clocks
        self.existingPaidHours = existingPaidHours
        self.showsNotes = showsNotes
        self.onSave = onSave
        self.onCancel = onCancel
        let start = clocks.flatMap { ManagerScheduleInterval.parseMinutes($0.fullDay.start) } ?? (7 * 60 + 30)
        let end = clocks.flatMap { ManagerScheduleInterval.parseMinutes($0.fullDay.end) } ?? (16 * 60)
        _customStart = State(initialValue: start)
        _customEnd = State(initialValue: end)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                        .font(.system(size: 12))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                    slotPicker
                    if slot == .custom {
                        customClocks
                    }
                    if let clocks {
                        breakdown(clocks: clocks)
                    }
                    if showsNotes {
                        notesField
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                    }
                    saveButton
                }
                .padding(18)
            }
            .background(ProjectWorksRevampColors.canvas)
            .navigationTitle("Quick Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("scheduleQuickAdd.cancel")
                }
            }
        }
    }

    private var slotPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Slot")
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    slotChip(.fullDay, title: "Full day", range: clocks?.fullDay.label)
                    slotChip(.morning, title: "AM", range: clocks?.morning.label)
                }
                HStack(spacing: 8) {
                    slotChip(.afternoon, title: "PM", range: clocks?.afternoon.label)
                    slotChip(.custom, title: "Custom", range: nil)
                }
            }
        }
    }

    private func slotChip(_ choice: Slot, title: String, range: String?) -> some View {
        let selected = slot == choice
        return Button {
            slot = choice
            errorMessage = nil
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(range ?? "Set times")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selected ? Color(red: 0.902, green: 0.945, blue: 0.984) : ProjectWorksRevampColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.border, lineWidth: selected ? 1.5 : 0.5)
            )
        }
        .accessibilityIdentifier("scheduleQuickAdd.\(choice.identifier)")
        .buttonStyle(.plain)
        .disabled(clocks == nil && choice != .custom)
    }

    private var customClocks: some View {
        HStack(spacing: 8) {
            timeMenu(title: "Start", minutes: $customStart, upperBound: max(0, customEnd - 30))
            timeMenu(title: "End", minutes: $customEnd, lowerBound: customStart + 30)
        }
    }

    private func timeMenu(title: String, minutes: Binding<Int>, lowerBound: Int = 0, upperBound: Int = 24 * 60) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            Menu {
                ForEach(Array(stride(from: 0, through: 24 * 60, by: 30)), id: \.self) { minute in
                    if minute >= lowerBound && minute <= upperBound {
                        Button(ScheduleWeekGrid.clockText(minute)) {
                            minutes.wrappedValue = minute
                            errorMessage = nil
                        }
                    }
                }
            } label: {
                Text(ScheduleWeekGrid.clockText(minutes.wrappedValue))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(ProjectWorksRevampColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                    )
            }
            .accessibilityIdentifier("scheduleQuickAdd.\(title.lowercased())")
        }
    }

    private func breakdown(clocks: ScheduleQuickAddClocks) -> some View {
        let range = selectedRange(clocks)
        let timeSlot = selectedTimeSlot
        let probe = Booking(
            operativeId: UUID(),
            projectId: UUID(),
            date: day,
            timeSlot: timeSlot,
            bookedBy: "",
            workStartTime: range.start,
            workEndTime: range.end
        )
        let paid = probe.paidBookedHours(policy: policy)
        let detail = BookingEditHoursBreakdown.compute(
            booking: probe,
            policy: policy,
            day: day,
            breakIncluded: true
        )
        let total = existingPaidHours + paid
        let missing = max(0, max(policy.standardPaidHours, 0) - total)
        return VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Hours breakdown")
            VStack(alignment: .leading, spacing: 4) {
                breakdownLine("Standard rate", value: "\(ScheduleCoverageFormat.hours(detail.standardRateHours))h · 1×", color: ProjectWorksRevampColors.blue)
                if detail.overtimeHours > 0.05 {
                    breakdownLine(
                        "Overtime",
                        value: "\(ScheduleCoverageFormat.overtimeEquation(rawHours: detail.overtimeHours, multiplier: detail.overtimeMultiplier))h",
                        color: ProjectWorksRevampColors.upcomingAmber
                    )
                }
                if detail.showsBreakLine {
                    breakdownLine("Break", value: "−\(ScheduleCoverageFormat.hours(detail.breakDeductionHours))h", color: ProjectWorksRevampColors.requiredPillFg)
                }
                breakdownLine("Existing booked", value: "\(ScheduleCoverageFormat.hours(existingPaidHours))h", color: ProjectWorksRevampColors.muted)
                breakdownLine("New booking", value: "\(ScheduleCoverageFormat.hours(paid))h", color: ProjectWorksRevampColors.activeGreen)
                breakdownLine("Total booked", value: "\(ScheduleCoverageFormat.hours(total))h", color: ProjectWorksRevampColors.ink)
                if missing > 0.05 {
                    breakdownLine("Missing to standard day", value: "\(ScheduleCoverageFormat.hours(missing))h", color: ProjectWorksRevampColors.upcomingAmber)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProjectWorksRevampColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
            )
        }
    }

    private func breakdownLine(_ title: String, value: String, color: Color) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
        }
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Notes")
            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(size: 14))
                .padding(10)
                .background(ProjectWorksRevampColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(ProjectWorksRevampColors.border, lineWidth: 0.5)
                )
                .accessibilityIdentifier("scheduleQuickAdd.notes")
        }
    }

    private var saveButton: some View {
        Button {
            guard !isSaving else { return }
            guard let clocks else {
                errorMessage = "Working hours are not available."
                return
            }
            let range = selectedRange(clocks)
            guard slot != .custom || customEnd > customStart else {
                errorMessage = "Choose an end time after the start time."
                return
            }
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let draft = ScheduleQuickAddDraft(
                timeSlot: selectedTimeSlot,
                workStart: range.start,
                workEnd: range.end,
                notes: showsNotes && !trimmed.isEmpty ? trimmed : nil
            )
            isSaving = true
            errorMessage = nil
            Task {
                let message = await onSave(draft)
                isSaving = false
                if let message {
                    errorMessage = message
                }
            }
        } label: {
            Text(isSaving ? "Saving…" : "Save")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(clocks == nil ? ProjectWorksRevampColors.muted : ProjectWorksRevampColors.blue)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityIdentifier("scheduleQuickAdd.save")
        .buttonStyle(.plain)
        .disabled(clocks == nil || isSaving)
    }

    private var selectedTimeSlot: TimeSlot {
        switch slot {
        case .fullDay: return .fullDay
        case .morning: return .morning
        case .afternoon: return .afternoon
        case .custom: return .customHours
        }
    }

    private func selectedRange(_ clocks: ScheduleQuickAddClocks) -> ScheduleClockRange {
        switch slot {
        case .fullDay: return clocks.fullDay
        case .morning: return clocks.morning
        case .afternoon: return clocks.afternoon
        case .custom:
            return ScheduleClockRange(
                start: ScheduleWeekGrid.clockText(customStart),
                end: ScheduleWeekGrid.clockText(customEnd)
            )
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProjectWorksRevampColors.muted)
            .tracking(0.4)
    }

    private enum Slot {
        case fullDay, morning, afternoon, custom

        var identifier: String {
            switch self {
            case .fullDay: return "fullDay"
            case .morning: return "am"
            case .afternoon: return "pm"
            case .custom: return "custom"
            }
        }
    }
}
