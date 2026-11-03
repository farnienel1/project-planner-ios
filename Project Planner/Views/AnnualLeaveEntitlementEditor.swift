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

    /// RULEBOOK 1.12.0 §4.4: a leave year is 12 months, so the end follows the start (`leaveYearEndMonth`).
    private var startSelection: Binding<Int> {
        Binding(
            get: { startMonth },
            set: { next in
                startMonth = next
                if let end = CanonicalBusinessEngine.leaveYearEndMonth(startMonth: next) { endMonth = end }
            }
        )
    }

    /// Picking the end month moves the start to the month whose `leaveYearEndMonth` it is (12 months either way).
    private var endSelection: Binding<Int> {
        Binding(
            get: { endMonth },
            set: { next in
                endMonth = next
                if let start = CanonicalBusinessEngine.leaveYearStartMonth(endingIn: next) { startMonth = start }
            }
        )
    }

    /// `validateLeaveYearMonths` for the months on screen (a stored mismatch shows until it is fixed).
    private var leaveYearError: String? {
        CanonicalBusinessEngine.leaveYearMonthsError(startMonth: startMonth, endMonth: endMonth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Days per year")
                    .font(.subheadline.weight(.semibold))
                TextField("e.g. 25", text: $daysText)
                    .accessibilityIdentifier("annualLeaveEntitlementEditor.eG25")
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
                    Picker("From month", selection: startSelection) {
                        ForEach(1...12, id: \.self) { m in
                            Text(monthSymbols[m - 1]).tag(m)
                        }
                    }
                    .accessibilityIdentifier("annualLeaveEntitlementEditor.fromMonth")
                    .pickerStyle(.menu)
                    .disabled(!isEnabled)

                    Text("→")
                        .foregroundStyle(.secondary)

                    Picker("To month", selection: endSelection) {
                        ForEach(1...12, id: \.self) { m in
                            Text(monthSymbols[m - 1]).tag(m)
                        }
                    }
                    .accessibilityIdentifier("annualLeaveEntitlementEditor.toMonth")
                    .pickerStyle(.menu)
                    .disabled(!isEnabled)
                }
                if let leaveYearError {
                    Text(leaveYearError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("annualLeaveEntitlementEditor.leaveYearError")
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
            .accessibilityIdentifier("annualLeaveEntitlementEditor.carryUnusedDaysIntoNextLeave")
            .disabled(!isEnabled)
        }
    }
}
