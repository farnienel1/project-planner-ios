//
//  OrganisationInvoicingSettingsView.swift
//  Project Planner
//

import SwiftUI

struct OrganisationInvoicingSettingsView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss

    @State private var draft: OrganizationInvoicingSettings = .default
    @State private var showHelp = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var coverageWarning: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHubChrome.card {
                    DisclosureGroup("How payment runs should be configured", isExpanded: $showHelp) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Date ranges need to cover the full month (days 1 to 31).")
                            Text("You can set one range or two ranges. Wrapped ranges are supported (for example 27 to 11).")
                            Text("For shorter months, invoice generation trims the run to that month’s last day.")
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .padding(.bottom, 10)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProjectWorksRevampColors.ink)
                    .padding(.vertical, 10)
                    .tint(ProjectWorksRevampColors.blue)
                }

                SettingsHubChrome.sectionTitle("Payment runs")
                SettingsHubChrome.card {
                    VStack(spacing: 10) {
                        paymentRunModeButton(
                            title: "Set payment run date ranges",
                            mode: .dateRanges
                        )
                        paymentRunModeButton(
                            title: "Choose recurring timeframe",
                            mode: .recurringTimeframe
                        )
                    }
                    .padding(.vertical, 12)

                    if draft.paymentRunMode == .dateRanges {
                        let ranges = draft.normalizedRanges
                        Text("Date ranges")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .textCase(.uppercase)
                            .tracking(0.4)
                        paymentRunRangeRow(
                            title: "Payment run date range 1",
                            index: 0,
                            item: ranges.first ?? PaymentRunDateRange(startDay: 1, endDay: 2)
                        )
                        if ranges.count > 1 {
                            paymentRunRangeRow(
                                title: "Payment run date range 2",
                                index: 1,
                                item: ranges[1]
                            )
                        }

                        if ranges.count < 2 {
                            Button {
                                var updated = ranges
                                let base = updated.first ?? PaymentRunDateRange(startDay: 1, endDay: 2)
                                let start = base.endDay == 31 ? 1 : base.endDay + 1
                                updated.append(PaymentRunDateRange(startDay: start, endDay: PaymentRunDateRange.defaultEndDay(for: start)))
                                draft.paymentRunDateRanges = updated
                            } label: {
                                HStack {
                                    Text("Add another payment run date range")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(ProjectWorksRevampColors.ink)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(ProjectWorksRevampColors.blue)
                                }
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        dayMenuRow(title: "Start day", selection: $draft.recurringRunStartDay)
                        dayMenuRow(title: "End day", selection: $draft.recurringRunEndDay)
                        Text(draft.recurringRunDisplaySummary)
                            .font(.system(size: 12))
                            .foregroundStyle(ProjectWorksRevampColors.muted)
                            .padding(.bottom, 10)
                    }
                }

                SettingsHubChrome.sectionTitle("Payment Day/Dates")
                SettingsHubChrome.card {
                    Picker("Date mode", selection: $draft.paymentDateMode) {
                        Text("Set Payment date/s").tag(PaymentDateConfigurationMode.specificDates)
                        Text("Recurring payment date").tag(PaymentDateConfigurationMode.recurringDate)
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 12)

                    if draft.paymentDateMode == .specificDates {
                        let dates = draft.normalizedPaymentDates
                        numericStepperRow(
                            title: "Payment date 1",
                            selection: paymentDateBinding(at: 0, fallback: dates.first ?? 1),
                            range: 1...31
                        )
                        if dates.count > 1 {
                            numericStepperRow(
                                title: "Payment date 2",
                                selection: paymentDateBinding(at: 1, fallback: dates[1]),
                                range: 1...31
                            )
                        } else {
                            Button {
                                var updated = dates
                                updated.append(min((dates.first ?? 1) + 14, 31))
                                draft.paymentDates = Array(updated.prefix(2))
                            } label: {
                                HStack {
                                    Text("Add another payment date")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(ProjectWorksRevampColors.ink)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(ProjectWorksRevampColors.blue)
                                }
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        dayMenuRow(
                            title: "Recurring payment date",
                            selection: $draft.recurringPaymentDay,
                            prefix: "Every "
                        )
                        .padding(.bottom, 8)
                    }
                }

                SettingsHubChrome.sectionTitle("Note to User")
                SettingsHubChrome.card {
                    TextEditor(text: $draft.noteToUsers)
                        .frame(minHeight: 120)
                        .font(.system(size: 13))
                        .padding(.vertical, 8)
                    Text("Use this section to explain how payment runs and timesheet requirements work. If there are specific requirements (for example submit price work by Thursday), detail them here. These notes appear on operative timesheet pages.")
                        .font(.system(size: 11))
                        .foregroundStyle(ProjectWorksRevampColors.muted)
                        .padding(.bottom, 12)
                }

                if let coverageWarning {
                    Text(coverageWarning)
                        .foregroundStyle(ProjectWorksRevampColors.requiredPillFg)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ProjectWorksRevampColors.requiredPillBg)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.bottom, 8)
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

                SettingsHubChrome.saveButton("Save Payment Run", isSaving: isSaving) {
                    Task { await save() }
                }
            }
            .padding(16)
        }
        .background(ProjectWorksRevampColors.canvas.ignoresSafeArea())
        .navigationTitle("Payment Runs and Timesheets")
        .navigationBarTitleDisplayMode(.inline)
        .appChromeNavigationBarSurface()
        .onAppear {
            draft = firebaseBackend.currentOrganization?.settings.invoicing ?? .default
            draft.refreshRecurringSummaryFromDays()
        }
        .onChange(of: draft.paymentRunMode) { _, mode in
            if mode == .recurringTimeframe {
                draft.paymentDateMode = .recurringDate
                draft.refreshRecurringSummaryFromDays()
            }
        }
        .onChange(of: draft.recurringRunStartDay) { _, _ in
            draft.refreshRecurringSummaryFromDays()
        }
        .onChange(of: draft.recurringRunEndDay) { _, _ in
            draft.refreshRecurringSummaryFromDays()
        }
    }

    @ViewBuilder
    private func paymentRunRangeRow(title: String, index: Int, item: PaymentRunDateRange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            numericStepperRow(
                title: "Start",
                selection: startBinding(at: index, fallback: item.startDay),
                range: 1...31
            )
            numericStepperRow(
                title: "End",
                selection: endBinding(at: index, fallback: item.endDay),
                range: 1...31
            )
        }
    }

    @ViewBuilder
    private func paymentRunModeButton(title: String, mode: PaymentRunConfigurationMode) -> some View {
        Button {
            draft.paymentRunMode = mode
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: draft.paymentRunMode == mode ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(draft.paymentRunMode == mode ? ProjectWorksRevampColors.blue : ProjectWorksRevampColors.muted)
                    .padding(.top, 1)
                Text(title)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(draft.paymentRunMode == mode ? ProjectWorksRevampColors.blue.opacity(0.08) : ProjectWorksRevampColors.canvas)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(draft.paymentRunMode == mode ? ProjectWorksRevampColors.blue.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func numericStepperRow(title: String, selection: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer()
            HStack(spacing: 8) {
                Button {
                    let next = selection.wrappedValue - 1 < range.lowerBound ? range.upperBound : selection.wrappedValue - 1
                    selection.wrappedValue = next
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ProjectWorksRevampColors.blue)

                Text("\(selection.wrappedValue)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ProjectWorksRevampColors.blue)
                    .frame(minWidth: 28, alignment: .trailing)

                Button {
                    let next = selection.wrappedValue + 1 > range.upperBound ? range.lowerBound : selection.wrappedValue + 1
                    selection.wrappedValue = next
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ProjectWorksRevampColors.blue)
            }
        }
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
        }
    }

    private func startBinding(at index: Int, fallback: Int) -> Binding<Int> {
        Binding(
            get: {
                let ranges = draft.normalizedRanges
                return ranges.indices.contains(index) ? ranges[index].startDay : fallback
            },
            set: { newStart in
                var ranges = draft.normalizedRanges
                guard ranges.indices.contains(index) else { return }
                ranges[index].startDay = PaymentRunDateRange.clampDay(newStart)
                ranges[index].endDay = PaymentRunDateRange.defaultEndDay(for: newStart)
                draft.paymentRunDateRanges = ranges
            }
        )
    }

    private func endBinding(at index: Int, fallback: Int) -> Binding<Int> {
        Binding(
            get: {
                let ranges = draft.normalizedRanges
                return ranges.indices.contains(index) ? ranges[index].endDay : fallback
            },
            set: { newEnd in
                var ranges = draft.normalizedRanges
                guard ranges.indices.contains(index) else { return }
                ranges[index].endDay = PaymentRunDateRange.clampDay(newEnd)
                draft.paymentRunDateRanges = ranges
            }
        )
    }

    private func paymentDateBinding(at index: Int, fallback: Int) -> Binding<Int> {
        Binding(
            get: {
                let dates = draft.normalizedPaymentDates
                return dates.indices.contains(index) ? dates[index] : fallback
            },
            set: { newValue in
                var dates = draft.normalizedPaymentDates
                let clamped = PaymentRunDateRange.clampDay(newValue)
                if dates.indices.contains(index) {
                    dates[index] = clamped
                } else {
                    dates.append(clamped)
                }
                draft.paymentDates = Array(dates.prefix(2))
            }
        )
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        coverageWarning = nil
        defer { isSaving = false }

        if let overlap = draft.paymentRunRangesOverlapWarning() {
            coverageWarning = overlap
            return
        }

        if let warning = draft.fullMonthCoverageWarning() {
            coverageWarning = warning
            return
        }

        do {
            try await firebaseBackend.updateOrganizationInvoicingSettings(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

