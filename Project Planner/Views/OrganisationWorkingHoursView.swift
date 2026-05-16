//
//  OrganisationWorkingHoursView.swift
//  Project Planner
//
//  Edits organisations/{orgId}.payrollTimePolicy — standard day, break window, weekday/weekend OT.
//

import SwiftUI

struct OrganisationWorkingHoursView: View {
    @EnvironmentObject var firebaseBackend: FirebaseBackend
    @Environment(\.dismiss) private var dismiss

    @State private var draft = OrgPayrollTimePolicy.default
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Standard day start (HH:mm)", text: $draft.standardDayStart)
                    .textInputAutocapitalization(.never)
                TextField("Standard day end (HH:mm)", text: $draft.standardDayEnd)
                    .textInputAutocapitalization(.never)

                Stepper("Unpaid break: \(draft.unpaidBreakMinutes) min", value: $draft.unpaidBreakMinutes, in: 0...120, step: 5)

                TextField("Break window start", text: $draft.breakWindowStart)
                    .textInputAutocapitalization(.never)
                TextField("Break window end", text: $draft.breakWindowEnd)
                    .textInputAutocapitalization(.never)

                Stepper("Standard paid hours (full day): \(draft.standardPaidHours, specifier: "%.1f")", value: $draft.standardPaidHours, in: 1...12, step: 0.5)
            } header: {
                Text("Standard day (Mon–Fri reference)")
            } footer: {
                Text("Clock times use 24h format (e.g. 07:30). Mon–Fri hours outside this window are treated as overtime at the weekday multiplier below.")
            }

            Section {
                HStack {
                    Text("Weekday OT (outside standard window)")
                    Spacer()
                    TextField("×", value: $draft.weekdayOutsideStandardMultiplier, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 56)
                }
            } footer: {
                Text("Applies Monday–Friday to time worked outside the standard day window.")
            }

            weekendSection(title: "Saturday", settings: $draft.saturday, referenceStart: $draft.standardDayStart)
            weekendSection(title: "Sunday", settings: $draft.sunday, referenceStart: $draft.standardDayStart)

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
                        Task { await save() }
                    }
                    .disabled(!isFormValid)
                }
            }
        }
        .onAppear {
            if let p = firebaseBackend.currentOrganization?.settings.payrollTimePolicy {
                draft = p
            }
        }
    }

    private var isFormValid: Bool {
        isValidHM(draft.standardDayStart)
            && isValidHM(draft.standardDayEnd)
            && isValidHM(draft.breakWindowStart)
            && isValidHM(draft.breakWindowEnd)
            && draft.standardPaidHours > 0
            && draft.weekdayOutsideStandardMultiplier > 0
            && weekendValid(draft.saturday)
            && weekendValid(draft.sunday)
    }

    private func weekendValid(_ w: OrgWeekendDayPayrollSettings) -> Bool {
        if w.allHoursMultiplier <= 0 || w.outsideStandardWindowMultiplier <= 0 { return false }
        if w.allHoursAtMultiplierMode { return true }
        guard w.useCustomStandardDayWindow else { return false }
        guard let s = w.customStandardStart, let e = w.customStandardEnd,
              isValidHM(s), isValidHM(e) else { return false }
        return true
    }

    @ViewBuilder
    private func weekendSection(title: String, settings: Binding<OrgWeekendDayPayrollSettings>, referenceStart: Binding<String>) -> some View {
        Section {
            Toggle("All hours at multiplier", isOn: Binding(
                get: { settings.wrappedValue.allHoursAtMultiplierMode },
                set: { on in
                    var w = settings.wrappedValue
                    w.allHoursAtMultiplierMode = on
                    if on {
                        w.useCustomStandardDayWindow = false
                    } else {
                        w.useCustomStandardDayWindow = true
                        if w.customStandardStart == nil {
                            w.customStandardStart = referenceStart.wrappedValue
                        }
                        if w.customStandardEnd == nil {
                            w.customStandardEnd = "13:00"
                        }
                    }
                    settings.wrappedValue = w
                }
            ))

            if settings.wrappedValue.allHoursAtMultiplierMode {
                Text("All hours on \(title) will be at the multiplier rate. Paid time still assumes a \(draft.unpaidBreakMinutes)-minute unpaid break when calculating hours, unless removed on a booking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Multiplier")
                Spacer()
                TextField("×", value: Binding(
                    get: { settings.wrappedValue.allHoursMultiplier },
                    set: { settings.wrappedValue.allHoursMultiplier = $0 }
                ), format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 64)
            }

            if !settings.wrappedValue.allHoursAtMultiplierMode {
                Toggle("Custom standard day window", isOn: Binding(
                    get: { settings.wrappedValue.useCustomStandardDayWindow },
                    set: { on in
                        var w = settings.wrappedValue
                        w.useCustomStandardDayWindow = on
                        if on {
                            if w.customStandardStart == nil { w.customStandardStart = referenceStart.wrappedValue }
                            if w.customStandardEnd == nil { w.customStandardEnd = "13:00" }
                        }
                        settings.wrappedValue = w
                    }
                ))

                Text("Set a custom timeframe that defines a full day on \(title). We assume this range accounts for \(draft.standardPaidHours, specifier: "%.1f") paid hours (industry standard), with no break deducted inside the band. Hours outside the window use the multiplier below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Window start (HH:mm)", text: Binding(
                    get: { settings.wrappedValue.customStandardStart ?? "" },
                    set: { settings.wrappedValue.customStandardStart = $0.isEmpty ? nil : $0 }
                ))
                .textInputAutocapitalization(.never)

                TextField("Window end (HH:mm)", text: Binding(
                    get: { settings.wrappedValue.customStandardEnd ?? "" },
                    set: { settings.wrappedValue.customStandardEnd = $0.isEmpty ? nil : $0 }
                ))
                .textInputAutocapitalization(.never)

                HStack {
                    Text("Outside window · multiplier")
                    Spacer()
                    TextField("×", value: Binding(
                        get: { settings.wrappedValue.outsideStandardWindowMultiplier },
                        set: { settings.wrappedValue.outsideStandardWindowMultiplier = $0 }
                    ), format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 64)
                }
            }
        } header: {
            Text(title)
        }
    }

    private func save() async {
        guard isFormValid else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await firebaseBackend.updateOrganizationPayrollTimePolicy(draft)
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
}
