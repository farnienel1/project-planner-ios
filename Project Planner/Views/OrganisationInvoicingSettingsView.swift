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
        Form {
            Section {
                DisclosureGroup("How payment runs should be configured", isExpanded: $showHelp) {
                    Text("Date ranges need to cover the full month (days 1 to 31).")
                    Text("You can set one range or two ranges. Wrapped ranges are supported (for example 27 to 11).")
                    Text("For shorter months, invoice generation trims the run to that month’s last day.")
                }
                .font(.subheadline)
            }

            Section("Payment runs") {
                Picker("Mode", selection: $draft.paymentRunMode) {
                    Text("Set payment run date ranges").tag(PaymentRunConfigurationMode.dateRanges)
                    Text("Choose recurring timeframe").tag(PaymentRunConfigurationMode.recurringTimeframe)
                }
                .pickerStyle(.segmented)

                if draft.paymentRunMode == .dateRanges {
                    ForEach(Array(draft.normalizedRanges.enumerated()), id: \.element.id) { index, item in
                        HStack {
                            Picker("Start", selection: startBinding(at: index, fallback: item.startDay)) {
                                ForEach(1...31, id: \.self) { day in
                                    Text("\(day)").tag(day)
                                }
                            }
                            Picker("End", selection: endBinding(at: index, fallback: item.endDay)) {
                                ForEach(1...31, id: \.self) { day in
                                    Text("\(day)").tag(day)
                                }
                            }
                        }
                    }

                    if draft.normalizedRanges.count < 2 {
                        Button {
                            var ranges = draft.normalizedRanges
                            let start = (ranges.first?.endDay ?? 1) == 31 ? 1 : (ranges.first?.endDay ?? 1) + 1
                            ranges.append(PaymentRunDateRange(startDay: start, endDay: PaymentRunDateRange.defaultEndDay(for: start)))
                            draft.paymentRunDateRanges = ranges
                        } label: {
                            HStack {
                                Text("Add payment run date range")
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                } else {
                    Text("In arrears: Monday to Sunday (of the previous week)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Payment date/dates") {
                Picker("Date mode", selection: $draft.paymentDateMode) {
                    Text("Set Payment date/s").tag(PaymentDateConfigurationMode.specificDates)
                    Text("Recurring payment date").tag(PaymentDateConfigurationMode.recurringDate)
                }
                .pickerStyle(.segmented)

                if draft.paymentDateMode == .specificDates {
                    let dates = draft.normalizedPaymentDates
                    Picker("Payment date 1", selection: paymentDateBinding(at: 0, fallback: dates.first ?? 1)) {
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day)").tag(day)
                        }
                    }
                    if dates.count > 1 {
                        Picker("Payment date 2", selection: paymentDateBinding(at: 1, fallback: dates[1])) {
                            ForEach(1...31, id: \.self) { day in
                                Text("\(day)").tag(day)
                            }
                        }
                    }
                } else {
                    Picker("Recurring payment date", selection: $draft.recurringPaymentDay) {
                        ForEach(RecurringPaymentDay.allCases) { day in
                            Text("Every \(day.title)").tag(day)
                        }
                    }
                }
            }

            if let coverageWarning {
                Section {
                    Text(coverageWarning)
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Save Payment Run")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .listRowBackground(Color.blue)
                .foregroundStyle(.white)
                .disabled(isSaving)
            }
        }
        .navigationTitle("Invoicing")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draft = firebaseBackend.currentOrganization?.settings.invoicing ?? .default
        }
        .onChange(of: draft.paymentRunMode) { _, mode in
            if mode == .recurringTimeframe {
                draft.paymentDateMode = .recurringDate
                draft.recurringPaymentRunSummary = "In arrears: Monday to Sunday (previous week)"
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

