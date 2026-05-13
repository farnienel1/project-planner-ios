//
//  AnnualLeaveEntitlementEditor.swift
//  Project Planner
//
//  Shared controls for days/year window/carry-over (Add user + Manage users).
//

import SwiftUI

struct AnnualLeaveEntitlementEditor: View {
    @Binding var daysText: String
    @Binding var startMonth: Int
    @Binding var endMonth: Int
    @Binding var carriesOver: Bool
    var isEnabled: Bool = true

    private var monthSymbols: [String] { AnnualLeavePolicy.shortMonthSymbols() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Days per year")
                    .font(.subheadline.weight(.semibold))
                TextField("e.g. 25", text: $daysText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isEnabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Company leave year")
                    .font(.subheadline.weight(.semibold))
                Text("Runs from the first day of the start month through the last day of the end month (e.g. April → March).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Picker("From month", selection: $startMonth) {
                        ForEach(1...12, id: \.self) { m in
                            Text(monthSymbols[m - 1]).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!isEnabled)

                    Text("→")
                        .foregroundStyle(.secondary)

                    Picker("To month", selection: $endMonth) {
                        ForEach(1...12, id: \.self) { m in
                            Text(monthSymbols[m - 1]).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!isEnabled)
                }
            }

            Toggle(isOn: $carriesOver) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Carry unused days into next leave year")
                        .font(.subheadline.weight(.semibold))
                    Text("Unused allowance from the previous leave year is added to this year’s balance (after booked and pending time in that year).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!isEnabled)
        }
    }
}
