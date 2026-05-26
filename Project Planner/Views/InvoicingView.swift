//
//  InvoicingView.swift
//  Project Planner
//

import SwiftUI

struct InvoicingView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @EnvironmentObject var userStore: UserStore

    private var settings: OrganizationInvoicingSettings {
        firebaseBackend.currentOrganization?.settings.invoicing ?? .default
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !userStore.canAccessInvoicing() {
                        ContentUnavailableView(
                            "Invoicing unavailable",
                            systemImage: "lock.fill",
                            description: Text("Invoicing is visible for self-employed users only.")
                        )
                    } else {
                        paymentSummaryCard
                        NavigationLink {
                            GenerateInvoiceView(settings: settings)
                        } label: {
                            Text("Invoice")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Invoicing")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var paymentSummaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Payment run(s)")
                .font(.headline)
            if settings.paymentRunMode == .dateRanges {
                ForEach(settings.normalizedRanges, id: \.id) { range in
                    Text("• \(range.startDay) to \(range.endDay)")
                        .font(.subheadline)
                }
            } else {
                Text("• \(settings.recurringPaymentRunSummary)")
                    .font(.subheadline)
            }

            Divider()

            Text("Payment date(s)")
                .font(.headline)
            if settings.paymentDateMode == .specificDates {
                ForEach(settings.normalizedPaymentDates, id: \.self) { day in
                    Text("• Day \(day)")
                        .font(.subheadline)
                }
            } else {
                Text("• Every \(settings.recurringPaymentDay.title)")
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}

private struct GenerateInvoiceView: View {
    let settings: OrganizationInvoicingSettings
    @State private var selectedRun = -1
    @State private var referenceMonth = Date()

    private var runOptions: [String] {
        if settings.paymentRunMode == .recurringTimeframe {
            return [settings.recurringPaymentRunSummary]
        }
        let daysInMonth = Calendar.current.range(of: .day, in: .month, for: referenceMonth)?.count ?? 31
        return settings.normalizedRanges.map { range in
            let boundedEnd = min(range.endDay, daysInMonth)
            if range.startDay <= range.endDay {
                return "\(range.startDay)-\(range.endDay) (this month: \(range.startDay)-\(boundedEnd))"
            }
            return "\(range.startDay)-\(range.endDay) (this month wraps to day \(daysInMonth))"
        }
    }

    var body: some View {
        Form {
            Section("Payment run") {
                DatePicker("Invoice month", selection: $referenceMonth, displayedComponents: [.date])
                Picker("Select run", selection: $selectedRun) {
                    Text("Choose payment run").tag(-1)
                    ForEach(Array(runOptions.enumerated()), id: \.offset) { idx, label in
                        Text(label).tag(idx)
                    }
                }
            }

            Section {
                Button("Generate Invoice") { }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    .tint(selectedRun >= 0 ? .green : .gray)
                    .disabled(selectedRun < 0)
            }
        }
        .navigationTitle("Generate Invoice")
        .navigationBarTitleDisplayMode(.inline)
    }
}

