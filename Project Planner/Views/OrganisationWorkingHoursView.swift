//
//  OrganisationWorkingHoursView.swift
//  Project Planner
//
//  Edits organisations/{orgId}.payrollTimePolicy — weekday, Saturday, Sunday, save + schedule.
//

import SwiftUI

struct OrganisationWorkingHoursView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss

    @State private var draft = OrgPayrollTimePolicy.default
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingImmediateSaveWarning = false
    @State private var showingScheduleSheet = false
    @State private var scheduleEffectiveDate = Calendar.current.startOfDay(for: Date())

    private var scheduledChange: OrgPayrollTimePolicyScheduledChange? {
        firebaseBackend.currentOrganization?.payrollTimePolicyScheduled
    }

    var body: some View {
        Form {
            if let scheduled = scheduledChange {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scheduled change")
                            .font(.subheadline.weight(.semibold))
                        Text("New working hours take effect on \(scheduled.effectiveFrom.formatted(date: .abbreviated, time: .omitted)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            weekdaySection
            saturdaySection
            sundaySection

            Section {
                Button {
                    showingScheduleSheet = true
                } label: {
                    Label("Schedule Working Hours Change", systemImage: "calendar.badge.clock")
                }
            } footer: {
                Text("Queue these settings for a future date. Any existing scheduled change will be replaced.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Working hours")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") {
                        showingImmediateSaveWarning = true
                    }
                    .disabled(!isFormValid)
                }
            }
        }
        .onAppear { loadDraft() }
        .sheet(isPresented: $showingScheduleSheet) {
            scheduleChangeSheet
        }
        .alert("Apply changes today?", isPresented: $showingImmediateSaveWarning) {
            Button("Decline Changes", role: .cancel) { }
            Button("Approve Changes") {
                Task { await saveImmediately() }
            }
        } message: {
            Text("If you save these settings now, they will take immediate effect. Any bookings on today's schedule will have these new working hours applied. This will be reflected in the weekly report, timesheets and on invoices. If you would like these changes to take effect from a future date, then use the Schedule Changes Button.")
        }
    }

    // MARK: - Weekday

    private var weekdaySection: some View {
        Section {
            timeField("Start", text: $draft.standardDayStart)
            timeField("End", text: $draft.standardDayEnd)

            Toggle("Break is paid", isOn: $draft.breakPaid)
            Stepper("Break length: \(draft.unpaidBreakMinutes) min", value: $draft.unpaidBreakMinutes, in: 0...120, step: 5)

            timeField("Break window start", text: $draft.breakWindowStart)
            timeField("Break window end", text: $draft.breakWindowEnd)

            HStack {
                Text("Standard paid day")
                Spacer()
                Text("\(draft.computedWeekdayPaidHours, specifier: "%.1f")h")
                    .foregroundStyle(.secondary)
            }

            multiplierField("Outside window OT (Multiplier)", value: $draft.weekdayOutsideStandardMultiplier)

            weekdayTimelineBar
            weekdaySummaryCard
        } header: {
            Text("Weekday (Mon–Fri)")
        } footer: {
            Text("Hours outside \(draft.standardDayStart)–\(draft.standardDayEnd) are paid at the outside-window multiplier. Unpaid breaks are deducted when the booking spans the break window.")
        }
    }

    private var weekdayTimelineBar: some View {
        WorkingHoursTimelineBar(
            windowStart: draft.standardDayStart,
            windowEnd: draft.standardDayEnd,
            breakStart: draft.breakPaid ? nil : draft.breakWindowStart,
            breakEnd: draft.breakPaid ? nil : draft.breakWindowEnd,
            accentLabel: "\(draft.computedWeekdayPaidHours, specifier: "%.1f")h"
        )
        .frame(height: 36)
    }

    private var weekdaySummaryCard: some View {
        let example = PayrollHoursEngine.compute(
            choice: OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: draft.standardDayStart,
                workEndTime: "18:00",
                isBreakRemoved: false,
                otMultiplierOverride: nil
            ),
            day: nextWeekday(),
            policy: draft
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text("Example: \(draft.standardDayStart)–18:00")
                .font(.caption.weight(.medium))
            Text(example.breakdownSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Saturday

    private var saturdaySection: some View {
        weekendSection(title: "Saturday", settings: $draft.saturday, mirrorSaturday: false)
    }

    // MARK: - Sunday

    private var sundaySection: some View {
        Section {
            Toggle("Same setup as Saturday", isOn: $draft.sundaySameAsSaturday)
        } header: {
            Text("Sunday")
        }
        if !draft.sundaySameAsSaturday {
            weekendSectionInner(title: "Sunday", settings: $draft.sunday)
        } else {
            Section {
                Text("Sunday uses Saturday's rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func weekendSection(title: String, settings: Binding<OrgWeekendDayPayrollSettings>, mirrorSaturday: Bool) -> some View {
        Section {
            weekendSectionInner(title: title, settings: settings)
        } header: {
            Text(title)
        }
    }

    @ViewBuilder
    private func weekendSectionInner(title: String, settings: Binding<OrgWeekendDayPayrollSettings>) -> some View {
        Picker("Mode", selection: Binding(
            get: { settings.wrappedValue.allHoursAtMultiplierMode ? 1 : 0 },
            set: { mode in
                var w = settings.wrappedValue
                w.allHoursAtMultiplierMode = mode == 1
                if mode == 0 {
                    w.useCustomStandardDayWindow = true
                    if w.customStandardStart == nil { w.customStandardStart = draft.standardDayStart }
                    if w.customStandardEnd == nil { w.customStandardEnd = "13:00" }
                    if w.countsAsHours == nil { w.countsAsHours = draft.standardPaidHours }
                }
                settings.wrappedValue = w
            }
        )) {
            Text("Defined window").tag(0)
            Text("Hours × multiplier").tag(1)
        }
        .pickerStyle(.segmented)

        if settings.wrappedValue.allHoursAtMultiplierMode {
            multiplierField("Multiplier", value: Binding(
                get: { settings.wrappedValue.allHoursMultiplier },
                set: { settings.wrappedValue.allHoursMultiplier = $0 }
            ))
            Text("All clock hours on \(title) are paid at this multiplier. No break is deducted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            timeField("Window start", text: Binding(
                get: { settings.wrappedValue.customStandardStart ?? "" },
                set: { settings.wrappedValue.customStandardStart = $0.isEmpty ? nil : $0 }
            ))
            timeField("Window end", text: Binding(
                get: { settings.wrappedValue.customStandardEnd ?? "" },
                set: { settings.wrappedValue.customStandardEnd = $0.isEmpty ? nil : $0 }
            ))
            HStack {
                Text("Counts as")
                Spacer()
                TextField("h", value: Binding(
                    get: { settings.wrappedValue.countsAsHours ?? draft.standardPaidHours },
                    set: { settings.wrappedValue.countsAsHours = $0 }
                ), format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 72)
                Text("h")
            }
            multiplierField("Outside window (Multiplier)", value: Binding(
                get: { settings.wrappedValue.outsideStandardWindowMultiplier },
                set: { settings.wrappedValue.outsideStandardWindowMultiplier = $0 }
            ))

            if let start = settings.wrappedValue.customStandardStart,
               let end = settings.wrappedValue.customStandardEnd {
                WorkingHoursTimelineBar(
                    windowStart: start,
                    windowEnd: end,
                    breakStart: nil,
                    breakEnd: nil,
                    accentLabel: "\(settings.wrappedValue.resolvedCountsAsHours(fallback: draft.standardPaidHours), specifier: "%.1f")h"
                )
                .frame(height: 36)
            }

            weekendExampleCard(settings: settings.wrappedValue, title: title)
        }
    }

    private func weekendExampleCard(settings: OrgWeekendDayPayrollSettings, title: String) -> some View {
        let start = settings.customStandardStart ?? draft.standardDayStart
        let end = settings.customStandardEnd ?? "16:00"
        let day = title == "Saturday" ? nextSaturday() : nextSunday()
        let result = PayrollHoursEngine.compute(
            choice: OperativeDayBookingChoice(
                timeSlot: .customHours,
                workStartTime: start,
                workEndTime: end,
                isBreakRemoved: true,
                otMultiplierOverride: nil
            ),
            day: day,
            policy: draft
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text("Example: \(start)–\(end)")
                .font(.caption.weight(.medium))
            Text(result.breakdownSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Schedule sheet

    private var scheduleChangeSheet: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Effective from",
                    selection: $scheduleEffectiveDate,
                    in: Calendar.current.startOfDay(for: Date())...,
                    displayedComponents: .date
                )
                Section {
                    Text("Bookings before this date keep the current working hours. From this date onward, these draft settings apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Schedule change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingScheduleSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        Task { await saveScheduled() }
                    }
                    .disabled(!isFormValid || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Save

    private func loadDraft() {
        if let p = firebaseBackend.currentOrganization?.settings.payrollTimePolicy {
            draft = p
        }
    }

    private func saveImmediately() async {
        guard isFormValid else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await firebaseBackend.applyOrganizationPayrollTimePolicyImmediately(draft)
            await MainActor.run {
                isSaving = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveScheduled() async {
        guard isFormValid else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await firebaseBackend.scheduleOrganizationPayrollTimePolicyChange(draft, effectiveFrom: scheduleEffectiveDate)
            await MainActor.run {
                isSaving = false
                showingScheduleSheet = false
            }
        } catch {
            await MainActor.run {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Validation

    private var isFormValid: Bool {
        isValidHM(draft.standardDayStart)
            && isValidHM(draft.standardDayEnd)
            && isValidHM(draft.breakWindowStart)
            && isValidHM(draft.breakWindowEnd)
            && draft.weekdayOutsideStandardMultiplier > 0
            && weekendValid(draft.saturday)
            && (draft.sundaySameAsSaturday || weekendValid(draft.sunday))
    }

    private func weekendValid(_ w: OrgWeekendDayPayrollSettings) -> Bool {
        if w.allHoursMultiplier <= 0 || w.outsideStandardWindowMultiplier <= 0 { return false }
        if w.allHoursAtMultiplierMode { return true }
        guard let s = w.customStandardStart, let e = w.customStandardEnd,
              isValidHM(s), isValidHM(e) else { return false }
        return (w.countsAsHours ?? draft.standardPaidHours) > 0
    }

    private func timeField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .textInputAutocapitalization(.never)
            .keyboardType(.numbersAndPunctuation)
    }

    private func multiplierField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("×", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 64)
        }
    }

    private func isValidHM(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = trimmed.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) else { return false }
        guard r.lowerBound == trimmed.startIndex && r.upperBound == trimmed.endIndex else { return false }
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]) else { return false }
        return h >= 0 && h < 24 && m >= 0 && m < 60
    }

    private func nextWeekday() -> Date {
        var d = Date()
        let cal = Calendar.current
        while cal.component(.weekday, from: d) == 1 || cal.component(.weekday, from: d) == 7 {
            d = cal.date(byAdding: .day, value: 1, to: d) ?? d
        }
        return cal.startOfDay(for: d)
    }

    private func nextSaturday() -> Date {
        var d = Date()
        let cal = Calendar.current
        while cal.component(.weekday, from: d) != 7 {
            d = cal.date(byAdding: .day, value: 1, to: d) ?? d
        }
        return cal.startOfDay(for: d)
    }

    private func nextSunday() -> Date {
        var d = Date()
        let cal = Calendar.current
        while cal.component(.weekday, from: d) != 1 {
            d = cal.date(byAdding: .day, value: 1, to: d) ?? d
        }
        return cal.startOfDay(for: d)
    }
}

// MARK: - Computed weekday paid hours

private extension OrgPayrollTimePolicy {
    var computedWeekdayPaidHours: Double {
        guard let ds = ManagerScheduleInterval.parseMinutes(standardDayStart),
              let de = ManagerScheduleInterval.parseMinutes(standardDayEnd), de > ds else {
            return standardPaidHours
        }
        var hours = Double(de - ds) / 60.0
        if !breakPaid {
            hours = max(0, hours - standardUnpaidBreakHours)
        }
        return hours
    }
}

// MARK: - Timeline bar

private struct WorkingHoursTimelineBar: View {
    let windowStart: String
    let windowEnd: String
    let breakStart: String?
    let breakEnd: String?
    let accentLabel: String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let clipLo = 6 * 60
            let clipHi = 21 * 60
            let xPos: (Int) -> CGFloat = { minutes in
                let clipped = min(clipHi, max(clipLo, minutes))
                return CGFloat(clipped - clipLo) / CGFloat(clipHi - clipLo) * w
            }
            let ws = ManagerScheduleInterval.parseMinutes(windowStart) ?? clipLo
            let we = ManagerScheduleInterval.parseMinutes(windowEnd) ?? clipHi
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                if we > ws {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [ProjectWorksRevampColors.blue, ProjectWorksRevampColors.blueLight],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, xPos(we) - xPos(ws)), height: h)
                        .offset(x: xPos(ws))
                }
                if let bs = breakStart, let be = breakEnd,
                   let bsm = ManagerScheduleInterval.parseMinutes(bs),
                   let bem = ManagerScheduleInterval.parseMinutes(be), bem > bsm {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .frame(width: max(3, xPos(bem) - xPos(bsm)), height: h * 0.7)
                        .offset(x: xPos(bsm), y: h * 0.15)
                }
                Text(accentLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
