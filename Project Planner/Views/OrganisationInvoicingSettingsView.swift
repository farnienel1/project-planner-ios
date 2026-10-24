//
//  OrganisationInvoicingSettingsView.swift
//  Project Planner
//

import SwiftUI

struct OrganisationInvoicingSettingsView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var notificationService: NotificationService
    @Environment(\.dismiss) private var dismiss

    @State private var draft: OrganizationInvoicingSettings = .default
    @State private var baseline: OrganizationInvoicingSettings = .default
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var didLoad = false

    private var isDirty: Bool { draft != baseline }

    private var showsMonthCoverage: Bool {
        CanonicalBusinessEngine.paymentRunShowsMonthCoverage(draft.canonicalInvoicingSettings()) == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                atAGlanceCard

                numberedStep(
                    1,
                    title: "How you run pay",
                    description: "Pick how your pay periods are set up."
                )
                VStack(spacing: 10) {
                    paymentRunModeButton(
                        title: "Set payment run date ranges",
                        description: "Two runs a month on fixed days of the month.",
                        example: "e.g. 1st–15th and 16th–31st",
                        mode: .dateRanges
                    )
                    paymentRunModeButton(
                        title: "Choose recurring timeframe",
                        description: "A weekly run, paid in arrears for the previous week.",
                        example: "e.g. Monday to Sunday, paid Friday",
                        mode: .recurringTimeframe
                    )
                }
                .padding(.bottom, 4)

                numberedStep(
                    2,
                    title: "Pay periods",
                    description: draft.paymentRunMode == .dateRanges
                        ? "Both runs together must cover days 1–31 with no gaps or overlaps, e.g. run 1: 1–15, run 2: 16–31."
                        : "The working week each payment covers."
                )
                SettingsHubChrome.card {
                    if draft.paymentRunMode == .dateRanges {
                        let ranges = editorRanges
                        ForEach(Array(ranges.enumerated()), id: \.offset) { index, item in
                            if index > 0 {
                                SettingsHubChrome.divider()
                            }
                            paymentRunRangeRow(index: index, item: item)
                        }
                        if showsMonthCoverage {
                            PaymentRunMonthStrip(days: coverageDays)
                                .padding(.vertical, 12)
                        }
                    } else {
                        dayMenuRow(title: "Start day", selection: $draft.recurringRunStartDay)
                        dayMenuRow(title: "End day", selection: $draft.recurringRunEndDay)
                        Text(draft.recurringRunDisplaySummary)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(ProjectWorksRevampColors.grayTint)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.bottom, 12)
                    }
                }

                numberedStep(3, title: "Pay day", description: "When operatives are paid for each run.")
                SettingsHubChrome.card {
                    paymentDateModePicker
                        .padding(.vertical, 12)

                    if draft.paymentDateMode == .specificDates {
                        ForEach(0..<2, id: \.self) { index in
                            monthDayMenuRow(
                                title: "Payment date \(index + 1)",
                                day: draft.paymentDates.indices.contains(index) ? draft.paymentDates[index] : 0
                            ) { day in
                                setPaymentDate(at: index, day: day)
                            }
                        }
                    } else {
                        dayMenuRow(
                            title: "Recurring payment date",
                            selection: Binding(
                                get: { draft.recurringPaymentDay },
                                set: { setRecurringPaymentDay($0) }
                            ),
                            prefix: "Every "
                        )
                        .padding(.bottom, 8)
                    }
                }

                timesheetSubmissionSection

                numberedStep(
                    5,
                    title: "Note to operatives",
                    description: "Shown on operative timesheet pages. Add anything specific, e.g. submit price work by Thursday."
                )
                SettingsHubChrome.card {
                    TextEditor(text: $draft.noteToUsers)
                        .accessibilityIdentifier("organisationInvoicingSettings.textEditor")
                        .frame(minHeight: 120)
                        .font(.system(size: 13))
                        .padding(.vertical, 8)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ProjectWorksRevampColors.requiredPillBg)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.bottom, 8)
                }

            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Payment runs & timesheets")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
        .safeAreaInset(edge: .bottom) {
            SettingsStickySaveBar(title: "Save", isDirty: isDirty, isSaving: isSaving) {
                Task { await save() }
            }
        }
        .settingsUnsavedLeave(isDirty: isDirty) {
            draft = baseline
            dismiss()
        }
        .onAppear {
            guard !didLoad else { return }
            draft = firebaseBackend.currentOrganization?.settings.invoicing ?? .default
            ensureTwoDateRanges()
            draft.refreshRecurringSummaryFromDays()
            adoptTimesheetRowsFromScript()
            baseline = draft
            didLoad = true
        }
        .onChange(of: draft.paymentRunMode) { _, mode in
            if mode == .recurringTimeframe {
                draft.paymentDateMode = .recurringDate
                draft.refreshRecurringSummaryFromDays()
            } else {
                draft.paymentDateMode = .specificDates
                ensureTwoDateRanges()
            }
            adoptTimesheetRowsFromScript()
        }
        .onChange(of: draft.recurringRunStartDay) { _, _ in
            draft.refreshRecurringSummaryFromDays()
        }
        .onChange(of: draft.recurringRunEndDay) { _, _ in
            draft.refreshRecurringSummaryFromDays()
        }
    }

    @ViewBuilder
    private func paymentRunRangeRow(index: Int, item: PaymentRunDateRange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                Text("Run \(index + 1)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 52, minHeight: 28)
                    .background(index == 0 ? PaymentRunStripPalette.run1 : PaymentRunStripPalette.run2)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                monthDayMenuRow(title: "Start day", day: item.startDay) { day in
                    setRangeDay(at: index, isStart: true, day: day)
                }
                monthDayMenuRow(title: "End day", day: item.endDay) { day in
                    setRangeDay(at: index, isStart: false, day: day)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func paymentRunModeButton(
        title: String,
        description: String,
        example: String,
        mode: PaymentRunConfigurationMode
    ) -> some View {
        let selected = draft.paymentRunMode == mode
        Button {
            draft.paymentRunMode = mode
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.muted)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                        .multilineTextAlignment(.leading)
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .multilineTextAlignment(.leading)
                    Text(example)
                        .font(.system(size: 12))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? ProjectWorksRevampColors.blue.opacity(0.08) : ProjectWorksRevampColors.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? ProjectWorksRevampColors.blue.opacity(0.35) : ProjectWorksRevampColors.border, lineWidth: 1)
            )
        }
        .accessibilityIdentifier("organisationInvoicingSettings.\(AccessibilityID.token(title))")
        .buttonStyle(.plain)
    }

    private var editorRanges: [PaymentRunDateRange] {
        Array(draft.paymentRunDateRanges.prefix(2))
    }

    private var coverageDays: [PaymentRunMonthCoverage.Day] {
        PaymentRunMonthCoverage.days(in: editorRanges.map {
            CanonicalBusinessEngine.CanonicalPaymentRunRange(startDay: $0.startDay, endDay: $0.endDay)
        })
    }

    private var glanceLines: [String] {
        if draft.paymentRunMode == .dateRanges {
            return editorRanges.enumerated().map { index, range in
                let span = ordinalSpan(start: range.startDay, end: range.endDay)
                let pay = draft.paymentDateMode == .specificDates ? paidOn(index) : "pay date not set"
                return "Run \(index + 1): work from the \(span), \(pay)"
            }
        }
        let week = "Weekly in arrears: \(draft.recurringRunStartDay.title) to \(draft.recurringRunEndDay.title) of the previous week"
        if draft.paymentDateMode == .recurringDate {
            return [week, "Paid every \(draft.recurringPaymentDay.title)"]
        }
        let dates = draft.paymentDates
            .map { PaymentRunDateRange.clampDay($0) }
            .filter { (1...31).contains($0) }
            .compactMap { ordinalDay($0) }
        let paid = dates.isEmpty ? "dates not set" : dates.map { "the \($0)" }.joined(separator: " and ")
        return [week, "Paid on \(paid)"]
    }

    private var atAGlanceCard: some View {
        SettingsHubChrome.card {
            VStack(alignment: .leading, spacing: 6) {
                Text("At a glance")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .padding(.top, 12)
                ForEach(Array(glanceLines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(ProjectWorksRevampColors.blue)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        Text(line)
                            .font(.system(size: 14))
                            .foregroundStyle(ProjectWorksRevampColors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Set your pay periods first, then the pay day. Warnings can use the end of the pay period for detection.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .padding(.bottom, 12)
            }
        }
    }

    private func numberedStep(_ step: Int, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(step)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ProjectWorksRevampColors.card)
                .frame(width: 24, height: 24)
                .background(ProjectWorksRevampColors.ink)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var paymentDateModePicker: some View {
        let recurringRun = draft.paymentRunMode == .recurringTimeframe
        return HStack(spacing: 6) {
            dateModeButton("Set payment date/s", mode: .specificDates, enabled: !recurringRun)
            dateModeButton("Recurring payment date", mode: .recurringDate, enabled: recurringRun)
        }
        .padding(3)
        .background(ProjectWorksRevampColors.grayTint)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("organisationInvoicingSettings.dateMode")
    }

    private func dateModeButton(_ title: String, mode: PaymentDateConfigurationMode, enabled: Bool) -> some View {
        let selected = draft.paymentDateMode == mode
        return Button {
            guard enabled else { return }
            draft.paymentDateMode = mode
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(selected ? ProjectWorksRevampColors.ink : ProjectWorksRevampColors.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? ProjectWorksRevampColors.card : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private func ensureTwoDateRanges() {
        guard draft.paymentRunMode == .dateRanges else { return }
        if draft.paymentRunDateRanges.count >= 2 {
            draft.paymentRunDateRanges = Array(draft.paymentRunDateRanges.prefix(2))
            return
        }
        if draft.paymentRunDateRanges.isEmpty {
            draft.paymentRunDateRanges = [
                PaymentRunDateRange(startDay: 1, endDay: 15),
                PaymentRunDateRange(startDay: 16, endDay: 31),
            ]
        } else {
            draft.paymentRunDateRanges.append(PaymentRunDateRange(startDay: 16, endDay: 31))
        }
    }

    private func setRangeDay(at index: Int, isStart: Bool, day: Int) {
        var ranges = draft.paymentRunDateRanges
        while ranges.count <= index {
            ranges.append(PaymentRunDateRange(startDay: index == 0 ? 1 : 16, endDay: index == 0 ? 15 : 31))
        }
        let clamped = PaymentRunDateRange.clampDay(day)
        if isStart {
            ranges[index].startDay = clamped
        } else {
            ranges[index].endDay = clamped
        }
        draft.paymentRunDateRanges = Array(ranges.prefix(2))
    }

    private func ordinalDay(_ day: Int) -> String? {
        let text = CanonicalBusinessEngine.monthDayOrdinal(day)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private func ordinalSpan(start: Int, end: Int) -> String {
        guard let startText = ordinalDay(start), let endText = ordinalDay(end) else { return "not set" }
        return "\(startText)–\(endText)"
    }

    private func paidOn(_ index: Int) -> String {
        guard draft.paymentDates.indices.contains(index), let text = ordinalDay(draft.paymentDates[index]) else {
            return "pay date not set"
        }
        return "paid on the \(text)"
    }

    @ViewBuilder
    private func monthDayMenuRow(title: String, day: Int, onSelect: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.muted)
            Menu {
                ForEach(1...31, id: \.self) { option in
                    Button(ordinalDay(option) ?? "\(option)") { onSelect(option) }
                }
            } label: {
                HStack {
                    Text(ordinalDay(day) ?? "Select")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.ink)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(ProjectWorksRevampColors.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityIdentifier("organisationInvoicingSettings.\(AccessibilityID.token(title))")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func dayMenuRow(title: String, selection: Binding<RecurringPaymentDay>, prefix: String = "") -> some View {
        HStack {
            Text(title)
                .font(.body)
            Spacer()
            Menu {
                ForEach(RecurringPaymentDay.allCases) { day in
                    Button {
                        selection.wrappedValue = day
                    } label: {
                        Text("\(prefix)\(day.title)")
                    }
                        .accessibilityIdentifier("organisationInvoicingSettings.row.\(day.id).\(AccessibilityID.token(title))")
                }
            } label: {
                HStack(spacing: 6) {
                    Text("\(prefix)\(selection.wrappedValue.title)")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ProjectWorksRevampColors.blue)
                }
            }
                .accessibilityIdentifier("organisationInvoicingSettings.\(AccessibilityID.token(title))2")
        }
    }

    /// Payment-day edits ask the script whether deadline and notify-at should move.
    private func setPaymentDate(at index: Int, day: Int) {
        var dates = draft.paymentDates.map { PaymentRunDateRange.clampDay($0) }
        let clamped = PaymentRunDateRange.clampDay(day)
        while dates.count <= index {
            dates.append(clamped)
        }
        dates[index] = clamped
        draft.paymentDates = Array(dates.prefix(2))
        var rows = draft.timesheetSubmission ?? []
        if !rows.indices.contains(index) {
            adoptTimesheetRowsFromScript()
            rows = draft.timesheetSubmission ?? []
        }
        guard rows.indices.contains(index),
              let next = CanonicalBusinessEngine.timesheetSubmissionAfterPaymentDayChange(rows[index], paymentDay: clamped) else {
            return
        }
        rows[index] = next
        draft.timesheetSubmission = rows
    }

    private func setRecurringPaymentDay(_ day: RecurringPaymentDay) {
        draft.recurringPaymentDay = day
        var rows = draft.timesheetSubmission ?? []
        if rows.isEmpty {
            adoptTimesheetRowsFromScript()
            rows = draft.timesheetSubmission ?? []
        }
        guard let current = rows.first,
              let next = CanonicalBusinessEngine.timesheetSubmissionAfterPaymentWeekdayChange(
                current,
                paymentWeekday: day.rawValue
              ) else {
            return
        }
        rows[0] = next
        draft.timesheetSubmission = rows
    }

    /// Reads deadline and notify-at from the script. A nil result leaves the draft unchanged.
    private func adoptTimesheetRowsFromScript() {
        guard let rows = CanonicalBusinessEngine.parseTimesheetSubmissionList(draft.timesheetSubmissionListInput()) else {
            return
        }
        draft.timesheetSubmission = rows
    }

    private func customiseTimesheet(
        at index: Int,
        _ update: (inout CanonicalBusinessEngine.CanonicalTimesheetSubmissionEntry) -> Void
    ) {
        var rows = draft.timesheetSubmission ?? []
        guard rows.indices.contains(index) else { return }
        update(&rows[index])
        rows[index].notifyCustomised = true
        draft.timesheetSubmission = rows
    }

    private func resetTimesheet(at index: Int) {
        if draft.paymentRunMode == .recurringTimeframe {
            guard let row = CanonicalBusinessEngine.defaultTimesheetSubmissionFromPaymentWeekday(
                draft.recurringPaymentDay.rawValue
            ) else { return }
            draft.timesheetSubmission = [row]
            return
        }
        let day = draft.normalizedPaymentDates.indices.contains(index) ? draft.normalizedPaymentDates[index] : 0
        guard let row = CanonicalBusinessEngine.defaultTimesheetSubmissionFromPaymentDay(day) else { return }
        var rows = draft.timesheetSubmission ?? []
        if rows.indices.contains(index) {
            rows[index] = row
        } else {
            rows.append(row)
        }
        draft.timesheetSubmission = rows
    }

    @ViewBuilder
    private var timesheetSubmissionSection: some View {
        let rows = draft.timesheetSubmission ?? []
        numberedStep(4, title: "Timesheet reminders", description: timesheetSectionIntro)
        SettingsHubChrome.card {
            VStack(alignment: .leading, spacing: 14) {
                if rows.isEmpty {
                    Text("Timesheet reminder times will appear when these payment settings can be read.")
                        .font(.system(size: 12))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                } else if draft.paymentRunMode == .recurringTimeframe, let row = rows.first {
                    timesheetRowEditor(index: 0, row: row, title: nil)
                } else {
                    ForEach(Array(rows.prefix(2).enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            SettingsHubChrome.divider()
                        }
                        timesheetRowEditor(index: index, row: row, title: "Run \(index + 1)")
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }

    private var timesheetSectionIntro: String {
        if draft.paymentRunMode == .recurringTimeframe {
            return "Remind everyone who submits timesheets about the previous payment run. Defaults are 08:00 three days before payday, and close of play the day before."
        }
        return "One reminder per payment run. Changing the payment day refreshes these times unless you have customised that row."
    }

    @ViewBuilder
    private func timesheetRowEditor(
        index: Int,
        row: CanonicalBusinessEngine.CanonicalTimesheetSubmissionEntry,
        title: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 52, minHeight: 28)
                    .background(index == 0 ? PaymentRunStripPalette.run1 : PaymentRunStripPalette.run2)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text(timesheetPaymentLabel(at: index))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ProjectWorksRevampColors.ink)

            if draft.paymentRunMode == .recurringTimeframe {
                weekdayChoice(
                    title: "Timesheets to be submitted by",
                    selection: row.timesheetDeadlineWeekday
                ) { day in
                    customiseTimesheet(at: index) { $0.timesheetDeadlineWeekday = day }
                }
                clockChoice(
                    title: "Deadline time",
                    hour: row.timesheetDeadlineHour,
                    minute: row.timesheetDeadlineMinute
                ) { hour, minute in
                    customiseTimesheet(at: index) {
                        $0.timesheetDeadlineHour = hour
                        $0.timesheetDeadlineMinute = minute
                    }
                }
                weekdayChoice(
                    title: "When to send the notification",
                    selection: row.notifyWeekday
                ) { day in
                    customiseTimesheet(at: index) { $0.notifyWeekday = day }
                }
                clockChoice(
                    title: "Notification time",
                    hour: row.notifyHour,
                    minute: row.notifyMinute
                ) { hour, minute in
                    customiseTimesheet(at: index) {
                        $0.notifyHour = hour
                        $0.notifyMinute = minute
                    }
                }
            } else {
                let paymentDay = draft.normalizedPaymentDates.indices.contains(index)
                    ? draft.normalizedPaymentDates[index]
                    : 0
                monthDayChoice(
                    title: "Timesheets to be submitted by",
                    day: row.timesheetDeadlineDay,
                    enabled: paymentDay > 0
                ) { day in
                    customiseTimesheet(at: index) { $0.timesheetDeadlineDay = day }
                }
                clockChoice(
                    title: "Deadline time",
                    hour: row.timesheetDeadlineHour,
                    minute: row.timesheetDeadlineMinute,
                    enabled: paymentDay > 0
                ) { hour, minute in
                    customiseTimesheet(at: index) {
                        $0.timesheetDeadlineHour = hour
                        $0.timesheetDeadlineMinute = minute
                    }
                }
                monthDayChoice(
                    title: "When to send the notification",
                    day: row.notifyDay,
                    enabled: paymentDay > 0
                ) { day in
                    customiseTimesheet(at: index) { $0.notifyDay = day }
                }
                clockChoice(
                    title: "Notification time",
                    hour: row.notifyHour,
                    minute: row.notifyMinute,
                    enabled: paymentDay > 0
                ) { hour, minute in
                    customiseTimesheet(at: index) {
                        $0.notifyHour = hour
                        $0.notifyMinute = minute
                    }
                }
            }

            let preview = timesheetPreview(at: index, row: row)
            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 13))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ProjectWorksRevampColors.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if row.notifyCustomised {
                Button("Reset to payment-day defaults") {
                    resetTimesheet(at: index)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ProjectWorksRevampColors.blue)
                .buttonStyle(.plain)
                .accessibilityIdentifier("organisationInvoicingSettings.resetTimesheet.\(index)")
            } else {
                Text("Auto-filled from the payment day. Edit to keep a custom pair.")
                    .font(.system(size: 11))
                    .foregroundStyle(ProjectWorksRevampColors.muted)
            }
        }
        .padding(.vertical, 4)
    }

    private func timesheetPaymentLabel(at index: Int) -> String {
        if draft.paymentRunMode == .recurringTimeframe {
            return "Paid every \(draft.recurringPaymentDay.title)"
        }
        let day = draft.normalizedPaymentDates.indices.contains(index) ? draft.normalizedPaymentDates[index] : 0
        return day > 0 ? "Paid on the \(ordinalDay(day) ?? "\(day)")" : "Set a payment date above"
    }

    private func timesheetPreview(
        at index: Int,
        row: CanonicalBusinessEngine.CanonicalTimesheetSubmissionEntry
    ) -> String {
        if draft.paymentRunMode == .recurringTimeframe {
            return CanonicalBusinessEngine.timesheetSubmissionNoticeCopy(
                CanonicalBusinessEngine.CanonicalTimesheetNoticeCopyInput(
                    mode: "recurring_timeframe",
                    deadlineWeekday: row.timesheetDeadlineWeekday,
                    paymentWeekday: draft.recurringPaymentDay.rawValue,
                    deadlineHour: row.timesheetDeadlineHour,
                    deadlineMinute: row.timesheetDeadlineMinute
                )
            ) ?? ""
        }
        let paymentDay = draft.normalizedPaymentDates.indices.contains(index) ? draft.normalizedPaymentDates[index] : 0
        return CanonicalBusinessEngine.timesheetSubmissionNoticeCopy(
            CanonicalBusinessEngine.CanonicalTimesheetNoticeCopyInput(
                mode: "date_ranges",
                deadlineDay: row.timesheetDeadlineDay,
                paymentDay: paymentDay,
                deadlineHour: row.timesheetDeadlineHour,
                deadlineMinute: row.timesheetDeadlineMinute
            )
        ) ?? ""
    }

    @ViewBuilder
    private func monthDayChoice(
        title: String,
        day: Int,
        enabled: Bool,
        onSelect: @escaping (Int) -> Void
    ) -> some View {
        choiceRow(title: title, value: day >= 1 && day <= 31 ? "\(day)" : "Select", enabled: enabled) {
            ForEach(1...31, id: \.self) { option in
                Button("\(option)") { onSelect(option) }
            }
        }
    }

    @ViewBuilder
    private func weekdayChoice(
        title: String,
        selection: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        let current = RecurringPaymentDay(rawValue: selection)?.title ?? "Select"
        choiceRow(title: title, value: current, enabled: true) {
            ForEach(RecurringPaymentDay.allCases) { day in
                Button(day.title) { onSelect(day.rawValue) }
            }
        }
    }

    @ViewBuilder
    private func clockChoice(
        title: String,
        hour: Int,
        minute: Int,
        enabled: Bool = true,
        onSelect: @escaping (Int, Int) -> Void
    ) -> some View {
        let options = timesheetClockOptions(hour: hour, minute: minute)
        choiceRow(title: title, value: timesheetClockLabel(hour: hour, minute: minute), enabled: enabled) {
            ForEach(options, id: \.self) { total in
                Button(timesheetClockLabel(totalMinutes: total)) {
                    onSelect(total / 60, total % 60)
                }
            }
        }
    }

    @ViewBuilder
    private func choiceRow<MenuContent: View>(
        title: String,
        value: String,
        enabled: Bool,
        @ViewBuilder menu: () -> MenuContent
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(ProjectWorksRevampColors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Menu {
                menu()
            } label: {
                HStack(spacing: 6) {
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(enabled ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.muted)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(enabled ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.muted)
                }
            }
            .disabled(!enabled)
        }
    }

    private func timesheetClockOptions(hour: Int, minute: Int) -> [Int] {
        var options = Array(stride(from: 0, through: 23 * 60 + 30, by: 30))
        let current = max(0, hour) * 60 + max(0, minute)
        if (0...23 * 60 + 59).contains(current), !options.contains(current) {
            options.append(current)
            options.sort()
        }
        return options
    }

    private func timesheetClockLabel(hour: Int, minute: Int) -> String {
        timesheetClockLabel(totalMinutes: hour * 60 + minute)
    }

    private func timesheetClockLabel(totalMinutes: Int) -> String {
        let hour24 = max(0, min(23, totalMinutes / 60))
        let minute = max(0, min(59, totalMinutes % 60))
        let hour12 = hour24 == 0 ? 12 : (hour24 > 12 ? hour24 - 12 : hour24)
        let suffix = hour24 >= 12 ? "PM" : "AM"
        return String(format: "%d:%02d %@", hour12, minute, suffix)
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        ensureTwoDateRanges()
        adoptTimesheetRowsFromScript()
        if let message = CanonicalBusinessEngine.validateInvoicingSettings(draft.canonicalInvoicingSettings()) {
            errorMessage = message
            return
        }

        do {
            try await firebaseBackend.updateOrganizationInvoicingSettings(draft)
            await notificationService.refreshTimesheetSubmissionReminders()
            baseline = draft
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Colours for the payment-run strip. Light and dark values are the web `--blue`, `--ops`, and `--red` tokens.
private enum PaymentRunStripPalette {
    static let run1 = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(30.0 / 255, 90.0 / 255, 168.0 / 255),
        dark: AppAdaptiveColor.rgb(76.0 / 255, 139.0 / 255, 230.0 / 255)
    )
    static let run2 = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(11.0 / 255, 142.0 / 255, 128.0 / 255),
        dark: AppAdaptiveColor.rgb(52.0 / 255, 205.0 / 255, 187.0 / 255)
    )
    static let overlap = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(210.0 / 255, 54.0 / 255, 54.0 / 255),
        dark: AppAdaptiveColor.rgb(255.0 / 255, 107.0 / 255, 107.0 / 255)
    )
    static let covered = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(14.0 / 255, 148.0 / 255, 103.0 / 255),
        dark: AppAdaptiveColor.rgb(59.0 / 255, 203.0 / 255, 152.0 / 255)
    )
    static let hatch = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(238.0 / 255, 242.0 / 255, 248.0 / 255),
        dark: AppAdaptiveColor.rgb(28.0 / 255, 40.0 / 255, 66.0 / 255)
    )
    static let gapBorder = AppAdaptiveColor.dynamic(
        light: AppAdaptiveColor.rgb(213.0 / 255, 220.0 / 255, 231.0 / 255),
        dark: AppAdaptiveColor.rgb(46.0 / 255, 61.0 / 255, 92.0 / 255)
    )
}

/// The 1–31 graphic from the web `MonthCoverage`. Membership is `normalizePaymentRunRange`
/// plus start ≤ day ≤ end. It does not wrap, and it is not the save gate.
enum PaymentRunMonthCoverage {
    enum DayState: Equatable {
        case run1
        case run2
        case overlap
        case gap
    }

    struct Day: Equatable {
        var day: Int
        var state: DayState
    }

    enum Legend: Equatable {
        case coveredOnce
        case issues(gaps: Int, overlaps: Int)

        var text: String {
            switch self {
            case .coveredOnce:
                return "✓ Every day covered once"
            case .issues(let gaps, let overlaps):
                var parts: [String] = []
                if gaps > 0 {
                    parts.append("\(gaps) day\(gaps == 1 ? "" : "s") not covered")
                }
                if overlaps > 0 {
                    parts.append("\(overlaps) day\(overlaps == 1 ? "" : "s") in both runs")
                }
                return parts.joined(separator: " · ")
            }
        }
    }

    static func days(in ranges: [CanonicalBusinessEngine.CanonicalPaymentRunRange]) -> [Day] {
        let normalized: [(Int, Int)?] = (0..<2).map { index in
            guard ranges.indices.contains(index) else { return nil }
            guard let range = CanonicalBusinessEngine.normalizePaymentRunRange(
                startDay: ranges[index].startDay,
                endDay: ranges[index].endDay
            ) else { return nil }
            return (range.startDay, range.endDay)
        }
        return (1...31).map { day in
            let one = contains(normalized[0], day)
            let two = contains(normalized[1], day)
            let state: DayState = one && two ? .overlap : one ? .run1 : two ? .run2 : .gap
            return Day(day: day, state: state)
        }
    }

    static func legend(for days: [Day]) -> Legend {
        let gaps = days.filter { $0.state == .gap }.count
        let overlaps = days.filter { $0.state == .overlap }.count
        if gaps == 0 && overlaps == 0 { return .coveredOnce }
        return .issues(gaps: gaps, overlaps: overlaps)
    }

    /// Linear, same as the web strip: a day is in the run only when start and end are set and start ≤ day ≤ end.
    private static func contains(_ range: (Int, Int)?, _ day: Int) -> Bool {
        guard let range, range.0 > 0, range.1 > 0 else { return false }
        return day >= range.0 && day <= range.1
    }
}

private struct PaymentRunMonthStrip: View {
    let days: [PaymentRunMonthCoverage.Day]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 4),
            count: horizontalSizeClass == .regular ? 31 : 16
        )
        let legend = PaymentRunMonthCoverage.legend(for: days)
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(days, id: \.day) { item in
                    dayCell(item)
                }
            }
            .accessibilityHidden(true)
            HStack(spacing: 16) {
                legendSwatch(PaymentRunStripPalette.run1, title: "Run 1")
                legendSwatch(PaymentRunStripPalette.run2, title: "Run 2")
            }
            Text(legend.text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(legend == .coveredOnce ? PaymentRunStripPalette.covered : PaymentRunStripPalette.overlap)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(ProjectWorksRevampColors.grayTint)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func dayCell(_ item: PaymentRunMonthCoverage.Day) -> some View {
        Text("\(item.day)")
            .font(.system(size: 10.5, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(item.state == .gap ? ProjectWorksRevampColors.muted : Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(cellBackground(item.state))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(item.state == .gap ? PaymentRunStripPalette.gapBorder : Color.clear, lineWidth: 1.5)
            )
    }

    @ViewBuilder
    private func cellBackground(_ state: PaymentRunMonthCoverage.DayState) -> some View {
        switch state {
        case .run1:
            PaymentRunStripPalette.run1
        case .run2:
            PaymentRunStripPalette.run2
        case .overlap:
            PaymentRunStripPalette.overlap
        case .gap:
            ZStack {
                ProjectWorksRevampColors.card
                PaymentRunGapHatch()
            }
        }
    }

    private func legendSwatch(_ color: Color, title: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(ProjectWorksRevampColors.ink)
        }
    }
}

private struct PaymentRunGapHatch: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 6
            var x = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(PaymentRunStripPalette.hatch), lineWidth: 3)
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

