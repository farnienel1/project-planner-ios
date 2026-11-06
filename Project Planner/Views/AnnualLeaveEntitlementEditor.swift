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
    /// Look only. `.form` is the original look (Manage Users and every existing screen); `.card` is the Add User card
    /// layout (add-user-ui-spec §4): days and months side by side, month pills. Same bindings, same month rules.
    var style: Style = .form

    enum Style {
        case form
        case card
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        switch style {
        case .form:
            formBody
        case .card:
            cardBody
        }
    }

    private var formBody: some View {
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

    /// Add User card layout. The same `daysText`, `startSelection`, `endSelection` and `carriesOver` as `formBody`.
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
            layout {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Days per year")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("e.g. 25", text: $daysText)
                            .accessibilityIdentifier("annualLeaveEntitlementEditor.eG25")
                            .keyboardType(.decimalPad)
                            .monospacedDigit()
                            .disabled(!isEnabled)
                        Text("days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .ppFormField()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Company leave year")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        monthPill(title: "From month", selection: startSelection, identifier: "annualLeaveEntitlementEditor.fromMonth")
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        monthPill(title: "To month", selection: endSelection, identifier: "annualLeaveEntitlementEditor.toMonth")
                    }
                }
            }

            Text("Runs from the first day of the start month through the last day of the end month (e.g. April → March).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let leaveYearError {
                Text(leaveYearError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("annualLeaveEntitlementEditor.leaveYearError")
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
            .tint(PPAddUserColor.selected)
            .disabled(!isEnabled)
        }
    }

    /// A month pill: the same Picker and binding as `formBody`, inside a Menu so it can look like a pill.
    private func monthPill(title: String, selection: Binding<Int>, identifier: String) -> some View {
        let shown = monthSymbols[min(max(selection.wrappedValue, 1), 12) - 1]
        return Menu {
            Picker(title, selection: selection) {
                ForEach(1...12, id: \.self) { m in
                    Text(monthSymbols[m - 1]).tag(m)
                }
            }
        } label: {
            Text(shown)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PPColor.brand)
                .padding(.horizontal, 14)
                .frame(minWidth: 60, minHeight: 44)
                .background(PPAddUserColor.field, in: Capsule())
                .overlay(Capsule().strokeBorder(PPBookingColor.cardBorder, lineWidth: 0.5))
        }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityValue(shown)
        .disabled(!isEnabled)
    }
}
